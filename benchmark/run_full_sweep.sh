#!/bin/bash
# Full benchmark sweep: 25k, 50k, 100k × 3 iterations, then compute all metrics.
#
# Usage (from the Linux server):
#     bash run_full_sweep.sh
#
# Optional: reduce noise by stopping non-essential SONiC containers first:
#     bash run_full_sweep.sh --quiet-switch
#
# Results land in ~/gobgp-bench/results/<size>-iter<N>/ and a summary is
# printed at the end.
set -uo pipefail
cd "$HOME/gobgp-bench"

DUT=${DUT_IP:-192.168.2.170}
PASS=${DUT_PASS:-'YourPaSsWoRd'}
SSHCMD="sshpass -p $PASS ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 admin@$DUT"
COOLDOWN=30          # seconds between iterations (let Redis + ASIC settle)
SIZES=(25000 50000 100000)
ITERS=3
STOPPED_CONTAINERS=""

log() { echo ""; echo "##########  $*  ##########"; }

cleanup() {
    # Restore stopped containers on exit (even on Ctrl-C)
    if [ -n "$STOPPED_CONTAINERS" ]; then
        echo ""
        echo "Restoring stopped containers: $STOPPED_CONTAINERS"
        $SSHCMD "sudo systemctl start $STOPPED_CONTAINERS" 2>/dev/null
    fi
}
trap cleanup EXIT

# ── Optional: quiet the switch ──────────────────────────────────────────────
if [[ "${1:-}" == "--quiet-switch" ]]; then
    STOPPED_CONTAINERS="snmp lldp gnmi pmon mgmt-framework"
    echo "Stopping non-essential containers on DUT for cleaner measurements..."
    $SSHCMD "sudo systemctl stop $STOPPED_CONTAINERS" 2>/dev/null
    sleep 5
    echo "Containers stopped. They will be restored when this script exits."
fi

# ── Preflight check ─────────────────────────────────────────────────────────
BASELINE=$($SSHCMD "sonic-db-cli COUNTERS_DB hget CRM:STATS crm_stats_ipv4_route_used" 2>/dev/null | grep -oE '^[0-9]+')
echo "DUT baseline CRM: ${BASELINE:-UNREACHABLE}"
[ -z "$BASELINE" ] && { echo "FATAL: cannot reach DUT"; exit 1; }
[ "$BASELINE" -gt 100 ] && { echo "FATAL: baseline too high ($BASELINE), switch not clean"; exit 1; }

TOTAL_RUNS=$(( ${#SIZES[@]} * ITERS ))
echo "Plan: ${SIZES[*]} × $ITERS iterations = $TOTAL_RUNS runs"
echo "Cooldown between runs: ${COOLDOWN}s"
echo "Results will be in: ~/gobgp-bench/results/"
echo ""

# ── Run the sweep ───────────────────────────────────────────────────────────
RUN_NUM=0
FAILED=""
for SIZE in "${SIZES[@]}"; do
    for ITER in $(seq 1 $ITERS); do
        RUN_NUM=$((RUN_NUM + 1))
        NAME="$(( SIZE / 1000 ))k-iter${ITER}"
        log "RUN $RUN_NUM/$TOTAL_RUNS: $NAME ($SIZE routes)"

        if bash run_bench.sh "$SIZE" "$NAME"; then
            echo "[OK] $NAME completed successfully"
            # Show this run's metrics immediately
            DIR="results/$NAME"
            if [ -f "$DIR/asic_results.json" ]; then
                python3 compute_metrics.py "$DIR" 2>&1 | grep -E '^\s+(Routes|RIB-IN|Pipeline|Program|Total|Download|E2E|Per-stage)'
            fi
        else
            RC=$?
            echo "[FAIL] $NAME failed with exit code $RC"
            FAILED="$FAILED $NAME"
            # Try to clean up so the next run starts clean
            echo "Attempting cleanup..."
            pkill -f './gobgpd -f gobgpd.conf' 2>/dev/null
            $SSHCMD "pgrep -f 'python3 /tmp/asic_monitor' | xargs -r kill 2>/dev/null" 2>/dev/null
            # Wait for any leftover routes to drain
            for _d in $(seq 1 40); do
                CUR=$($SSHCMD "sonic-db-cli COUNTERS_DB hget CRM:STATS crm_stats_ipv4_route_used" 2>/dev/null | grep -oE '^[0-9]+')
                [ -n "$CUR" ] && [ "$CUR" -le 100 ] && break
                sleep 3
            done
        fi

        # Cooldown (skip after the very last run)
        if [ $RUN_NUM -lt $TOTAL_RUNS ]; then
            echo "Cooling down ${COOLDOWN}s before next run..."
            sleep $COOLDOWN
        fi
    done
done

# ── Compute metrics ─────────────────────────────────────────────────────────
log "COMPUTING METRICS"
echo ""

# Save JSON for each run, then build a side-by-side table
METRICS_DIR="results/_metrics"
mkdir -p "$METRICS_DIR"
for SIZE in "${SIZES[@]}"; do
    for ITER in $(seq 1 $ITERS); do
        NAME="$(( SIZE / 1000 ))k-iter${ITER}"
        DIR="results/$NAME"
        if [ -f "$DIR/asic_results.json" ]; then
            python3 compute_metrics.py "$DIR" > "$METRICS_DIR/$NAME.json" 2>/dev/null
        fi
    done
done

# Print side-by-side iteration tables (the format used in 15_benchmark.md)
python3 -c "
import json, os, sys

sizes = [25000, 50000, 100000]
iters = $ITERS
mdir = 'results/_metrics'

def load(name):
    p = os.path.join(mdir, name + '.json')
    if os.path.exists(p):
        with open(p) as f:
            return json.load(f)
    return None

def fmt(v, unit=''):
    if v is None: return '—'
    return f'{v}{unit}'

rows = [
    ('Routes programmed',      'routes_programmed',      ''),
    ('RIB-IN convergence',     'ribin_convergence_s',    ' s'),
    ('Pipeline fill',          'pipeline_fill_s',        ' s'),
    ('Programming window',     'programming_window_s',   ' s'),
    ('Total time',             'total_time_s',           ' s'),
    ('Download rate',          'download_rate_rps',      ' r/s'),
    ('E2E rate',               'e2e_rate_rps',           ' r/s'),
    ('Per-stage lag: bgpd',    'lag_bgpd_s',             ' s'),
    ('Per-stage lag: orchagent','lag_orchagent_s',        ' s'),
    ('Per-stage lag: syncd',   'lag_syncd_asic_s',       ' s'),
]

for it in range(1, iters + 1):
    print(f'--- Iteration {it} ---')
    print(f'{\"Metric\":<28} {\"25k\":>12} {\"50k\":>12} {\"100k\":>12}')
    print('-' * 66)
    data = {}
    for s in sizes:
        name = f'{s // 1000}k-iter{it}'
        data[s] = load(name) or {}
    for label, key, unit in rows:
        vals = [fmt(data[s].get(key), unit) for s in sizes]
        print(f'  {label:<26} {vals[0]:>12} {vals[1]:>12} {vals[2]:>12}')
    print()

# Cross-iteration consistency
print('--- Cross-Iteration Summary ---')
print(f'{\"\":<16} {\"25k\":>18} {\"50k\":>18} {\"100k\":>18}')
print('-' * 72)
for label, key in [('Download rate', 'download_rate_rps'), ('E2E rate', 'e2e_rate_rps'), ('Total time', 'total_time_s')]:
    for s in [25000, 50000, 100000]:
        pass
    line_parts = [f'  {label:<14}']
    for s in sizes:
        vals = []
        for it in range(1, iters + 1):
            d = load(f'{s // 1000}k-iter{it}')
            if d and d.get(key) is not None:
                vals.append(d[key])
        if vals:
            avg = sum(vals) / len(vals)
            spread = (max(vals) - min(vals)) / avg * 100
            line_parts.append(f'avg={avg:>6.0f} ±{spread:.0f}%')
        else:
            line_parts.append('—')
    print(f'{line_parts[0]} {line_parts[1]:>18} {line_parts[2]:>18} {line_parts[3]:>18}')
print()
"

# ── Summary ─────────────────────────────────────────────────────────────────
log "SWEEP COMPLETE"
echo "Total runs: $TOTAL_RUNS"
if [ -z "$FAILED" ]; then
    echo "All runs succeeded ✓"
else
    echo "Failed runs: $FAILED"
fi
echo "Results in: ~/gobgp-bench/results/"
echo ""
echo "To re-run a single failed iteration:"
echo "  bash run_bench.sh <routes> <name>   e.g. bash run_bench.sh 100000 100k-iter2"
