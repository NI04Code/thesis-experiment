# reset-imbalance.sh — Creates orthogonal CPU/Memory imbalance
kubectl delete ns test-app --ignore-not-found
sleep 5

# Cordon everything so we can precisely place pods
for n in worker-585 worker-235 worker-861 worker-481 worker-930; do kubectl cordon "$n"; done
kubectl create ns test-app

# 1. Place db on worker-861 (1b - Healthy Anchor)
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
              cpu: 1400m
              memory: 450Mi
EOF
sleep 10

# 2. Place payment and CPU-filler on worker-585 and worker-235 (Healthy - CPU SKEW)
kubectl cordon worker-861
kubectl uncordon worker-585 worker-235
kubectl apply -n test-app -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment
spec:
  replicas: 2
  selector:
    matchLabels:
      app: payment
  template:
    metadata:
      labels:
        app: payment
        network-group: checkout-flow
    spec:
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: payment
      containers:
        - name: app
          image: registry.k8s.io/pause:3.9
          resources:
            requests:
              cpu: 600m
              memory: 50Mi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: filler-cpu
spec:
  replicas: 4
  selector:
    matchLabels:
      app: filler-cpu
  template:
    metadata:
      labels:
        app: filler-cpu
    spec:
      containers:
        - name: app
          image: registry.k8s.io/pause:3.9
          resources:
            requests:
              cpu: 500m
              memory: 50Mi
EOF
sleep 15

# 3. Place Memory-filler on worker-481 and worker-930 (Degraded - MEM SKEW)
kubectl cordon worker-585 worker-235
kubectl uncordon worker-481 worker-930
kubectl apply -n test-app -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: filler-mem
spec:
  replicas: 4
  selector:
    matchLabels:
      app: filler-mem
  template:
    metadata:
      labels:
        app: filler-mem
    spec:
      containers:
        - name: app
          image: registry.k8s.io/pause:3.9
          resources:
            requests:
              cpu: 50m
              memory: 300Mi
EOF
sleep 15

# 4. Restore the cluster to normal (uncordon all schedulable nodes)
for n in worker-585 worker-235 worker-861 worker-481 worker-930; do kubectl uncordon "$n"; done