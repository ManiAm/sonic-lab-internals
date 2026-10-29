#!/bin/bash
# show_copp_traps.sh — Display all installed CoPP traps with full details
#
# Combines data from three Redis databases to show the complete picture:
#   APPL_DB  — COPP_TABLE entries published by coppmgrd
#   ASIC_DB  — SAI trap objects, trap groups, and policers in hardware
#   STATE_DB — installation status feedback
#
# Uses sonic-db-cli (not redis-cli -n) so it works in both single-DB
# and multi-DB configurations.
#
# Usage: bash show_copp_traps.sh

# ── Helpers ──────────────────────────────────────────────────────────────────

db() { sonic-db-cli "$@" 2>/dev/null | tr -d '\r'; }

dbfield() {
  local val
  val=$(sonic-db-cli "$1" hget "$2" "$3" 2>/dev/null | tr -d '\r\n\t ')
  echo "$val"
}

read_keys() {
  local -n _arr=$1
  local dbname=$2 pattern=$3
  mapfile -t _arr < <(sonic-db-cli "$dbname" keys "$pattern" 2>/dev/null \
    | tr -d '\r' | grep -v '^$' | sort)
}

strip_trap()   { echo "${1#SAI_HOSTIF_TRAP_TYPE_}"; }
strip_action() { echo "${1#SAI_PACKET_ACTION_}"; }

# ── Determine CIR/CBS units from the first APPL_DB group ───────────────────

first_key=$(sonic-db-cli APPL_DB keys 'COPP_TABLE:*' 2>/dev/null \
  | tr -d '\r' | grep -v '^$' | head -1)
meter_type=""
if [[ -n "$first_key" ]]; then
  meter_type=$(dbfield APPL_DB "$first_key" meter_type)
fi
if [[ "$meter_type" == "bytes" ]]; then
  CIR_LABEL="CIR (B/s)"
  CBS_LABEL="CBS (B)"
else
  CIR_LABEL="CIR (pps)"
  CBS_LABEL="CBS (pkts)"
fi

# ── Build lookup maps from ASIC_DB ──────────────────────────────────────────

declare -A GRP_QUEUE GRP_POLICER
declare -A POL_CIR POL_CBS POL_RED

read_keys grp_keys ASIC_DB "ASIC_STATE:SAI_OBJECT_TYPE_HOSTIF_TRAP_GROUP:*"
for gkey in "${grp_keys[@]}"; do
  [[ -z "$gkey" ]] && continue
  oid="oid:${gkey##*:oid:}"
  GRP_QUEUE[$oid]=$(dbfield ASIC_DB "$gkey" SAI_HOSTIF_TRAP_GROUP_ATTR_QUEUE)
  GRP_POLICER[$oid]=$(dbfield ASIC_DB "$gkey" SAI_HOSTIF_TRAP_GROUP_ATTR_POLICER)
done

read_keys pol_keys ASIC_DB "ASIC_STATE:SAI_OBJECT_TYPE_POLICER:*"
for pkey in "${pol_keys[@]}"; do
  [[ -z "$pkey" ]] && continue
  oid="oid:${pkey##*:oid:}"
  POL_CIR[$oid]=$(dbfield ASIC_DB "$pkey" SAI_POLICER_ATTR_CIR)
  POL_CBS[$oid]=$(dbfield ASIC_DB "$pkey" SAI_POLICER_ATTR_CBS)
  red=$(dbfield ASIC_DB "$pkey" SAI_POLICER_ATTR_RED_PACKET_ACTION)
  POL_RED[$oid]="${red#SAI_PACKET_ACTION_}"
done

# ── Section 1: APPL_DB view ────────────────────────────────────────────────

print_appl_db_view() {
  printf "\n\033[1;36m══ CoPP Policy (APPL_DB — what coppmgrd published) ══\033[0m\n\n"
  printf "%-18s  %-5s  %-6s  %-38s  %-10s  %-10s\n" \
    "TRAP GROUP" "QUEUE" "ACTION" "TRAP IDs" "$CIR_LABEL" "$CBS_LABEL"
  printf "%-18s  %-5s  %-6s  %-38s  %-10s  %-10s\n" \
    "──────────────────" "─────" "──────" "──────────────────────────────────────" "──────────" "──────────"

  read_keys appl_keys APPL_DB "COPP_TABLE:*"
  for key in "${appl_keys[@]}"; do
    [[ -z "$key" ]] && continue
    local group queue action trap_ids cir cbs
    group="${key#COPP_TABLE:}"
    queue=$(dbfield APPL_DB "$key" queue);        : "${queue:=-}"
    action=$(dbfield APPL_DB "$key" trap_action); : "${action:=-}"
    trap_ids=$(dbfield APPL_DB "$key" trap_ids);  : "${trap_ids:=-}"
    cir=$(dbfield APPL_DB "$key" cir);            : "${cir:=-}"
    cbs=$(dbfield APPL_DB "$key" cbs);            : "${cbs:=-}"

    printf "%-18s  %-5s  %-6s  %-38s  %-10s  %-10s\n" \
      "$group" "$queue" "$action" "$trap_ids" "$cir" "$cbs"
  done
}

# ── Section 2: Combined ASIC_DB view ───────────────────────────────────────

print_combined_view() {
  printf "\n\033[1;33m══ Combined Trap View (ASIC_DB — what is actually in hardware) ══\033[0m\n\n"
  printf "%-5s  %-28s  %-6s  %-4s  %-10s  %-10s  %-10s\n" \
    "QUEUE" "SAI TRAP TYPE" "ACTION" "PRIO" "$CIR_LABEL" "$CBS_LABEL" "RED ACTION"
  printf "%-5s  %-28s  %-6s  %-4s  %-10s  %-10s  %-10s\n" \
    "─────" "────────────────────────────" "──────" "────" "──────────" "──────────" "──────────"

  local lines=()
  read_keys trap_keys ASIC_DB "ASIC_STATE:SAI_OBJECT_TYPE_HOSTIF_TRAP:*"

  if [[ ${#trap_keys[@]} -eq 0 ]]; then
    printf "  (no trap objects found in ASIC_DB)\n"
    return
  fi

  for tkey in "${trap_keys[@]}"; do
    [[ -z "$tkey" ]] && continue

    local trap_type action prio grp_oid queue pol_oid cir cbs red
    trap_type=$(dbfield ASIC_DB "$tkey" SAI_HOSTIF_TRAP_ATTR_TRAP_TYPE)
    action=$(dbfield ASIC_DB "$tkey" SAI_HOSTIF_TRAP_ATTR_PACKET_ACTION)
    prio=$(dbfield ASIC_DB "$tkey" SAI_HOSTIF_TRAP_ATTR_TRAP_PRIORITY)
    grp_oid=$(dbfield ASIC_DB "$tkey" SAI_HOSTIF_TRAP_ATTR_TRAP_GROUP)

    queue="${GRP_QUEUE[$grp_oid]:-?}"
    pol_oid="${GRP_POLICER[$grp_oid]:-}"
    if [[ -n "$pol_oid" ]]; then
      cir="${POL_CIR[$pol_oid]:--}"
      cbs="${POL_CBS[$pol_oid]:--}"
      red="${POL_RED[$pol_oid]:--}"
    else
      cir="-"; cbs="-"; red="-"
    fi

    lines+=("${queue}|$(strip_trap "$trap_type")|$(strip_action "$action")|${prio}|${cir}|${cbs}|${red}")
  done

  IFS=$'\n' sorted=($(printf '%s\n' "${lines[@]}" | sort -t'|' -k1,1rn -k2,2))
  unset IFS

  local prev_q=""
  for line in "${sorted[@]}"; do
    IFS='|' read -r q tt act pr ci cb re <<< "$line"
    if [[ -n "$prev_q" && "$prev_q" != "$q" ]]; then
      printf "\n"
    fi
    printf "%-5s  %-28s  %-6s  %-4s  %-10s  %-10s  %-10s\n" \
      "Q${q}" "$tt" "$act" "$pr" "$ci" "$cb" "$re"
    prev_q="$q"
  done
}

# ── Section 3: Installation status ─────────────────────────────────────────

print_state_db_view() {
  printf "\n\033[1;36m══ Installation Status (STATE_DB) ══\033[0m\n\n"

  local json_file="/etc/sonic/copp_cfg.json"

  # Use copp_cfg.json to map trap name → trap_ids (comma-separated)
  declare -A trap_ids_map
  if [[ -f "$json_file" ]]; then
    while IFS='|' read -r name ids; do
      trap_ids_map[$name]="$ids"
    done < <(python3 -c "
import json
with open('$json_file') as f:
  cfg = json.load(f)
for name, val in sorted(cfg.get('COPP_TRAP', {}).items()):
  print(f'{name}|{val.get(\"trap_ids\",\"\")}')
" 2>/dev/null)
  fi

  # Collect installed trap_ids, deduplicating across COPP_TRAP entries
  declare -A seen_ids
  local installed_ids=()
  read_keys trap_state_keys STATE_DB "COPP_TRAP_TABLE|*"
  for skey in "${trap_state_keys[@]}"; do
    [[ -z "$skey" ]] && continue
    local name="${skey#COPP_TRAP_TABLE|}"
    local ids="${trap_ids_map[$name]:-$name}"
    IFS=',' read -ra id_arr <<< "$ids"
    for id in "${id_arr[@]}"; do
      if [[ -z "${seen_ids[$id]:-}" ]]; then
        seen_ids[$id]=1
        installed_ids+=("$id")
      fi
    done
  done
  # TTL_ERROR — hardcoded by CoppOrch (only if not already present)
  if [[ -z "${seen_ids[ttl_error]:-}" ]]; then
    installed_ids+=("ttl_error")
  fi

  printf "  %-30s  %-10s\n" "TRAP ID" "STATUS"
  printf "  %-30s  %-10s\n" "──────────────────────────────" "──────────"
  IFS=$'\n' sorted_ids=($(printf '%s\n' "${installed_ids[@]}" | sort))
  unset IFS
  for id in "${sorted_ids[@]}"; do
    printf "  %-30s  %-10s\n" "$id" "ok"
  done

  # Disabled traps — in copp_cfg.json but not in STATE_DB
  local disabled=()
  for name in "${!trap_ids_map[@]}"; do
    local found=false
    for skey in "${trap_state_keys[@]}"; do
      [[ "${skey#COPP_TRAP_TABLE|}" == "$name" ]] && { found=true; break; }
    done
    if ! $found; then
      IFS=',' read -ra id_arr <<< "${trap_ids_map[$name]}"
      for id in "${id_arr[@]}"; do
        disabled+=("$id")
      done
    fi
  done
  if [[ ${#disabled[@]} -gt 0 ]]; then
    IFS=$'\n' disabled=($(printf '%s\n' "${disabled[@]}" | sort -u))
    unset IFS
    printf "\n  Disabled (feature not enabled): %s\n" "$(IFS=','; echo "${disabled[*]}" | sed 's/,/, /g')"
  fi
}

# ── Main ────────────────────────────────────────────────────────────────────

hn=$(hostname 2>/dev/null || echo "switch")
title="CoPP Trap Summary — $hn"
inner=$(( 56 - ${#title} ))
lpad=$(( inner / 2 ))
rpad=$(( inner - lpad ))
printf "\n\033[1;37m========================================================\033[0m\n"
printf "\033[1;37m%*s%s%*s\033[0m\n" $lpad "" "$title" $rpad ""
printf "\033[1;37m========================================================\033[0m\n"

print_appl_db_view
print_combined_view
print_state_db_view

printf "\n"
