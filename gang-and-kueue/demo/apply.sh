#!/usr/bin/env bash
# Apply the full Kueue + gang scheduling benchmark.
#
# All 170 gangs are submitted simultaneously. Kueue suspends every Job immediately
# on creation (zero pods exist). It then admits one gang at a time based on the
# 3 CPU / 6Gi ClusterQueue quota. When Kueue admits a gang, the Job controller
# creates 3 pods; the gang scheduler holds all 3 at its Permit gate until they
# can all start simultaneously.
#
# Prerequisites:
#   - ../resourceflavor.yaml applied (ResourceFlavor 'default' exists)
#   - Run from the demo/ directory
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Applying namespace..."
kubectl apply -f "$DEMO_DIR/00-namespace.yaml"

echo "==> Applying Kueue queue infrastructure (gang-cq, gang-bench-lq)..."
kubectl apply -f "$DEMO_DIR/01-kueue-queue.yaml"

echo "==> Applying RBAC, orchestrator, job-script configmap..."
kubectl apply -f "$DEMO_DIR/02-rbac.yaml"
kubectl apply -f "$DEMO_DIR/03-orchestrator.yaml"
kubectl apply -f "$DEMO_DIR/04-job-script.yaml"

echo "==> Waiting for orchestrator to be ready..."
kubectl wait deployment/orchestrator -n gang-bench \
  --for=condition=Available \
  --timeout=120s

echo "==> Generating gang manifests (170 gangs × 3 pods = 510 pods)..."
(cd "$DEMO_DIR" && python3 generate-jobs.py)

echo "==> Submitting all 170 gangs simultaneously..."
echo "    Kueue will queue them and admit 1 gang (3 pods) at a time."
kubectl apply -f "$DEMO_DIR/all-gangs.yaml"

echo ""
echo "Done. Monitor progress with:"
echo "  kubectl get clusterqueue gang-cq        # watch PENDING/ADMITTED counts"
echo "  kubectl get jobs -n gang-bench           # watch job completions"
echo "  kubectl get pods -n gang-bench | grep -v orchestrator"
