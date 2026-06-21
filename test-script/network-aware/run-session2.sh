#!/bin/bash
set -e

# run-session2.sh
mkdir -p results

# Start Prometheus port-forward in background and ensure cleanup on exit
kubectl -n prom port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 >/dev/null 2>&1 &
PF_PID=$!
trap "kill $PF_PID 2>/dev/null" EXIT
sleep 3 # Wait for connection to establish

for rep in 1; do
  for s in B1:configs/high-baseline.yaml \
           B2:configs/high-l1-topo.yaml \
           B3:configs/high-l2-topo.yaml \
           B4:configs/high-both-topo.yaml \
           B5:configs/high-l1-latency.yaml \
           B6:configs/high-l2-latency.yaml \
           B7:configs/high-both-latency.yaml; do
    ID="${s%%:*}"; FILE="${s##*:}"
    ./run-test.sh "$ID" "$rep" "$FILE" reset-high.sh
  done
done
./analyze.sh
