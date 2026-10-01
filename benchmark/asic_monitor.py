#!/usr/bin/env python3
"""Non-blocking route programming monitor — v3.

Polls two counters on the switch once per INTERVAL:
  - RIB-IN:      prefixes received from the BGP peer (FRR pfxRcd) — the IETF
                 "RIB-IN convergence" metric, clock stops inside bgpd.
  - programmed:  IPv4 routes in the ASIC (CRM counters, non-blocking).

Uses CRM counters (not KEYS scan) for ASIC monitoring: a KEYS scan is O(N) on
Redis's single thread and throttles the route programming being measured
(~5-15% error at 200K scale). CRM counters are maintained by syncd internally.

Deploy to DUT:
    scp asic_monitor.py admin@<DUT_IP>:/tmp/

Pre-requisites (run once before benchmark):
    sudo crm config polling interval 1

Run on DUT:
    python3 /tmp/asic_monitor.py [target_routes] [timeout_seconds] [peer_ip]

    peer_ip is optional; when given, RIB-IN convergence is measured too.

Examples:
    python3 /tmp/asic_monitor.py 200000 60 10.9.100.176
    python3 /tmp/asic_monitor.py 100000 45

Output:
    - Prints progress to stdout (suitable for piping/logging)
    - Writes detailed JSON to /tmp/asic_results.json
    - Parses this run's slice of /var/log/swss/swss.rec for precise timing
"""
import time
import subprocess
import sys
import json
import re
from datetime import datetime, timezone
from pathlib import Path

TARGET = int(sys.argv[1]) if len(sys.argv) > 1 else 200000
TIMEOUT = int(sys.argv[2]) if len(sys.argv) > 2 else 90
PEER = sys.argv[3] if len(sys.argv) > 3 else None
INTERVAL = 0.5

SWSS_REC = Path("/var/log/swss/swss.rec")


def get_crm_ipv4_route_count():
    """Get IPv4 route count from CRM (non-blocking, uses COUNTERS_DB)."""
    r = subprocess.run(
        ["sonic-db-cli", "COUNTERS_DB", "hget",
         "CRM:STATS", "crm_stats_ipv4_route_used"],
        capture_output=True, text=True, timeout=5)
    val = r.stdout.strip()
    if val and val != "None":
        return int(val)
    # Fallback: parse crm show output
    r = subprocess.run(
        ["crm", "show", "resources", "ipv4", "route"],
        capture_output=True, text=True, timeout=5)
    for line in r.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[0].isdigit():
            return int(parts[0])
    return None


def get_asic_count_legacy():
    """Fallback: O(N) KEYS scan. Only used if CRM is unavailable."""
    r = subprocess.run(
        ["sonic-db-cli", "ASIC_DB", "eval",
         "return #redis.call('keys', 'ASIC_STATE:SAI_OBJECT_TYPE_ROUTE_ENTRY*')", "0"],
        capture_output=True, text=True, timeout=10)
    return int(r.stdout.strip())


def get_pfx_received():
    """Prefixes received from PEER (FRR). None if unavailable."""
    if PEER is None:
        return None
    try:
        r = subprocess.run(["vtysh", "-c", "show bgp summary json"],
                           capture_output=True, text=True, timeout=5)
        d = json.loads(r.stdout)
        peers = d.get("ipv4Unicast", {}).get("peers", {})
        if PEER in peers:
            return peers[PEER].get("pfxRcd")
    except Exception:
        pass
    try:
        r = subprocess.run(["vtysh", "-c", f"show bgp neighbors {PEER} json"],
                           capture_output=True, text=True, timeout=5)
        d = json.loads(r.stdout)
        af = d.get(PEER, {}).get("addressFamilyInfo", {}).get("ipv4Unicast", {})
        return af.get("acceptedPrefixCounter")
    except Exception:
        return None


def parse_swss_rec(start_wall_time):
    """Parse swss.rec for precise first/last ROUTE_TABLE SET timestamps of THIS run.

    swss.rec format: "2026-09-30.17:49:01.251270|ROUTE_TABLE:1.2.3.0/24|SET|..."
    Note: SAI-level SAI_OBJECT_TYPE_ROUTE_ENTRY lines live in sairedis.rec, NOT here.
    Only timestamps after start_wall_time (monitor start, switch clock UTC) count,
    so earlier runs in the same file are excluded.
    """
    if not SWSS_REC.exists():
        return None

    route_timestamps = []
    try:
        with open(SWSS_REC, 'r') as f:
            for line in f:
                if "ROUTE_TABLE" not in line or "|SET|" not in line:
                    continue
                ts_match = re.match(r'(\d{4}-\d{2}-\d{2}\.\d{2}:\d{2}:\d{2}\.\d+)', line)
                if not ts_match:
                    continue
                ts = ts_match.group(1)
                epoch = datetime.strptime(ts, "%Y-%m-%d.%H:%M:%S.%f").replace(
                    tzinfo=timezone.utc).timestamp()
                if epoch >= start_wall_time - 1:
                    route_timestamps.append(ts)
    except Exception:
        return None

    if len(route_timestamps) < 10:
        return None

    return {
        "first_route_ts": route_timestamps[0],
        "last_route_ts": route_timestamps[-1],
        "route_count_in_log": len(route_timestamps),
    }


def main():
    # Try CRM first, fall back to legacy KEYS
    use_crm = True
    baseline = get_crm_ipv4_route_count()
    if baseline is None:
        print("WARNING: CRM counters unavailable, falling back to KEYS scan (slower)")
        use_crm = False
        baseline = get_asic_count_legacy()

    method = "CRM" if use_crm else "KEYS(legacy)"
    print(f"MONITOR STARTED | method={method} | baseline={baseline} | "
          f"target={TARGET} | timeout={TIMEOUT}s | peer={PEER}")
    sys.stdout.flush()

    start = time.time()
    start_wall = datetime.now(timezone.utc).isoformat()
    samples = []
    first_route_time = None
    t_ribin_complete = None
    prev_count = baseline

    while True:
        elapsed = time.time() - start
        if elapsed > TIMEOUT:
            print(f"TIMEOUT after {TIMEOUT}s")
            break

        count = get_crm_ipv4_route_count() if use_crm else get_asic_count_legacy()
        received = get_pfx_received()
        if count is None:
            time.sleep(INTERVAL)
            continue

        programmed = count - baseline
        delta = count - prev_count

        if programmed > 50 and first_route_time is None:
            first_route_time = elapsed
            print(f"FIRST_ROUTES | t={elapsed:.3f}s | count={programmed}"
                  " (threshold: >50 to avoid CRM noise)")
            sys.stdout.flush()

        if (received is not None and received >= TARGET - 500
                and t_ribin_complete is None):
            t_ribin_complete = elapsed
            print(f"RIBIN_COMPLETE | t={elapsed:.3f}s | received={received}")
            sys.stdout.flush()

        samples.append({
            "t": round(elapsed, 3),
            "count": count,
            "prog": programmed,
            "delta": delta,
            "received": received
        })

        if programmed >= TARGET - 500:
            print(f"COMPLETE | t={elapsed:.3f}s | programmed={programmed}")
            sys.stdout.flush()
            # Capture a few more samples for tail measurement
            for _ in range(3):
                time.sleep(INTERVAL)
                elapsed = time.time() - start
                count = get_crm_ipv4_route_count() if use_crm else get_asic_count_legacy()
                if count is None:
                    continue
                programmed = count - baseline
                samples.append({
                    "t": round(elapsed, 3),
                    "count": count,
                    "prog": programmed,
                    "delta": count - prev_count,
                    "received": get_pfx_received()
                })
                prev_count = count
            break

        prev_count = count
        time.sleep(INTERVAL)

    # Compute final metrics
    total_time = samples[-1]["t"] if samples else 0
    final_programmed = samples[-1]["prog"] if samples else 0

    # High-precision timing from this run's slice of swss.rec
    swss_rec_data = parse_swss_rec(start)

    results = {
        "method": method,
        "start_epoch": start,
        "start_wall": start_wall,
        "baseline": baseline,
        "target": TARGET,
        "peer": PEER,
        "first_route_time_s": first_route_time,
        "t_ribin_complete_s": t_ribin_complete,
        "total_time_s": total_time,
        "final_programmed": final_programmed,
        "samples": samples,
        "swss_rec": swss_rec_data,
    }

    with open("/tmp/asic_results.json", "w") as f:
        json.dump(results, f, indent=2)

    print(f"\nResults saved to /tmp/asic_results.json")
    fr_str = f"{first_route_time:.3f}s" if first_route_time is not None else "never"
    ri_str = f"{t_ribin_complete:.3f}s" if t_ribin_complete is not None else "n/a"
    print(f"SUMMARY: method={method} first_route={fr_str} ribin_complete={ri_str} "
          f"total={total_time:.3f}s routes={final_programmed}")
    if first_route_time and total_time > first_route_time:
        active_time = total_time - first_route_time
        e2e_rate = final_programmed / total_time if total_time > 0 else 0
        active_rate = final_programmed / active_time if active_time > 0 else 0
        print(f"APPROX_RATES (from monitor start, not session established):")
        print(f"  E2E_RATE: {e2e_rate:.0f} r/s | DOWNLOAD_RATE: {active_rate:.0f} r/s")
    if swss_rec_data:
        print(f"SWSS_REC: {swss_rec_data['route_count_in_log']} entries, "
              f"first={swss_rec_data['first_route_ts']} last={swss_rec_data['last_route_ts']}")


if __name__ == "__main__":
    main()
