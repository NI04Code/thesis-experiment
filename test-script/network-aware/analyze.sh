#!/bin/bash
# analyze.sh

print_table() {
  local pattern=$1
  local title=$2
  local goal=$3

  echo "=== $title ==="
  echo "Goal: $goal"
  
  printf "%-24s | %4s | %18s | %18s | %16s | %6s | %22s | %s\n" \
    "Scenario" "Evic" "CPU_StdDev" "MEM_StdDev" "Stranding_S" "Active" "AvgLatency" "SDegraded"
  printf -- "%.0s-" {1..134}; echo

  shopt -s nullglob
  local dirs=(results/*/)
  shopt -u nullglob

  local sorted_dirs=()
  if [ ${#dirs[@]} -gt 0 ]; then
    IFS=$'\n' read -r -d '' -a sorted_dirs < <(printf '%s\n' "${dirs[@]}" | sort -V && printf '\0')
  fi

  for d in "${sorted_dirs[@]}"; do
    local clean_d="${d%/}"
    local S=$(basename "$clean_d")
    
    if [[ "$S" =~ $pattern ]]; then
      # Squeezed and stripped any hidden breaks from the eviction count
      local E=$(grep -c "Evicted pod" "$clean_d/descheduler.log" 2>/dev/null | tr -d '\r\n' || echo 0)
      [[ -z "$E" ]] && E=0

      local UC_BEFORE=$(grep -oP 'cpu_stddev=\K[0-9.]+' "$clean_d/before_node_util.txt" 2>/dev/null | tr -d '\r\n' || echo "?")
      local UM_BEFORE=$(grep -oP 'mem_stddev=\K[0-9.]+' "$clean_d/before_node_util.txt" 2>/dev/null | tr -d '\r\n' || echo "?")
      local RII_BEFORE=$(grep -oP 'total_rii=\K[0-9.]+' "$clean_d/before_node_util.txt" 2>/dev/null | tr -d '\r\n' || echo "?")
      local L_BEFORE=$(grep "avg=" "$clean_d/before_cost.txt" 2>/dev/null | grep -oP 'avg=\K[0-9.]+' | tr -d '\r\n' || echo "?")
      
      local UC=$(grep -oP 'cpu_stddev=\K[0-9.]+' "$clean_d/after_node_util.txt" 2>/dev/null | tr -d '\r\n' || echo "N/A")
      local UM=$(grep -oP 'mem_stddev=\K[0-9.]+' "$clean_d/after_node_util.txt" 2>/dev/null | tr -d '\r\n' || echo "N/A")
      local RII=$(grep -oP 'total_rii=\K[0-9.]+' "$clean_d/after_node_util.txt" 2>/dev/null | tr -d '\r\n' || echo "N/A")
      local ACT=$(grep -oP 'ActiveNodes=\K[0-9]+' "$clean_d/after_node_util.txt" 2>/dev/null | tr -d '\r\n' || echo "N/A")
      local L=$(grep "avg=" "$clean_d/after_cost.txt" 2>/dev/null | grep -oP 'avg=\K[0-9.]+' | tr -d '\r\n' || echo "N/A")
      local CR=$(grep -E "worker-481|worker-930" "$clean_d/after_group.txt" 2>/dev/null | wc -l | tr -d ' \r\n')
      
      local UC_DISP="${UC_BEFORE}%->${UC}%"
      local UM_DISP="${UM_BEFORE}%->${UM}%"
      local RII_DISP="${RII_BEFORE}%->${RII}%"
      local L_DISP="${L_BEFORE}ms->${L}ms"

      printf "%-24s | %4s | %18s | %18s | %16s | %6s | %22s | %s pods\n" \
        "$S" "$E" "$UC_DISP" "$UM_DISP" "$RII_DISP" "$ACT" "$L_DISP" "$CR"
    fi
  done
  echo ""
}

print_table "^a[1-7]-r[1-3]$" "LowNodeUtilization (Session 1)" "LOWER StdDev is better (even spreading)"
print_table "^b[1-7]-r[1-3]$" "HighNodeUtilization (Session 2)" "HIGHER StdDev is better (tight packing)"
print_table "^c[1-3]-r[1-3]$" "ImbalanceIndexUtilization (Session 3)" "HIGHER StdDev is better (tight packing)"