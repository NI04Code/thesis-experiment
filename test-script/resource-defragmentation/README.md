# Walkthrough — re-running the consolidation experiment

How to reproduce the `ResourceDefragmentation` (RD) descheduler evaluation in this
directory, from a clean cluster to aggregated tables. Every step is plain
`kubectl` + `python3`; nothing else is required.

---

## 0. Prerequisites

| Requirement | Detail |
|---|---|
| **Cluster** | 1 control-plane + **6 workers**, each **2000m CPU / 830876Ki (~811 MiB)** allocatable (kubeadm v1.36.1, flannel CNI in the original run). Worker count is overridable via `WORKER_COUNT`, but the scenario pod sizes are hand-scaled to 2000m/811Mi workers — change the node shape and you must re-tune the scenarios. |
| **`kubectl`** | Configured against the cluster, with rights to cordon/uncordon nodes, create namespaces, deploy, and apply RBAC in `kube-system`. |
| **`python3`** | Stdlib only (for `metrics.py` and the `aggregate_*.py` scripts). |
| **Descheduler image** | The runs pull `keegou/descheduler-custom:<tag>` from a registry the cluster can reach (tags: `alpha-7/8/9`, `beta-1`…`beta-5`). The cluster nodes must be able to pull these. |
| **Scheduler precondition** | The cluster scheduler **must pack** (MostAllocated + BalancedAllocation). See §2 — this is the single most important precondition; with the default LeastAllocated scheduler the whole experiment is invalid. |

```bash
cd /home/ubuntu/experiment
chmod +x */*.sh          # first time only
kubectl get nodes        # confirm 6 schedulable workers + 1 control-plane
```

---

## 1. How the harness works (read once)

- **[`common.sh`](common.sh)** — shared bash helpers sourced by every scenario script. Key knobs (all env-overridable):
  - `NS=defrag-exp` — experiment namespace (created if missing; never auto-deleted).
  - `WORKER_COUNT=6`, `PAUSE_IMAGE=registry.k8s.io/pause:3.9`.
  - `MAX_PASSES=5` — re-run the descheduler until a pass evicts 0 (convergence) or this cap.
  - `SETTLE_SECONDS=20` — wait after each pass for re-scheduling.
  - `SUT_MANIFEST` — which descheduler manifest to apply (defaults to `descheduler/sut-requests.yaml`).
  - `RUN_TAG` — suffix appended to the results dir name (used to label strategy/seed).
- **Workload** = `pause` pods that reserve their CPU/mem **requests** and use ~0, so in *requests mode* declared load == accounted load. No metrics-server needed.
- **Why setup cordons nodes:** under a packing scheduler, just applying Deployments would pack them at deploy time, leaving no fragmented "before" state. So setup **cordons all workers, then uncordons one at a time** to seed each node deterministically, then **uncordons all** before the descheduler runs. Pods carry no `nodeName`/affinity, so the descheduler can move them freely.
- Each `perform_and_capture.sh` does: **before** snapshot → up to `MAX_PASSES` descheduler passes → **after** snapshot, writing everything under `results/<scenario>/<timestamp>[-RUN_TAG]/`.
- **[`metrics.py`](metrics.py)** is tool-agnostic — it reads only `kubectl get nodes/pods -o json`, never descheduler logs, so the numbers are comparable across RD / HNU / any baseline. It emits N_active, N_empty, S (stranding), and H_* headroom probes.

Captured per run (see the table in [`README.md`](README.md)): `metrics_before/after.txt`,
`nodes_*.json`, `pods_*.json`, `desched_passN.log`, `events_descheduled.txt`,
`pdb.txt`, `summary.txt`.

---

## 2. Verify the scheduler packs (do this first, once)

The plugin assumes the cluster scheduler packs. Confirm
`/etc/kubernetes/scheduler-config.yaml` on the control-plane matches
[`scheduler/most-allocated-config.yaml`](scheduler/most-allocated-config.yaml)
(NodeResourcesFit = **MostAllocated** + NodeResourcesBalancedAllocation):

```bash
# on the control-plane node:
sudo cat /etc/kubernetes/scheduler-config.yaml
# the kube-scheduler must run with --config=/etc/kubernetes/scheduler-config.yaml
```

If it shows LeastAllocated (the kube default), edit it to match the reference file;
the static pod restarts automatically. The same profile must be used for **every**
strategy you compare (fairness control). §6 of `REPORT.md` documents how the pack
was confirmed empirically.

---

## 3. Run one scenario (the basic loop)

Three steps per scenario: **setup → perform_and_capture → cleanup**. Example (S2,
the discriminating fragmented scenario):

```bash
cd /home/ubuntu/experiment

./s2_fragmented/scenario_s2_setup.sh      # seed the fragmented layout
./s2_fragmented/perform_and_capture.sh    # before -> descheduler passes -> after
./s2_fragmented/cleanup.sh                # tear down, uncordon, remove the job
```

Results land in `results/s2/<timestamp>/`. `cat results/s2/<ts>/summary.txt` for the
per-pass eviction counts and convergence; `metrics_before/after.txt` for N/S/H.

The scenarios (sizes scaled to 2000m/811Mi workers):

| Scenario | Setup script | Intent |
|---|---|---|
| **S1** under-utilized | `s1_underutilized/scenario_s1_setup.sh` | pure consolidation (O1) |
| **S2** fragmented | `s2_fragmented/scenario_s2_setup.sh` | reducible stranding (O2/O3) — the discriminator |
| **S3** mixed | `s3_mixed/scenario_s3_setup.sh` | O1 + O2 together |
| **S4** hogs+jumbo | `s4_hogs/scenario_s4_setup.sh` | merge hogs around an unmovable jumbo (5/6 filled) |
| **S5** heterogeneous | `s5_heterogeneous/scenario_s5_setup.sh` | selector ablation (one drain node, complementary receivers) |
| **S6** c1/c3/c4/mix | `s6_c1`, `s6_c3`, `s6_c4`, `s6_mix/scenario_*_setup.sh` | per-criterion selector necessity (needs PriorityClasses) |

Useful overrides:

```bash
MAX_PASSES=6   ./s2_fragmented/perform_and_capture.sh   # cap descheduler re-runs
SETTLE_SECONDS=30 ./s2_fragmented/perform_and_capture.sh
MAX_PASSES=0   ./s2_fragmented/perform_and_capture.sh   # B0 row: before == after, no descheduler
SUT_MANIFEST=$PWD/descheduler/b1-hnu.yaml ./s2_fragmented/perform_and_capture.sh   # run a different strategy
```

---

## 4. Choosing the descheduler / strategy ([`descheduler/`](descheduler))

`SUT_MANIFEST` picks which descheduler runs. Use **`descheduler/rd-c2-beta5.yaml`** —
it is the single, current SUT manifest: a self-contained ServiceAccount + RBAC +
ConfigMap(policy) + Job running `ResourceDefragmentationC2` on the `beta-5` image.
The harness deletes & recreates the Job each pass (idempotent re-apply).

Its **fairness controls** (the knobs to keep fixed across runs): namespace scope
`defrag-exp`, `usageMode: requests`, `consolidationThreshold: 0.40`,
`consolidationTarget: 0.9`, `maxEvictions: 50`.

If `SUT_MANIFEST` is unset the harness falls back to its built-in default; pass it
explicitly so every run uses the same manifest:

```bash
SUT_MANIFEST=$PWD/descheduler/rd-c2-beta5.yaml ./<scenario>/perform_and_capture.sh
```

---

## 5. The driver scripts (multi-strategy / multi-seed)

These wrap the basic loop over scenarios × strategies × seeds, waiting for the
namespace to drain to zero between runs so placements are independent. Run from the
`experiment/` directory.

| Script | What it does | Key env |

| [`run_s15_compare_beta5.sh`](run_s15_compare_beta5.sh) | S1–S5 × {hnu, rdc2} both on the **beta-5** binary (only strategy varies); tees to a log | `SEEDS`, `SCENARIOS`, 
Examples:

```bash
# Beta-5 two-way (HNU vs RD-C2 on the same binary):
SEEDS=3 ./run_s15_compare_beta5.sh


# A subset of the S6 necessity suite:
SCENARIOS="s6-mix" POLICIES="topsis just-c2" SEEDS=1 ./run_s6_suite.sh
```

Driver runs tag their results dirs as `<ts>-<strategy>-k<seed>` (or
`<ts>-<policy>-k<seed>` for ablation) so the aggregators can group them.

---

## 6. Aggregate the results

The `aggregate_*.py` scripts scan `results/` and print mean ± 95% CI tables.

```bash
# S1-S5 x {hnu, rd, rdc2} comparison. RUN_DATE filters by the run's date prefix
# (default 20260607) so old same-named runs aren't mixed in; STRATS picks columns.
RUN_DATE=20260607 STRATS="hnu rd rdc2" python3 aggregate_compare.py
RUN_DATE=<YYYYMMDD> STRATS="hnu rdc2" python3 aggregate_compare.py   # beta-5 two-way

# S5 selector ablation -> per-policy S/H table:
python3 aggregate_s5.py

# S6 necessity suite -> regret matrix + N1-N4 verdict:
python3 aggregate_suite.py
```

`RUN_DATE` matters: `aggregate_compare.py` only reads dirs whose timestamp starts
with that date. Set it to the date your driver actually ran.

---

## 7. Baselines

- **B0 (no descheduler):** run setup, then `MAX_PASSES=0 ./<scn>/perform_and_capture.sh`. The before snapshot == after; the "before" of any normal run is already the B0 reference.
- **B1 (HighNodeUtilization):** `SUT_MANIFEST=$PWD/descheduler/b1-hnu.yaml ./<scn>/perform_and_capture.sh`, or use a driver with the `hnu` strategy. Same scope + 0.40 threshold as RD.
- **E (evictions)** is counted tool-agnostically from the framework `"Evicted pod"` log line (every plugin emits it), cross-checked against `events_descheduled.txt`.

---

## 7b. Actual-usage + network-aware run

The S1–S6 scenarios use `pause` pods in **requests mode** (declared load ==
accounted load). To exercise the plugin with **actual usage** and the
**network-aware** path instead, use the **`descheduler/rd-c2-beta5.yaml`** config —
the beta-5 binary is the one that supports those signals.

Two things change versus the standard loop:

1. **Workload must do real work.** `pause` pods report ~0 actual usage, so an
   actual-usage run on them looks like a fully-empty cluster. Seed pods that
   genuinely consume CPU/mem and talk to each other (a real app, or chatty
   client/server pods), rather than the `pause` workloads `common.sh` deploys.
2. **The descheduler must read actual usage.** `rd-c2-beta5.yaml` ships with
   `usageMode: "requests"` pinned (the comment in it explains why: beta-5
   auto-defaults to `actual-ewma` only when a metrics collector is present, and
   this cluster had none). For an actual-usage/network-aware run, install a
   metrics source (e.g. `metrics-server`) and set `usageMode: "actual-ewma"` in
   that manifest's policy ConfigMap before running.

```bash
# one-time: a metrics source must exist for actual-ewma to have data
kubectl top nodes        # must return data; if not, install metrics-server

# edit descheduler/rd-c2-beta5.yaml:  usageMode: "requests" -> "actual-ewma"

# then drive it like any other strategy (point SUT_MANIFEST at beta-5):
SUT_MANIFEST=$PWD/descheduler/rd-c2-beta5.yaml ./<scenario>/perform_and_capture.sh
```

Caveats: `metrics.py` computes its N/S/H numbers from pod **requests**, so for an
actual-usage run treat its output as the requests-side view and read the real
behaviour from the raw `nodes_*.json` / `pods_*.json` + the `desched_pass*.log`
(predicted targets, eviction decisions). The network-aware co-location signal is
visible in the pass logs, not in `metrics.py`.

---

## 8. Cleanup / reset

```bash
./s2_fragmented/cleanup.sh        # per-scenario: delete workloads, uncordon, remove the job
# fully remove the namespace when completely done:
kubectl delete ns defrag-exp
```

Each scenario's `cleanup.sh` deletes that scenario's Deployments (by
`scenario=<id>` label), uncordons all workers (in case a setup was interrupted),
and removes the `descheduler-job`. The namespace is intentionally kept between
runs; delete it manually to fully reset. The drivers already call cleanup and wait
for the namespace to drain between runs.

---

## 9. End-to-end: reproduce the main report

```bash
cd /home/ubuntu/experiment
chmod +x */*.sh

# 1. confirm the scheduler packs (§2) — once.
# 2. headline S1-S3 on the current config + S4:
./run_s123_current.sh
SEEDS=5 ./run_s4_multiseed.sh
# 3. SUT vs B1 baseline:
./run_hnu_vs_rd.sh
SEEDS=5 ./run_s3_multiseed.sh
# 4. inspect: results/<scn>/<ts>*/summary.txt  and  metrics_before/after.txt
# 5. three-way + ablation + necessity suite as needed (§5), then aggregate (§6).
```

Every number in the reports is recomputable from the per-run `nodes_*.json` /
`pods_*.json` via `metrics.py`, so existing `results/` dirs can be re-aggregated
without re-running the cluster work.
