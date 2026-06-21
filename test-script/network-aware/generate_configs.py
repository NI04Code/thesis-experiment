#!/usr/bin/env python3
"""Generate all 17 descheduler policy YAML configs for E2E testing."""
import yaml
import os

os.makedirs("configs", exist_ok=True)

PROMETHEUS_URL = "http://prometheus-kube-prometheus-prometheus.prom.svc.cluster.local:9090"

QUERY = """(rate(goldpinger_peers_response_time_s_sum[5m])
/
rate(goldpinger_peers_response_time_s_count[5m]))
* on(host_ip) group_left(node) kube_pod_info{namespace="monitoring"}"""


def write_config(strategy, level, metric_type):
    if level == "baseline":
        name = f"{strategy}-baseline"
    else:
        name = f"{strategy}-{level}-{metric_type}"

    obj = {
        "apiVersion": "descheduler/v1alpha2",
        "kind": "DeschedulerPolicy",
        "profiles": [
            {
                "name": name,
                "pluginConfig": [
                    {"name": "DefaultEvictor", "args": {"nodeFit": True}}
                ],
                "plugins": {
                    "filter": {"enabled": ["DefaultEvictor"]},
                    "preevictionfilter": {"enabled": ["DefaultEvictor"]},
                },
            }
        ],
    }

    # Latency-based configs need a Prometheus metricsProvider
    if metric_type == "latency":
        obj["metricsProviders"] = [
            {"source": "Prometheus", "prometheus": {"url": PROMETHEUS_URL}}
        ]

    pconf = obj["profiles"][0]["pluginConfig"]
    plugins = obj["profiles"][0]["plugins"]

    # --- L1: NetworkCostEvictor (PreEvictionFilter) ---
    if level in ["l1", "both"]:
        args = {
            "networkGroupLabelKey": "network-group",
            "minBetterCandidatesPercent": 75,
            "excludeSameOwner": True,
        }
        if metric_type == "latency":
            args["latencyMetrics"] = {
                "prometheus": {
                    "query": QUERY,
                    "sourceNodeLabel": "goldpinger_instance",
                    "targetNodeLabel": "node",
                }
            }
        pconf.append({"name": "NetworkCostEvictor", "args": args})
        plugins["preevictionfilter"]["enabled"].append("NetworkCostEvictor")

    # --- L2: NodeUtilization (Balance / Deschedule) or ResourceDefragmentation ---
    if strategy == "low":
        plugin_name = "LowNodeUtilization"
        plugin_args = {
            "thresholds": {"cpu": 20, "memory": 20},
            "targetThresholds": {"cpu": 50, "memory": 50},
        }
    elif strategy == "high":
        plugin_name = "HighNodeUtilization"
        plugin_args = {
            "thresholds": {"cpu": 30, "memory": 40},
        }
    elif strategy == "imbalance":
        plugin_name = "ResourceDefragmentation"
        plugin_args = {
            "imbalanceThreshold": 0.15,
            "usageMode": "requests",
            "maxEvictions": 50,
        }

    if level in ["l2", "both"] and strategy in ["low", "high"]:
        strategy_val = "topology" if metric_type == "topo" else metric_type
        plugin_args["networkAware"] = {
            "networkGroupLabelKey": "network-group",
            "minBetterCandidatesPercent": 75,
            "excludeSameOwner": True,
            "strategy": strategy_val,
        }
        if metric_type == "latency":
            plugin_args["networkAware"]["latencyMetrics"] = {
                "prometheus": {
                    "query": QUERY,
                    "sourceNodeLabel": "goldpinger_instance",
                    "targetNodeLabel": "node",
                }
            }

    pconf.append({"name": plugin_name, "args": plugin_args})
    plugins["balance"] = {"enabled": [plugin_name]}

    filepath = f"configs/{name}.yaml"
    with open(filepath, "w") as f:
        yaml.dump(obj, f, sort_keys=False)
    print(f"  ✓ {filepath}")


# --- Generate all configs ---
print("Generating descheduler configs...\n")
for s in ["low", "high"]:
    write_config(s, "baseline", None)
    for l in ["l1", "l2", "both"]:
        for t in ["topo", "latency"]:
            write_config(s, l, t)

# Imbalance only tests baseline and L1
write_config("imbalance", "baseline", None)
write_config("imbalance", "l1", "topo")
write_config("imbalance", "l1", "latency")

print(f"\nAll config files generated in ./configs/")