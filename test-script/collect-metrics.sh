#!/bin/bash
# collect-metrics.sh <scenario> <before|after>
SCENARIO=$1; PHASE=$2; DIR="./results/${SCENARIO}"; mkdir -p "$DIR"

echo "=== ${SCENARIO} / ${PHASE} ==="

# 1. Request-based node utilization (matches descheduler's view)
#    Formula: util% = sum(pod requests on node) / node allocatable × 100
#    Computed for BOTH CPU and memory
echo "--- Request-Based Node Utilization ---"
python3 - <<'PY' | tee "${DIR}/${PHASE}_node_util.txt"
import subprocess, json, math

def parse_cpu(val):
    """Convert CPU string to millicores: '500m' -> 500, '2' -> 2000"""
    if not val: return 0
    val = str(val)
    if val.endswith('m'): return int(val[:-1])
    return int(float(val) * 1000)

def parse_mem(val):
    """Convert memory string to MiB: '256Mi' -> 256, '1Gi' -> 1024"""
    if not val: return 0
    val = str(val)
    if val.endswith('Ki'): return int(val[:-2]) / 1024
    if val.endswith('Mi'): return int(val[:-2])
    if val.endswith('Gi'): return int(val[:-2]) * 1024
    if val.endswith('k'):  return int(val[:-1]) / 1024
    if val.endswith('M'):  return int(val[:-1])
    if val.endswith('G'):  return int(val[:-1]) * 1024
    return int(val) / (1024 * 1024)  # bytes to MiB

def stddev(values):
    mean = sum(values) / len(values)
    var = sum((v - mean) ** 2 for v in values) / len(values)
    return mean, var ** 0.5

nodes = json.loads(subprocess.check_output(
    ["kubectl", "get", "nodes", "-o", "json"]).decode())["items"]
# Exclude unschedulable nodes (controlplane and worker-286)
nodes = [n for n in nodes if n["metadata"]["name"] not in ["controlplane", "worker-286"]]
pods = json.loads(subprocess.check_output(
    ["kubectl", "get", "pods", "--all-namespaces",
     "--field-selector=status.phase=Running", "-o", "json"]).decode())["items"]

# Sum CPU and memory requests per node (separate DaemonSet vs workload)
cpu_reqs = {}       # total (all pods)
mem_reqs = {}       # total (all pods)
cpu_workload = {}   # non-DaemonSet only
mem_workload = {}   # non-DaemonSet only
for pod in pods:
    nn = pod["spec"].get("nodeName", "")
    if not nn: continue
    # Check if pod is owned by a DaemonSet
    is_daemonset = any(
        ref.get("kind") == "DaemonSet"
        for ref in pod["metadata"].get("ownerReferences", [])
    )
    for c in pod["spec"].get("containers", []):
        res = c.get("resources", {}).get("requests", {})
        cpu_val = parse_cpu(res.get("cpu", "0"))
        mem_val = parse_mem(res.get("memory", "0"))
        cpu_reqs[nn] = cpu_reqs.get(nn, 0) + cpu_val
        mem_reqs[nn] = mem_reqs.get(nn, 0) + mem_val
        if not is_daemonset:
            cpu_workload[nn] = cpu_workload.get(nn, 0) + cpu_val
            mem_workload[nn] = mem_workload.get(nn, 0) + mem_val

cpu_utils = []
mem_utils = []
active_nodes_count = 0
print(f"{'NODE':<16} {'CPU_REQ':>8} {'CPU_ALLOC':>10} {'CPU%':>6} {'MEM_REQ':>8} {'MEM_ALLOC':>10} {'MEM%':>6}  {'WORKLOAD':>8}  LOCATION")
for node in sorted(nodes, key=lambda n: n["metadata"]["name"]):
    name = node["metadata"]["name"]
    cpu_alloc = parse_cpu(node["status"]["allocatable"].get("cpu", "0"))
    mem_alloc = parse_mem(node["status"]["allocatable"].get("memory", "0"))
    cpu_req = cpu_reqs.get(name, 0)
    mem_req = mem_reqs.get(name, 0)
    cpu_pct = (cpu_req / cpu_alloc * 100) if cpu_alloc > 0 else 0
    mem_pct = (mem_req / mem_alloc * 100) if mem_alloc > 0 else 0
    cpu_utils.append(cpu_pct)
    mem_utils.append(mem_pct)
    # "Active" = has non-DaemonSet workload requests
    has_workload = cpu_workload.get(name, 0) > 0 or mem_workload.get(name, 0) > 0
    if has_workload:
        active_nodes_count += 1
    zone = node["metadata"].get("labels", {}).get("topology.kubernetes.io/zone", "?")
    region = node["metadata"].get("labels", {}).get("topology.kubernetes.io/region", "?")
    marker = "active" if has_workload else "empty"
    print(f"{name:<16} {cpu_req:>6}m  {cpu_alloc:>8}m  {cpu_pct:>5.1f}% {mem_req:>6.0f}Mi {mem_alloc:>8.0f}Mi {mem_pct:>5.1f}%  {marker:>8}  ({region}/{zone})")

# All-nodes StdDev
cpu_mean, cpu_sd = stddev(cpu_utils)
mem_mean, mem_sd = stddev(mem_utils)

# Calculate Mean RII
rii_list = [abs(c - m) for c, m in zip(cpu_utils, mem_utils)]
mean_rii = sum(rii_list) / len(rii_list) if rii_list else 0

print(f"\nDefragmentation (all nodes, N={len(cpu_utils)}):")
print(f"  CPU:    mean={cpu_mean:.1f}%  cpu_stddev={cpu_sd:.1f}%")
print(f"  Memory: mean={mem_mean:.1f}%  mem_stddev={mem_sd:.1f}%")
print(f"  Mean RII: mean_rii={mean_rii:.1f}%")
print(f"  ActiveNodes={active_nodes_count} (nodes with non-DaemonSet workload requests)")
PY

# 2. Pod placement
echo "--- Pod Placement ---"
kubectl get pods -n test-app -o wide --sort-by=.spec.nodeName \
  | tee "${DIR}/${PHASE}_pods.txt"

# 3. Network-group distribution
echo "--- Network Group Distribution ---"
kubectl get pods -n test-app -l network-group=checkout-flow \
  -o custom-columns='NAME:.metadata.name,APP:.metadata.labels.app,NODE:.spec.nodeName' \
  | tee "${DIR}/${PHASE}_group.txt"

# 4. Group communication cost (cross-service only, excludeSameOwner)
echo "--- Group Communication Cost ---"
python3 - <<'PY' | tee "${DIR}/${PHASE}_cost.txt"
import subprocess, json, urllib.request, urllib.parse

# 1. Fetch pods
pods = json.loads(subprocess.check_output(["kubectl","get","pods","-n","test-app","-l","network-group=checkout-flow","-o","json"]).decode())["items"]

# 2. Fetch latency from Prometheus using urllib to avoid curl/subprocess shell quoting issues
query = "(rate(goldpinger_peers_response_time_s_sum[5m]) / rate(goldpinger_peers_response_time_s_count[5m])) * on(host_ip) group_left(node) kube_pod_info{namespace='monitoring'}"
url = "http://localhost:9090/api/v1/query?" + urllib.parse.urlencode({"query": query})

try:
    req = urllib.request.Request(url)
    with urllib.request.urlopen(req) as response:
        lat_raw = json.loads(response.read().decode())
except Exception as e:
    print(f"Error querying Prometheus: {e}")
    lat_raw = {}

latency = {}
results = lat_raw.get("data", {}).get("result", [])
if not results:
    print("WARNING: Prometheus query returned 0 metrics!")

for s in results:
    metric = s.get("metric", {})
    src = metric.get("goldpinger_instance", "")
    dst = metric.get("node", "")
    val = float(s.get("value", [0, 0])[1])
    latency[(src, dst)] = val

apps = {}
for p in pods:
    app = p["metadata"]["labels"].get("app","?")
    apps.setdefault(app,[]).append(p["spec"].get("nodeName",""))

total, pairs = 0.0, 0
for i, a in enumerate(list(apps)):
    for b in list(apps)[i+1:]:
        for na in apps[a]:
            for nb in apps[b]:
                val = latency.get((na, nb))
                if val is None:
                    # Try reverse direction path
                    val = latency.get((nb, na))
                if val is not None:
                    total += val
                    pairs += 1
                else:
                    print(f"  Warning: No latency data found for pair ({na} -> {nb})")

# Convert from seconds to milliseconds
total_ms = total * 1000
avg_ms = total_ms / max(pairs, 1)
print(f"pairs={pairs} total_cost={total_ms:.3f}ms avg={avg_ms:.3f}ms")
for app, nodes in apps.items():
    print(f"  {app}: {len(nodes)} pods on {sorted(set(nodes))}")
PY