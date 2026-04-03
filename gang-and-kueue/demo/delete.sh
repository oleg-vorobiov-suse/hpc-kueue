#!/usr/bin/env bash
# Remove ALL gang-and-kueue demo resources from the cluster.
#
# This deletes: jobs, gang Workload objects, orchestrator, PVC, ConfigMaps,
# RBAC, and the Kueue queue infrastructure (gang-cq, gang-bench-lq).
#
# It does NOT delete:
#   - The gang-bench namespace (may contain other workloads)
#   - ResourceFlavor 'default' (shared with kueue/ benchmark)
#
# To remove the namespace entirely:
#   kubectl delete namespace gang-bench
#
# To remove the shared ResourceFlavor (only if kueue/ demo is also torn down):
#   kubectl delete resourceflavor default
set -euo pipefail

echo "==> Deleting all gang jobs..."
kubectl delete jobs -n gang-bench -l app=gang-job --ignore-not-found --wait=false

echo "==> Deleting gang Workload objects (scheduling.k8s.io)..."
kubectl delete workloads.scheduling.k8s.io -n gang-bench -l app=gang-job --ignore-not-found

echo "==> Deleting orchestrator..."
kubectl delete deployment/orchestrator -n gang-bench --ignore-not-found
kubectl delete service/orchestrator-svc -n gang-bench --ignore-not-found

echo "==> Deleting PVC (PV and data removed automatically)..."
kubectl delete pvc orchestrator-data -n gang-bench --ignore-not-found

echo "==> Deleting ConfigMaps..."
kubectl delete configmap orchestrator-script job-script -n gang-bench --ignore-not-found

echo "==> Deleting RBAC..."
kubectl delete rolebinding job-reporter -n gang-bench --ignore-not-found
kubectl delete role job-reporter -n gang-bench --ignore-not-found
kubectl delete serviceaccount job-reporter -n gang-bench --ignore-not-found

echo "==> Deleting Kueue queue infrastructure..."
kubectl delete localqueue gang-bench-lq -n gang-bench --ignore-not-found
kubectl delete clusterqueue gang-cq --ignore-not-found

echo ""
echo "Done. ResourceFlavor 'default' and namespace 'gang-bench' were NOT deleted."
echo "To remove the namespace: kubectl delete namespace gang-bench"
