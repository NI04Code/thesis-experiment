# reset-low-hard.sh — Hard Tradeoff Scenario (No Filler Pods)
echo "Resetting cluster for LowNodeUtilization (Hard Tradeoff)..."

for n in worker-235 worker-286 worker-481 worker-585 worker-861 worker-930; do kubectl cordon "$n"; done
kubectl delete ns test-app --ignore-not-found
sleep 5
kubectl create ns test-app

# 1. Deploy DB and Transaction strictly to worker-861 (us-east-1b)
kubectl uncordon worker-861

kubectl apply -n test-app -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: db
spec:
  replicas: 1
  selector:
    matchLabels:
      app: db
  template:
    metadata:
      labels:
        app: db
        network-group: checkout-flow
    spec:
      containers:
        - name: app
          image: registry.k8s.io/pause:3.9
          resources:
            requests:
              cpu: 250m
              memory: 150Mi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: transaction
spec:
  replicas: 2
  selector:
    matchLabels:
      app: transaction
  template:
    metadata:
      labels:
        app: transaction
        network-group: checkout-flow
    spec:
      containers:
        - name: app
          image: registry.k8s.io/pause:3.9
          resources:
            requests:
              cpu: 200m
              memory: 48Mi
EOF
sleep 15

# 2. Deploy 8 Payment Pods strictly to worker-235 and worker-585 (us-east-1d)
# This will overutilize the nodes using ONLY critical, network-sensitive workloads
kubectl cordon worker-861
kubectl uncordon worker-235 worker-585

kubectl apply -n test-app -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment
spec:
  replicas: 8
  selector:
    matchLabels:
      app: payment
  template:
    metadata:
      labels:
        app: payment
        network-group: checkout-flow
    spec:
      containers:
        - name: app
          image: registry.k8s.io/pause:3.9
          resources:
            requests:
              cpu: 250m
              memory: 64Mi
EOF
sleep 15

# 3. Uncordon the degraded nodes in 1a so Descheduler sees them as empty targets!
kubectl uncordon worker-481 worker-861 worker-930
echo "Cluster ready for LowNodeUtilization (Hard Tradeoff) tests."