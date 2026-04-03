#!/usr/bin/env python3
"""
Generate all-gangs.yaml: 170 gang jobs for the combined Kueue + gang scheduling benchmark.

Design rationale:
  - Gang size: 3 pods   → 1 concurrent gang = 3 concurrent pods (matches Kueue standalone)
  - Gang count: 170     → 170 × 3 = 510 total pods (matches Kueue standalone ~500)
  - ClusterQueue quota: 3 CPU / 6Gi → Kueue admits exactly 1 gang at a time
  - spec.workloadRef on pods → gang scheduler ensures all 3 start simultaneously

Each entry in all-gangs.yaml contains two objects:
  1. scheduling.k8s.io/v1alpha1 Workload — defines the gang policy (minCount: 3)
  2. batch/v1 Job — carries the kueue queue label; pods reference the Workload

Because Kueue suspends Jobs on creation and only creates pods after admission,
all 170 Jobs can be submitted simultaneously without deadlock. Kueue queues them
and admits one at a time; the gang scheduler then starts the 3 pods atomically.
"""

GANG_COUNT   = 170
GANG_SIZE    = 3
NAMESPACE    = "gang-bench"
QUEUE        = "gang-bench-lq"
IMAGE        = "python:3-slim"
ORCHESTRATOR = "http://orchestrator-svc.gang-bench.svc.cluster.local:8080"

WORKLOAD_TEMPLATE = """\
apiVersion: scheduling.k8s.io/v1alpha1
kind: Workload
metadata:
  name: {name}
  namespace: {namespace}
  labels:
    app: gang-job
spec:
  podGroups:
    - name: workers
      policy:
        gang:
          minCount: {gang_size}
"""

JOB_TEMPLATE = """\
apiVersion: batch/v1
kind: Job
metadata:
  name: {name}
  namespace: {namespace}
  labels:
    kueue.x-k8s.io/queue-name: {queue}
    app: gang-job
spec:
  parallelism: {gang_size}
  completions: {gang_size}
  completionMode: Indexed
  backoffLimit: 0
  template:
    metadata:
      labels:
        app: gang-job
        gang-name: {name}
    spec:
      serviceAccountName: job-reporter
      restartPolicy: Never
      workloadRef:
        name: {name}
        podGroup: workers
      containers:
      - name: job
        image: {image}
        command: ["python3", "/scripts/job.py"]
        resources:
          requests:
            cpu: "1"
            memory: "2Gi"
          limits:
            cpu: "1"
            memory: "2Gi"
        env:
        - name: GANG_NAME
          value: "{name}"
        - name: GANG_SIZE
          value: "{gang_size}"
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: ORCHESTRATOR_URL
          value: "{orchestrator}"
        volumeMounts:
        - name: job-script
          mountPath: /scripts
      volumes:
      - name: job-script
        configMap:
          name: job-script
"""

output_file = "all-gangs.yaml"

with open(output_file, "w") as f:
    for i in range(1, GANG_COUNT + 1):
        name = f"gang-{i:03d}"
        f.write(WORKLOAD_TEMPLATE.format(
            name=name,
            namespace=NAMESPACE,
            gang_size=GANG_SIZE,
        ))
        f.write("---\n")
        f.write(JOB_TEMPLATE.format(
            name=name,
            namespace=NAMESPACE,
            queue=QUEUE,
            gang_size=GANG_SIZE,
            image=IMAGE,
            orchestrator=ORCHESTRATOR,
        ))
        if i < GANG_COUNT:
            f.write("---\n")

print(f"Generated {output_file}: {GANG_COUNT} gangs × {GANG_SIZE} pods = {GANG_COUNT * GANG_SIZE} total pods.")
print(f"ClusterQueue quota (3 CPU / 6Gi) admits 1 gang at a time → 3 concurrent pods.")
