#!/usr/bin/env bash
# Delete all sleep jobs and reset the orchestrator with a fresh PVC.
# Scaling the deployment to 0 before deleting the PVC avoids a mount conflict.
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG="${KUBECONFIG:-$DEMO_DIR/../kubeconfig.yaml}"
export KUBECONFIG

echo "==> Deleting all sleep jobs..."
kubectl delete jobs -n batch -l app=sleep-job --ignore-not-found --wait=false

echo "==> Scaling orchestrator to 0..."
kubectl scale deployment/orchestrator -n batch --replicas=0
kubectl wait deployment/orchestrator -n batch \
  --for=jsonpath='{.status.readyReplicas}'=0 \
  --timeout=60s 2>/dev/null || true

echo "==> Deleting PVC (ReclaimPolicy=Delete will remove the PV and data)..."
kubectl delete pvc orchestrator-data -n batch --ignore-not-found

echo "==> Re-applying PVC and scaling orchestrator back to 1..."
kubectl apply -f "$DEMO_DIR/02-orchestrator.yaml"
kubectl scale deployment/orchestrator -n batch --replicas=1

echo "==> Waiting for orchestrator to be ready..."
kubectl wait deployment/orchestrator -n batch \
  --for=condition=Available \
  --timeout=120s

echo "Done. Orchestrator has a fresh filesystem."
