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



## Boot-Time Configuration Services

Several one-shot services run at boot to configure the host environment before or alongside containers. They execute once, apply their settings, and exit. Because they only read CONFIG_DB and apply whatever it currently holds, running them again always produces the same result — the order and number of runs does not matter.

| Service | What it configures |
|---------|--------------------|
| `config-setup` | On a normal boot, the database container's startup hook has already loaded `config_db.json` into CONFIG_DB; `config-setup` simply waits for that to complete. On a first boot or image upgrade, `config-setup` takes over — generating or migrating the configuration and finalizing `CONFIG_DB_INITIALIZED` (see [Database Container — Startup](07_database_container.md#startup-and-readiness)). Either way, all other host config services depend on `config-setup` completing before they start. |
| `hostname-config` | Sets the system hostname from CONFIG_DB `DEVICE_METADATA`. |
| `interfaces-config` | Configures host-level network interfaces (management port, loopbacks). |
| `resolv-config` | Writes `/etc/resolv.conf` from CONFIG_DB DNS settings. |
| `topology` | Creates port network devices (virtual interfaces in the Linux kernel) to set up the internal kernel network topology. Depends on `database.service`. |
| `copp-config` | Applies control-plane policing rules — rate limits that prevent excessive packets from overwhelming the switch's CPU. |
| `banner-config` | Configures login banners (message of the day). |
| `rsyslog-config` | Configures remote syslog forwarding destinations. |
| `logrotate-config` | Configures log rotation to prevent disk exhaustion. |

On a `config reload`, many of these are re-triggered as part of the service restart sequence (see [Config Reload](20_config_reload.md)).



## Process Monitoring (monit)

**monit** is an open-source process monitoring tool that runs on the host as a long-running daemon. Once the system boots, monit waits for a 300-second startup delay (so all containers and services have time to come up) and then begins performing periodic **system-wide health checks** every 60 seconds. Its configuration lives in `/etc/monit/conf.d/sonic-host` and defines two kinds of checks:

**Host resource monitoring** (alert only — no automatic restart):

| Check                        | What it watches | Action on failure |
|------------------------------|----------------|-------------------|
| Filesystem (`/`, `/var/log`) | Disk space usage > 90%              | Alert (syslog) |
| System resources             | CPU or memory usage > 90%           | Alert (syslog) |
| `routeCheck`                 | APPL_DB ↔ ASIC_DB route consistency | Alert (syslog) |
| `container_checker`          | Expected containers are running (cross-references FEATURE table) | Alert (syslog) |
| `diskCheck`                  | `/etc` and `/home` are writable     | Alert (syslog) |
| `vnetRouteCheck`             | VNET route consistency              | Alert (syslog) |
| `controlPlaneDropCheck`      | Control-plane packet drops (`softnet_stats`) | Alert (syslog) |
| `mgmtOperStatus`             | Management interface operational status | Alert (syslog) |
| `arp_update_checker`         | Whether `arp_update` script is stuck    | Alert (syslog) |

**Active remediation** (can restart):

| Check          | What it watches                          | Action on failure |
|----------------|------------------------------------------|-------------------|
| `rsyslog`      | Host syslog daemon memory usage > 800 MB | Restart rsyslog   |
| `memory_check` | Per-container memory exceeds threshold   | Restart the container via `systemctl restart` |

Notice the pattern: monit mostly **alerts** rather than fixes. The only process it directly restarts is `rsyslog` (for excessive memory). The only container-level action it takes is restarting a container whose memory exceeds its threshold — a resource-limit concern, not a process-crash concern.

You can view the current status of all monit checks with:

```
admin@sonic:~$ sudo monit summary
```

This prints a table of every monitored item and its current status (`OK`, `Failed`, etc.).



## System Health Monitoring (healthd)

`healthd` is the **system health monitor daemon** that aggregates hardware state, container status, and process health into a single system-wide health verdict. It runs on the host because one of its primary jobs is checking whether Docker containers themselves are running — something that cannot be done from inside a container.

### What It Checks

`healthd` performs three categories of checks on every poll cycle (default: 60 seconds):

#### ServiceChecker

The ServiceChecker performs two independent checks on each cycle:

1. **Container and process check** — queries the Docker daemon for running containers, reads each container's `critical_processes` file, and runs `supervisorctl status` inside each container to verify that every critical process is alive. It cross-references the FEATURE table in CONFIG_DB to know which containers are expected to be running.

2. **monit integration** — runs `monit summary -B` to collect monit's check results (disk space, route consistency, container presence, and all other items from the monit tables above). If any monit-monitored item reports a failure, `healthd` records it in `SYSTEM_HEALTH_INFO`. This makes monit an **input to the health-check pipeline**: monit detects and alerts, `healthd` aggregates those alerts into the system-wide verdict.

#### HardwareChecker

The HardwareChecker verifies that all hardware components are operating within acceptable ranges. It reads the `FAN_INFO`, `PSU_INFO`, `TEMPERATURE_INFO`, and (when enabled) `LIQUID_COOLING_INFO` tables in STATE_DB — the same tables that PMON daemons populate. Specifically, it checks:

- **ASIC temperature** — current temperature is below the high threshold.
- **Fans** — all fans are present, in a healthy state, running at expected speed, and oriented in a consistent direction.
- **PSUs** — all PSUs are present, powered, and with temperature, voltage, and power within acceptable ranges.
- **Liquid cooling** (opt-in) — if the platform enables it via `include_devices`, checks for coolant leaks by reading `LIQUID_COOLING_INFO`.

> **Note:** The HardwareChecker is a **read-only observer** — it reads STATE_DB tables but never writes to them or controls hardware. The PMON daemons (`thermalctld`, `psud`) are the sole producers of `FAN_INFO`, `PSU_INFO`, `TEMPERATURE_INFO`, and `LIQUID_COOLING_INFO`. The HardwareChecker simply consumes that data to produce a pass/fail health verdict.

#### UserDefinedChecker

The UserDefinedChecker runs custom vendor-specific check scripts listed in the platform's `system_health_monitoring_config.json` file. Each script outputs a category name followed by one line per checked object (e.g. `Device1:OK` or `Device2:Out of power`). This allows vendors to extend health monitoring for platform-specific hardware or conditions without modifying `healthd` itself.

### Results and System LED

After each check cycle, `healthd` writes results to the `SYSTEM_HEALTH_INFO` table in STATE_DB — recording every checked item and its pass/fail status — and sets the **system status LED** via the Platform API. The LED provides a quick at-a-glance indication of overall system health:

- **Green** — all checks pass.
- **Amber/Red** — at least one check failed (after the boot-up grace period).
- **Blinking** — system is still booting (within the monit start delay window, typically 300 seconds).

The `show system-health summary` CLI command reads from `SYSTEM_HEALTH_INFO` in STATE_DB.

### Configuration

Each platform provides a `system_health_monitoring_config.json` file in its [platform directory](17_platform_configuration.md) to tell `healthd` what to skip or customize. For example, the Celestica Seastone DX010:

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

| Field                   | Purpose                                          |
|-------------------------|--------------------------------------------------|
| `services_to_ignore`    | Containers or monit services to skip (e.g. a service that is expected to be absent on this platform) |
| `devices_to_ignore`     | Hardware devices or check categories to skip — can be a device name (`PSU-1 FAN-1`), a category (`asic`), or a specific check (`psu.temperature`, `fan.speed`) |
| `user_defined_checkers` | Paths to custom check scripts the vendor wants to run |
| `polling_interval`      | Check interval in seconds |
| `led_color`             | Maps health states to LED colors — vendors override this because different platforms support different LED colors |



## Watchdog Control

A **hardware watchdog** is a countdown timer built into the switch's CPU/board chipset (e.g. Intel's iTCO watchdog on x86 platforms, or the ARM SBSA Generic Watchdog on DPU platforms). If software fails to "pet" (reset) the timer before it expires, the watchdog forces a hardware reboot. This protects against total system hangs where software can no longer recover itself.

The **watchdog-control** service runs after the SWSS container is up (`After=swss.service`) and manages this timer via the `watchdogutil` CLI, which calls the Platform API's `WatchdogBase` class (`arm()`, `disarm()`). Its behavior depends on the platform:

- **Most platforms** — the bootloader or BIOS firmware arms the watchdog before SONiC starts (to catch boot failures). Once SWSS is running and the software monitoring stack (monit, healthd) has taken over, `watchdog-control` **disarms** the hardware watchdog because software-level health checks now handle fault detection.

- **Smart Switch DPUs** — the watchdog is kept **armed** for runtime monitoring, since the ARM SBSA Generic Watchdog is designed for continuous system health supervision.

> **Note:** This is a separate mechanism from any ASIC-internal watchdog managed by the SDK/syncd layer. The hardware watchdog discussed here monitors the **host CPU** — not the switching ASIC.


## pcie-check

A one-shot service that runs early in boot. It scans the PCIe bus — the high-speed hardware bus that connects the switch ASIC, NICs, and other cards to the CPU — and compares the discovered devices against the platform's expected device list ([`pcie.yaml`](17_platform_configuration.md)). If a device is missing (indicating a PCIe link failure or a hardware fault), it logs an error. This catches hardware problems before they manifest as mysterious container failures later in the boot sequence.


## warmboot-finalizer

After a warm reboot, the **warmboot-finalizer** service monitors reconciliation progress across all containers. Reconciliation is the process where each container compares its saved pre-reboot state with the current hardware state and re-programs any differences. Each container signals completion by writing to STATE_DB, and the finalizer waits until all containers have finished before disabling warmboot mode. This prevents the system from getting stuck in a half-warm-rebooted state.

For the full warm reboot lifecycle, see [Warm Reboot Deep Dive](22_warm_reboot.md).


## Maintenance Services

| Service | What it does | Runs as |
|---------|-------------|---------|
| `core_uploader` | Watches for core dump files (crash snapshots) and uploads them for debugging | Long-running daemon |
| `fstrim` | Runs periodic SSD TRIM operations — a command that tells the SSD which data blocks are no longer in use, maintaining storage health and performance over time | Periodic |

---

**Previous**: [← Platform Configuration](17_platform_configuration.md) · **Next**: [Configuration Management →](19_configuration_management.md)
