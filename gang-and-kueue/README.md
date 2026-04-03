# Gang Scheduling + Kueue Combined Benchmark

Combines two orthogonal Kubernetes scheduling layers:

- **Kueue** (v0.17.0) — admission controller. Suspends all Jobs on creation, admits them FIFO when ClusterQueue quota is available. Controls *when* pods are created.
- **k8s 1.35 Gang Scheduling** (KEP-4671, Alpha) — in-tree kube-scheduler plugin. Holds all pods in a gang at the Permit gate until they can all start simultaneously. Controls *how* pods start.

**Benchmark design**: 170 gangs × 3 pods = 510 total pods. ClusterQueue quota: 3 CPU / 6Gi → exactly 1 gang admitted at a time → 3 concurrent pods. Directly comparable to the `kueue/` standalone benchmark (also 3 concurrent pods, 510 total).

## Prerequisites

- RKE2 v1.35+ with feature gates enabled (see below)
- Kueue v0.17.0 installed (`kueue-system` namespace)
- ResourceFlavor `default` applied (from `../resourceflavor.yaml`)
- `local-path` provisioner installed
- `kubectl` configured

## 1. Install local-path Provisioner

The orchestrator uses a `local-path` PVC for persistent storage. If the provisioner is not already installed in your cluster:

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.35/deploy/local-path-storage.yaml
```

Verify it is running before continuing:

```bash
kubectl -n local-path-storage get pod
# local-path-provisioner-* should be Running
```

See [rancher/local-path-provisioner](https://github.com/rancher/local-path-provisioner?tab=readme-ov-file#installation) for details.

## 2. Install Kueue

```bash
helm install kueue oci://registry.k8s.io/kueue/charts/kueue \
  --version=0.17.0 \
  --namespace kueue-system \
  --create-namespace
```

## 3. Apply the ResourceFlavor (shared with kueue/ demo)

```bash
kubectl apply -f ../resourceflavor.yaml
```

Skip if already applied.

## 4. Enable Feature Gates in RKE2

Add to `/etc/rancher/rke2/config.yaml` on the server node, then restart RKE2:

```yaml
kube-apiserver-arg:
  - "feature-gates=GangScheduling=true,GenericWorkload=true"
  - "runtime-config=scheduling.k8s.io/v1alpha1=true"
kube-scheduler-arg:
  - "feature-gates=GangScheduling=true,GenericWorkload=true"
```

Verify the API is available:

```bash
kubectl get crd workloads.scheduling.k8s.io
# must return a result — if not, the feature gate is not active
```

## 5. Run the Benchmark

```bash
cd demo/
./apply.sh
```

This creates the `gang-bench` namespace, `gang-cq` ClusterQueue, `gang-bench-lq` LocalQueue,
RBAC, orchestrator, and submits all 170 gangs simultaneously.

Kueue suspends all 170 Jobs immediately on creation (zero pods exist). It then admits one gang
at a time. When admitted, the Job controller creates 3 pods; the gang scheduler holds all 3 at
the Permit gate until they can start simultaneously.

Monitor progress:

```bash
kubectl get clusterqueue gang-cq        # watch PENDING/ADMITTED counts
kubectl get jobs -n gang-bench          # watch job completions
kubectl get pods -n gang-bench | grep -v orchestrator
```

## 6. Collect Results

```bash
./collect.sh               # saves to results.jsonl
./collect.sh my-run.jsonl  # or specify a filename
```

510 records expected (170 gangs × 3 pods).

## 7. Reset for Another Run

```bash
./reset.sh
```

Deletes all Jobs and Workload objects, cycles the PVC for a fresh orchestrator filesystem.
Queue infrastructure (`gang-cq`, `gang-bench-lq`) is preserved.

## 8. Full Teardown

```bash
./delete.sh
```

Removes everything except the `gang-bench` namespace and the shared `default` ResourceFlavor.

---

## Architecture

```
170 Workload objects  (scheduling.k8s.io/v1alpha1)
  each defines: podGroups[workers], gang policy, minCount: 3
        │
170 Job objects  (kueue.x-k8s.io/queue-name: gang-bench-lq)
  parallelism: 3, completionMode: Indexed
  pods carry spec.workloadRef → Workload
        │
        ▼ Kueue (admission layer)
  Suspends all 170 Jobs on creation
  Admits 1 gang at a time (3 CPU / 6Gi quota → 1 gang = 3 pods)
        │
        ▼ Gang Scheduler (scheduling layer, KEP-4671)
  Holds all 3 pods at Permit gate until all can start simultaneously
        │
        ▼ (all 3 pods released atomically)
Pod starts → job.py runs
  1. records script_start (first line)
  2. queries Kueue Workload → quota_reserved_time, admitted_time
  3. queries own Pod → pod_scheduled_time
  4. sleep 12s
  5. records script_end
  6. POSTs JSON record to orchestrator-svc:8080
        │
        ▼
Orchestrator Deployment  (python:3-slim, persistent)
  → appends to /data/results.jsonl on local-path PVC
        │
        ▼
kubectl cp → results.jsonl on your local machine
```

### Why no ResourceQuota?

ResourceQuota fires at pod **creation** time. Gang scheduling fires at **scheduling** time.
With a ResourceQuota tight enough to allow only 1 gang:

1. Kueue admits gang A → Job controller creates 3 pods for gang A
2. Kueue admits gang B → Job controller creates 3 pods for gang B
3. ResourceQuota allows only 3 pods total → gang B's pods fail to create
4. Gang A's pods are at Permit gate waiting for each other → gang A is stuck
5. **Deadlock**: gang A can't finish (needs scheduler), gang B can't create (needs quota)

The fix: let Kueue be the sole throttle. Kueue suspends Jobs before pod creation, so the
race condition never occurs. Do not add ResourceQuota to `gang-bench`.

### How the gang scheduler works (KEP-4671)

1. **PreEnqueue** — pods wait in the scheduling queue until `minCount` pods from the same gang are all present.
2. **Reserve** — each pod goes through the normal filter/score pipeline and gets a tentative node assignment.
3. **Permit** — each pod blocks at the Permit gate. When the last pod arrives, all are released simultaneously. If quorum is not reached within 5 minutes, all pods are returned to unscheduled state.

---

## Results Format

Each line of `results.jsonl` is one pod record:

| Field | Source | Measures |
|---|---|---|
| `gang_name` | env var | which gang this pod belongs to |
| `pod_index` | `JOB_COMPLETION_INDEX` (0–2) | pod position within the gang |
| `pod_name` | downward API | pod identity |
| `quota_reserved_time` | Workload condition `QuotaReserved.lastTransitionTime` | Kueue queue wait |
| `admitted_time` | Workload condition `Admitted.lastTransitionTime` | full Kueue admission |
| `pod_scheduled_time` | Pod condition `PodScheduled.lastTransitionTime` | k8s scheduler latency |
| `script_start` | `datetime.now()` — first line of job.py | container startup time |
| `script_end` | `datetime.now()` — after sleep | pod completion time |

### Key metrics to derive

**Gang cohesion** — how tightly all 3 pods in a gang start together:
```
cohesion = max(script_start) - min(script_start)  [within a gang]
```
Should be near-zero if the gang scheduler is working.

**Kueue admission latency per gang**:
```
kueue_wait = quota_reserved_time - job_creation_time
```

**Inter-gang gap**:
```
gap = min(script_start of gang N+1) - max(script_end of gang N)
```

**Comparing with kueue/ standalone**:  
Both benchmarks use 3 concurrent pods and 510 total pods. Comparing inter-job/inter-gang gaps
isolates the cost of gang coordination vs. individual pod admission.

---

## API Note

The `scheduling.k8s.io/v1alpha1` Workload type and `spec.workloadRef` field on PodSpec are
intentionally short-lived. A redesigned `v1alpha2` API is planned for Kubernetes 1.36 using a
standalone `PodGroup` object. Expect manifest changes when upgrading beyond 1.35.

## Known Gotchas

**Server node is tainted** — all pods schedule onto the agent node(s) only. Server node
capacity is irrelevant.

**`workloadRef` is immutable** — once a pod is created, its gang assignment cannot be changed.
Delete the Jobs and Workload objects first before resubmitting (`./reset.sh` handles this).

**Both benchmarks share ResourceFlavor `default`** — deleting it (via `kueue/demo/delete.sh`)
will break this demo too. Delete ResourceFlavor only when tearing down everything.
