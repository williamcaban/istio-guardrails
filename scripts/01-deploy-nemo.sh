#!/usr/bin/env bash
# Phase 0, Tasks 0.3-0.4: Deploy NeMo and validate endpoint
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== Phase 0: Deploy NeMo Guardrails ==="

# --- Apply manifests ---
echo ""
echo "--- Applying NeMo manifests ---"
oc apply -f "$REPO_ROOT/deploy/nemo/00-namespace.yaml"
oc apply -f "$REPO_ROOT/deploy/nemo/01-configmap-pii.yaml"
oc apply -f "$REPO_ROOT/deploy/nemo/02-nemoguardrails-cr.yaml"

echo ""
echo "--- Waiting for NemoGuardrails to be Ready (up to 5 minutes) ---"
oc wait nemoguardrails/nemo-pii -n guardrails \
  --for=jsonpath='{.status.phase}'=Ready --timeout=300s

echo "✓ NeMo is Ready"

# --- Apply AuthorizationPolicy ---
oc apply -f "$REPO_ROOT/deploy/nemo/03-authorizationpolicy.yaml"
echo "✓ AuthorizationPolicy applied"

# --- Validate endpoint ---
echo ""
echo "--- Validating /v1/guardrail/checks endpoint ---"

oc -n guardrails port-forward svc/nemo-pii 8000:8000 &
PF_PID=$!
sleep 3

CLEAN_STATUS=$(curl -s http://localhost:8000/v1/guardrail/checks \
  -H "Content-Type: application/json" \
  -d '{"model":"","messages":[{"role":"user","content":"What is Kubernetes?"}]}' \
  | jq -r .status)

PII_STATUS=$(curl -s http://localhost:8000/v1/guardrail/checks \
  -H "Content-Type: application/json" \
  -d '{"model":"","messages":[{"role":"user","content":"My SSN is 123-45-6789"}]}' \
  | jq -r .status)

kill $PF_PID 2>/dev/null || true
wait $PF_PID 2>/dev/null || true

echo "Clean request status: $CLEAN_STATUS  (expected: success)"
echo "PII request status:   $PII_STATUS   (expected: blocked)"

if [ "$CLEAN_STATUS" != "success" ]; then
  echo "ERROR: Clean request did not return 'success'. Got: $CLEAN_STATUS"
  exit 1
fi
if [ "$PII_STATUS" != "blocked" ]; then
  echo "ERROR: PII request did not return 'blocked'. Got: $PII_STATUS"
  exit 1
fi

echo ""
echo "✓ NeMo validation passed"
echo ""
echo "=== NeMo deployment complete ==="
echo "Next step: scripts/02-get-cluster-name.sh"
