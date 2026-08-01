#!/usr/bin/env bash
# Resume POC deployment after cluster reconnect.
# Run this after: oc login --token=<token> --server=https://api.wbos.podzone.org:6443
#
# What's already done (do NOT re-apply):
#   ✓ IstioCNI default (v1.28.5, Healthy)
#   ✓ Istio default (v1.28.5, Healthy) — istiod in istio-system
#   ✓ namespace/guardrails (istio-discovery=enabled)
#   ✓ namespace/app-ns (istio-discovery=enabled, istio-injection=enabled)
#
# What this script completes:
#   → NeMo ConfigMap + CR in guardrails
#   → httpbin mock backend in app-ns
#   → test-app curl pod in app-ns
#   → WasmPlugin (after getting Envoy cluster name)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== Verifying cluster connection ==="
oc whoami || { echo "Not logged in. Run: oc login --token=... --server=..."; exit 1; }

echo ""
echo "=== Verifying prior work is intact ==="
oc get istio default &>/dev/null && echo "✓ Istio CR" || echo "✗ Istio CR missing — run scripts/00-prereqs.sh first"
oc get istiocni default &>/dev/null && echo "✓ IstioCNI" || echo "✗ IstioCNI missing"
oc get namespace guardrails &>/dev/null && echo "✓ guardrails namespace" || echo "✗ guardrails namespace missing"
oc get namespace app-ns &>/dev/null && echo "✓ app-ns namespace" || echo "✗ app-ns namespace missing"
oc get pods -n istio-system | grep istiod && echo "✓ istiod running" || echo "✗ istiod not running"

echo ""
echo "=== Step 1: Deploy NeMo ConfigMap ==="
oc apply -f "$REPO_ROOT/deploy/nemo/01-configmap-pii.yaml"

echo ""
echo "=== Step 2: Deploy NemoGuardrails CR ==="
oc apply -f "$REPO_ROOT/deploy/nemo/02-nemoguardrails-cr.yaml"

echo ""
echo "=== Step 3: Deploy AuthorizationPolicy ==="
oc apply -f "$REPO_ROOT/deploy/nemo/03-authorizationpolicy.yaml"

echo ""
echo "=== Step 4: Deploy httpbin mock backend and test pod in app-ns ==="
oc apply -f "$REPO_ROOT/deploy/app-ns/httpbin.yaml"
oc apply -f "$REPO_ROOT/deploy/app-ns/test-app.yaml"

echo ""
echo "=== Step 5: Wait for NeMo to be Ready (up to 5 min) ==="
echo "Watching NemoGuardrails status..."
oc wait nemoguardrails/nemo-pii -n guardrails \
  --for=jsonpath='{.status.phase}'=Ready --timeout=300s \
  && echo "✓ NeMo Ready" \
  || { echo "Not ready yet — check:"; oc get nemoguardrails -n guardrails; oc get pods -n guardrails; }

echo ""
echo "=== Step 6: Wait for app-ns pods ==="
oc rollout status deployment/httpbin -n app-ns --timeout=120s
oc rollout status deployment/test-app -n app-ns --timeout=120s

echo ""
echo "=== Step 7: Validate NeMo endpoint ==="
bash "$REPO_ROOT/scripts/01-deploy-nemo.sh" || true   # validation only

echo ""
echo "=== Step 8: Get Envoy cluster name ==="
bash "$REPO_ROOT/scripts/02-get-cluster-name.sh"

echo ""
echo "=== Next: Update WasmPlugin YAML with cluster name, then apply ==="
echo "  oc apply -f deploy/ossm/phase1-wasm/wasmplugin.yaml"
echo "  kubectl label deployment test-app guardrails.trustyai.io/config=pii -n app-ns"
echo "  bash scripts/test/test-blocked.sh http://httpbin.app-ns.svc/post"
echo "  bash scripts/test/test-allowed.sh http://httpbin.app-ns.svc/post"
