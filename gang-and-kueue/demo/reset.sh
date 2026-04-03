#!/usr/bin/env bash
# Delete all gang jobs and Workload objects, then reset the orchestrator
# with a fresh PVC (ReclaimPolicy=Delete removes the PV and all data).
# Queue infrastructure (gang-cq, gang-bench-lq) is preserved.
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Deleting all gang jobs..."
kubectl delete jobs -n gang-bench -l app=gang-job --ignore-not-found --wait=false

echo "==> Deleting all gang Workload objects (scheduling.k8s.io)..."
kubectl delete workloads.scheduling.k8s.io -n gang-bench -l app=gang-job --ignore-not-found

echo "==> Scaling orchestrator to 0..."
kubectl scale deployment/orchestrator -n gang-bench --replicas=0
kubectl wait deployment/orchestrator -n gang-bench \
  --for=jsonpath='{.status.readyReplicas}'=0 \
  --timeout=60s 2>/dev/null || true

echo "==> Deleting PVC (PV and data will be removed automatically)..."
kubectl delete pvc orchestrator-data -n gang-bench --ignore-not-found

echo "==> Re-provisioning orchestrator..."
kubectl apply -f "$DEMO_DIR/03-orchestrator.yaml"
kubectl scale deployment/orchestrator -n gang-bench --replicas=1

echo "==> Waiting for orchestrator to be ready..."
kubectl wait deployment/orchestrator -n gang-bench \
  --for=condition=Available \
  --timeout=120s

echo "Done. Orchestrator has a fresh filesystem."
