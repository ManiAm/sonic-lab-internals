# Config Reload

> **Prerequisites**: [Configuration Management](17_configuration_management.md) (CONFIG_DB, config_db.json, and the configuration flow) and [Container Run Time](05_container_run_time.md) (systemd lifecycle and service dependencies).

`config reload` replaces the entire running configuration with the contents of a JSON file — by default `/etc/sonic/config_db.json`, or a user-specified file. It stops all SONiC service containers, erases every entry in CONFIG_DB, loads the new file into CONFIG_DB, and restarts the services. Every container re-initializes and the forwarding chip (ASIC) is reprogrammed from scratch.

Unlike a reboot, `config reload` does not restart the Linux kernel or power-cycle the hardware. Only the SONiC application layer is cycled, making it faster than a full reboot while still performing a complete configuration replacement.


## Command Syntax

```bash
# Reload from default /etc/sonic/config_db.json (prompts for confirmation)
sudo config reload

# Reload without confirmation prompt
sudo config reload -y

# Reload from a specific file
sudo config reload /path/to/new_config.json

# Load config into CONFIG_DB without restarting services
# Used during boot or when you want to pre-stage a configuration and restart containers yourself later
sudo config reload -n
```


## What Happens Step by Step

The following is the complete sequence from the moment the user runs `config reload` to a fully converged system.

```
 1. User runs: sudo config reload [filename]

 2. Sanity checks
    - Is the system healthy? Are essential services (database, swss) running?
    - If checks fail, the command aborts with an error.

 3. systemctl stop sonic.target
    - Systemd stops all SONiC service containers in reverse dependency order.
    - The database container is NOT part of sonic.target, so Redis
      stays running throughout the entire process.

 4. CONFIG_DB is flushed — every key is deleted.

 5. New configuration is loaded from the file into CONFIG_DB.
    - Default: /etc/sonic/config_db.json
    - Or: user-specified file

 6. Host services are reconfigured
    - hostname-config, interfaces-config, ntp-config, rsyslog-config

 7. systemctl start sonic.target
    - Systemd starts all SONiC service containers in dependency order.

 8. Manager daemons inside the containers read CONFIG_DB, configure the
    Linux kernel, and write the processed state into APPL_DB.

 9. orchagent (the central orchestrator) translates APPL_DB entries into
    ASIC_DB entries. syncd then programs those entries into the
    forwarding chip.

10. BGP sessions re-establish and routes are re-learned from neighbors.

11. System fully converges (typically 1–3 minutes, platform-dependent).
    "Converged" means the data plane is forwarding traffic again and
    the control plane has re-learned all routes.
```

> **Why separate stop and start?** Steps 3 and 7 are intentionally a `stop` then a `start` — not a single `restart`. The CONFIG_DB flush and reload (steps 4–6) must happen while no containers are running but Redis is still available to receive the new data. Keeping the `database` container outside `sonic.target` (see [Container Run Time](05_container_run_time.md)) is what makes this possible.


### CONFIG_DB Flush (Step 4)

The flush runs Redis's `FLUSHDB` command on database #4, which deletes every key in that database. Every table — `PORT`, `VLAN`, `INTERFACE`, `BGP_NEIGHBOR`, `ACL_TABLE`, and all others — is removed.

This is intentional: `config reload` is a **full replacement**, not a merge. Any running configuration that is not present in the new file will be gone after the reload.


### Load from File (Step 5)

The JSON file is parsed and written into CONFIG_DB using `sonic-cfggen`:

```bash
sonic-cfggen -j <filename> --write-to-db
```

This translates the JSON structure into Redis hash entries:

```
JSON:    "PORT" → "Ethernet0" → { "speed": "100000", "mtu": "9100" }
Redis:   HSET "PORT|Ethernet0" "speed" "100000"
         HSET "PORT|Ethernet0" "mtu" "9100"
```


### Host Service Reconfiguration (Step 6)

Before the SONiC containers restart, the host itself must reflect the new configuration. `config reload` triggers several host-level systemd services that read the freshly loaded CONFIG_DB and apply settings to the host OS:

| Host Service        | What It Does                                                           |
|---------------------|------------------------------------------------------------------------|
| `hostname-config`   | Sets the system hostname from `DEVICE_METADATA\|localhost\|hostname`   |
| `interfaces-config` | Configures the management interface (eth0) from `MGMT_INTERFACE` table |
| `ntp-config`        | Updates `/etc/ntp.conf` from `NTP_SERVER` table                        |
| `rsyslog-config`    | Updates syslog forwarding rules from `SYSLOG_SERVER` table             |


## Delayed Service Start

In newer SONiC versions, not all services start at the same time. This is an optimization to reduce CPU contention: if every service tries to initialize simultaneously, they compete for CPU and some may time out before they finish.

```
Phase 1 — Immediate start:
    database → syncd → swss → bgp → teamd
    (critical forwarding and routing services)

Phase 2 — Delayed until PortInitDone:
    snmp, lldp, telemetry, dhcp_relay
    (non-critical monitoring and helper services)
```

How the handoff works:

1. `portsyncd` (inside the SWSS container) detects when all front-panel ports have been initialized in the Linux kernel.
2. `portsyncd` writes a `PortInitDone` flag to APPL_DB.
3. `hostcfgd` (a host-level daemon) subscribes to APPL_DB and watches for `PortInitDone`.
4. When the flag arrives, `hostcfgd` starts the Phase 2 services.
5. A safety timeout ensures Phase 2 services start even if port initialization fails — they are never blocked indefinitely.


## Impact

| Aspect               | Impact                           |
|----------------------|----------------------------------|
| Data plane           | **Full disruption** — the forwarding chip is reprogrammed from scratch; traffic is dropped until convergence |
| Control plane        | **Full disruption** — all containers restart |
| BGP sessions         | Torn down and re-established (neighbors detect the session loss and withdraw routes) |
| Duration             | 1–3 minutes (platform-dependent) |
| Kernel               | Stays running (no reboot) |
| CONFIG_DB            | Flushed and replaced with file contents |
| Host-level processes | Unaffected (SSH, cron, and other host-level processes keep running) |


## When to Use Config Reload

- After manually editing `/etc/sonic/config_db.json` and wanting to apply the complete file.
- To recover from a corrupted running configuration by reloading from a known-good backup.
- When removing entire tables or features that cannot be removed incrementally.
- During initial provisioning with a pre-built configuration file.
- When many interdependent changes need to be applied atomically (all-or-nothing).

## When NOT to Use Config Reload

- **For routine changes** — use individual CLI commands or `config apply-patch` instead. These apply incrementally with no service disruption.
- **When zero downtime is required** — config reload disrupts both the data plane and control plane. Use `config apply-patch` for hitless incremental changes.
- **To restart a single container** — use `systemctl restart <service>` instead. Config reload restarts everything.
- **When changes are already in CONFIG_DB** — if you modified CONFIG_DB through the CLI and just want to persist those changes, use `config save`, not `config reload`.

---

**Previous**: [← Configuration Management](17_configuration_management.md) · **Next**: [Reboot Types →](19_reboot_types.md)
