# reset-high.sh — Creates fragmentation across 5 nodes
echo "Resetting cluster for HighNodeUtilization..."

for n in worker-235 worker-286 worker-481 worker-585 worker-861 worker-930; do kubectl cordon "$n"; done
kubectl delete ns test-app --ignore-not-found
sleep 5
kubectl create ns test-app

# 1. Put DB and Transaction on worker-861 (us-east-1b) - 36% Allocated
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

# 2. Put Filler pods on the DEGRADED nodes (worker-481, worker-930) to create a Gravity Well!
kubectl cordon worker-861
kubectl uncordon worker-481 worker-930

kubectl apply -n test-app -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: filler-481
spec:
  replicas: 6
  selector:
    matchLabels:
      app: filler-481
  template:
    metadata:
      labels:
        app: filler-481
    spec:
      nodeSelector:
        kubernetes.io/hostname: worker-481
      containers:
        - name: app
          image: registry.k8s.io/pause:3.9
          resources:
            requests:
              cpu: 150m
              memory: 48Mi
            limits:
              cpu: 150m
              memory: 48Mi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: filler-930
spec:
  replicas: 5
  selector:
    matchLabels:
      app: filler-930
  template:
    metadata:
      labels:
        app: filler-930
    spec:
      nodeSelector:
        kubernetes.io/hostname: worker-930
      containers:
        - name: app
          image: registry.k8s.io/pause:3.9
          resources:
            requests:
              cpu: 150m
              memory: 48Mi
            limits:
              cpu: 150m
              memory: 48Mi
EOF
sleep 15

# 3. Put Payment and Filler on worker-235 and worker-585 to make them UNDERUTILIZED
kubectl cordon worker-481 worker-930
kubectl uncordon worker-235 worker-585

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
              cpu: 100m
              memory: 16Mi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: filler-source
spec:
  replicas: 2
  selector:
    matchLabels:
      app: filler-source
  template:
    metadata:
      labels:
        app: filler-source
    spec:
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: filler-source
      containers:
        - name: app
          image: registry.k8s.io/pause:3.9
          resources:
            requests:
              cpu: 100m
              memory: 16Mi
EOF
sleep 15

# Uncordon all 5 active nodes
kubectl uncordon worker-861 worker-481 worker-930 worker-235 worker-585
echo "Cluster ready for HighNodeUtilization tests."
