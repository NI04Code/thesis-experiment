#!/bin/bash
# run-session3.sh
mkdir -p results

# Start Prometheus port-forward in background and ensure cleanup on exit
kubectl -n prom port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 >/dev/null 2>&1 &
PF_PID=$!
trap "kill $PF_PID 2>/dev/null" EXIT
sleep 3 # Wait for connection to establish

for rep in 1; do
  for s in C1:configs/imbalance-baseline.yaml \
           C2:configs/imbalance-l1-topo.yaml \
           C3:configs/imbalance-l1-latency.yaml; do
    ID="${s%%:*}"; FILE="${s##*:}"
    ./run-test.sh "$ID" "$rep" "$FILE" reset-imbalance.sh
  done
done
./analyze.sh
