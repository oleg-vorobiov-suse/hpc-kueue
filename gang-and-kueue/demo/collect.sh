#!/usr/bin/env bash
# Copy results.jsonl from the orchestrator pod to a local file.
# Usage: ./collect.sh [output-file]   (default: results.jsonl)
set -euo pipefail

OUTPUT="${1:-results.jsonl}"

POD=$(kubectl get pod -n gang-bench -l app=orchestrator \
  -o jsonpath='{.items[0].metadata.name}')

if [[ -z "$POD" ]]; then
  echo "Error: no orchestrator pod found in namespace 'gang-bench'." >&2
  exit 1
fi

echo "==> Copying from $POD:/data/results.jsonl to $OUTPUT ..."
kubectl cp "gang-bench/$POD:/data/results.jsonl" "$OUTPUT"

LINES=$(wc -l < "$OUTPUT")
echo "Done. $LINES pod records written to $OUTPUT"
echo "(170 gangs × 3 pods = 510 records expected)"
echo ""
echo "Key analysis queries (jq required):"
echo "  # Gang cohesion per gang (spread between pod start times):"
echo "  jq -r '[.gang_name, .pod_index, .script_start] | @tsv' $OUTPUT | sort"
