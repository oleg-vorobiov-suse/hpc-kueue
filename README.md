# HPC Scheduling on Kubernetes: Kueue vs Gang Scheduling

This repository benchmarks two complementary Kubernetes scheduling primitives:
- **Kueue** — admission-layer queue management
- **k8s 1.35 Gang Scheduling (KEP-4671)** — scheduling-layer atomicity

The core finding: these tools solve fundamentally different problems at different layers of the stack. Neither replaces the other. Used together, they address the full scheduling problem for multi-pod HPC workloads.

---

## The Two Layers of Kubernetes Scheduling

Before comparing the tools, it helps to understand that pod execution involves two distinct phases:

```
Phase 1 — Admission (before pods exist)
  Who decides: Kueue, ResourceQuota, LimitRanges
  Question answered: "Should this workload be allowed to create pods right now?"

Phase 2 — Scheduling (pods exist, not yet running)
  Who decides: kube-scheduler and its plugins
  Question answered: "Which node should each pod run on, and when?"
```

Kueue operates in Phase 1. The gang scheduler operates in Phase 2. They do not overlap.

---

## Kueue: Admission-Layer Queue Management

Kueue intercepts Job creation and **suspends** the Job immediately. No pods are created. It then maintains a queue of suspended workloads and **admits** them (unsuspends) when quota is available.

```
Job created
    │
    ▼ (Kueue webhook fires)
Job suspended — zero pods exist
    │
    ▼ (Kueue controller watches queue)
Quota available → Job unsuspended
    │
    ▼ (Job controller responds)
Pods created → k8s scheduler places them
    │
    ▼
Pods run → Job completes → quota freed → next Job unsuspended
```

**What Kueue provides:**
- **Quota enforcement**: at most N CPU / M memory worth of active pods at any time
- **FIFO/priority ordering**: workloads are admitted in a controlled sequence
- **Multi-tenant fairness**: multiple namespaces and teams share a ClusterQueue fairly
- **Gang admission**: multi-pod Jobs are admitted atomically (all PodSets or none)

**What Kueue does not provide:**
- Any guarantee about *how* pods within a workload start relative to each other
- Any protection against the k8s scheduler starting pod 1 of 5 on a node that later becomes full before pods 2-5 can be placed

---

## k8s 1.35 Gang Scheduling (KEP-4671): Scheduling-Layer Atomicity

The k8s 1.35 gang scheduler is a kube-scheduler plugin (`GangScheduling` feature gate, Alpha). It operates after pods exist. Its sole guarantee: **all pods in a group start running simultaneously, or none do**.

```
500 pods exist in the cluster (from 100 submitted Jobs)
    │
    ▼ (gang scheduler PreEnqueue gate)
Pods parked until all minCount pods for the gang are present
    │
    ▼ (standard filter/score pipeline runs per pod)
Each pod gets a tentative node assignment (Reserve)
    │
    ▼ (gang scheduler Permit gate)
Each pod waits here until ALL pods in the gang have a node reserved
When the last pod arrives → all pods released simultaneously
    │
    ▼
All 5 pods start running at the same moment
```

**What the gang scheduler provides:**
- **Atomicity**: eliminates partial startup (e.g. 3 of 5 workers running while 2 wait for resources)
- **Deadlock avoidance within a gang**: if the full gang cannot fit, none of it runs

**What the gang scheduler does not provide:**
- Any concurrency limit (it will schedule as many simultaneous gangs as node resources allow)
- Any queue management (all pods must already exist in the cluster)
- Any FIFO/priority ordering between gangs

---

## Why Gang Scheduling is Not a Kueue Replacement

The difference comes down to **when** each system acts:

| Dimension | Kueue | k8s 1.35 Gang Scheduler |
|---|---|---|
| Operates at | Admission — before pods exist | Scheduling — after pods exist |
| Controls | *When* workloads get pods created | *How* pods within a gang start |
| Concurrency limit | Yes — explicit quota (e.g. 5 CPU) | No — bounded only by node capacity |
| 100 pending workloads | 100 Workload objects, zero pods | 500 pods sitting in the scheduler queue |
| Pod creation timing | On demand, after admission | All at once when Jobs are submitted |
| Queue management | FIFO, priority classes, fair sharing | None |

### The ResourceQuota trap

A natural instinct is to use Kubernetes `ResourceQuota` to limit gang scheduling concurrency, the way Kueue's ClusterQueue does. This does not work. ResourceQuota fires at pod **creation** time (API server admission). The gang scheduler fires at **scheduling** time. The ordering is wrong:

```
ResourceQuota enforced here    Gang scheduler enforced here
        ↓                                 ↓
   Pod creation  ──────────────────▶  Pod scheduling
```

When 100 Jobs are submitted simultaneously without Kueue, the Job controller races to create pods for all 100 at once. A tight ResourceQuota cuts off creation mid-gang — gang-001 gets 3 pods created, gang-002 gets 2. Neither gang has all 5, so neither can be scheduled. But both hold quota. **Deadlock.**

Kueue avoids this entirely by ensuring pods for a workload are only created when that workload is admitted.

---

## How They Complement Each Other

The correct production architecture for HPC multi-pod workloads uses both:

```
                  ADMISSION LAYER (Kueue)
┌─────────────────────────────────────────────────────────┐
│  ClusterQueue quota: 5 CPU / 10Gi                       │
│  = exactly 1 gang admitted at a time                    │
│                                                         │
│  Job submitted → suspended immediately (no pods)        │
│  Kueue watches queue → admits 1 gang when quota free    │
│  Job unsuspended → Job controller creates 5 pods        │
└─────────────────────────────────────────────────────────┘
                          │
                          ▼
                 SCHEDULING LAYER (Gang Scheduler)
┌─────────────────────────────────────────────────────────┐
│  5 pods created simultaneously (Job just unsuspended)   │
│  PreEnqueue: all 5 present → pass                       │
│  Reserve: tentative node assignment for each            │
│  Permit: all 5 held until count reaches minCount        │
│  → all 5 released and start running simultaneously      │
└─────────────────────────────────────────────────────────┘
                          │
                          ▼
               All 5 pods running atomically
               Gang completes → quota freed
               Kueue admits next gang
```

**Each layer contributes what the other cannot:**
- Kueue contributes: concurrency control, FIFO ordering, quota management
- Gang scheduler contributes: atomic startup guarantee, partial-start prevention

**Without Kueue**: gangs compete for node resources freely (2 concurrent gangs on a 12-CPU node with 5-CPU gangs). No concurrency limit. Queue depth = 500 pending pods.

**Without gang scheduler**: Kueue admits 1 gang at a time, but the k8s scheduler may start pod 1 before pod 5 is placed. On a fragmented cluster, some pods of the gang may start running while others are still pending.

**Together**: Kueue controls when a gang runs. The gang scheduler controls how the gang starts. This is the complete solution.

---

## What the Benchmarks Measure

### `kueue/` — Kueue standalone
510 individual 1-pod Jobs through a Kueue ClusterQueue. Measures Kueue admission latency and whether inter-job gap grows over time. No gang scheduling involved.

**Key result:** Kueue admission is essentially instant (~0ms). The dominant cost is kubelet + container runtime startup (~2s). No growing inter-job delays were observed.

### `gang-and-kueue/` — Kueue + Gang Scheduling
100 5-pod gangs through Kueue (for concurrency control) and the k8s 1.35 gang scheduler (for atomic startup). Measures gang cohesion (how tightly all 5 pods start together) and the overhead the Permit gate adds on top of Kueue admission.

**Key metric:** `max(script_start) - min(script_start)` per gang — should be near zero if the gang scheduler is working correctly.

---

## Repository Structure

```
hpc-kueue/
├── resourceflavor.yaml             # Shared ResourceFlavor — apply once for both benchmarks
├── kueue/                          # Kueue standalone benchmark
│   ├── clusterqueue.yaml
│   ├── localqueue.yaml
│   └── demo/
│       ├── apply.sh
│       ├── reset.sh
│       ├── collect.sh
│       ├── delete.sh
│       └── ...
└── gang-and-kueue/                 # Kueue + k8s 1.35 gang scheduling
    └── demo/
        ├── apply.sh
        ├── reset.sh
        ├── collect.sh
        ├── delete.sh
        └── ...
```

See `kueue/README.md` and `gang-and-kueue/README.md` for per-demo setup instructions.
