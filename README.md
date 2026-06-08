# Kubernetes Descheduler Thesis E2E Testing Workflow

This guide details the steps to reproduce the end-to-end evaluation of the Resource Defragmentation and Network-Aware Descheduler policies.

## 1. Provision Kubernetes Cluster
You can use on-premise infrastructure or any cloud provider (e.g., AWS, GCP). Ensure that all worker nodes use the exact same hardware profile equivalent to an AWS `t3.micro` (2 vCPU, 1GiB RAM). 

You need to provision:
* **1 Control Plane Node**
* **6 Worker Nodes**

> **Important**: Ensure your firewall / security groups allow the specific Kubernetes communication ports (e.g., 6443, 10250) and Flannel CNI overlay network ports (UDP 8472).

---

## 2. Initialize Control Plane
On your **Control Plane node**, run the startup script. This script prepares the node (installing containerd, crictl, kubelet, kubeadm, etc.) and finishes by automatically initializing the Kubernetes cluster using the provided configuration:
```bash
sudo bash cluster-provisioner/startup-script.sh
```
*(Note: The script has been updated so that its final step is to run `kubeadm init --config kubeadm.conf` and configure the `kubeconfig` for your user.)*

---

## 3. Apply Network and Telemetry
After the cluster is initialized and your `kubectl` is configured, apply the Flannel CNI for networking, and the Goldpinger DaemonSet for network latency measurement:
```bash
kubectl apply -f cluster-provisioner/flannel.yaml
kubectl apply -f cluster-provisioner/goldpinger.yaml
```

---

## 4. Join Worker Nodes
Run the `kubeadm join` command that was outputted by the control plane initialization on all **6 Worker Nodes** to attach them to the cluster.

---

## 5. Deploy Prometheus Monitoring Stack
To evaluate network locality, deploy Prometheus using Helm to collect latency metrics from Goldpinger. Because `t3.micro` nodes are severely resource-constrained, you must remove heavy monitoring overhead:
* Disable Grafana, Alertmanager, `kube-state-metrics`, and `node-exporter` in your Helm values.
* Pin the Prometheus server strictly to `worker-6` using node selectors.
* **Cordon** `worker-6` so the descheduler and test workloads do not get scheduled on it.

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install prometheus prometheus-community/prometheus \
  --namespace monitoring --create-namespace \
  --set alertmanager.enabled=false \
  --set pushgateway.enabled=false \
  --set kube-state-metrics.enabled=false \
  --set prometheus-node-exporter.enabled=false \
  --set server.nodeSelector.kubernetes\\.io/hostname=<name-of-worker-6>

kubectl cordon <name-of-worker-6>
```
Once Prometheus is running, apply the scraping configuration for Goldpinger:
```bash
kubectl apply -f cluster-provisioner/goldpinger-scraper.yaml
```

---

## 6. Label Nodes by Locality
Label all active worker nodes (`worker-1` through `worker-5`) according to their designated region and zone:
```bash
kubectl label nodes <worker-1> topology.kubernetes.io/region=us-east-1 topology.kubernetes.io/zone=us-east-1a
# Repeat for the rest of the nodes based on your topology scenario
```

---

## 7. Setup Degraded Zone
Label `worker-4` and `worker-5` to identify them as part of the degraded latency zone:
```bash
kubectl label nodes <worker-4> <worker-5> simulate-zone="degraded-zone"
```

---

## 8. Apply Latency Simulation
Apply the latency simulation DaemonSet. This will inject synthetic network delay (via Linux `tc` netem) onto the nodes labeled in the previous step, simulating high cross-zone round-trip times.
```bash
kubectl apply -f cluster-provisioner/latency-sim.yaml
```

---

## Running the Tests

### 9. Deploy Descheduler Service Account
Apply the default Kubernetes Descheduler ServiceAccount and ClusterRole.
**Crucial Step:** You must edit the `ClusterRole` permissions for the descheduler to explicitly allow reading `PersistentVolumeClaims` (`pvc`), as the defragmentation and predictive target logic requires it.

### 10. Generate Policy Configurations
Run the Python config generator to build the descheduler policy manifests needed for the tests.
```bash
python3 test-script/generate_configs.py
```
*(You can modify the configurations directly within `generate_configs.py` before running it).*

### 11. Execute Test Sessions
Use the provided scripts to evaluate specific scenarios. Each script resets the cluster state, populates the workloads, and triggers the descheduler.

* **LowNodeUtilization Test**: 
  ```bash
  bash test-script/run-session1.sh
  ```
  *(To run the "No Filler" strict tradeoff test, edit `run-session1.sh` and change its source file from `reset-low.sh` to `reset-low-nofiller.sh`).*

* **HighNodeUtilization Test**:
  ```bash
  bash test-script/run-session2.sh
  ```

* **ResourceDefragmentation Test**:
  ```bash
  bash test-script/run-session3.sh
  ```

### 12. Wait and Analyze Results
Wait for the descheduling pass to complete and workloads to stabilize, then run the analyzer script to compute evaluation metrics:
```bash
bash test-script/analyze.sh
```
The table output will display the Evicted Pod Count, Standard Deviation changes, Mean RII changes, and Average Latency Degradation across the cluster.
