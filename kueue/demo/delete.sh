#!/usr/bin/env bash
# Remove ALL kueue standalone demo resources from the cluster.
#
# This deletes: jobs, orchestrator, PVC, ConfigMaps, RBAC, and the
# Kueue queue infrastructure (skyhawk-cq, skyhawk-lq, ResourceFlavor default).
#
# It does NOT delete:
#   - The batch namespace (may contain other workloads)
#
# WARNING: Deleting ResourceFlavor 'default' will also break the
#   gang-and-kueue demo if it is still running.
#
# To remove the namespace entirely:
#   kubectl delete namespace batch
set -euo pipefail

echo "==> Deleting all sleep jobs..."
kubectl delete jobs -n batch -l app=sleep-job --ignore-not-found --wait=false

echo "==> Deleting orchestrator..."
kubectl delete deployment/orchestrator -n batch --ignore-not-found
kubectl delete service/orchestrator-svc -n batch --ignore-not-found

echo "==> Deleting PVC (PV and data removed automatically)..."
kubectl delete pvc orchestrator-data -n batch --ignore-not-found

echo "==> Deleting ConfigMaps..."
kubectl delete configmap orchestrator-script job-script -n batch --ignore-not-found

echo "==> Deleting RBAC..."
kubectl delete rolebinding job-reporter -n batch --ignore-not-found
kubectl delete role job-reporter -n batch --ignore-not-found
kubectl delete serviceaccount job-reporter -n batch --ignore-not-found

echo "==> Deleting Kueue queue infrastructure..."
kubectl delete localqueue skyhawk-lq -n batch --ignore-not-found
kubectl delete clusterqueue skyhawk-cq --ignore-not-found
kubectl delete resourceflavor default --ignore-not-found

echo ""
echo "Done. Namespace 'batch' was NOT deleted."
echo "To remove the namespace: kubectl delete namespace batch"
