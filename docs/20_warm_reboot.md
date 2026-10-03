# Warm Reboot Deep Dive

> **Prerequisites**: [Reboot Types](19_reboot_types.md) (comparison of cold, fast, and warm reboot), [The Database Container](07_database_container.md) (Redis persistence and AOF), [SAI and Syncd](13_sai_and_syncd.md) (VID/RID mappings and the SAI meta layer), and [Orchagent Deep Dive](12_orchagent.md) (how orchagent processes state from APPL_DB to ASIC_DB).

[Reboot Types](19_reboot_types.md) introduced the five reboot types and summarized what each one does. This document goes deeper into **warm reboot** — the most complex reboot path in SONiC. It covers the full lifecycle: what happens before shutdown, how the kernel transitions, how each layer restores and reconciles state after boot, and how the system knows that warm reboot is complete.

## The Core Idea

In a cold reboot, all state is destroyed and rebuilt from scratch. In a fast reboot, the ASIC is reset but state is saved to disk and restored quickly. In a warm reboot, the ASIC is **never reset** — it continues forwarding traffic while the entire SONiC software stack restarts around it.

This is possible because the ASIC is an independent piece of hardware. Its forwarding tables (routes, neighbors, ACLs, next-hop groups) are stored in the ASIC's own memory, not in the CPU's RAM. As long as no one explicitly clears those tables, traffic keeps flowing even if the Linux kernel, Redis, orchagent, and every other piece of software on the CPU restarts.

The challenge is reconnecting the new software stack to the existing ASIC state without disturbing it. That reconnection process is called **reconciliation**, and it is where most of the complexity lives.

## Why Warm Reboot Exists

Every reboot causes some disruption. For operators running networks that carry production traffic around the clock, even a 25-second fast reboot disruption can be too much — especially when the reboot is for a routine software upgrade, not a failure recovery.

Warm reboot targets the use case of **hitless software upgrades**: upgrading the SONiC image (kernel, containers, configuration) with zero or near-zero packet loss. The switch continues forwarding traffic throughout the process. This lets operators upgrade switches during business hours without scheduling maintenance windows.

## End-to-End Timeline

The following diagram shows the full warm reboot sequence from the operator's command to the final convergence. Each phase is explained in detail in the sections that follow.

```
Operator runs: sudo warm-reboot

┌─────────────────────────────────────────────────────────────────────┐
│ PHASE 1: PRE-SHUTDOWN (old software)                                │
│                                                                     │
│  1. Validate warm reboot is possible (checks & prerequisites)       │
│  2. Enable Redis AOF persistence on required databases              │
│  3. Flush all Redis databases to AOF files on disk                  │
│  4. BGP sends Graceful Restart notification to peers                │
│  5. LACP sends final PDU update to LAG partners                     │
│  6. syncd saves its internal state (VID↔RID map, SAI object tree)   │
│  7. Set WARM_RESTART_TABLE entries in STATE_DB                      │
│  8. Install new SONiC image for kexec                               │
│  9. Stop all SONiC containers (ASIC is NOT touched)                 │
│ 10. kexec loads new kernel into memory                              │
└─────────────────────────────────┬───────────────────────────────────┘
                                  │
                     ──── kexec ──── (kernel switch, ~5 seconds)
                                  │
                                  v
┌─────────────────────────────────────────────────────────────────────┐
│ PHASE 2: BOOT (new software)                                        │
│                                                                     │
│ 11. New kernel boots (BIOS/firmware skipped)                        │
│ 12. systemd starts services in dependency order                     │
│ 13. database container starts:                                      │
│     - Redis loads state from AOF files (pre-reboot state restored)  │
│ 14. syncd starts in warm boot mode:                                 │
│     - Reads saved VID↔RID map and SAI object tree                   │
│     - Connects to ASIC without resetting it                         │
│ 15. SWSS container starts:                                          │
│     - orchagent enters reconciliation mode                          │
│ 16. BGP container starts:                                           │
│     - FRR re-establishes sessions with Graceful Restart             │
│ 17. teamd container starts:                                         │
│     - Rejoins LACP sessions without breaking LAGs                   │
└─────────────────────────────────┬───────────────────────────────────┘
                                  │
                                  v
┌─────────────────────────────────────────────────────────────────────┐
│ PHASE 3: RECONCILIATION (new software, ASIC untouched)              │
│                                                                     │
│ 18. Each layer compares old state (from Redis) with new intent      │
│ 19. Only differences are pushed to the ASIC                         │
│ 20. Each container signals "reconciliation done" in STATE_DB        │
│ 21. warmboot-finalizer checks all components are reconciled         │
│ 22. System clears warm restart flags — warm reboot complete         │
└─────────────────────────────────────────────────────────────────────┘

     Data plane: ████████████████████████████████████████████████████████
                 Forwarding continues uninterrupted throughout
```

## Phase 1: Pre-Shutdown

The warm reboot script (`/usr/local/bin/warm-reboot`) runs on the old software and prepares the system for a hitless restart. Every step in this phase is designed to ensure that the new software stack can pick up exactly where the old one left off.

### Step 1: Validation and Prerequisites

Before doing anything disruptive, the script checks that warm reboot is safe to proceed:

- **Platform support.** Not all ASICs and vendor SAI libraries support warm boot. The script checks whether the platform's SAI implementation advertises warm restart capability. If it does not, the script aborts.

- **System health.** The script verifies that critical services are running (database, swss, syncd, bgp). Attempting a warm reboot on a degraded system risks a failed restart.

- **Current boot type.** If the system is already mid-way through a previous warm restart that did not complete, the script may abort or force a cold reboot to avoid compounding failures.

### Step 2–3: Redis State Persistence

SONiC's operational state lives in Redis databases. Under normal operation, these databases are in-memory — fast, but volatile. For warm reboot, the state must survive the kernel restart.

The script enables **AOF (Append Only File)** persistence on the databases that need to survive:

```
APPL_DB    — contains the intended state (routes, neighbors, ports) written by application daemons
ASIC_DB    — contains the SAI objects currently programmed in hardware (VIDs, attributes)
STATE_DB   — contains observed runtime state (warm restart flags, feature status)
CONFIG_DB  — contains the operator's configuration (recoverable from config_db.json, but
              persisting it avoids reloading from disk)
```

The script then forces a `BGSAVE` or AOF rewrite to flush all pending writes to disk. This ensures the on-disk files reflect the exact state at shutdown time. See [Persistence and Warm Reboot](07_database_container.md#persistence-and-warm-reboot) for how AOF works.

### Step 4: BGP Graceful Restart

Before the BGP daemon shuts down, it signals **Graceful Restart (GR)** to all of its peers (as defined in RFC 4724). The GR notification tells each peer:

> "I am going to restart. Please hold all the routes you learned from me for up to 120 seconds (the restart timer). Do not withdraw them. When I come back, I will re-establish the session and confirm which routes are still valid."

From the peers' perspective, the SONiC switch's routes remain in their forwarding tables — traffic continues to flow toward the switch. The peers set a timer; if the switch does not return before the timer expires, they withdraw the routes.

This is critical because warm reboot takes time. Without GR, the moment BGP closes its sessions, every peer would immediately withdraw all routes learned from the switch, causing traffic to be rerouted or dropped across the network — even though the switch's own ASIC is still forwarding correctly.

### Step 5: LACP Final PDU

If the switch has LAG (Link Aggregation Group) interfaces using LACP (Link Aggregation Control Protocol), the teamd daemon sends a final LACP PDU (Protocol Data Unit) to the partner switch before shutting down. This tells the partner that the switch is entering a timeout period.

**Why LACP slow mode is required.** LACP has two speeds:
- **Fast mode**: PDUs every 1 second, timeout after 3 seconds.
- **Slow mode**: PDUs every 30 seconds, timeout after 90 seconds.

Warm reboot takes longer than 3 seconds, so fast mode would cause the partner to declare the LAG member down and stop sending traffic through it. Slow mode gives the switch a 90-second window to restart and rejoin the LAG. This is why warm reboot (and fast reboot) **requires LACP slow mode** on all LAG interfaces.

### Step 6: Syncd State Save

This is one of the most important pre-shutdown steps. Syncd saves its internal state to a file on disk so the new syncd instance can reconnect to the ASIC without resetting it.

What gets saved:

| Saved State | Purpose |
|-------------|---------|
| **VID↔RID mapping table** | Maps SONiC's Virtual IDs to the ASIC's Real IDs. Without this, the new syncd would not know which SAI objects correspond to which hardware entries. See [VID and RID](13_sai_and_syncd.md#virtual-ids-and-real-ids). |
| **SAI object tree** | The complete tree of SAI objects (switches, ports, routes, neighbors, next-hop groups, ACLs, etc.) and their attributes as last known. |
| **SAI meta layer state** | The meta layer's internal bookkeeping — reference counts, attribute records — needed to resume validation of future SAI operations. |

The vendor SAI library also saves whatever internal state it needs for warm restart. This is vendor-specific — for example, the Broadcom SAI may save internal table pointers, while the NVIDIA SAI may save different structures. The important thing is that the SAI library can reconnect to the ASIC and resume operations without a hardware reset.

### Step 7: Warm Restart Flags

The script writes entries to the `WARM_RESTART_TABLE` in STATE_DB, marking which services are performing a warm restart. These flags tell each container, on the next boot, to start in warm restart mode rather than cold start mode.

```
STATE_DB:
  WARM_RESTART_ENABLE_TABLE|system → { "enable": "true" }
```

Individual services also have their own warm restart entries:

```
STATE_DB:
  WARM_RESTART_TABLE|orchagent  → { "restart_count": "1", "state": "initialized" }
  WARM_RESTART_TABLE|bgp        → { "restart_count": "1", "state": "initialized" }
  WARM_RESTART_TABLE|teamsyncd  → { "restart_count": "1", "state": "initialized" }
```

### Step 8–9: Image Setup and Container Stop

The script installs the new SONiC image (if upgrading) and prepares it for kexec. It then stops all SONiC containers in the correct order. Critically, the stop sequence does **not** reset the ASIC — syncd shuts down gracefully after saving state, leaving the ASIC's forwarding tables intact.

### Step 10: kexec

The script calls `kexec` to load the new kernel directly into memory. `kexec` is a Linux mechanism that boots a new kernel without going through the BIOS/firmware POST sequence. This saves 30–60+ seconds compared to a cold reboot.

```
kexec --load <new_kernel> --initrd=<initrd> --append="SONIC_BOOT_TYPE=warm ..."
kexec --exec
```

The `SONIC_BOOT_TYPE=warm` kernel argument tells the new SONiC system to expect a warm restart and to handle services accordingly.

At this point, the old kernel is gone. The CPU is running new code. But the ASIC — a separate piece of hardware with its own memory — has not been touched. Its forwarding tables, counters, and port state are exactly as they were before the reboot.

## Phase 2: Boot

The new kernel boots and systemd starts SONiC services. The key difference from a cold boot is that every service checks the `SONIC_BOOT_TYPE` flag and, if it is `warm`, enters warm restart mode instead of initializing from scratch.

### Database Container

The database container starts first (it is a dependency for everything else). Instead of starting with empty Redis instances, it:

1. Detects that `SONIC_BOOT_TYPE=warm`.
2. Starts Redis with AOF replay enabled.
3. Redis reads the AOF files saved in Phase 1 and reconstructs the pre-reboot in-memory state.

After this step, all Redis databases contain exactly the same data they had before the reboot. APPL_DB has the routes and neighbors, ASIC_DB has the SAI objects, CONFIG_DB has the configuration, and STATE_DB has the warm restart flags.

### Syncd Container

Syncd starts with a special flag indicating warm boot. The SAI boot type is set to `1` (warm), as opposed to `0` (cold) or `2` (fast):

```
SAI_KEY_BOOT_TYPE = 1  (warm)
```

Syncd's warm boot startup:

1. **Load saved state.** Syncd reads the VID↔RID mapping table and SAI object tree from the file saved in Phase 1 (Step 6).

2. **Initialize SAI in warm mode.** Syncd calls `sai_api_initialize()` followed by `sai_switch_api->create_switch()` with the `SAI_SWITCH_ATTR_RESTART_WARM` attribute set to `true`. This tells the vendor SAI library: "The ASIC is already running with programmed state. Connect to it without resetting anything."

3. **Verify ASIC connection.** The vendor SAI connects to the ASIC driver and verifies that the hardware state is still intact. If it detects corruption, it may fall back to a cold restart.

At this point, syncd has a complete picture of what is in the ASIC (from the saved state file) and a live connection to the ASIC (through the vendor SAI). It is ready to accept new operations from orchagent.

### SWSS Container (orchagent)

Orchagent starts and detects that it is in warm restart mode. Instead of programming state from scratch, it enters **reconciliation mode** (covered in detail in the next section).

### BGP Container

FRR starts and re-establishes BGP sessions with all peers. Because the switch signaled Graceful Restart before shutting down, the peers have been holding routes. The new BGP session negotiates GR, and the peers send their full route tables again. FRR processes these routes and pushes them to zebra → fpmsyncd → APPL_DB, just like a normal route update.

The key difference is that most of these routes will match what is already in APPL_DB (carried over from the pre-reboot state). Orchagent's reconciliation process detects this and avoids reprogramming them.

### teamd Container

teamd reconnects to LACP sessions. Because the LAG partner's timeout has not expired (thanks to LACP slow mode from Step 5), the partner still considers the LAG member active. teamd resumes sending PDUs, and the LAG remains up without any traffic disruption.

## Phase 3: Reconciliation

Reconciliation is the heart of warm reboot. It is the process by which each layer compares the **old state** (what was running before the reboot, preserved in Redis) with the **new state** (what the newly started software computes), and pushes only the differences to the ASIC.

### Why Reconciliation Is Necessary

You might wonder: if the ASIC is untouched and Redis has the old state, why not just leave everything as-is? The answer is that the new software might be different from the old. The new SONiC version might:

- Add new routes (e.g., a new default route from updated configuration).
- Remove routes (e.g., a configuration change removes a static route).
- Modify attributes (e.g., a bug fix changes how an ACL is programmed).
- Have the same routes but computed differently (e.g., ECMP group membership changes).

Even if the new software is identical to the old (same version, same configuration), reconciliation is still needed to **re-register** the software's interest in the existing state. Without reconciliation, orchagent's in-memory data structures would be empty, and it would have no record of the SAI objects it manages.

### How Reconciliation Works

Each layer of the stack handles reconciliation independently:

```
┌─────────────────────────────────────────────────────────────┐
│                    Application Layer                        │
│                                                             │
│  orchagent reads APPL_DB (old state from Redis AOF)         │
│  + receives new state from daemons (fpmsyncd, neighsyncd)   │
│  → compares old vs new                                      │
│  → pushes ONLY diffs to syncd                               │
└──────────────────────────┬──────────────────────────────────┘
                           │  Only differences
                           v
┌─────────────────────────────────────────────────────────────┐
│                    SAI/Syncd Layer                          │
│                                                             │
│  syncd has the saved VID↔RID map and SAI object tree        │
│  + receives diff operations from orchagent                  │
│  → translates VIDs to RIDs                                  │
│  → programs only the changed entries in the ASIC            │
└──────────────────────────┬──────────────────────────────────┘
                           │  Minimal ASIC changes
                           v
┌─────────────────────────────────────────────────────────────┐
│                    ASIC Hardware                            │
│                                                             │
│  Forwarding tables updated incrementally                    │
│  Traffic flow is never interrupted                          │
└─────────────────────────────────────────────────────────────┘
```

### Orchagent Reconciliation in Detail

Orchagent is where most of the reconciliation logic lives. Here is how it works step by step:

**1. Load old state from Redis.**

When orchagent starts in warm mode, APPL_DB already contains the pre-reboot state (restored from AOF). Orchagent reads all relevant tables — `ROUTE_TABLE`, `NEIGH_TABLE`, `VLAN_TABLE`, `PORT_TABLE`, etc. — into its in-memory Orch data structures. This gives orchagent a complete picture of what the ASIC was programmed with before the reboot.

**2. Receive new state from application daemons.**

Meanwhile, the application daemons (fpmsyncd, neighsyncd, portsyncd, etc.) start up and begin writing their computed state to APPL_DB. For example, fpmsyncd receives routes from zebra (which received them from the re-established BGP sessions) and writes them to `ROUTE_TABLE`.

**3. Compare and compute the diff.**

Once orchagent has both the old state (from the AOF-restored APPL_DB) and the new state (from the newly started daemons), it compares them entry by entry:

| Comparison Result                                           | Action |
|-------------------------------------------------------------|-------------------------------|
| Entry exists in both old and new, with identical attributes | **No action** — the ASIC already has the correct entry |
| Entry exists in both but attributes differ                  | **Modify** — update only the changed attributes in the ASIC |
| Entry exists in new but not in old                          | **Create** — program the new entry into the ASIC |
| Entry exists in old but not in new                          | **Delete** — remove the stale entry from the ASIC |

In a typical same-version upgrade with the same configuration, the vast majority of entries fall into the "no action" category. The ASIC receives very few (or zero) programming operations, which is why warm reboot achieves near-zero disruption.

**4. Signal completion.**

After orchagent finishes processing all tables, it updates the `WARM_RESTART_TABLE` in STATE_DB:

```
WARM_RESTART_TABLE|orchagent → { "state": "reconciled" }
```

### Syncd Reconciliation

Syncd's reconciliation works at the SAI layer. On warm boot, syncd enters **comparison mode**:

1. Syncd has the **old view** — the saved SAI object tree from before the reboot.
2. Orchagent sends SAI operations representing the **new view** — what the new software wants programmed.
3. Syncd compares the new operations against its saved state.
4. Only operations that represent actual changes (creates, deletes, or modifies) are forwarded to the vendor SAI library and applied to the ASIC.

The comparison logic uses the VID↔RID mappings to correlate the new software's SAI objects with the existing ASIC entries. For example, if orchagent sends a `create_route_entry` for a prefix that already exists with the same attributes, syncd recognizes it as a no-op and skips the hardware call entirely.

After syncd has processed all pending operations and confirmed they match the old state, it transitions out of comparison mode and resumes normal operation.

### BGP Reconciliation

BGP reconciliation happens naturally through the Graceful Restart protocol:

1. The new FRR instance re-establishes BGP sessions.
2. Peers resend their full route tables (they held these routes during the GR timer).
3. FRR runs best-path selection on the received routes.
4. The selected routes are pushed through the normal pipeline: zebra → fpmsyncd → APPL_DB → orchagent.
5. Orchagent's reconciliation logic handles the comparison with pre-reboot state.

If the BGP configuration has not changed, the re-learned routes will be identical to the pre-reboot routes, and orchagent will find no diffs to program.

### teamd Reconciliation

teamd (the LAG daemon) also performs reconciliation:

1. teamd reads the pre-reboot LAG state from Redis (member ports, LACP state).
2. It re-joins the LACP sessions with the partner switches.
3. It compares the current LAG membership with the pre-reboot membership.
4. Any differences (ports added or removed) are updated incrementally.
5. It signals reconciliation complete in `WARM_RESTART_TABLE`.

## The Warmboot Finalizer

The **warmboot-finalizer** is a service that monitors the reconciliation process and declares warm reboot complete. It runs as a systemd service after all SONiC containers have started.

### What It Does

1. Polls the `WARM_RESTART_TABLE` in STATE_DB, watching for each critical service to report `"state": "reconciled"`.
2. Waits for all required services (orchagent, bgp, teamsyncd, and any others enabled for warm restart) to reach the reconciled state.
3. Once all services are reconciled, clears the warm restart flags:
   - Sets `WARM_RESTART_ENABLE_TABLE|system` → `{ "enable": "false" }`.
   - Cleans up individual service warm restart entries.
4. Disables AOF persistence on Redis databases (no longer needed after warm restart is complete; keeping AOF enabled would add unnecessary write overhead during normal operation).
5. Declares warm reboot complete.

### Timeouts

The finalizer does not wait forever. Each service has a configurable warm restart timer (default varies by service, typically 120–300 seconds). If a service does not reach the reconciled state before its timer expires, the warm reboot is considered **failed**. The system may:

- Log an error and continue running with whatever state was reconciled successfully.
- Fall back to a cold restart (platform-dependent behavior).

The timer values are configurable:

```bash
# Set warm restart timer for BGP to 180 seconds
config warm_restart bgp_timer 180

# View current timer settings
show warm_restart config
```

## Container-Level Warm Restart

In addition to full-system warm reboot, SONiC supports **per-container warm restart**. This allows restarting a single service (e.g., BGP, SWSS, or teamd) without affecting the rest of the system or the data plane.

### How It Works

Per-container warm restart follows the same principles as full warm reboot, but scoped to a single container:

1. Enable warm restart for the target service.
2. The service saves its state (just as it would during a full warm reboot).
3. The container restarts.
4. On startup, the service detects warm restart mode and performs reconciliation.
5. The warmboot-finalizer watches for reconciliation to complete.

### Commands

```bash
# Enable warm restart for a specific service
config warm_restart enable swss
config warm_restart enable bgp
config warm_restart enable teamd

# Disable warm restart for a service
config warm_restart disable bgp

# Check warm restart state for all services
show warm_restart state

# Check warm restart configuration
show warm_restart config
```

### Example: Restarting BGP with Warm Restart

```bash
# 1. Enable warm restart for BGP
admin@sonic:~$ config warm_restart enable bgp

# 2. Restart the BGP container
admin@sonic:~$ systemctl restart bgp

# 3. Monitor reconciliation progress
admin@sonic:~$ show warm_restart state
Name         Restore_count  State
-----------  -------------  ------------
orchagent    0              reconciled
bgp          1              reconciled
teamsyncd    0              reconciled
```

During this process:
- The ASIC continues forwarding with the pre-restart routes.
- BGP peers hold routes (Graceful Restart).
- The new BGP instance re-learns routes and orchagent reconciles them.
- Once reconciled, normal operation resumes.

### Use Cases for Container-Level Warm Restart

| Scenario                                     | Which Container |
|----------------------------------------------|-----------------|
| Upgrading FRR to fix a BGP bug               | `bgp`           |
| Applying a fix to orchagent or a sync daemon | `swss`          |
| Updating LACP configuration                  | `teamd`         |
| Debugging a container issue without rebooting the whole switch | Any supported container |

Container-level warm restart is less disruptive than a full warm reboot because the kernel stays running, Redis does not need AOF persistence, and only one service goes through reconciliation.

## Requirements Summary

Warm reboot has more requirements than cold or fast reboot because it must preserve running state across a software restart:

| Requirement | Why It Is Needed |
|-------------|------------------|
| **SAI warm boot support** | The vendor SAI library must support connecting to an already-running ASIC without resetting it. Not all ASICs or SAI implementations support this. |
| **Redis AOF persistence** | APPL_DB and ASIC_DB state must survive the kernel restart. AOF files are written to disk before shutdown and replayed after boot. |
| **BGP Graceful Restart** | Peers must hold routes during the restart window (~120 seconds). Both the SONiC switch and its peers must support RFC 4724. |
| **LACP slow mode** | LAG partners must use 30-second PDU intervals so they do not time out the LAG during the restart (a 3-second fast-mode timeout is too short). |
| **kexec** | The Linux kernel must support kexec for fast kernel loading (skipping BIOS/firmware). |
| **Application warm restart support** | Each container/daemon that participates in warm restart must implement reconciliation logic. A daemon that does not support it will reinitialize from scratch, potentially causing brief disruption for its specific feature. |
| **Sufficient disk space** | Redis AOF files, syncd state files, and the new SONiC image all require disk space. |

## Limitations and Failure Modes

### Not All Features Support Warm Restart

Warm restart requires every participating daemon to implement reconciliation. Some features do not have this support:

- Certain **ACL** changes may not reconcile correctly across warm restart.
- Some **QoS** (Quality of Service) policies may be reset.
- **NAT** (Network Address Translation) state may be lost.
- **PBR** (Policy-Based Routing) may not be fully supported.

The exact list of supported features depends on the SONiC version and the vendor platform. Always check the release notes.

### Failure Scenarios

| Failure | What Happens | Recovery |
|---------|-------------|----------|
| SAI warm boot fails (ASIC state corrupted) | Syncd detects the mismatch and triggers a cold restart | Full ASIC reprogram, traffic disruption |
| Redis AOF corrupted or missing | Database container starts with empty state | Falls back to cold behavior — full reinit |
| BGP GR timer expires (peers withdraw routes) | Routes are withdrawn across the network | BGP re-converges after sessions re-establish, but traffic was disrupted during the gap |
| LACP timeout (fast mode was used) | LAG partner declares members down | LAG breaks; traffic on that LAG is disrupted until LACP re-converges |
| Reconciliation timeout | warmboot-finalizer logs an error | System continues running but may have stale or missing entries |
| New software version is incompatible | Reconciliation finds too many diffs or crashes | May fall back to cold restart |

### When NOT to Use Warm Reboot

- **Downgrading to an older version.** Warm reboot reconciliation assumes the new software understands the old state format. Older software may not understand state saved by newer software.
- **ASIC SDK upgrade.** If the new SONiC image includes a different ASIC SDK version, the vendor SAI may not support warm restart across SDK versions. Use cold or fast reboot instead.
- **System is in a bad state.** If you suspect corrupted state (unexpected behavior, crashed daemons), warm reboot carries that state forward. Use cold reboot to start clean.
- **Platform does not support it.** Some platforms or ASIC families lack SAI warm boot support entirely.

## Warm Reboot vs Fast Reboot — A Closer Look

Both warm and fast reboot use kexec and BGP Graceful Restart. The fundamental difference is what happens to the ASIC:

```
Fast Reboot:                          Warm Reboot:

   ASIC is RESET                         ASIC is PRESERVED
        │                                     │
        v                                     v
   Forwarding tables cleared             Forwarding tables intact
   FDB/ARP restored from disk            FDB/ARP still in ASIC
   Routes reprogrammed as                Routes stay programmed
   BGP re-converges                      Only diffs applied
        │                                     │
        v                                     v
   ~25s data plane disruption            ~0s data plane disruption
```

The trade-off is complexity. Fast reboot is simpler — it saves state to disk, resets everything, and restores from the saved state. If the restore fails, the system just re-learns everything (slower but safe). Warm reboot is more complex — it must maintain ASIC state across a software restart and reconcile it, which requires more sophisticated logic in syncd, orchagent, and every participating daemon.

## Verifying Warm Reboot

After a warm reboot, you can verify that it completed successfully:

```bash
# Check the boot type
admin@sonic:~$ cat /proc/cmdline | grep SONIC_BOOT_TYPE
SONIC_BOOT_TYPE=warm

# Check warm restart state — all services should be "reconciled"
admin@sonic:~$ show warm_restart state
Name         Restore_count  State
-----------  -------------  ------------
orchagent    1              reconciled
bgp          1              reconciled
teamsyncd    1              reconciled

# Check that no routes were lost
admin@sonic:~$ show ip route summary

# Check BGP sessions are re-established
admin@sonic:~$ show ip bgp summary

# Check LAG interfaces are up
admin@sonic:~$ show interfaces portchannel

# Check system log for warm reboot events
admin@sonic:~$ sudo grep -i "warm" /var/log/syslog | tail -20
```

If any service shows a state other than `reconciled`, check the syslog for errors from that service. Common issues include timer expiry (the service took too long to reconcile) and state mismatches (the new software found unexpected entries in the saved state).

---

**Previous**: [← Reboot Types](19_reboot_types.md) · **Next**: [State Interactions →](21_state_interactions.md)
