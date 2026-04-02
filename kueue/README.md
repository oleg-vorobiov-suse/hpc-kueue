# Kueue Scheduling Benchmark

Measures Kueue admission latency across 500 sequential jobs and exposes why the delay between consecutive job starts grows over time.

## Prerequisites

- Kubernetes cluster with `kubectl` configured
- Helm 3

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

## 3. Create the batch Namespace

```bash
kubectl create namespace batch
```

## 4. Apply Queue Infrastructure

Order matters — ResourceFlavor must exist before ClusterQueue references it.

```bash
kubectl apply -f resourceflavor.yaml
kubectl apply -f clusterqueue.yaml
kubectl apply -f localqueue.yaml
```

Verify the ClusterQueue is active before proceeding:

```bash
kubectl get clusterqueue skyhawk-cq
# ACTIVE column must be "True"
```

Queue hierarchy:

```
LocalQueue (skyhawk-lq, ns: batch)
  └── ClusterQueue (skyhawk-cq)
        └── ResourceFlavor (default)
              CPU:    3 cores nominal
              Memory: 6Gi nominal
              Strategy: BestEffortFIFO
```

## 5. Run the Benchmark

```bash
cd demo/
./apply.sh
```

This applies RBAC, deploys the orchestrator, and submits 500 jobs to Kueue. The orchestrator is a persistent HTTP server that collects timing records from each job as it completes.

Monitor progress:

```bash
kubectl get clusterqueue skyhawk-cq -w
# Watch PENDING WORKLOADS count down to 0
```

## 6. Collect Results

Once all jobs have finished (`PENDING WORKLOADS: 0`, `ADMITTED WORKLOADS: 0`):

```bash
./collect.sh               # saves to results.jsonl
./collect.sh my-run.jsonl  # or specify a filename
```

## 7. Reset for Another Run

Deletes all jobs and re-provisions a fresh PVC on the orchestrator (the `local-path` PV is deleted with the PVC due to `ReclaimPolicy: Delete`):

```bash
./reset.sh
```

---

## Architecture

```
500 Job objects  (kueue.x-k8s.io/queue-name: skyhawk-lq)
  │
  │  Kueue admits up to quota, BestEffortFIFO
  ▼
Pod starts → job.py runs
  1. records script_start (first line)
  2. queries Kueue Workload  → quota_reserved_time, admitted_time
  3. queries own Pod         → pod_scheduled_time
  4. sleep 12s
  5. records script_end
  6. POSTs JSON record to orchestrator-svc:8080
  │
  ▼
Orchestrator Deployment  (python:3-slim, survives between runs)
  │  ThreadingHTTPServer appends each record to /data/results.jsonl
  │  Backed by local-path PVC (ReclaimPolicy: Delete)
  ▼
kubectl cp → results.jsonl on your local machine
```

### RBAC

ServiceAccount `job-reporter` in `batch` has the minimum permissions needed for `job.py` to query its own scheduling metadata:

| API Group | Resource | Verb |
|---|---|---|
| `batch` | `jobs` | `get` |
| `kueue.x-k8s.io` | `workloads` | `list` |
| `` (core) | `pods` | `get` |

---

## Results Format

Each line of `results.jsonl` is a JSON object:

| Field | Source | Measures |
|---|---|---|
| `quota_reserved_time` | Workload condition `QuotaReserved.lastTransitionTime` | When Kueue decided to run this job |
| `admitted_time` | Workload condition `Admitted.lastTransitionTime` | When Kueue fully admitted the workload |
| `pod_scheduled_time` | Pod condition `PodScheduled.lastTransitionTime` | When the k8s scheduler placed the pod |
| `script_start` | `datetime.now()` — first line of job.py | When the container started executing |
| `script_end` | `datetime.now()` — after sleep | When the job finished |
| `received_at` | Orchestrator timestamp on POST receipt | Orchestrator-side record time |

### Decomposing the inter-job gap

For consecutive jobs N and N+1:

```
gap = script_start(N+1) - script_end(N)
    = [quota_reserved(N+1) - script_end(N)]   ← Kueue queue latency
    + [pod_scheduled(N+1) - quota_reserved(N+1)]  ← k8s scheduler latency
    + [script_start(N+1) - pod_scheduled(N+1)]    ← kubelet + runtime startup
```

Known observation: this gap grows roughly linearly (e.g. 0.1s at job 33, 45s at job 300, 82s at job 499). The timestamps above isolate which layer is responsible.

---

## Known Gotchas

**Kueue v1beta2 requires `namespaceSelector` on ClusterQueue.** Without it, all workloads are rejected with `Workload namespace doesn't match ClusterQueue selector`. The manifests here include `namespaceSelector: {}` (match all namespaces).

**Do not double-enforce quota.** Rancher project resource quotas and Kueue ClusterQueue quotas are independent. If the namespace `ResourceQuota` is more restrictive than the ClusterQueue quota, pods will be blocked from creation even after Kueue admits the workload. Use Kueue as the sole throttle for this benchmark.

