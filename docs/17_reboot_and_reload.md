# Reboot Types and Config Reload

> **Prerequisites**: [Container Run Time](05_container_run_time.md) (systemd lifecycle), [The Database Container](07_database_container.md) (Redis persistence), and [Configuration Management](16_configuration_management.md) (CONFIG_DB and config_db.json).

SONiC supports multiple reboot types, each with different tradeoffs between disruption time, state preservation, and complexity. Understanding these is critical for operational planning — choosing the wrong reboot type during maintenance can cause unnecessary outages.

## Reboot Types Comparison

| Aspect | Cold Reboot | Fast Reboot | Warm Reboot |
|--------|-------------|-------------|-------------|
| **Command** | `sudo reboot` | `sudo fast-reboot` | `sudo warm-reboot` |
| **Data plane disruption** | Full (minutes) | < 30 seconds | Sub-second / zero |
| **Control plane disruption** | Full (minutes) | < 90 seconds | < 90 seconds |
| **ASIC state** | Fully cleared and reprogrammed | Reset, then restored from saved state | Preserved (no reset) |
| **Redis state** | Flushed and rebuilt from config_db.json | Restored from saved dumps | Persisted (AOF) and kept intact |
| **Kernel** | Full reboot (BIOS/firmware → GRUB → kernel) | kexec (skip BIOS/firmware) | kexec (skip BIOS/firmware) |
| **BGP sessions** | Torn down | Graceful Restart (peers hold routes ~120s) | Graceful Restart (peers hold routes ~120s) |
| **LAG requirement** | None | LACP slow mode (30s PDU interval) | LACP slow mode (30s PDU interval) |
| **FDB/ARP** | Lost and re-learned | Saved to disk, restored after reboot | Preserved in ASIC |
| **Use case** | Recovery from failures, major upgrades | Planned maintenance, image upgrades | Hitless upgrades, zero-downtime maintenance |
| **Complexity** | Low | Medium | High |
| **SAI boot type flag** | 0 (cold) | 2 (fast) | 1 (warm) |
| **Kernel arg** | `SONIC_BOOT_TYPE=cold` | `SONIC_BOOT_TYPE=fast-reboot` | `SONIC_BOOT_TYPE=warm` |

## Cold Reboot

Cold reboot is a standard full system restart. It is the simplest and most reliable reboot path.

### What Happens

```
1. System initiates shutdown
2. All containers stop
3. Linux kernel shuts down
4. Hardware powers through BIOS/firmware POST
5. GRUB loads the SONiC kernel
6. systemd starts all services from scratch
7. database container starts Redis (empty)
8. config_db.json is loaded into CONFIG_DB
9. All containers start and re-initialize
10. ASIC is fully reprogrammed from scratch
11. BGP sessions re-establish, routes re-learned
12. Full convergence (may take 2-5 minutes)
```

### When to Use

- After a catastrophic failure where system state is untrustworthy.
- When downgrading to an older SONiC version (warm/fast may not support downgrade).
- When warm or fast reboot is not supported for the specific upgrade path.
- First boot after image installation.

### Command

```bash
sudo reboot
# OR
sudo config reload  # (doesn't reboot the kernel, but restarts all services)
```

## Fast Reboot

Fast reboot minimizes downtime by using Linux `kexec` to skip the slow BIOS/firmware initialization, and by saving FDB/ARP state to restore the data plane quickly after ASIC re-initialization.

### What Happens

```
1. fast-reboot script initiates the process
2. FDB and ARP entries are dumped from Redis to disk
3. BGP daemon stops with Graceful Restart signaling
   (peers hold routes for ~120 seconds)
4. LACP sends a final PDU update, then teamd stops
5. syncd stops (ASIC is reset)
6. kexec loads the new kernel directly (skips BIOS/firmware)
   └── This takes ~5 seconds instead of 30-60+ seconds
7. New kernel boots, systemd starts services
8. syncd starts with '-t fast' flag:
   - ASIC is re-initialized in "fast" mode
   - Saved FDB/ARP entries are re-programmed
   - Routes are re-programmed as BGP re-converges
9. BGP sessions re-establish (peers still have routes from GR)
10. LAG interfaces are restored
11. Data plane is fully restored (~25 seconds total disruption)
12. Control plane fully converges (~90 seconds)
```

### Requirements

- **LACP slow mode**: LAG interfaces must use 30-second LACP PDU intervals. Fast mode (1-second) will cause LAGs to go down during the ~25 second data plane disruption.
- **BGP Graceful Restart**: BGP peers must support GR (RFC 4724) so they hold routes while the control plane restarts.
- **kexec support**: The Linux kernel must support kexec for fast kernel loading.

### Key Differences from Cold Reboot

1. **kexec**: Bypasses BIOS/firmware/GRUB — boots the new kernel directly from memory.
2. **State preservation**: FDB and ARP tables are saved before reboot and restored after.
3. **Graceful Restart**: BGP peers don't withdraw routes during the restart window.
4. **ASIC fast init**: The ASIC reinitializes in a faster mode (vendor-specific optimization).

### Command

```bash
sudo fast-reboot
```

## Warm Reboot

Warm reboot is the most advanced reboot type. Its goal is to restart the entire control plane (SONiC software) **without any data plane disruption** — traffic continues to flow through the ASIC during the entire reboot process.

### What Happens

```
1. warm-reboot script initiates the process
2. Redis databases are persisted to disk (AOF flush)
3. BGP daemon stops with Graceful Restart signaling
4. LACP sends a final PDU update
5. syncd saves its internal state (VID/RID mappings, etc.)
6. ASIC forwarding state is PRESERVED (not reset)
   └── This is the key difference from fast reboot
7. kexec loads the new kernel
8. New kernel boots, systemd starts services
9. database container starts:
   - Redis loads from persisted AOF files
   - All previous state is immediately available
10. syncd starts with warm boot flag:
    - Reads SAI state file from previous shutdown
    - Connects to ASIC without resetting it
    - Forwarding continues uninterrupted
11. orchagent starts and performs RECONCILIATION:
    - Reads current state from Redis (pre-reboot state)
    - Compares with what the new control plane computes
    - Only pushes DIFFERENCES to syncd/ASIC
    - This avoids reprogramming unchanged state
12. BGP re-establishes sessions, re-learns routes
13. warmboot-finalizer checks all components are reconciled
14. System is fully converged with zero data plane loss
```

### The Reconciliation Process

The most complex part of warm reboot is **reconciliation**. After warm boot:

- orchagent has the pre-reboot state in Redis.
- The new control plane computes what the state _should_ be.
- orchagent compares old vs new and only pushes the delta.

This ensures:
- Existing routes/neighbors/ACLs stay programmed (no disruption).
- Any new state from the new software version gets added.
- Any removed state gets cleaned up.

Each layer handles reconciliation:

| Layer | Responsibility |
|-------|---------------|
| Application / orchagent | Restore state from Redis, compare with new computation, push only diffs |
| syncd | Restore from SAI state file, reconnect to ASIC without reset |
| SAI / ASIC | Vendor ensures ASIC state is intact across warm restart |

### Requirements

- Everything required for fast reboot (LACP slow mode, BGP GR, kexec).
- **SAI warm boot support**: The vendor's SAI implementation must support warm restart (not all do).
- **Redis persistence (AOF)**: Must be enabled for databases that need to survive reboot.
- **Application warm restart support**: Each container/daemon must implement reconciliation logic.

### Limitations

- More complex and error-prone than cold/fast reboot.
- Not all features support warm restart (e.g., some ACL changes, some QoS configurations).
- If warm reboot fails, the system falls back to cold restart.
- Vendor SAI support varies — not all ASICs/SDKs fully support warm boot.

### Command

```bash
sudo warm-reboot
```

## Container-Level Warm Restart

In addition to full-system reboots, SONiC supports **per-container warm restart** for individual services:

```bash
# Enable warm restart for a specific service
config warm_restart enable swss
config warm_restart enable bgp

# Check warm restart status
show warm_restart state
```

This allows restarting a single container (e.g., BGP) without affecting the data plane or other containers. The restarted container performs reconciliation upon startup, just like in a full warm reboot.

## Reboot Type Selection Guide

| Scenario | Recommended Reboot |
|----------|-------------------|
| First installation of SONiC | Cold |
| Major version upgrade (e.g., 202305 → 202405) | Fast or Warm (if supported) |
| Minor patch / bugfix | Warm (preferred) or Fast |
| Hardware failure recovery | Cold |
| Configuration corruption | Cold (or config reload) |
| ASIC SDK upgrade | Cold (SDK changes require ASIC reinit) |
| Routine maintenance window | Warm (zero disruption) |
| Warm reboot not supported by platform | Fast |
| Emergency / unknown state | Cold |

---

## Config Reload

`config reload` is NOT a reboot — it does not restart the kernel or the hardware. It reloads the SONiC configuration by restarting all SONiC service containers.

### What Config Reload Does

```
1. User runs: config reload [filename]
2. Sanity checks: system status OK, essential services up, swss ready
3. All SONiC services are stopped (in order):
   - dhcp_relay, snmp, lldp, pmon, bgp, teamd, swss, syncd
4. CONFIG_DB is flushed (all data cleared from Redis DB #4)
5. New configuration is loaded from file into CONFIG_DB:
   - Default: /etc/sonic/config_db.json
   - Or user-specified file
6. Host services are restarted:
   - hostname-config, interfaces-config, ntp-config, rsyslog-config
7. All SONiC services are restarted (in dependency order):
   - swss, syncd, bgp, teamd, pmon, lldp, snmp, dhcp_relay
8. System re-converges with the new configuration
```

### Under the Hood

`config reload` internally uses:

```bash
systemctl restart sonic.target
```

This restarts all services bound to `sonic.target`. The startup order is determined by systemd service dependencies (`After=`, `Requires=`).

### Impact

| Aspect | Impact |
|--------|--------|
| Data plane | **Disrupted** — ASIC is reprogrammed from scratch |
| Control plane | **Disrupted** — all containers restart |
| BGP sessions | Torn down and re-established |
| Duration | 1-3 minutes (platform dependent) |
| Config state | Replaced with file contents |

### Command Options

```bash
# Reload from default config_db.json (prompts for confirmation)
sudo config reload

# Reload without confirmation
sudo config reload -y

# Reload from a specific file
sudo config reload /tmp/new_config.json

# Reload without restarting services (used at boot time)
sudo config reload -n
```

### Config Reload vs Other Operations

| Operation | What Changes | Service Restart | Data Plane Impact |
|-----------|-------------|-----------------|-------------------|
| `config reload` | Entire CONFIG_DB replaced | All services restart | Full disruption |
| `config load` | Adds/modifies CONFIG_DB entries | No restart | Incremental (handled by managers) |
| `config save` | Writes CONFIG_DB to disk | None | None |
| `config apply-patch` | Applies JSON patch to CONFIG_DB | No restart | Incremental (minimal) |
| Individual CLI commands | Modifies specific CONFIG_DB entries | No restart | Incremental (per-feature) |

### When to Use Config Reload

- After manually editing `config_db.json` and wanting to apply the full file.
- To recover from a corrupted running configuration (reload from a known-good file).
- When incremental changes are insufficient (e.g., removing a table entirely).
- During initial provisioning with a pre-built configuration file.

### When NOT to Use Config Reload

- For routine configuration changes — use individual CLI commands instead (no disruption).
- When zero downtime is required — consider `config apply-patch` for incremental changes.
- If you only need to restart one container — use `systemctl restart <service>` instead.

### Delayed Service Start (Optimization)

In newer SONiC versions, `config reload` uses an event-driven approach to reduce CPU contention:

1. **Critical services** (swss, syncd, bgp) start immediately.
2. **Non-critical services** (snmp, telemetry, lldp) are delayed until `PortInitDone` is signaled.
3. `hostcfgd` monitors APPL_DB for the `PortInitDone` event from portsyncd.
4. Once ports are initialized, delayed services are started.
5. A timeout ensures delayed services start even if port initialization fails.

This prevents all services from competing for CPU simultaneously, reducing initialization time and avoiding false "timeout" errors.

---

**Previous**: [← Configuration Management](16_configuration_management.md) · **Next**: [State Interactions →](18_state_interactions.md)
