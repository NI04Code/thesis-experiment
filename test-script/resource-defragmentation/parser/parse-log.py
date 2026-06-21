import re
import statistics
import json
import matplotlib.pyplot as plt
import numpy as np

# --- 1. Parsing Logic ---
def parse_logs(log_text):
    results = {}
    
    blocks = re.split(r"### (s\d+) / (\w+) / seed (\d+)", log_text)
    
    for i in range(1, len(blocks), 4):
        scenario = blocks[i]
        strategy = blocks[i+1]
        seed = blocks[i+2]
        block_text = blocks[i+3]
        
        if scenario not in results:
            results[scenario] = {}
        if strategy not in results[scenario]:
            results[scenario][strategy] = {
                'initial_s': [], 'final_s': [], 'evictions': [],
                'active_nodes': [], 'h_balanced': [],
                'h_cpu_skewed': [], 'h_mem_skewed': [], 'h_jumbo': [],
                'avg_util': []
            }
            
        # 1. Extract Total Evictions
        eviction_matches = re.findall(r"pass \d+: (\d+) eviction decision\(s\)", block_text)
        evictions = sum(int(e) for e in eviction_matches)
        
        # 2. Extract metrics from METRICS_JSON
        json_matches = re.findall(r"METRICS_JSON ({.*?})", block_text)
        
        before_s = 0.0
        after_s = 0.0
        active_nodes = 0
        h_balanced = 0
        h_cpu_skewed = 0
        h_mem_skewed = 0
        h_jumbo = 0
        
        for j_str in json_matches:
            try:
                j_data = json.loads(j_str)
                if j_data.get("label") == "before":
                    before_s = float(j_data.get("S", 0.0))
                elif j_data.get("label") == "after":
                    after_s = float(j_data.get("S", 0.0))
                    active_nodes = int(j_data.get("N_active", 0))
                    h_balanced = int(j_data.get("H_balanced", 0))
                    # Support both old key name and new renamed key
                    h_cpu_skewed = int(j_data.get("H_cpu_skewed",
                                       j_data.get("H_skewed", 0)))
                    h_mem_skewed = int(j_data.get("H_mem_skewed", 0))
                    h_jumbo = int(j_data.get("H_jumbo", 0))
            except json.JSONDecodeError:
                continue
        
        # 3. Extract Node Table for Average Utilization
        after_split = block_text.split("== AFTER ==")
        avg_util = 0.0
        
        if len(after_split) > 1:
            after_block = after_split[1]
            utils = []
            for line in after_block.split('\n'):
                line = line.strip()
                if line.startswith("ip-"):
                    parts = line.split()
                    if len(parts) >= 8:
                        clean_cpu = re.sub(r'[^\d\.]', '', parts[5])
                        clean_mem = re.sub(r'[^\d\.]', '', parts[6])
                        if clean_cpu and clean_mem:
                            cpu_f = float(clean_cpu)
                            mem_f = float(clean_mem)
                            utils.append((cpu_f + mem_f) / 2.0)
            
            utils.sort(reverse=True)
            active_utils = utils[:active_nodes] if active_nodes > 0 else []
            avg_util = sum(active_utils) / len(active_utils) if active_utils else 0.0
            
        results[scenario][strategy]['initial_s'].append(before_s)
        results[scenario][strategy]['final_s'].append(after_s)
        results[scenario][strategy]['evictions'].append(evictions)
        results[scenario][strategy]['active_nodes'].append(active_nodes)
        results[scenario][strategy]['h_balanced'].append(h_balanced)
        results[scenario][strategy]['h_cpu_skewed'].append(h_cpu_skewed)
        results[scenario][strategy]['h_mem_skewed'].append(h_mem_skewed)
        results[scenario][strategy]['h_jumbo'].append(h_jumbo)
        results[scenario][strategy]['avg_util'].append(avg_util)

    # Calculate averages across seeds
    avg_results = {}
    for sc, strats in results.items():
        avg_results[sc] = {}
        for st, metrics in strats.items():
            avg_results[sc][st] = {k: statistics.mean(v) if v else 0.0 for k, v in metrics.items()}
                
    return avg_results

# --- 2. Chart Generation & Console Output ---
def generate_charts(data):
    scenarios = ['s1', 's2', 's3', 's4', 's5']
    possible_strategies = ['hnu', 'rd', 'rdc2']
    
    strategies = [s for s in possible_strategies if any(s in data.get(sc, {}) for sc in scenarios)]
    
    colors = {'hnu': '#e2e8f0', 'rd': '#93c5fd', 'rdc2': '#2563eb'}
    labels = {
        'hnu': 'HighNodeUtilization',
        'rd': 'Multi-Criteria (TOPSIS)',
        'rdc2': 'Resource Defragmentation'
    }

    print(f"{'Scenario':<10} | {'Strategy':<10} | {'Evictions':<10} | {'Avg Util (%)':<15} | {'Active Nodes':<12} | {'H_cpu_skewed':<14} | {'H_mem_skewed':<14} | {'H_jumbo':<10}")
    print("-" * 110)
    for sc in scenarios:
        for st in strategies:
            d = data.get(sc, {}).get(st, {})
            evictions    = d.get('evictions', 0)
            avg_util     = d.get('avg_util', 0) * 100
            active       = d.get('active_nodes', 0)
            h_cpu_skewed = d.get('h_cpu_skewed', 0)
            h_mem_skewed = d.get('h_mem_skewed', 0)
            h_jumbo      = d.get('h_jumbo', 0)
            print(f"{sc.upper():<10} | {st.upper():<10} | {evictions:<10.1f} | {avg_util:<14.2f}% | {active:<12.1f} | {h_cpu_skewed:<14.1f} | {h_mem_skewed:<14.1f} | {h_jumbo:<10.1f}")
    print("\nGenerating charts...")

    x = np.arange(len(scenarios))
    width = 0.8 / max(len(strategies), 1)

    def get_x_offset(i):
        return x + (i - len(strategies) / 2 + 0.5) * width

    def make_bar_chart(metric_key, ylabel, title, filename,
                       legend_loc='best', pct=False):
        fig, ax = plt.subplots(figsize=(10, 6))
        for i, strat in enumerate(strategies):
            y_vals = [
                data.get(sc, {}).get(strat, {}).get(metric_key, 0) * (100 if pct else 1)
                for sc in scenarios
            ]
            ax.bar(get_x_offset(i), y_vals, width,
                   label=labels[strat], color=colors[strat], edgecolor='black')
        ax.set_ylabel(ylabel)
        ax.set_title(title)
        ax.set_xticks(x)
        ax.set_xticklabels([s.upper() for s in scenarios])
        ax.legend(loc=legend_loc)
        plt.tight_layout()
        plt.savefig(filename)
        plt.close()
        print(f"  Saved {filename}")

    # 1. Final Stranding (S)
    make_bar_chart('final_s',
                   'Stranding Score (S) — Lower is Better',
                   'Final Resource Stranding by Scenario',
                   'chart_stranding.png')

    # 2. Total Evictions
    make_bar_chart('evictions',
                   'Total Pod Evictions',
                   'Eviction Churn by Scenario',
                   'chart_evictions.png')

    # 3. Active Nodes
    make_bar_chart('active_nodes',
                   'Number of Active Nodes',
                   'Active Nodes After Descheduling',
                   'chart_active_nodes.png',
                   legend_loc='lower left')

    # 4. Average Utilization (Active Nodes)
    make_bar_chart('avg_util',
                   'Average Utilization of Active Nodes (%)',
                   'Node Density Post-Descheduling',
                   'chart_avg_utilization.png',
                   legend_loc='lower right',
                   pct=True)

    # 5. H_balanced (Schedulable Pods Yield)
    make_bar_chart('h_balanced',
                   'Schedulable H_balanced Pods (Yield)',
                   'Cluster Schedulability Yield — Balanced Pods (200m/80Mi)',
                   'chart_h_balanced.png',
                   legend_loc='lower right')

    # 6. H_cpu_skewed (CPU-heavy pod yield)
    make_bar_chart('h_cpu_skewed',
                   'Schedulable H_cpu_skewed Pods (Yield)',
                   'Cluster Schedulability Yield — CPU-Skewed Pods (700m/20Mi)',
                   'chart_h_cpu_skewed.png',
                   legend_loc='lower right')

    # 7. H_mem_skewed (Memory-heavy pod yield)
    make_bar_chart('h_mem_skewed',
                   'Schedulable H_mem_skewed Pods (Yield)',
                   'Cluster Schedulability Yield — Memory-Skewed Pods (20m/280Mi)',
                   'chart_h_mem_skewed.png',
                   legend_loc='lower right')

    # 8. H_jumbo (Large pod yield)
    make_bar_chart('h_jumbo',
                   'Schedulable H_jumbo Pods (Yield)',
                   'Cluster Schedulability Yield — Jumbo Pods (800m/324Mi)',
                   'chart_h_jumbo.png',
                   legend_loc='lower right')

    print("\nAll charts saved successfully!")

if __name__ == "__main__":
    try:
        with open('raw_logs.txt', 'r', encoding='utf-8') as file:
            log_data = file.read()
        
        parsed_data = parse_logs(log_data)
        generate_charts(parsed_data)
        
    except FileNotFoundError:
        print("Please save your log data into a file named 'raw_logs.txt' to run this script.")