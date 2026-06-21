#!/bin/bash
# run-session1.sh
mkdir -p results

# Start Prometheus port-forward in background and ensure cleanup on exit
kubectl -n prom port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 >/dev/null 2>&1 &
PF_PID=$!
trap "kill $PF_PID 2>/dev/null" EXIT
sleep 3 # Wait for connection to establish

for rep in 1; do
  for s in A1:configs/low-baseline.yaml \
           A2:configs/low-l1-topo.yaml \
           A3:configs/low-l2-topo.yaml \
           A4:configs/low-both-topo.yaml \
           A5:configs/low-l1-latency.yaml \
           A6:configs/low-l2-latency.yaml \
           A7:configs/low-both-latency.yaml; do
    ID="${s%%:*}"; FILE="${s##*:}"
    ./run-test.sh "$ID" "$rep" "$FILE" reset-low2.sh
  done
done
./analyze.sh
