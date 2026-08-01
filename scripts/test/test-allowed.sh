#!/usr/bin/env bash
# Assert that clean requests pass through (expect 200)
set -euo pipefail

MODEL_SVC="${1:-${MODEL_SVC:-http://vllm-svc.model-ns.svc:8080}}"

echo "--- Test: Clean request should pass through (expect 200) ---"

HTTP_CODE=$(oc exec -n app-ns deploy/test-app -- \
  curl -s -o /dev/null -w "%{http_code}" \
  -H "Content-Type: application/json" \
  -d '{"model":"llama3","messages":[{"role":"user","content":"Explain Kubernetes networking in one sentence"}]}' \
  "$MODEL_SVC/v1/chat/completions")

if [ "$HTTP_CODE" = "200" ]; then
  echo "✓ PASS: Clean request returned 200"
else
  echo "✗ FAIL: Expected 200, got $HTTP_CODE"
  echo "  Check NeMo logs: oc logs -n guardrails deploy/nemo-pii"
  exit 1
fi
