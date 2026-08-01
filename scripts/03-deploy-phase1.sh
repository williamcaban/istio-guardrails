#!/usr/bin/env bash
# Phase 1: Deploy TrafficExtension + Lua and run validation tests
# Prerequisites: scripts/00-prereqs.sh, 01-deploy-nemo.sh, 02-get-cluster-name.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODEL_SVC="${MODEL_SVC:-http://vllm-svc.model-ns.svc:8080}"

echo "=== Phase 1: TrafficExtension + Lua (input guardrail) ==="
echo "Using model service: $MODEL_SVC"
echo "(Override with: export MODEL_SVC=http://<your-model-svc>)"

# --- Deploy TrafficExtension ---
echo ""
echo "--- Applying TrafficExtension ---"
oc apply -f "$REPO_ROOT/deploy/ossm/phase1-lua/traffic-extension-lua.yaml"
oc get trafficextension nemo-input-guard -n app-ns

# --- Label test app ---
echo ""
echo "--- Labeling test-app with guardrails.trustyai.io/config=pii ---"
kubectl label deployment test-app \
  guardrails.trustyai.io/config=pii -n app-ns --overwrite
oc rollout restart deployment/test-app -n app-ns
oc rollout status deployment/test-app -n app-ns --timeout=120s

# --- Verify filter loaded ---
echo ""
echo "--- Verifying Lua filter in Envoy listener config ---"
sleep 5  # brief wait for xDS propagation
FILTER_FOUND=$(istioctl proxy-config listener -n app-ns deploy/test-app \
  --port 8080 -o json 2>/dev/null | grep -c "envoy.filters.http.lua" || true)
if [ "$FILTER_FOUND" -gt 0 ]; then
  echo "✓ Lua filter found in Envoy listener"
else
  echo "⚠ Lua filter not visible yet — may need a few more seconds for xDS propagation"
  echo "  Retry: istioctl proxy-config listener -n app-ns deploy/test-app --port 8080 -o json | grep lua"
fi

# --- Run tests ---
echo ""
echo "--- Running Phase 1 tests ---"
bash "$REPO_ROOT/scripts/test/test-blocked.sh" "$MODEL_SVC"
bash "$REPO_ROOT/scripts/test/test-allowed.sh" "$MODEL_SVC"

echo ""
echo "=== Phase 1 deployment complete ==="
echo "Manually verify latency impact by running:"
echo "  for i in \$(seq 5); do time curl -s -o /dev/null -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\":\"llama3\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}]}' \\"
echo "    $MODEL_SVC/v1/chat/completions; done"
