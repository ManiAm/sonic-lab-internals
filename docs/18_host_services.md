# Host Services

> **Prerequisites**: [Container Run Time](05_container_run_time.md) (how systemd manages SONiC containers), [Core Redis Databases](08_redis_databases.md) (STATE_DB and CONFIG_DB roles), and [The PMON Container](16_pmon_container.md) (the hardware monitoring daemons whose STATE_DB output several host services consume).

SONiC runs most of its functionality inside Docker containers — SWSS, Syncd, BGP, PMON, and so on. But some tasks cannot run inside a container. Checking whether containers themselves are alive, arming a hardware watchdog, setting up host networking, and finalizing a warm reboot all require direct access to the host OS. These tasks are handled by **host-level systemd services** that run directly on the switch, outside of any container.

This document covers the most important host services: what each one does, when it runs, and how it fits into the overall system.

## Why Some Services Run on the Host

A Docker container can see its own processes but cannot reliably monitor other containers. The host is the only place where a service can:

- Query the Docker daemon to check whether all expected containers are running.
- Arm or disarm a hardware watchdog timer that persists across container restarts.
- Configure host-level network interfaces before any container starts.
- Coordinate reboot sequences that tear down and rebuild the entire container fleet.

The rule of thumb: if a service needs to **supervise containers** or **outlive container restarts**, it belongs on the host.


## System Health Monitoring (healthd)

The STATE_DB tables that PMON daemons populate — `FAN_INFO`, `PSU_INFO`, `TEMPERATURE_INFO`, `TRANSCEIVER_INFO` — are consumed by CLI commands, SNMP, and telemetry. But one consumer sits above all of them: `healthd`, the **system health monitor daemon**.

`healthd` runs on the host (not inside PMON) because one of its primary jobs is checking whether Docker containers themselves are running — something that cannot be done from inside a container.

### What It Checks

`healthd` performs three categories of checks on every poll cycle (default: 60 seconds):

| Checker | What it verifies | How |
|---------|-----------------|-----|
| **ServiceChecker** | All expected Docker containers are running and all critical processes inside each container are alive | Queries `docker` for running containers, runs `supervisorctl status` inside each, cross-references with the FEATURE table in CONFIG_DB |
| **HardwareChecker** | ASIC temperature within threshold, all fans present and running at expected speed with consistent direction, all PSUs present with voltage/temperature in range | Reads the `FAN_INFO`, `PSU_INFO`, and `TEMPERATURE_INFO` tables in STATE_DB — the same tables that PMON's `thermalctld`, `psud`, and `xcvrd` populate |
| **UserDefinedChecker** | Custom vendor-specific checks | Runs external scripts listed in the platform's configuration file |

### Results and System LED

After each check cycle, `healthd` writes results to the `SYSTEM_HEALTH_INFO` table in STATE_DB and sets the **system status LED** via the Platform API (`chassis.set_status_led()`):

- **Green** — all checks pass.
- **Amber/Red** — at least one check failed (after the boot-up grace period).
- **Blinking** — system is still booting (within the monit start delay window, typically 300 seconds).

The `show system-health summary` CLI command reads from `SYSTEM_HEALTH_INFO` in STATE_DB.

### Configuration: system_health_monitoring_config.json

Each platform provides a `system_health_monitoring_config.json` file in its [platform directory](17_platform_configuration.md) to tell `healthd` what to skip. For example, the Celestica Seastone DX010:

```json
{
    "services_to_ignore": [],
    "devices_to_ignore": [
        "PSU-1 FAN-1",
        "PSU-2 FAN-1"
    ],
    "user_defined_checkers": [],
    "polling_interval": 60,
    "led_color": {
        "fault": "orange",
        "normal": "green",
        "booting": "orange_blink"
    }
}
```

| Field | Purpose |
|-------|---------|
| `services_to_ignore` | Containers or monit services to skip (e.g. a service that is expected to be absent on this platform) |
| `devices_to_ignore` | Hardware devices or check categories to skip — can be a device name (`PSU-1 FAN-1`), a category (`asic`), or a specific check (`psu.temperature`, `fan.speed`) |
| `user_defined_checkers` | Paths to custom check scripts the vendor wants to run |
| `polling_interval` | Check interval in seconds |
| `led_color` | Maps health states to LED colors — vendors override this because different platforms support different LED colors |

### Data Flow

```
Hardware → PMON daemons → STATE_DB → healthd → SYSTEM_HEALTH_INFO (STATE_DB)
                                             → System LED (via Platform API)
```

PMON daemons read hardware and write raw state to STATE_DB. `healthd` reads those STATE_DB tables, applies pass/fail thresholds, and produces a single aggregated health verdict. It also checks things PMON cannot — like whether containers and their critical processes are alive — because it runs on the host with access to the Docker daemon.


## Process Monitoring (monit)

While `healthd` provides a high-level health summary, **monit** is the low-level process watchdog. It continuously monitors critical processes across the system and restarts them if they fail.

monit watches two categories:

1. **Host processes** — systemd services running on the host (e.g. `rsyslogd`, `containerd`).
2. **Container processes** — critical processes inside each Docker container. Each container declares its critical processes in a `critical_processes` file, and monit checks them via `docker exec`.

If a monitored process dies, monit restarts it immediately. If it fails repeatedly, monit can escalate (e.g. restart the entire container).

`healthd`'s ServiceChecker queries monit (`monit summary -B`) as part of its own checks — so monit is both a remediation tool and an input to the health-check pipeline.

```
admin@sonic:~$ sudo monit summary
```


## Watchdog Control

The **watchdog-control** service arms the hardware watchdog timer after the SWSS container is running. A hardware watchdog is a countdown timer built into the switch's board — if the system fails to "pet" (reset) the timer before it expires, the watchdog forces a hardware reboot.

This protects against total system hangs where software can no longer recover itself. The PMON container's `WatchdogBase` Platform API class provides the `arm()`, `disarm()`, and `get_remaining_time()` methods that control the watchdog hardware.


## Boot-Time Configuration Services

Several one-shot services run at boot to configure the host environment before or alongside containers. They execute once, apply their settings, and exit:

| Service | What it configures |
|---------|--------------------|
| `config-setup` | The foundational setup service — checks if `/etc/sonic/config_db.json` exists and loads it into CONFIG_DB. All other services depend on this. |
| `hostname-config` | Sets the system hostname from CONFIG_DB `DEVICE_METADATA` |
| `interfaces-config` | Configures host-level network interfaces (management port, loopbacks) |
| `resolv-config` | Writes `/etc/resolv.conf` from CONFIG_DB DNS settings |
| `topology` | Sets up internal kernel network topology (creates port netdevs) — depends on `database.service` |
| `copp-config` | Applies control-plane policing rules to protect the CPU from packet floods |
| `banner-config` | Configures login banners (message of the day) |
| `rsyslog-config` | Configures remote syslog forwarding destinations |
| `logrotate-config` | Configures log rotation to prevent disk exhaustion |

These services are idempotent — they read CONFIG_DB and apply the current state. On a `config reload`, many of these are re-triggered as part of the service restart sequence (see [Config Reload](20_config_reload.md)).


## Warm Reboot Support

### warmboot-finalizer

After a warm reboot, the **warmboot-finalizer** service monitors reconciliation progress across all containers. Each container signals completion by writing to STATE_DB, and the finalizer waits until all containers have finished reconciling before disabling warmboot mode. This prevents the system from getting stuck in a half-warm-rebooted state.

For the full warm reboot lifecycle, see [Warm Reboot Deep Dive](22_warm_reboot.md).

### pcie-check

A one-shot service that runs early in boot. It scans the PCIe bus and compares the discovered devices against the platform's expected device list ([`pcie.yaml`](17_platform_configuration.md)). If a device is missing — indicating a PCIe link failure or a hardware fault — it logs an error. This catches hardware problems before they manifest as mysterious container failures later in the boot sequence.


## Maintenance Services

| Service | What it does | Interval |
|---------|-------------|----------|
| `core_uploader` | Long-running daemon that watches for core dump files and uploads them for debugging | Continuous |
| `fstrim` | Runs periodic SSD TRIM operations to maintain storage health and prevent write amplification | Periodic |


## Summary

| Category | Service | Runs as | Purpose |
|----------|---------|---------|---------|
| Health | `healthd` | Long-running daemon | Aggregates hardware + service health, sets system LED |
| Health | `monit` | Long-running daemon | Watches critical processes, restarts on failure |
| Health | `watchdog-control` | Long-running daemon | Arms hardware watchdog to force reboot on total hang |
| Boot config | `config-setup` | One-shot | Loads `config_db.json` into CONFIG_DB |
| Boot config | `hostname-config`, `interfaces-config`, `resolv-config`, etc. | One-shot | Applies CONFIG_DB settings to the host |
| Boot config | `topology` | One-shot | Creates kernel network topology |
| Reboot | `warmboot-finalizer` | One-shot | Monitors warm reboot reconciliation, disables warmboot mode |
| Reboot | `pcie-check` | One-shot | Verifies PCIe devices are present after boot |
| Maintenance | `core_uploader` | Long-running daemon | Collects and uploads core dumps |
| Maintenance | `fstrim` | Periodic | SSD TRIM for storage health |

The key architectural point: **containers handle features** (routing, forwarding, monitoring), while **host services handle the infrastructure** that keeps those containers running, configured, and healthy.

---

**Previous**: [← Platform Configuration](17_platform_configuration.md) · **Next**: [Configuration Management →](19_configuration_management.md)
