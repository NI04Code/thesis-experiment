#!/bin/bash
# run-test.sh <scenario-id> <rep> <policy-file> <reset-script>
SCENARIO=$1; REP=$2; POLICY=$3; RESET=$4
RUN_ID=$(echo "${SCENARIO}-r${REP}" | tr '[:upper:]' '[:lower:]')

echo "===== ${SCENARIO}-r${REP} (Job: descheduler-${RUN_ID}) ====="

# 1. Reset to initial state
bash $RESET

# 2. Collect BEFORE metrics
./collect-metrics.sh "$RUN_ID" before

# 3. Run descheduler
kubectl -n kube-system create configmap descheduler-policy \
  --from-file=policy.yaml="$POLICY" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n kube-system delete job "descheduler-${RUN_ID}" --ignore-not-found 2>/dev/null
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: descheduler-${RUN_ID}
  namespace: kube-system
spec:
  template:
    spec:
      serviceAccountName: descheduler-sa
      containers:
        - name: descheduler
          image: ni04code/descheduler:dev2
          imagePullPolicy: Always
          command: ["/bin/descheduler"]
          args: ["--policy-config-file=/policy/policy.yaml", "--v=4"]
          volumeMounts:
            - name: policy
              mountPath: /policy
      volumes:
        - name: policy
          configMap:
            name: descheduler-policy
      restartPolicy: Never
  backoffLimit: 0
EOF

kubectl -n kube-system wait --for=condition=complete "job/descheduler-${RUN_ID}" --timeout=120s
kubectl -n kube-system logs "job/descheduler-${RUN_ID}" > "./results/${RUN_ID}/descheduler.log" 2>&1
sleep 45

# 4. Collect AFTER metrics
./collect-metrics.sh "$RUN_ID" after

# 5. Cleanup job
kubectl -n kube-system delete job "descheduler-${RUN_ID}" --ignore-not-found
kubectl -n kube-system delete configmap descheduler-policy --ignore-not-found
echo "  Results → ./results/${RUN_ID}/"
