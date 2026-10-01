#!/usr/bin/env python3
"""Compute all benchmark table metrics from a single run's artifacts.

Usage:
    python3 compute_metrics.py results/100k-iter1

Reads from the run directory:
    asic_results.json       — monitor output (start_epoch, CRM samples, RIB-IN)
    bgp_neighbor.json       — FRR session-established epoch
    swss_rec_firstlast.txt  — orchagent first/last ROUTE_TABLE SET timestamps
    sairedis_rec_firstlast.txt — syncd first/last SAI bulk-create timestamps
    meta.txt                — baseline, route count

Outputs a single JSON object with every metric needed for the results table.
All timestamps use the DUT clock only — no cross-machine correlation.
"""
import json
import sys
from datetime import datetime, timezone
from pathlib import Path


def parse_swss_ts(ts_str):
    """Parse '2026-10-01.10:01:05.340007|ROUTE_TABLE:...' → epoch float."""
    ts_part = ts_str.strip().split("|")[0]
    return datetime.strptime(ts_part, "%Y-%m-%d.%H:%M:%S.%f").replace(
        tzinfo=timezone.utc).timestamp()


def parse_sairedis_ts(ts_str):
    """Parse sairedis.rec line → epoch float.

    Format: '2026-10-01.10:01:05.340007|C|SAI_OBJECT_TYPE_...' (bulk create)
        or: '2026-10-01.10:01:05.340007|c|SAI_OBJECT_TYPE_...' (individual create)
    """
    ts_part = ts_str.strip().split("|")[0]
    return datetime.strptime(ts_part, "%Y-%m-%d.%H:%M:%S.%f").replace(
        tzinfo=timezone.utc).timestamp()


def load_meta(run_dir):
    meta = {}
    meta_path = run_dir / "meta.txt"
    if meta_path.exists():
        for line in meta_path.read_text().splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                meta[k.strip()] = v.strip()
    return meta


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <run_directory>", file=sys.stderr)
        sys.exit(1)

    run_dir = Path(sys.argv[1])
    metrics = {"run_dir": str(run_dir), "errors": []}

    # --- Load artifacts ---
    meta = load_meta(run_dir)
    metrics["target_routes"] = int(meta.get("ROUTES", 0))

    # asic_results.json
    asic_path = run_dir / "asic_results.json"
    if not asic_path.exists():
        metrics["errors"].append("asic_results.json not found")
        print(json.dumps(metrics, indent=2))
        sys.exit(1)
    asic = json.loads(asic_path.read_text())

    monitor_start_epoch = asic.get("start_epoch")
    if monitor_start_epoch is None:
        metrics["errors"].append(
            "start_epoch missing from asic_results.json — "
            "update asic_monitor.py and re-run")

    metrics["routes_programmed"] = asic.get("final_programmed")
    metrics["baseline"] = asic.get("baseline")
    metrics["method"] = asic.get("method")

    # bgp_neighbor.json → established epoch (DUT clock)
    bgp_path = run_dir / "bgp_neighbor.json"
    established_epoch = None
    if bgp_path.exists():
        try:
            bgp = json.loads(bgp_path.read_text())
            peer_ip = asic.get("peer")
            if peer_ip and peer_ip in bgp:
                established_epoch = bgp[peer_ip].get("bgpTimerUpEstablishedEpoch")
            elif bgp:
                first_peer = next(iter(bgp.values()))
                if isinstance(first_peer, dict):
                    established_epoch = first_peer.get("bgpTimerUpEstablishedEpoch")
        except Exception as e:
            metrics["errors"].append(f"bgp_neighbor.json parse error: {e}")
    else:
        metrics["errors"].append("bgp_neighbor.json not found")
    metrics["established_epoch"] = established_epoch

    # swss.rec first/last (orchagent timestamps)
    swss_path = run_dir / "swss_rec_firstlast.txt"
    orchagent_first = None
    orchagent_last = None
    orchagent_count = None
    if swss_path.exists():
        lines = swss_path.read_text().strip().splitlines()
        # Format: first_line / --- / last_line / --- / count  (5 lines with separators)
        # Strip separator lines to get [first, last, count]
        data_lines = [l for l in lines if l.strip() != "---"]
        if len(data_lines) >= 3 and data_lines[0].strip():
            try:
                orchagent_first = parse_swss_ts(data_lines[0])
                orchagent_last = parse_swss_ts(data_lines[1])
                orchagent_count = int(data_lines[2].strip())
            except Exception as e:
                metrics["errors"].append(f"swss_rec parse error: {e}")
    else:
        metrics["errors"].append("swss_rec_firstlast.txt not found")

    # sairedis.rec first/last (syncd → ASIC timestamps)
    sairedis_path = run_dir / "sairedis_rec_firstlast.txt"
    syncd_first = None
    syncd_last = None
    syncd_count = None
    if sairedis_path.exists():
        lines = sairedis_path.read_text().strip().splitlines()
        data_lines = [l for l in lines if l.strip() != "---"]
        if len(data_lines) >= 3 and data_lines[0].strip():
            try:
                syncd_first = parse_sairedis_ts(data_lines[0])
                syncd_last = parse_sairedis_ts(data_lines[1])
                syncd_count = int(data_lines[2].strip())
            except Exception as e:
                metrics["errors"].append(f"sairedis_rec parse error: {e}")
    else:
        metrics["errors"].append("sairedis_rec_firstlast.txt not found")

    # --- Compute RIB-IN convergence ---
    # RIB-IN = time from session established to Adj-RIB-In complete
    t_ribin_rel = asic.get("t_ribin_complete_s")
    if t_ribin_rel is not None and monitor_start_epoch and established_epoch:
        ribin_abs = monitor_start_epoch + t_ribin_rel
        metrics["ribin_convergence_s"] = max(0, round(ribin_abs - established_epoch, 1))
    else:
        metrics["ribin_convergence_s"] = None
        if t_ribin_rel is None:
            metrics["errors"].append("RIBIN_COMPLETE not detected (peer_ip not given?)")

    # --- Primary metrics use CRM-based timing from asic_monitor.py ---
    # CRM measures actual ASIC presence (hardware-verified).
    # swss.rec measures orchagent processing (route is in ASIC_DB, not ASIC yet).
    # sairedis.rec measures syncd dispatch (closer to ASIC but not confirmed).
    # Only CRM confirms the route is forwarding in hardware.
    first_route_rel = asic.get("first_route_time_s")
    total_time_rel = asic.get("total_time_s")

    # Pipeline fill (established → first route in ASIC, CRM-based)
    if first_route_rel is not None and monitor_start_epoch and established_epoch:
        first_route_abs = monitor_start_epoch + first_route_rel
        metrics["pipeline_fill_s"] = max(0, round(first_route_abs - established_epoch, 1))
    else:
        metrics["pipeline_fill_s"] = None

    # Programming window (first → last route in ASIC, CRM-based)
    # start_epoch cancels out: (start + total) - (start + first) = total - first
    if first_route_rel is not None and total_time_rel is not None:
        metrics["programming_window_s"] = round(total_time_rel - first_route_rel, 1)
    else:
        metrics["programming_window_s"] = None

    # Total time (established → last route in ASIC, CRM-based)
    if total_time_rel is not None and monitor_start_epoch and established_epoch:
        last_route_abs = monitor_start_epoch + total_time_rel
        metrics["total_time_s"] = round(last_route_abs - established_epoch, 1)
    else:
        metrics["total_time_s"] = None

    # --- Compute rates ---
    n = metrics["routes_programmed"]
    if n and metrics["programming_window_s"] and metrics["programming_window_s"] > 0:
        metrics["download_rate_rps"] = round(n / metrics["programming_window_s"])
    else:
        metrics["download_rate_rps"] = None

    if n and metrics["total_time_s"] and metrics["total_time_s"] > 0:
        metrics["e2e_rate_rps"] = round(n / metrics["total_time_s"])
    else:
        metrics["e2e_rate_rps"] = None

    # --- Per-stage lags (from stage-specific log files, not CRM) ---
    # bgpd: session established → first route enters orchagent (swss.rec)
    # This measures the delay through bgpd → zebra → fpmsyncd before orchagent
    # sees the first route. Not the same as RIB-IN convergence (which measures
    # when all routes have been received by bgpd).
    if orchagent_first and established_epoch:
        metrics["lag_bgpd_s"] = round(orchagent_first - established_epoch, 1)
    else:
        metrics["lag_bgpd_s"] = None

    # orchagent: first → last ROUTE_TABLE SET in swss.rec
    # (measures orchagent processing span, not ASIC confirmation)
    if orchagent_first and orchagent_last:
        metrics["lag_orchagent_s"] = round(orchagent_last - orchagent_first, 1)
    else:
        metrics["lag_orchagent_s"] = None

    # syncd → ASIC: first → last SAI bulk-create in sairedis.rec
    # (measures syncd dispatch span; actual ASIC install is ms after each call)
    if syncd_first and syncd_last:
        metrics["lag_syncd_asic_s"] = round(syncd_last - syncd_first, 1)
    else:
        metrics["lag_syncd_asic_s"] = None

    metrics["orchagent_route_count"] = orchagent_count
    metrics["sairedis_entry_count"] = syncd_count

    # --- Print results ---
    print(json.dumps(metrics, indent=2))

    # --- Human-readable summary ---
    print("\n--- Table Row ---", file=sys.stderr)
    def fmt(v, unit=""):
        return f"{v} {unit}".strip() if v is not None else "—"
    print(f"  Routes programmed:      {fmt(metrics['routes_programmed'])}", file=sys.stderr)
    print(f"  RIB-IN convergence:     {fmt(metrics['ribin_convergence_s'], 's')}", file=sys.stderr)
    print(f"  Pipeline fill:          {fmt(metrics['pipeline_fill_s'], 's')}", file=sys.stderr)
    print(f"  Programming window:     {fmt(metrics['programming_window_s'], 's')}", file=sys.stderr)
    print(f"  Total time:             {fmt(metrics['total_time_s'], 's')}", file=sys.stderr)
    print(f"  Download rate:          {fmt(metrics['download_rate_rps'], 'r/s')}", file=sys.stderr)
    print(f"  E2E rate:               {fmt(metrics['e2e_rate_rps'], 'r/s')}", file=sys.stderr)
    print(f"  Per-stage lag: bgpd:    {fmt(metrics['lag_bgpd_s'], 's')}", file=sys.stderr)
    print(f"  Per-stage lag: orchagent:{fmt(metrics['lag_orchagent_s'], 's')}", file=sys.stderr)
    print(f"  Per-stage lag: syncd:   {fmt(metrics['lag_syncd_asic_s'], 's')}", file=sys.stderr)
    if metrics["errors"]:
        print(f"\n  Warnings: {'; '.join(metrics['errors'])}", file=sys.stderr)


if __name__ == "__main__":
    main()
