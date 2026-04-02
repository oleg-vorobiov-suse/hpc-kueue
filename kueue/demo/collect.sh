#!/usr/bin/env bash
# Copy results.jsonl from the orchestrator pod to a local file.
# Usage: ./collect.sh [output-file]   (default: results.jsonl)
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG="${KUBECONFIG:-$DEMO_DIR/../kubeconfig.yaml}"
export KUBECONFIG

OUTPUT="${1:-results.jsonl}"

POD=$(kubectl get pod -n batch -l app=orchestrator \
  -o jsonpath='{.items[0].metadata.name}')

if [[ -z "$POD" ]]; then
  echo "Error: no orchestrator pod found in namespace 'batch'." >&2
  exit 1
fi

echo "==> Copying from $POD:/data/results.jsonl to $OUTPUT ..."
kubectl cp "batch/$POD:/data/results.jsonl" "$OUTPUT"

LINES=$(wc -l < "$OUTPUT")
echo "Done. $LINES records written to $OUTPUT"
echo ""
echo "Quick summary (jq required):"
echo "  jq -r '[.job_name,.script_start,.script_end] | @tsv' $OUTPUT | sort"
