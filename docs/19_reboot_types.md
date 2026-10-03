# Reboot Types

> **Prerequisites**: [Container Run Time](05_container_run_time.md) (systemd lifecycle), [The Database Container](07_database_container.md) (Redis persistence), and [Config Reload](18_config_reload.md) (CONFIG_DB flush/reload and service restart).

SONiC supports multiple reboot types, each with different tradeoffs between disruption time, state preservation, and complexity. Understanding these is critical for operational planning — choosing the wrong reboot type during maintenance can cause unnecessary outages.

## Reboot Types Comparison

| Aspect                       | Cold Reboot | Soft Reboot | Fast Reboot | Warm Reboot | Express Reboot |
|------------------------------|-------------|-------------|-------------|-------------|----------------|
| **Command**                  | `sudo reboot`  | `sudo soft-reboot` | `sudo fast-reboot` | `sudo warm-reboot` | `sudo express-reboot` |
| **Data plane disruption**    | Full (minutes) | Full (shorter) | < 30 seconds | Sub-second / zero | Sub-second / zero |
| **Control plane disruption** | Full (minutes) | Full (shorter) | < 90 seconds | < 90 seconds | < 90 seconds |
| **ASIC state**               | Fully cleared and reprogrammed | Fully cleared and reprogrammed | Reset, then restored from saved state | Preserved (no reset) | Preserved (vendor-specific PXE mode) |
| **Redis state**              | Flushed and rebuilt from config_db.json | Flushed and rebuilt from config_db.json | Restored from saved dumps | Persisted (AOF) and kept intact | Persisted and kept intact |
| **Kernel**                   | Full reboot (BIOS/firmware → GRUB → kernel) | kexec (skip BIOS/firmware) | kexec (skip BIOS/firmware) | kexec (skip BIOS/firmware) | kexec (skip BIOS/firmware) |
| **BGP sessions**             | Torn down | Torn down | Graceful Restart (peers hold routes ~120s) | Graceful Restart (peers hold routes ~120s) | Graceful Restart (peers hold routes ~120s) |
| **LAG requirement**          | None | None | LACP slow mode (30s PDU interval) | LACP slow mode (30s PDU interval) | LACP slow mode (30s PDU interval) |
| **FDB/ARP**                  | Lost and re-learned | Lost and re-learned | Saved to disk, restored after reboot | Preserved in ASIC | Preserved in ASIC |
| **Use case**                 | Recovery from failures, major upgrades | Faster cold restart (skip BIOS) | Planned maintenance, image upgrades | Hitless upgrades, zero-downtime maintenance | Hitless upgrades on supported platforms |
| **Complexity**               | Low | Low | Medium | High | High |
| **Platform support**         | All | All | All | Requires SAI warm boot support | Cisco 8000 and Marvell Teralynx only |
| **SAI boot type flag**       | 0 (cold) | — (cold shutdown) | 2 (fast) | 1 (warm) | — (vendor-specific) |
| **Kernel arg**               | `SONIC_BOOT_TYPE=cold` | `SONIC_BOOT_TYPE=soft` | `SONIC_BOOT_TYPE=fast-reboot` | `SONIC_BOOT_TYPE=warm` | `SONIC_BOOT_TYPE=express` |

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
```

## Soft Reboot

Soft reboot is a **cold reboot that uses kexec** to skip the slow BIOS/firmware initialization. The ASIC is fully reset and all services restart from scratch — just like a cold reboot — but the kernel loads directly via kexec instead of going through the full hardware POST sequence. No state is saved or restored.

### What Happens

```
1. soft-reboot script initiates the process
2. syncd receives a cold shutdown request (ASIC will be fully reset)
3. Any outstanding warm-reboot state is cleared
4. kexec loads the new kernel directly (skips BIOS/firmware)
5. New kernel boots, systemd starts services
6. All services initialize from scratch (identical to cold reboot)
7. ASIC is fully reprogrammed
8. BGP sessions re-establish, routes re-learned
9. Full convergence
```

### When to Use

- When you want a cold reboot but want to skip the BIOS/firmware boot delay (saves 30–60+ seconds).
- For image upgrades where fast/warm reboot is not needed but faster restart is preferred.
- On platforms where BIOS POST is particularly slow.

### Command

```bash
sudo soft-reboot
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

Warm reboot is the most advanced reboot type. Its goal is to restart the entire control plane (SONiC software) **without any data plane disruption** — traffic continues to flow through the ASIC during the entire reboot process. Unlike fast reboot, which resets the ASIC and restores state from saved dumps, warm reboot **preserves the ASIC state entirely** and reconnects the new software stack to it through a process called reconciliation.

```bash
sudo warm-reboot
```

Because of its complexity — state persistence, multi-layer reconciliation, and strict platform requirements — warm reboot has its own dedicated document. For the full explanation, see [Warm Reboot Deep Dive](20_warm_reboot.md).

> **Note — NVIDIA/Mellanox platforms:** On NVIDIA (Mellanox) switches, running `warm-reboot` internally triggers a vendor-specific mechanism called **Fast-Fast Boot (FFB)**, which sets `SONIC_BOOT_TYPE=fastfast`. FFB is NVIDIA's implementation of the warm reboot concept, optimized for their Spectrum ASICs. From the operator's perspective, the command and the goal are the same — hitless restart — but the underlying shutdown and ASIC handling differ from the generic warm reboot path.

## Express Reboot

Express reboot is a **vendor-specific variant** that combines elements of warm and fast reboot. It preserves the ASIC forwarding state (like warm reboot) but uses a specialized PXE-mode shutdown signal to the vendor SAI, allowing the ASIC to handle the restart in an optimized way.

Express reboot is **only supported on Cisco 8000 and Marvell Teralynx ASICs**. Running `express-reboot` on an unsupported platform will fail with an error.

### What Happens

```
1. express-reboot script initiates the process
2. Warm restart is enabled for the system
3. syncd receives a PXE-mode shutdown request (vendor-specific)
4. ASIC forwarding state is preserved
5. kexec loads the new kernel directly (skips BIOS/firmware)
6. New kernel boots, systemd starts services
7. Services reconcile state (similar to warm reboot)
8. System is fully converged with minimal data plane disruption
```

### When to Use

- On supported platforms (Cisco 8000, Marvell Teralynx) when hitless restart is desired.
- As a vendor-optimized alternative to warm reboot on platforms that support it.

### Command

```bash
sudo express-reboot
```

## Reboot Type Selection Guide

| Scenario                                      | Recommended Reboot          |
|-----------------------------------------------|-----------------------------|
| First installation of SONiC                   | Cold                        |
| Major version upgrade (e.g., 202305 → 202405) | Fast or Warm (if supported) |
| Minor patch / bugfix                          | Warm (preferred) or Fast    |
| Hardware failure recovery                     | Cold                        |
| ASIC SDK upgrade                              | Cold (SDK changes require ASIC reinit) |
| Routine maintenance window                    | Warm (zero disruption)      |
| Warm reboot not supported by platform         | Fast                        |
| Cold reboot but want to skip BIOS delay       | Soft                        |
| Hitless restart on Cisco 8000 / Marvell Teralynx | Express                  |
| Emergency / unknown state                     | Cold                        |

---

**Previous**: [← Config Reload](18_config_reload.md) · **Next**: [Warm Reboot Deep Dive →](20_warm_reboot.md)
