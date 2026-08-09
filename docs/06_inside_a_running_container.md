# Inside a Running Container

This document covers what happens inside a SONiC container once Docker starts it — how the entrypoint generates runtime configuration, how supervisord manages the daemons, how logging works, and how health monitoring detects failures and triggers recovery. For how containers are started and managed from the host, see [Container Run Time](05_container_run_time.md).

## 1. The Entrypoint Script

Once Docker starts the container, the entrypoint from the Dockerfile begins executing. Everything from here happens inside the container's isolated environment.

The entrypoint (`/usr/bin/docker-init.sh` for most containers) performs one-time setup and then hands off. Its central job is **rendering this container's configuration from the live database**:

```bash
sonic-cfggen -d \
    -t /usr/share/sonic/templates/ports.json.j2,/etc/swss/config.d/ports.json \
    -t /usr/share/sonic/templates/critical_processes.j2,/etc/supervisor/critical_processes \
    -t /usr/share/sonic/templates/watchdog_processes.j2,/etc/supervisor/watchdog_processes \
    -t /usr/share/sonic/templates/supervisord.conf.j2,/etc/supervisor/conf.d/supervisord.conf

exec /usr/local/bin/supervisord
```

The `-d` flag tells `sonic-cfggen` to read from CONFIG_DB, and each `-t template,output` pair renders one template to one file. This is why the templates were merely copied into the image at build time: their content depends on the switch's actual configuration, which does not exist until the device is running. On a fabric-only ASIC, for instance, the rendered `supervisord.conf` contains a different set of daemons than on a regular switching ASIC.

Note that even **supervisord's own configuration** is generated this way — it is a runtime artifact, not a build artifact. The same goes for `critical_processes` and `watchdog_processes`, two health-monitoring lists that tell the container which daemons are essential and which should be watched for hangs. Section 3 explains how these lists are used.

The script also runs platform-specific and HWSKU-specific init hooks if the vendor provides them, then `exec`s supervisord — replacing itself, so supervisord becomes PID 1 inside the container.

## 2. supervisord: The In-Container Process Manager

Each SONiC container runs several cooperating daemons. **supervisord** — a small Python process manager — starts and supervises them.

**Why not systemd inside the container?** systemd is built to manage an entire machine: hardware initialization, kernel parameters, mount points, cgroups, hundreds of units. A container needs none of that. supervisord does exactly one job — run and watch a handful of processes in a single environment — which makes it a much better fit, and much lighter.

What supervisord provides in SONiC:

- Starts the container's daemons and keeps them running as child processes.
- Captures each daemon's stdout and stderr and forwards them to syslog.
- Emits **events** (a process started, a process exited) to registered **event listeners** — small helper programs that can act on those events. SONiC's health monitoring, covered in Section 3, is built entirely on this mechanism.

A typical program entry looks like this:

```ini
[program:orchagent]
command=/usr/bin/orchagent.sh
autostart=false
autorestart=false
stdout_logfile=NONE
stdout_syslog=true
dependent_startup=true
dependent_startup_wait_for=portsyncd:running
```

Two of these settings surprise people.

### Startup Ordering: Why autostart Is false

Almost every SONiC program sets `autostart=false`, so supervisord does *not* launch it at boot. Ordering is delegated instead to the **`supervisord-dependent-startup`** plugin, which runs as an event listener and starts each program only once its declared prerequisites are satisfied.

A program can wait for another to be *running* (`dependent_startup_wait_for=portsyncd:running`) or, for one-shot setup tasks, to have *finished* (`dependent_startup_wait_for=swssconfig:exited`). In the SWSS container this produces a chain: rsyslogd starts first so nothing logs into the void, then portsyncd populates port state, then orchagent, then swssconfig loads static configuration, and so on. Plain supervisord priorities could not express "wait until this other process is actually ready."

### Restart Policy: Why autorestart Is Mostly false

Critical SONiC daemons set `autorestart=false`. When orchagent dies, supervisord does *not* restart it.

This is intentional. Restarting orchagent alone would leave it out of sync with everything else — stale entries in APPL_DB, ASIC state that no longer matches, half-applied configuration. The safe recovery is to restart the whole container so every daemon re-initializes from a known state together. Section 3 describes how that is triggered.

Helper programs that are genuinely independent do use `autorestart=unexpected`, meaning "restart only if the exit code was not one of the expected ones." One-shot tasks such as `swssconfig` are expected to exit, and their exit is not treated as a failure.

### Logging: rsyslog and Log Forwarding

Notice `stdout_logfile=NONE` and `stdout_syslog=true` in the program block above. Daemons do not write their own log files. Everything goes to syslog, and each container runs its own **rsyslogd** to handle it.

The container's rsyslogd does not write files either. It tags every message with the container name and forwards the lot to the host over **RELP** (a reliable syslog transport) on port 2514:

```
orchagent (stdout/stderr)
    → supervisord captures it
        → container's rsyslogd tags it "swss#orchagent"
            → RELP to host port 2514
                → host rsyslogd
                    → /var/log/syslog
```

Centralizing on the host has real advantages: one chronological view of the entire system, log rotation managed in one place, no risk of a container filling its own filesystem, and logs that survive the container being destroyed and recreated. From the host, everything is in `/var/log/syslog`:

```bash
# All messages from the swss container
grep 'swss#' /var/log/syslog

# Follow orchagent live
tail -f /var/log/syslog | grep orchagent
```

A few components with high log volume get dedicated files on the host — `/var/log/frr/bgpd.log`, `/var/log/frr/zebra.log`, `/var/log/teamd.log`, `/var/log/telemetry.log` — configured by host-side rsyslog rules. The host can also forward everything onward to an external syslog server.

## 3. Health Monitoring and Failure Recovery

SONiC monitors health at two levels: individual processes inside the container, and the container as a whole on the host. This section works from the inside out.

### Critical Processes

Not every process in a container matters equally. Each container declares a list of **critical processes** — the ones without which it cannot do its job — rendered at container startup to `/etc/supervisor/critical_processes`.

In the SWSS container the list includes `orchagent`, `portsyncd`, `neighsyncd`, and the various `*mgrd` manager daemons. If `orchagent` dies, nothing can be programmed into the ASIC and the container is useless. By contrast `swssconfig` (a one-shot that loads static configuration and exits) and `countersyncd` are not on the list; their absence degrades the container but does not break it.

The list is generated from a template, so it adapts to the device: on a fabric-only ASIC most of the manager daemons do not run and are correctly left off the list.

### The Process Exit Listener

Monitoring is implemented by a supervisord event listener called **`supervisor-proc-exit-listener`**, which runs in every SONiC container and subscribes to supervisord's event stream. When a process exits, this is what happens:

1. Supervisord emits a `PROCESS_STATE_EXITED` event.
2. The listener checks whether the exit was **expected** — a one-shot task finishing normally. If so, nothing happens.
3. The listener checks whether the process appears in `/etc/supervisor/critical_processes`. If not, nothing happens.
4. For an unexpected exit of a critical process, the listener reads `auto_restart` for this container from the FEATURE table in CONFIG_DB and branches:
   - **`enabled`** — it logs the failure, publishes a system event, and sends `SIGTERM` to its parent process, which is supervisord (PID 1). Supervisord shuts down, every remaining daemon goes with it, and the container exits.
   - **`disabled`** — the container is deliberately left running in its degraded state, and the listener writes a warning to syslog once a minute (`Process 'orchagent' is not running in namespace 'host' (3 minutes).`) until the process comes back or an operator intervenes.

Step 4 is where the design becomes clear: **the recovery action is to kill the container, not to fix it.** Container death is the signal, and the host is what acts on it.

### Detecting Stuck Processes

A crashed process is easy to spot. A process that is still alive but no longer doing anything is harder, and a hung orchagent is just as damaging as a dead one.

For this, a container can also declare a list of **watchdog processes** in `/etc/supervisor/watchdog_processes`. Those processes periodically emit a heartbeat on stdout; the same exit listener records the timestamp of each one. If a heartbeat does not arrive within its configured interval — the default is 60 seconds, adjustable per process through the `HEARTBEAT` table in CONFIG_DB — the listener logs a warning that the process is stuck. Unlike a critical-process exit, a missed heartbeat raises an alert but does not tear the container down, because a slow process is not always a broken one.

### From Container Exit to systemd Restart

Recall from the [runtime document](05_container_run_time.md) that `ExecStart` is blocked in `docker wait`. When the container exits, that call returns:

1. `ExecStart` (`swss.sh wait`) returns, so systemd sees the unit stop.
2. Systemd consults the effective restart policy — `Restart=always` if `auto_restart` is enabled in the FEATURE table, `Restart=no` if it is not.
3. If restarting, systemd waits `RestartSec` (30 seconds) and starts the unit again from `ExecStartPre`, which re-runs the whole sequence: service script, container control script, `docker start`, entrypoint, supervisord, daemons.
4. If more than `StartLimitBurst` (3) start attempts occur within `StartLimitIntervalSec` (1200 seconds), systemd gives up and marks the unit **failed**.

The rate limit exists to stop a crash loop from consuming the CPU and flooding the logs forever. A persistently broken container should end up in a stable, visible failed state rather than thrashing.

Recovering from the failed state requires an explicit operator action, which is the point — it means someone has looked at the logs:

```bash
systemctl status swss.service            # Why did it fail?
sudo systemctl reset-failed swss.service # Clear the failure counter
sudo systemctl restart swss.service      # Try again
```

### The Complete Failure-Handling Chain

```
Non-critical process exits
    → Listener sees it is not in critical_processes
        → Nothing happens at container level
        → (if autorestart=unexpected, supervisord restarts just that process)

Watchdog process stops sending heartbeats
    → Listener logs "stuck" warning to syslog
        → Container keeps running; operator investigates

Critical process exits unexpectedly
    → Listener reads auto_restart from the FEATURE table
    ├── disabled → syslog warning every 60s, container stays up but degraded
    └── enabled  → listener SIGTERMs supervisord → container exits
                     → "docker wait" returns → ExecStart exits
                         → systemd restarts the unit after RestartSec
                             → if >3 attempts in 1200s: unit marked failed,
                                manual reset-failed required
```

## 4. Putting It All Together

The full chain from power-on to a working container, with each layer's responsibility:

```
systemd starts the unit (swss.service)
    │
    ├─ ExecStartPre: /usr/local/bin/swss.sh start          [service script]
    │      → waits for Redis to answer and CONFIG_DB_INITIALIZED=1
    │      → flushes stale APPL_DB / ASIC_DB / COUNTERS_DB state
    │      → calls /usr/bin/swss.sh start                  [control script]
    │             → docker create (first boot) or docker start
    │                    → /usr/bin/docker-init.sh runs    [entrypoint, in container]
    │                           → sonic-cfggen renders config from CONFIG_DB
    │                           → exec supervisord         [process manager]
    │                                  → dependent-startup launches daemons in order
    │                                  → exit listener begins monitoring
    │
    ├─ ExecStart: /usr/local/bin/swss.sh wait
    │      → starts peer containers (syncd, bgp, teamd, ...)
    │      → blocks in "docker wait" for as long as the container lives
    │
    └─ ExecStop: /usr/local/bin/swss.sh stop
               → stops peers, then stops the container
```

| Where | Component | Responsibility |
|-------|-----------|----------------|
| Host | systemd | *When* to start and stop; dependency ordering; restart policy and rate limiting |
| Host | `featured` | Applies FEATURE table settings by masking units and writing restart drop-ins |
| Host | Service script (`/usr/local/bin/`) | SONiC-specific preconditions: wait for Redis, clean stale state, manage peer containers, handle warm/fast boot |
| Host | Control script (`/usr/bin/`) | *How* to run the container: create versus start, mounts, network mode, environment |
| Container | Entrypoint script | Generates the container's runtime configuration from Redis |
| Container | supervisord | Starts and supervises the container's daemons |
| Container | dependent-startup listener | Enforces startup ordering between daemons |
| Container | Process exit listener | Detects critical failures and stuck processes; triggers container-level recovery |

## 5. Inspecting a Running System

Commands worth knowing when something looks wrong, roughly in the order you would use them:

```bash
# Which containers are up, and for how long?
docker ps

# What does systemd think of a unit, and what were its last log lines?
systemctl status swss.service
journalctl -u swss.service -n 50

# Which features are enabled, and which restart automatically?
show feature status

# What is running inside a container, and in what state?
docker exec swss supervisorctl status

# What does this container consider critical?
docker exec swss cat /etc/supervisor/critical_processes

# Restart a single daemon inside a container (for debugging only —
# this bypasses the normal whole-container recovery path)
docker exec swss supervisorctl restart orchagent

# Read the logs, which live on the host, not in the container
grep 'swss#' /var/log/syslog
```

Two diagnostic notes. First, `docker ps` showing a container restarting every 30 seconds almost always means a critical process is dying at startup — search the host syslog for `exited unexpectedly` to find which one. Second, a container that is *running* but not doing its job is often a masked-off or crashed non-critical daemon; `supervisorctl status` inside the container will show it as `EXITED` or `FATAL` while the container itself stays healthy.

---

**Previous**: [← Container Run Time](05_container_run_time.md) · **Next**: [The Database Container →](07_database_container.md)
