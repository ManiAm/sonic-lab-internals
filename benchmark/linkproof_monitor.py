#!/usr/bin/env python3
"""Dual monitor: BGP prefixes RECEIVED vs routes PROGRAMMED in ASIC.

Purpose: prove whether the injection link/injector is the benchmark bottleneck.
If 'received' reaches the target long before 'programmed', the link and the
injector finished early and sat idle -- the bottleneck is inside the switch
pipeline (bgpd -> zebra -> fpmsyncd -> orchagent -> syncd -> ASIC).

Run ON the switch:  python3 /tmp/linkproof_monitor.py <peer_ip> <target> [timeout]
Writes /tmp/linkproof_results.json and prints a per-0.5s timeline.
"""
import time
import subprocess
import json
import sys

PEER = sys.argv[1]
TARGET = int(sys.argv[2]) if len(sys.argv) > 2 else 200000
TIMEOUT = int(sys.argv[3]) if len(sys.argv) > 3 else 180


def pfx_received():
    """Prefixes received from the injector, from FRR (summary first, fallback to neighbors)."""
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


def crm_used():
    r = subprocess.run(["sonic-db-cli", "COUNTERS_DB", "hget",
                        "CRM:STATS", "crm_stats_ipv4_route_used"],
                       capture_output=True, text=True, timeout=5)
    v = r.stdout.strip()
    return int(v) if v and v != "None" else None


def main():
    base = crm_used() or 0
    start = time.time()
    samples = []
    t_rcv_done = None
    t_prog_done = None
    print(f"START base={base} target={TARGET}", flush=True)

    while time.time() - start < TIMEOUT:
        t = round(time.time() - start, 2)
        rcv = pfx_received()
        c = crm_used()
        prog = (c - base) if c is not None else None
        samples.append({"t": t, "received": rcv, "programmed": prog})
        print(f"t={t:7.2f}s received={rcv} programmed={prog}", flush=True)

        if rcv is not None and rcv >= TARGET - 1000 and t_rcv_done is None:
            t_rcv_done = t
            print(f"*** RECEIVE COMPLETE at {t}s ***", flush=True)
        if prog is not None and prog >= TARGET - 1000 and t_prog_done is None:
            t_prog_done = t
            print(f"*** PROGRAM COMPLETE at {t}s ***", flush=True)
            break
        time.sleep(0.5)

    with open("/tmp/linkproof_results.json", "w") as f:
        json.dump({"base": base, "target": TARGET,
                   "t_receive_complete": t_rcv_done,
                   "t_program_complete": t_prog_done,
                   "samples": samples}, f, indent=1)
    print(f"DONE t_receive_complete={t_rcv_done} t_program_complete={t_prog_done}", flush=True)


if __name__ == "__main__":
    main()
