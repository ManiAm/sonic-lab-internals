#!/bin/bash
# GoBGP route-download benchmark — single-iteration orchestrator.
# Injector: this machine (GoBGP 4.9.0 in ~/gobgp-bench).
# Next-hop for injected routes: 10.0.0.9 (Ethernet16, static ARP).
# Usage: bash run_bench.sh <routes> <run_name>   e.g. bash run_bench.sh 100000 100k-iter1
set -uo pipefail
cd "$HOME/gobgp-bench"

ROUTES=${1:-10000}
RUN=${2:-run-$ROUTES}
DUT=${DUT_IP:-192.168.2.170}
MYIP=${MY_IP:-192.168.2.197}
PASS=${DUT_PASS:-'YourPaSsWoRd'}
SSHCMD="sshpass -p $PASS ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 admin@$DUT"
MRT="routes_$((ROUTES/1000))k.mrt"
OUT="results/$RUN"
mkdir -p "$OUT"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

# ── 0. Prereqs ──────────────────────────────────────────────────────────────
[ -f "$MRT" ] || { log "Generating $MRT..."; python3 scripts/gen_mrt.py "$ROUTES" 10.0.0.9 65432 "$MRT"; }
[ -x ./gobgpd ] || { log "FATAL: gobgpd missing"; exit 1; }

# ── 1. DUT prep (idempotent) ────────────────────────────────────────────────
log "Prepping DUT..."
$SSHCMD "sudo crm config polling interval 1 >/dev/null 2>&1;
  sudo ip neigh replace 10.0.0.9 lladdr 02:aa:bb:cc:dd:01 dev Ethernet16;
  sudo iptables -C INPUT -p tcp -s $MYIP --dport 179 -j ACCEPT 2>/dev/null || sudo iptables -I INPUT 2 -p tcp -s $MYIP --dport 179 -j ACCEPT;
  ls /tmp/asic_monitor.py >/dev/null 2>&1 || echo MISSING_MONITOR" > "$OUT/prep.txt" 2>&1
grep -q MISSING_MONITOR "$OUT/prep.txt" && sshpass -p "$PASS" scp -o StrictHostKeyChecking=no scripts/asic_monitor.py admin@$DUT:/tmp/

# Verify static neighbor made it to ASIC
$SSHCMD "sonic-db-cli APPL_DB hgetall 'NEIGH_TABLE:Ethernet16:10.0.0.9'; sonic-db-cli ASIC_DB keys '*NEIGHBOR_ENTRY*\"ip\":\"10.0.0.9\"*' | head -1" >> "$OUT/prep.txt" 2>&1

# FRR neighbor (idempotent add)
$SSHCMD "vtysh -c 'conf t' -c 'router bgp 65100' -c 'neighbor $MYIP remote-as 65432' -c 'neighbor $MYIP description GOBGP-BENCH' -c 'neighbor $MYIP timers 60 180' -c 'address-family ipv4 unicast' -c 'neighbor $MYIP activate' -c 'end' >/dev/null 2>&1; vtysh -c 'show run' | grep -A1 '$MYIP' | head -4" >> "$OUT/prep.txt" 2>&1

# Record DUT config context
$SSHCMD "docker exec swss ps -o args -C orchagent | tail -1; sonic-db-cli CONFIG_DB hget 'DEVICE_METADATA|localhost' synchronous_mode" > "$OUT/dut_config.txt" 2>&1

# ── 2. Baseline ─────────────────────────────────────────────────────────────
BASELINE=$($SSHCMD "sonic-db-cli COUNTERS_DB hget CRM:STATS crm_stats_ipv4_route_used" 2>/dev/null | grep -oE '^[0-9]+')
[ -z "$BASELINE" ] && BASELINE=$($SSHCMD "crm show resources ipv4 route 2>/dev/null | awk '/ipv4_route/ {print \$2}'")
[ -z "$BASELINE" ] && BASELINE=$($SSHCMD "sonic-db-cli ASIC_DB eval \"return #redis.call('keys','ASIC_STATE:SAI_OBJECT_TYPE_ROUTE_ENTRY*')\" 0")
log "Baseline route count: $BASELINE"
[ "$BASELINE" -gt 100 ] && { log "ABORT: baseline too high ($BASELINE), not clean"; exit 1; }

# Mark position in swss.rec so we only parse this run's entries
SWSS_POS=$($SSHCMD "sudo wc -c /var/log/swss/swss.rec 2>/dev/null | awk '{print \$1}'" 2>/dev/null | grep -oE '^[0-9]+')
[ -z "$SWSS_POS" ] && SWSS_POS=0
log "swss.rec position: $SWSS_POS"

# Mark position in sairedis.rec for per-stage lag (syncd → ASIC)
SAIREDIS_POS=$($SSHCMD "sudo wc -c /var/log/swss/sairedis.rec 2>/dev/null | awk '{print \$1}'" 2>/dev/null | grep -oE '^[0-9]+')
[ -z "$SAIREDIS_POS" ] && SAIREDIS_POS=0
log "sairedis.rec position: $SAIREDIS_POS"

# ── 3. Kill old monitor, start fresh ────────────────────────────────────────
# IMPORTANT: Kill the monitor in a SEPARATE ssh call from the one that starts it.
# pgrep/pkill patterns that match "asic_monitor" also match the ssh command line
# itself — if kill and start are in the same session, the ssh process dies.
$SSHCMD "pgrep -f 'python3 /tmp/asic_monitor' | xargs -r kill 2>/dev/null; echo ok" 2>/dev/null
sleep 1

# ── 4. Fresh gobgpd + preload RIB ───────────────────────────────────────────
log "Starting gobgpd and preloading $ROUTES routes..."
pkill -f './gobgpd -f gobgpd.conf' 2>/dev/null; sleep 1
nohup ./gobgpd -f gobgpd.conf -l warn > "$OUT/gobgpd.log" 2>&1 &
sleep 2
# Flush any leftover routes from a previous run
./gobgp global rib del all -a ipv4 2>/dev/null
INJ_START=$(date +%s)
./gobgp mrt inject global "$MRT" --no-ipv6 2>&1 | tail -1
INJ_END=$(date +%s)
RIBCOUNT=$(./gobgp global rib summary -a ipv4 2>/dev/null | grep -oE '[0-9]+' | head -1)
log "RIB preloaded in $((INJ_END-INJ_START))s (rib summary: ${RIBCOUNT:-?})"

# ── 5. Start ASIC monitor on DUT (background) ──────────────────────────────
# Timeout: ~2× expected programming time. At ~700 r/s: 100k→~290s, 200k→~580s.
MONITOR_TIMEOUT=$(( (ROUTES / 500) + 60 ))
log "Starting ASIC monitor on DUT (timeout=${MONITOR_TIMEOUT}s)..."
$SSHCMD "rm -f /tmp/asic_results.json /tmp/asic_monitor.log" 2>/dev/null
$SSHCMD "nohup python3 -u /tmp/asic_monitor.py $ROUTES $MONITOR_TIMEOUT $MYIP > /tmp/asic_monitor.log 2>&1 &" 2>/dev/null
sleep 3
# Verify monitor started
MON=$($SSHCMD "head -1 /tmp/asic_monitor.log 2>/dev/null" 2>/dev/null)
echo "$MON" | grep -q "MONITOR STARTED" || { log "WARNING: monitor may not have started: $MON"; }

# ── 6. T_START: bring up the session ────────────────────────────────────────
T_START_S=$(date +%s)
log "T_START — adding neighbor (session up triggers full-table send)"
./gobgp neighbor add "$DUT" as 65100

# ── 7. Wait for completion ──────────────────────────────────────────────────
# Search the FULL log for SUMMARY/TIMEOUT — these lines may be far from the
# end of the file (after APPROX_RATES, SWSS_REC lines). Using grep instead
# of tail avoids the off-by-N miss that was found during testing.
for i in $(seq 1 200); do
  CHECK=$($SSHCMD "grep -E 'SUMMARY|TIMEOUT' /tmp/asic_monitor.log 2>/dev/null" 2>/dev/null | head -1)
  if echo "$CHECK" | grep -qE 'SUMMARY|TIMEOUT'; then
    break
  fi
  if (( i % 5 == 0 )); then
    PROG=$($SSHCMD "grep -oE 'programmed=[0-9]+' /tmp/asic_monitor.log 2>/dev/null" 2>/dev/null | tail -1)
    CRM=$($SSHCMD "sonic-db-cli COUNTERS_DB hget CRM:STATS crm_stats_ipv4_route_used" 2>/dev/null | grep -oE '^[0-9]+')
    log "  poll $i: ${PROG:-waiting} CRM=${CRM:-?}"
  fi
  sleep 3
done
T_POLL_DONE_S=$(date +%s)
log "Monitor finished after $(( T_POLL_DONE_S - T_START_S ))s"

# ── 8. Collect artifacts ────────────────────────────────────────────────────
sleep 3
sshpass -p "$PASS" scp -o StrictHostKeyChecking=no admin@$DUT:/tmp/asic_results.json "$OUT/" 2>/dev/null
sshpass -p "$PASS" scp -o StrictHostKeyChecking=no admin@$DUT:/tmp/asic_monitor.log "$OUT/" 2>/dev/null
# BGP session established epoch on the DUT clock (single-clock math)
$SSHCMD "vtysh -c 'show bgp neighbors $MYIP json'" > "$OUT/bgp_neighbor.json" 2>/dev/null
# Precise first/last route SET timestamps from this run's slice of swss.rec
# Output format: first_line / --- / last_line / --- / count  (separators for compute_metrics.py)
$SSHCMD "sudo tail -c +$((SWSS_POS+1)) /var/log/swss/swss.rec 2>/dev/null | grep 'ROUTE_TABLE' | grep '|SET|' | head -1; echo '---'; sudo tail -c +$((SWSS_POS+1)) /var/log/swss/swss.rec 2>/dev/null | grep 'ROUTE_TABLE' | grep '|SET|' | tail -1; echo '---'; sudo tail -c +$((SWSS_POS+1)) /var/log/swss/swss.rec 2>/dev/null | grep 'ROUTE_TABLE' | grep -c '|SET|'" > "$OUT/swss_rec_firstlast.txt" 2>&1
# Per-stage lag: first/last SAI route-create from this run's slice of sairedis.rec
$SSHCMD "sudo tail -c +$((SAIREDIS_POS+1)) /var/log/swss/sairedis.rec 2>/dev/null | grep 'SAI_OBJECT_TYPE_ROUTE_ENTRY' | grep -E '\|[Cc]\|' | head -1; echo '---'; sudo tail -c +$((SAIREDIS_POS+1)) /var/log/swss/sairedis.rec 2>/dev/null | grep 'SAI_OBJECT_TYPE_ROUTE_ENTRY' | grep -E '\|[Cc]\|' | tail -1; echo '---'; sudo tail -c +$((SAIREDIS_POS+1)) /var/log/swss/sairedis.rec 2>/dev/null | grep 'SAI_OBJECT_TYPE_ROUTE_ENTRY' | grep -cE '\|[Cc]\|'" > "$OUT/sairedis_rec_firstlast.txt" 2>&1
./gobgp neighbor "$DUT" > "$OUT/gobgp_neighbor.txt" 2>&1

# ── 9. Teardown this run: withdraw everything, wait for drain ───────────────
log "Withdrawing routes (neighbor del)..."
./gobgp neighbor del "$DUT"
./gobgp global rib del all -a ipv4 2>/dev/null
for i in $(seq 1 90); do
  CUR=$($SSHCMD "sonic-db-cli COUNTERS_DB hget CRM:STATS crm_stats_ipv4_route_used" 2>/dev/null | grep -oE '^[0-9]+')
  [ -n "$CUR" ] && [ "$CUR" -le $((BASELINE+50)) ] && break
  (( i % 10 == 0 )) && log "  draining... CRM=${CUR:-?}"
  sleep 3
done
log "Drained back to ${CUR:-?} (baseline $BASELINE)"
pkill -f './gobgpd -f gobgpd.conf' 2>/dev/null

echo "BASELINE=$BASELINE"              >  "$OUT/meta.txt"
echo "T_START_S=$T_START_S"            >> "$OUT/meta.txt"
echo "ROUTES=$ROUTES"                  >> "$OUT/meta.txt"
echo "SWSS_POS=$SWSS_POS"             >> "$OUT/meta.txt"
echo "SAIREDIS_POS=$SAIREDIS_POS"     >> "$OUT/meta.txt"
echo "RUN=$RUN"                        >> "$OUT/meta.txt"
log "Run complete. Artifacts in $OUT/"
