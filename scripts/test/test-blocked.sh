#!/usr/bin/env bash
# Assert that PII in request body returns 403
set -euo pipefail

MODEL_SVC="${1:-${MODEL_SVC:-http://vllm-svc.model-ns.svc:8080}}"

echo "--- Test: PII request should be blocked (expect 403) ---"

HTTP_CODE=$(oc exec -n app-ns deploy/test-app -- \
  curl -s -o /dev/null -w "%{http_code}" \
  -H "Content-Type: application/json" \
  -d '{"model":"llama3","messages":[{"role":"user","content":"My SSN is 123-45-6789"}]}' \
  "$MODEL_SVC/v1/chat/completions")

if [ "$HTTP_CODE" = "403" ]; then
  echo "✓ PASS: PII request returned 403"
else
  echo "✗ FAIL: Expected 403, got $HTTP_CODE"
  exit 1
fi

# Also test email address
HTTP_CODE=$(oc exec -n app-ns deploy/test-app -- \
  curl -s -o /dev/null -w "%{http_code}" \
  -H "Content-Type: application/json" \
  -d '{"model":"llama3","messages":[{"role":"user","content":"Contact me at alice@example.com"}]}' \
  "$MODEL_SVC/v1/chat/completions")

if [ "$HTTP_CODE" = "403" ]; then
  echo "✓ PASS: Email PII request returned 403"
else
  echo "✗ FAIL: Email PII — Expected 403, got $HTTP_CODE"
  exit 1
fi
