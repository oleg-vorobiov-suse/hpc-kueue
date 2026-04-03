#!/usr/bin/env python3
"""Generate all-jobs.yaml containing 510 Kueue-managed Job manifests."""

JOB_COUNT        = 510
NAMESPACE        = "batch"
QUEUE_NAME       = "skyhawk-lq"
ORCHESTRATOR_URL = "http://orchestrator-svc.batch.svc.cluster.local:8080"
IMAGE            = "python:3-slim"

TEMPLATE = """\
apiVersion: batch/v1
kind: Job
metadata:
  name: {name}
  namespace: {namespace}
  labels:
    kueue.x-k8s.io/queue-name: {queue}
    app: sleep-job
spec:
  backoffLimit: 0
  template:
    metadata:
      labels:
        app: sleep-job
    spec:
      serviceAccountName: job-reporter
      restartPolicy: Never
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
        - name: JOB_NAME
          value: "{name}"
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: ORCHESTRATOR_URL
          value: "{orchestrator_url}"
        volumeMounts:
        - name: job-script
          mountPath: /scripts
      volumes:
      - name: job-script
        configMap:
          name: job-script
"""

output_file = "all-jobs.yaml"

with open(output_file, "w") as f:
    for i in range(1, JOB_COUNT + 1):
        name = f"sleep-job-{i:03d}"
        f.write(TEMPLATE.format(
            name=name,
            namespace=NAMESPACE,
            queue=QUEUE_NAME,
            image=IMAGE,
            orchestrator_url=ORCHESTRATOR_URL,
        ))
        if i < JOB_COUNT:
            f.write("---\n")

print(f"Generated {output_file} with {JOB_COUNT} jobs.")
