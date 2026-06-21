#!/usr/bin/env bash
# Driver: re-run scenarios S1..S5 across TWO consolidation strategies on the
# SAME cluster / scheduler / workloads / 0.40 threshold, requests signal, with
# BOTH strategies on the same beta-5 binary so the only changed variable is the
# consolidation STRATEGY:
#
#   hnu   HighNodeUtilization        descheduler/b1-hnu-beta5.yaml  (image beta-5)
#   rdc2  ResourceDefragmentationC2  descheduler/rd-c2-beta5.yaml   (image beta-5)
#
# For each (scenario, strategy, seed): fresh setup -> capture -> cleanup, waiting
# for the namespace to drain to zero between runs so placement is independent.
# Results land in results/<scenario>/<ts>-<strategy>-k<seed>/ (RUN_TAG), so
# aggregate_compare.py can group them (use RUN_DATE=<today> STRATS="hnu rdc2").
#
# All output is teed to $LOG below; per-run raw json/metrics live under results/.
set -uo pipefail
cd "$(dirname "$0")"

LOG="${LOG:-$PWD/run_s15_compare_beta5.log}"
exec > >(tee -a "$LOG") 2>&1

SEEDS="${SEEDS:-3}"
SCENARIOS="${SCENARIOS:-s1 s2 s3 s4 s5}"
STRATS="${STRATS:-hnu rdc2}"

declare -A SETUP=(
  [s1]=s1_underutilized/scenario_s1_setup.sh
  [s2]=s2_fragmented/scenario_s2_setup.sh
  [s3]=s3_mixed/scenario_s3_setup.sh
  [s4]=s4_hogs/scenario_s4_setup.sh
  [s5]=s5_heterogeneous/scenario_s5_setup.sh
)
declare -A PERF=(
  [s1]=s1_underutilized/perform_and_capture.sh
  [s2]=s2_fragmented/perform_and_capture.sh
  [s3]=s3_mixed/perform_and_capture.sh
  [s4]=s4_hogs/perform_and_capture.sh
  [s5]=s5_heterogeneous/perform_and_capture.sh
)
declare -A CLEAN=(
  [s1]=s1_underutilized/cleanup.sh
  [s2]=s2_fragmented/cleanup.sh
  [s3]=s3_mixed/cleanup.sh
  [s4]=s4_hogs/cleanup.sh
  [s5]=s5_heterogeneous/cleanup.sh
)
declare -A MANIFEST=(
  [hnu]="${HNU_MANIFEST:-descheduler/b1-hnu-beta5.yaml}"
  [rdc2]="${RDC2_MANIFEST:-descheduler/rd-c2-beta5.yaml}"
)

wait_ns_empty() {
  local tries=0
  until [ "$(kubectl -n defrag-exp get pods --no-headers 2>/dev/null | grep -c .)" = "0" ]; do
    sleep 3; tries=$((tries+1)); (( tries > 60 )) && break
  done
}

echo "### START S1-S5 beta-5 compare (hnu, rdc2)  ($(date +%Y-%m-%d\ %H:%M:%S))"
echo "### log: $LOG"
for sc in $SCENARIOS; do
  for k in $(seq 1 "$SEEDS"); do
    for st in $STRATS; do
      echo "============================================================"
      echo "### $sc / $st / seed $k   ($(date +%H:%M:%S))"
      echo "============================================================"
      bash "${SETUP[$sc]}" || echo "SETUP FAILED $sc/$st/k$k"
      RUN_TAG="${st}-k${k}" SUT_MANIFEST="${MANIFEST[$st]}" bash "${PERF[$sc]}" \
        || echo "PERF FAILED $sc/$st/k$k"
      bash "${CLEAN[$sc]}" || echo "CLEAN FAILED $sc/$st/k$k"
      wait_ns_empty
    done
  done
done
echo "### ALL S1-S5 beta-5 COMPARE RUNS DONE ($(date +%Y-%m-%d\ %H:%M:%S))"
