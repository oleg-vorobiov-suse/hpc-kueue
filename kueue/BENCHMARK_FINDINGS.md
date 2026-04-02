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
