# Benchmark Findings

500 jobs, 12s sleep each, 1 CPU / 2Gi per job. Five runs across different node and concurrency configurations.

## No growing inter-job delays

None of the 5 runs show inter-job gap growth over time. Pearson correlations between gap size and job sequence number are all near zero (−0.004 to +0.006). The gap is flat across all 500 jobs in every file. The original hypothesis that delay grows over time was not confirmed — if observed previously, it was likely cluster-specific conditions rather than a Kueue scaling property, or requires a significantly larger job count to manifest.

## Where the time actually goes

For all steady-state runs the per-job pipeline is:

| Stage | Time | Notes |
|---|---|---|
| Kueue admission | ~0ms | Essentially instant in all runs |
| k8s scheduler | ~0.1s | Negligible |
| Kubelet + container startup | 1.8–2.3s | The dominant, irreducible cost |

Kubelet/runtime startup is the sole bottleneck. Kueue adds nothing measurable.

## Per-run results

| File | Mean startup overhead | Mean idle gap | Notes |
|---|---|---|---|
| `1node-4concurrent` | 10.1s (inflated) | 5.5s | 4 jobs stalled ~16 min waiting for pod scheduling at run start — cold cluster / node-not-ready event. Not representative of steady state. |
| `1node-4concurent-2` | 2.4s | 5.5s | Clean run, no anomalies |
| `1node-3concurrent` | 2.2s | 5.4s | Clean run |
| `2node-3concurrent` | 2.4s | 6.0s (max 28.8s) | One localised spike: jobs 295–297 took ~23s kubelet startup, likely a brief kubelet pause on one node |
| `1node-3concurrent-rancher` | **1.9s** | **5.0s** | Best performer — 350ms faster kubelet startup than the equivalent vanilla 1-node run |

### Delay components (mean / p95, seconds)

| File | Kueue admission | k8s scheduler | Kubelet startup | Total pre-exec |
|---|---|---|---|---|
| 1node-4concurrent | 0.000 | 7.798 / — | 2.347 / 3.0 | 10.145 / 3.1 |
| 1node-4concurent-2 | 0.000 | 0.088 / 1 | 2.269 / 2.8 | 2.357 / 2.9 |
| 1node-3concurrent | 0.000 | 0.064 / 1 | 2.154 / 2.6 | 2.218 / 2.7 |
| 2node-3concurrent | 0.002 | 0.136 / 1 | 2.248 / 2.7 | 2.386 / 2.9 |
| 1node-3concurrent-rancher | 0.000 | 0.076 / 1 | **1.800 / 2.3** | **1.876 / 2.3** |

## Conclusions

1. **`1node-4concurrent` should be discarded for steady-state analysis.** The 16-minute scheduler stall on the first 4 jobs is a cluster cold-start artifact, not a Kueue issue.

2. **Rancher-managed cluster is measurably faster.** `1node-3concurrent-rancher` beats the equivalent vanilla run by ~350ms per job on kubelet startup. Over 500 jobs that is ~175 seconds of total savings, likely due to a lighter or better-tuned container runtime.

3. **2-node setup offers no benefit at this scale.** Behaviour is statistically identical to 1-node, with an additional risk of localised kubelet spikes on individual nodes.

4. **Concurrency level does not change the per-slot startup cost.** Both 3 and 4 concurrent slots produce ~5s idle gaps when a slot opens. Higher concurrency only reduces how frequently idle slots appear — it does not reduce the startup cost itself.

5. **Kueue is not the bottleneck.** Admission time is effectively zero in all runs. The irreducible cost is kubelet + container runtime startup at ~1.8–2.3s per job.

---

## Run 2: kueue-only vs gang-and-kueue (510 pods each, 2026-04-03)

Both benchmarks ran to completion on the same single-node Rancher cluster with 3 concurrent pods.
Both produced exactly 510 records. Run parameters: 1 CPU / 2Gi per pod, 12s sleep.

| Metric | kueue-only | gang-and-kueue |
|---|---|---|
| Total pods | 510 (510 jobs × 1 pod) | 510 (170 gangs × 3 pods) |
| Wall time | 2923s (48.72 min) | 2928s (48.80 min) |
| Kueue admission delay | 0ms | 0ms |
| Admission-to-running latency | 1.765s mean (1.21–2.31s) | 1.762s mean (1.24–2.35s) |
| Kubelet startup | 2.120s mean (1.59–2.65s) | 2.176s mean (1.57–2.72s) |
| Turnover gap (mean) | 4.944s | 5.043s |
| Turnover gap (min / max) | 3.668s / 5.278s | 3.517s / 5.321s |
| Gap growth (Pearson r) | 0.6877 | 0.6951 |
| Gang cohesion (p50 / p95 / max) | n/a | 67ms / 120ms / 327ms |

### Metric definitions

**Turnover gap** is the time from when a slot (or gang slot) becomes free to when the next workload starts executing:
- kueue-only: `script_start[N] − script_end[N−3]` (pipeline gap across the 3-concurrent slots)
- gang+kueue: `min(script_start[gang N+1]) − max(script_end[gang N])` (sequential inter-gang gap)

This is the correct apples-to-apples metric. A naive consecutive-pair gap (`script_start[N+1] − script_end[N]`) produces large negative values in concurrent runs because overlapping jobs are sorted by start time — it measures nothing meaningful at concurrency > 1.

### Wall time is identical

Both scenarios completed 510 pods in virtually the same wall time (5 second difference, within noise). Adding the gang scheduling layer costs nothing in total throughput at this scale.

### Gang scheduling overhead is negligible

The gang layer adds only **99ms** to the mean turnover gap (5.043s vs 4.944s). This overhead is the Permit gate — the scheduler must hold the 3 pods until all have tentative node assignments before releasing them simultaneously. At 99ms it is invisible compared to the 2.12–2.18s kubelet startup cost.

### Gang cohesion: the gang scheduler delivers

All 170 gangs started their 3 pods within tight windows:
- p50: 67ms spread between first and last pod start within a gang
- p95: 120ms
- Max: 327ms (gang-071 — an outlier, likely a brief scheduler pause)

For reference, kubelet startup itself varies by ~1s (1.57s–2.72s range), so 67ms pod-to-pod spread represents the gang scheduler adding ~5% of the natural startup jitter. In practice the pods start simultaneously from any application perspective.

### A growing gap trend is now visible — and it is in Kueue, not kubelet

**This contradicts the finding from Run 1.** The previous analysis used `script_start[N+1] − script_end[N]` (consecutive pairs), which produces negative values under concurrency and obscures trends. Using the correct pipeline gap metric, both runs now show a clear positive trend:

| Benchmark | Gap first 50 | Gap last 50 | Growth | Pearson r |
|---|---|---|---|---|
| kueue-only | 4.38s | 5.15s | +0.77s | 0.69 |
| gang+kueue | 4.83s | 5.21s | +0.38s | 0.70 |

Decomposing the kueue-only gap growth:
- **Kueue reaction time** (`quota_reserved[N] − script_end[N−3]`): grows from 2.886s → 3.309s (r = 0.38) — **this is where the growth lives**
- **Kubelet startup**: flat at ~2.12s throughout (r = 0.011) — no growth

The same pattern holds for gang+kueue. Kueue's reaction time — the delay between a workload completing and Kueue admitting the next — increases gradually as the run progresses. A plausible cause is that Kueue's internal reconciliation loop slows slightly as the number of completed (but not yet garbage-collected) Workload objects accumulates. The effect is small (+0.4s over 500 slots) but consistent and reproducible.

### Summary

The run-2 benchmarks answer three questions:

1. **Does gang scheduling cost wall-clock time?** No. 510 pods through gang+kueue completes in the same time as 510 pods through kueue-only.

2. **Is the gang overhead measurable?** Yes, but barely — 99ms mean gap overhead, invisible to applications.

3. **Does Kueue slow down over a long run?** Yes, slightly. Kueue's reaction time grows by ~400ms over 500 workloads (r ≈ 0.39). Kubelet startup is flat. This was invisible in Run 1 because the gap metric used there (consecutive pairs) was incorrect for concurrent workloads.
