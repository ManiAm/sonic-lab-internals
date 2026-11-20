# Container Run Time: How the Host Manages Containers

> **Prerequisites**: This document assumes familiarity with systemd — unit files, service directives, requirement vs. ordering dependencies, and targets. For that background, see the [Linux Init Systems](https://github.com/ManiAm/linux-init-systems) companion project, especially [Unit Files](https://github.com/ManiAm/linux-init-systems/blob/master/docs/06_systemd_unit_files.md), [Service Configuration](https://github.com/ManiAm/linux-init-systems/blob/master/docs/07_systemd_services.md), [Unit Dependencies](https://github.com/ManiAm/linux-init-systems/blob/master/docs/08_systemd_dependencies.md), and [Targets](https://github.com/ManiAm/linux-init-systems/blob/master/docs/11_systemd_targets.md).

This document covers the **SONiC-specific** host-side machinery that manages containers — how SONiC wraps each container in a systemd unit, the two layers of shell scripts that create and control them, the `sonic.target` service group, SONiC's dependency and failure-propagation graphs, and the FEATURE table that lets operators enable, disable, and configure automatic restarts. For how container images are built, see [Container Build Time](04_container_build_time.md). What happens *inside* a running container is covered in [Inside a Running Container](06_inside_a_running_container.md).

## 1. How systemd Manages Containers

Once SONiC is installed on a switch, all container images are pre-loaded into Docker. systemd decides *when* to start each one, in what order, and what to do when one dies. SONiC wraps every container in a systemd unit so that containers and plain host processes (rsyslog, CLI helpers, platform services) share one interface:

```bash
sudo systemctl start swss        # Start the SWSS container
sudo systemctl stop bgp          # Stop the BGP container
systemctl status database        # Check the database container
```

### A SONiC Container Unit

Here is the SWSS unit, rendered for a single-ASIC switch:

```ini
[Unit]
Description=switch state service

After=database.service
After=config-setup.service
After=sonic.target

Requires=database.service
Requires=config-setup.service
BindsTo=sonic.target

StartLimitIntervalSec=1200
StartLimitBurst=3

[Service]
User=root
Environment=sonic_asic_platform=vs
ExecStartPre=/usr/local/bin/swss.sh start
ExecStart=/usr/local/bin/swss.sh wait
ExecStop=/usr/local/bin/swss.sh stop
RestartSec=30

[Install]
WantedBy=sonic.target
```

What matters for SONiC (for the general meaning of each directive, see the companion docs linked in the prerequisites):

| Directive | SONiC meaning |
|-----------|---------------|
| `After=database.service` / `config-setup.service` / `sonic.target` | SWSS must not start until Redis is up, CONFIG_DB is loaded/migrated, and the SONiC target is active. |
| `Requires=database.service` / `config-setup.service` | Hard dependencies — if either fails or is stopped, SWSS is stopped too. SWSS must not run against an empty database. |
| `BindsTo=sonic.target` | Ties SWSS to the SONiC service group — stopping or restarting the target stops SWSS. |
| `StartLimitBurst=3` / `StartLimitIntervalSec=1200` | At most 3 start attempts in 1200 seconds, then the unit is marked failed. |
| `RestartSec=30` | Wait 30 seconds between restart attempts. |
| `Environment=sonic_asic_platform=vs` | ASIC vendor family (`broadcom`, `mellanox`, `vs`, …). Scripts branch on it for vendor-specific steps. |
| `WantedBy=sonic.target` | Enables SWSS as part of the SONiC service group. |

Two SONiC-specific design choices stand out.

**There is no `Restart=` directive.** Most SONiC units deliberately omit it — restart policy is not a build-time constant. It is supplied at run time from the FEATURE table, described later in this document.

**`ExecStartPre` starts the container; `ExecStart` waits on it.** Nearly every SONiC container unit uses this pattern so systemd can track Docker container health:

```
ExecStartPre  → swss.sh start   → creates and starts the Docker container, then returns
ExecStart     → swss.sh wait    → blocks for as long as the container keeps running
ExecStop      → swss.sh stop    → stops the container gracefully
```

Because `ExecStart` blocks, systemd considers the unit active exactly as long as the container is alive. When the container exits, `wait` returns, `ExecStart` finishes, and systemd applies its restart policy. Without this, systemd would treat the unit as finished the instant `docker start` returned and would never notice the container dying.

For most containers, `wait` watches only that one container. `swss.sh` is the exception — its `wait` watches multiple containers at once, creating a cross-container failure coupling invisible to systemd. See [Script-Level Failure Coupling](#script-level-failure-coupling).

### The Two Scripts Behind Every Container

The unit file above references `/usr/local/bin/swss.sh` for all three operations. But SONiC actually has *two* layers of shell script per container:

| Script | Path | Origin | Responsibility |
|--------|------|--------|----------------|
| **Service script** | `/usr/local/bin/<name>.sh` | Hand-written, in `files/scripts/` | SONiC-specific orchestration: wait for Redis, flush stale database state, start and stop peer containers, handle warm/fast boot |
| **Container control script** | `/usr/bin/<name>.sh` | Generated from `docker_image_ctl.j2` | Pure Docker mechanics: `docker create`, `docker start`, `docker wait`, `docker stop` |

Note that the two files have the *same name* and differ only by directory, which is easy to misread. The service script always calls the control script; never the reverse.

Not every container needs the extra orchestration layer. Containers with cross-container dependencies or boot-mode logic (`database`, `swss`, `syncd`, `bgp`, `teamd`, `lldp`, `snmp`, `telemetry`, and a few more) have a service script. Simpler containers such as `pmon` skip it, and their unit files invoke `/usr/bin/pmon.sh` directly.

### Service Groups: `multi-user.target` and `sonic.target`

SONiC uses two targets to separate infrastructure from application services. (For how targets work in general, see [Targets and Boot Flow](https://github.com/ManiAm/linux-init-systems/blob/master/docs/11_systemd_targets.md).)

**`multi-user.target`** — SONiC places two critical services here so they start as part of ordinary system startup, before any SONiC application container:

- **`database`** — starts the Redis container. Every other SONiC service needs Redis, so this must be up first.
- **`config-setup`** — configuration initialization and migration. On a normal boot the database container itself loads `config_db.json` into Redis; `config-setup` runs afterward to apply migration hooks. On first boot to a new image (or when no configuration exists), it generates the initial configuration from minigraph, ZTP, or factory defaults and loads it into Redis. This is a one-shot host service, not a container.

By the time systemd reaches `sonic.target`, Redis is running and CONFIG_DB is loaded.

**`sonic.target`** — SONiC's own target. Every service in this group declares `BindsTo=sonic.target`, so their lifecycles are coupled to it:

```bash
sudo systemctl restart sonic.target   # Restart every SONiC container
```

This is exactly what `config reload` does internally: stop `sonic.target`, reload configuration into Redis, then restart `sonic.target`.

The `database` container is deliberately **not** in this group — it must survive a `sonic.target` restart so Redis remains available while containers re-initialize.

### Dependency Graph

SONiC has around 30 container services, each declaring its ordering constraints (`After=` / `Before=`) in a `.service.j2` template. Extracting those relationships produces the graph below. (Ordering vs. requirement dependencies are covered in [Unit Dependencies](https://github.com/ManiAm/linux-init-systems/blob/master/docs/08_systemd_dependencies.md).)

The green nodes (`config-setup` and `topology`) are host-side services, not containers. They sit at the root of the tree — no SONiC container can start until the host completes its setup. If something goes wrong at this level (e.g., a corrupt `config_db.json` stalls `config-setup`), no container will start.

An arrow from A to B means B declares `After=A` (or A declares `Before=B`) — B will not start until A is running. Most transitive edges are omitted (e.g., `database → snmp` is implied through `database → … → swss → syncd → snmp`).

```mermaid
flowchart LR
    subgraph infra ["Infrastructure"]
        database
        config-setup
        topology
    end

    subgraph core ["Core Pipeline"]
        swss
        syncd
    end

    subgraph protocol ["Protocol Services"]
        bgp
        teamd
        lldp
        stp
        macsec
        iccpd
        gbsyncd
        dash-ha
        bmp
    end

    subgraph network ["Network Services"]
        dhcp_relay
        dhcp_server
        nat
        radv
        sflow
        mux
    end

    subgraph mgmt ["Management & Monitoring"]
        pmon
        snmp
        telemetry
        gnmi
        mgmt-framework
        restapi
        sysmgr
        p4rt
    end

    database --> config-setup
    database --> swss
    database --> pmon
    database --> bmp
    config-setup --> swss
    config-setup --> pmon
    config-setup --> restapi
    topology --> swss

    swss --> syncd
    swss --> bgp
    swss --> teamd
    swss --> iccpd
    swss --> mux
    swss --> dash-ha
    swss --> gbsyncd
    swss --> p4rt
    swss --> sysmgr

    syncd --> lldp
    syncd --> snmp
    syncd --> telemetry
    syncd --> gnmi
    syncd --> mgmt-framework
    syncd --> nat
    syncd --> radv
    syncd --> sflow
    syncd --> macsec
    syncd --> dhcp_relay
    syncd --> dhcp_server
    syncd --> stp

    teamd --> dhcp_relay

    style config-setup fill:#d4edda,stroke:#155724
    style topology fill:#d4edda,stroke:#155724
```

**Layered startup.** The graph has a clear left-to-right structure — services start in waves, not all at once. Wave 1 is `database`, which belongs to `multi-user.target` and must be available before anything else. Wave 2 is `config-setup` and `topology`, which load the switch configuration and determine the topology. Wave 3 is `swss`, the orchestration brain. Wave 4 is `syncd`, `bgp`, `teamd`, and other services that need the orchestrator running. Wave 5 is the remaining services (`lldp`, `snmp`, `telemetry`, etc.) that need the full pipeline — including the ASIC connection — before they can do useful work.

**Two fan-out hubs.** Look at where the arrows concentrate. `swss` is the first hub — around nine services wait for it before they can start. `syncd` is the second hub — another twelve services wait for it. These two nodes are the **critical-path bottlenecks**: if either one takes a long time to initialize, every service downstream is delayed. No amount of parallelism elsewhere can compensate.

**Parallelism within a tier.** Once a hub finishes starting, all its dependents launch **simultaneously**. For example, the moment `swss` is ready, systemd starts `syncd`, `bgp`, `teamd`, `iccpd`, and others all in parallel — it does not wait for one to finish before starting the next. This is how SONiC keeps boot time manageable despite having around 30 services.

**The longest chain determines boot time.** The critical startup path through the graph is `database → config-setup → swss → syncd → (lldp | snmp | telemetry | …)` — five sequential hops. Total boot time is dominated by the sum of these five startup durations. Adding more services at the same depth (e.g., adding another service after `syncd`) does not increase boot time because they run in parallel. Only adding a new sequential hop would.

**Most services depend on infrastructure only transitively.** Only a handful of services (`swss`, `pmon`, `bmp`, `restapi`) have direct arrows from the infrastructure tier. Every other service inherits that dependency indirectly through `swss → syncd`. In practice, this means you rarely need to think about `database` or `config-setup` when reasoning about a specific service — just know that "swss and syncd must be up first."

**syncd gates the monitoring world.** All management and monitoring services (`snmp`, `telemetry`, `gnmi`, `mgmt-framework`) wait for `syncd`, not just `swss`. The same is true for network services (`nat`, `dhcp_relay`, `sflow`, etc.) and even `stp`. This makes sense: these services need to read hardware state — port counters, interface status, ASIC health — which is only available once `syncd` has established the connection to the ASIC through the vendor SAI.


### Failure Propagation

The graph above shows **startup ordering**. A separate question is: **when a service crashes, what else gets pulled down with it?** That is controlled by requirement dependencies (`Requires=`, `Requisite=`, `BindsTo=`, …), not by `After=` / `Before=`. For the full directive reference, see [Unit Dependencies](https://github.com/ManiAm/linux-init-systems/blob/master/docs/08_systemd_dependencies.md).

In SONiC specifically:

- Service templates use `Requires=` and `Requisite=` for hard dependencies between containers.
- Every application container declares `BindsTo=sonic.target` to tie its lifecycle to the target group.
- `Wants=` is used sparingly (only `database` uses `Wants=database-chassis.service` for an optional chassis dependency).

The fate-coupling graph below shows which of those relationships actually pull dependents down when a dependency dies. A dashed arrow from B to A means "A declares `Requires=B` or `Requisite=B`" — if B dies, A is pulled down. Only relationships between SONiC services are shown.

```mermaid
flowchart LR
    subgraph infra ["Infrastructure"]
        database
        config-setup
        topology
    end

    subgraph core ["Core Pipeline"]
        swss
        syncd
    end

    subgraph protocol ["Protocol Services"]
        bgp
        teamd
        lldp
        iccpd
        gbsyncd
        macsec
        stp
        dash-ha
        bmp
    end

    subgraph network ["Network Services"]
        dhcp_relay
        dhcp_server
        nat
        radv
        sflow
        mux
    end

    subgraph mgmt ["Management & Monitoring"]
        pmon
        snmp
        telemetry
        gnmi
        mgmt-framework
        eventd
        restapi
        otel
        sysmgr
        p4rt
    end

    database -.-> swss
    database -.-> syncd
    database -.-> bgp
    database -.-> pmon
    database -.-> gnmi
    database -.-> telemetry
    database -.-> mgmt-framework
    database -.-> otel
    database -.-> p4rt
    database -.-> sysmgr
    database -.-> bmp
    database -.-> lldp
    database -.-> gbsyncd
    database -.-> config-setup
    database -.-> mux
    database -.-> dash-ha

    config-setup -.-> swss
    config-setup -.-> syncd
    config-setup -.-> teamd
    config-setup -.-> bgp
    config-setup -.-> pmon
    config-setup -.-> lldp
    config-setup -.-> snmp
    config-setup -.-> iccpd
    config-setup -.-> nat
    config-setup -.-> dhcp_relay
    config-setup -.-> eventd
    config-setup -.-> restapi
    config-setup -.-> radv
    config-setup -.-> gbsyncd
    config-setup -.-> mux
    config-setup -.-> dash-ha

    topology -.-> swss
    topology -.-> syncd
    topology -.-> teamd

    swss -.-> iccpd
    swss -.-> macsec
    swss -.-> mux
    swss -.-> stp
    swss -.-> dash-ha
    swss -.-> dhcp_server
    swss -.-> sflow
    swss -.-> snmp

    style config-setup fill:#d4edda,stroke:#155724
    style topology fill:#d4edda,stroke:#155724
```

The key takeaway: **`database` is the single point of failure.** If the database container crashes, nearly every other service is pulled down through `Requires=`. This is by design — without Redis, no container can function, so there is no point in keeping them running.

The second critical node is **`swss`**. Eight services are directly coupled to it: `iccpd`, `macsec`, `mux`, `stp`, `dash-ha`, and `dhcp_server` declare `Requires=swss`, while `sflow` and `snmp` declare `Requisite=swss` (same fate-coupling, but systemd won't try to start swss on their behalf — it must already be running). All eight are stopped if SWSS crashes.

Notice that **`syncd` has no outgoing arrows.** If the syncd container crashes, no other service is affected — not even swss, which sits directly upstream of it. That is what systemd believes. But on a real switch, syncd crashing triggers a restart of swss *and* every service swss manages — a much larger blast radius than the graph suggests. This coupling exists, but it lives in a shell script, not in a `.service` file, so systemd cannot see it. The next section explains how it works.

#### Script-Level Failure Coupling

The systemd graph above is not the complete picture. There is a second failure-propagation path that is entirely invisible to systemd — it lives inside `swss.sh`, the service script for the SWSS container. This path is what makes syncd's death take down swss (and everything else) even though no systemd directive connects them.

**This mechanism is unique to swss.** Every other container's `wait()` function runs a plain single-container wait — if syncd's service script (`syncd.sh`) detects that swss has died, it does not react; only swss watches across container boundaries. This is a deliberate design choice: swss is the orchestration hub, so it owns the group lifecycle.

**Why not use `BindsTo=` instead?** If `swss.service` declared `BindsTo=syncd.service`, systemd would stop swss when syncd died — achieving the same effect without any script logic. But systemd would then restart them as independent units, potentially in parallel and in the wrong order. By keeping the coupling in `swss.sh`, SONiC controls the exact sequence: stop dependents first, then stop the peer, then start the peer, then start dependents. The script also handles warm-boot and fast-boot cases where the stop/restart behavior must be different.


### The FEATURE Table: Turning Containers On and Off

Not every container is needed in every deployment, and not every operator wants automatic restarts. SONiC keeps these decisions in a **FEATURE table** in CONFIG_DB, so they are configuration rather than image content.

Useful fields on each entry:

| Field | Meaning |
|-------|---------|
| `state` | `enabled` or `disabled` — whether this container should run at all. |
| `auto_restart` | `enabled` or `disabled` — whether the container is restarted automatically after a critical failure. |
| `delayed` | If set, the feature is started through a systemd `.timer` unit rather than immediately at boot. |
| `has_global_scope` / `has_per_asic_scope` | On multi-ASIC platforms (see note below), whether the feature runs once for the host, once per ASIC, or both. |
| `high_mem_alert` | Whether high-memory-usage alerting is enabled for this container. |

**A note on multi-ASIC platforms.** Most switches contain a single forwarding ASIC, but some chassis-based or high-density platforms contain multiple ASICs managed by one SONiC instance. On such a platform, containers like `swss` and `syncd` must run once *per ASIC* (e.g., `swss0`, `swss1`), each in its own Linux network namespace — because each ASIC has its own set of ports and forwarding tables. Other containers like `snmp` only need to run once for the entire device. The `has_global_scope` and `has_per_asic_scope` fields control this behavior. If you are working with a single-ASIC device, you can ignore these fields.

Operators change these through the CLI:

```bash
show feature status                          # Current state of every feature
show feature autorestart                     # Just the auto-restart settings

sudo config feature state snmp disabled      # Stop running the SNMP container
sudo config feature autorestart swss enabled # Restart SWSS automatically on failure
```

A host daemon called **`featured`** subscribes to this table and translates changes into systemd actions. It is the piece that makes a Redis value have an effect on a running system:

- **`state` changes.** `enabled` → `systemctl unmask` + `enable` + `start`. `disabled` → `systemctl stop` + `disable` + `mask`. Masking is what makes "off" stick — a masked unit cannot be started even by a dependency. (See [Masking and Unmasking](https://github.com/ManiAm/linux-init-systems/blob/master/docs/05_systemd_management.md#masking-and-unmasking-units).)

- **`auto_restart` changes.** `featured` writes a drop-in at `/etc/systemd/system/<name>.service.d/auto_restart.conf` containing either `Restart=always` or `Restart=no`, then runs `systemctl daemon-reload`. That is the missing `Restart=` from the unit file shown earlier — the shipped unit is never modified.


## 2. The Container Control Script

When the service script reaches the point of actually launching the container, it calls `/usr/bin/<name>.sh` — the script generated from `docker_image_ctl.j2`. That script accepts four operations: `start`, `wait`, `stop`, and `kill`.

Its most interesting logic is in `start`, which has to distinguish first boot from every subsequent boot:

```bash
# Simplified from /usr/bin/swss.sh
start() {
    if docker inspect swss >/dev/null 2>&1 && [ "$existing_hwsku_mount" = "$MOUNTPATH" ]; then
        preStartAction              # per-container setup that must happen before launch
        docker start swss           # Container already exists — just start it
        postStartAction             # per-container setup that needs the container running
        exit $?
    fi

    docker rm -f swss 2>/dev/null   # Exists but was created for a different HWSKU

    docker create --name swss \
        --net=host \
        -v /var/run/redis:/var/run/redis:rw \
        -v /usr/share/sonic/device/$PLATFORM/$HWSKU:/usr/share/sonic/hwsku:ro \
        --env "PLATFORM"=$PLATFORM \
        --env "CONTAINER_NAME"=swss \
        --log-opt max-size=2M --log-opt max-file=5 \
        docker-orchagent:latest

    preStartAction
    docker start swss
    postStartAction
}
```

### create Versus start

`docker create` builds the container instance from the image and fixes its volume mounts, network mode, and environment variables. Those settings cannot be changed afterwards, which is why creation happens only once. `docker start` then boots that already-configured instance, and is much faster because it skips creation.

The script recreates the container in two situations. The obvious one is that no container with that name exists — first boot after installing a new SONiC image, since each installed image carries its own Docker state. The subtler one is that a container exists but was created with a *different HWSKU* mount path. HWSKU ("hardware SKU") identifies the specific port layout and hardware profile of the switch. Because the HWSKU directory is baked in at create time, changing HWSKU requires tearing the container down and building a new one — the script detects this by comparing the existing mount against the current configuration.

### What the create Options Do

| Option | Why it is there |
|--------|-----------------|
| `--net=host` | The container shares the host's network namespace, so it sees `Ethernet0`, `PortChannel1`, and every other interface directly. Networking daemons need this to manage interfaces and receive Netlink events. |
| `-v /var/run/redis:/var/run/redis:rw` | Mounts the host directory holding the Redis Unix sockets (`redis.sock`) and `sonic-db/database_config.json`. This is how a container reaches Redis running in a *different* container, without any network hop. |
| `-v .../$PLATFORM/$HWSKU:/usr/share/sonic/hwsku:ro` | Exposes this switch's hardware profile — port configuration, buffer profiles, SAI settings — read-only. |
| `--env PLATFORM=...`, `--env CONTAINER_NAME=...` | Identify the hardware platform and the container's own name. The platform string (for example `x86_64-broadcom_td3-r0`, or `vs` for the virtual switch) selects platform-specific drivers and config files; the container name is used to tag log messages. |
| `--log-opt max-size=2M --log-opt max-file=5` | Caps Docker's own log capture so a chatty container cannot fill the disk. |

Vendor and container specifics are layered on top of these. The syncd container gets ASIC device nodes and shared memory; pmon gets I²C, CPLD, and other hardware devices; the BGP container gets a writable `/etc/frr`.

### The preStartAction and postStartAction Hooks

The template defines two per-container hooks. They are how one generic script serves thirty different containers:

- **`preStartAction`** runs after the container is created but before it starts. The database container uses it to place a saved Redis dump into the container for a warm reboot; the SNMP container uses it to publish the chassis serial number into STATE_DB.
- **`postStartAction`** runs once the container is up. The database container waits here until Redis answers `PING`, loads `config_db.json`, runs the database schema migrator, and sets the `CONFIG_DB_INITIALIZED` flag — which is precisely the flag every other container's service script waits for.

### stop and kill

`stop` asks Docker to shut the container down gracefully, giving processes time to flush state. Some containers get a longer grace period: teamd is allowed 60 seconds so port-channels can be torn down cleanly. `kill` terminates immediately and is reserved for warm and fast reboot, where the goal is to freeze state rather than unwind it.

### What About Container State?

A common question from beginners: if a container is destroyed and recreated, does it lose its data? The short answer is **no** — all important state lives in Redis, which runs in a separate container with its own persistent storage. When a container restarts, its entrypoint regenerates configuration files from the current contents of Redis (as the [next document](06_inside_a_running_container.md) describes). This is exactly why SONiC uses a database-centric design: containers are disposable, but the state they depend on persists in Redis across restarts.

---

**Previous**: [← Container Build Time](04_container_build_time.md) · **Next**: [Inside a Running Container →](06_inside_a_running_container.md)
