#!/usr/bin/env bash
# Apply the full demo: namespace, RBAC, orchestrator, job script ConfigMap, then 500 jobs.
# Run from the demo/ directory.
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# KUBECONFIG="${KUBECONFIG:-$DEMO_DIR/../kubeconfig.yaml}"
# export KUBECONFIG

echo "==> Applying namespace, RBAC, orchestrator, job-script configmap..."
# kubectl apply -f "$DEMO_DIR/00-namespace.yaml"
kubectl apply -f "$DEMO_DIR/01-rbac.yaml"
kubectl apply -f "$DEMO_DIR/02-orchestrator.yaml"
kubectl apply -f "$DEMO_DIR/03-job-script.yaml"

echo "==> Waiting for orchestrator to be ready..."
kubectl wait deployment/orchestrator -n batch \
  --for=condition=Available \
  --timeout=120s

echo "==> Generating job manifests..."
(cd "$DEMO_DIR" && python3 generate-jobs.py)

echo "==> Submitting 500 jobs to Kueue..."
kubectl apply -f "$DEMO_DIR/all-jobs.yaml"

echo ""
echo "Done. Monitor progress with:"
echo "  kubectl get workloads -n batch"
echo "  kubectl get jobs -n batch"
