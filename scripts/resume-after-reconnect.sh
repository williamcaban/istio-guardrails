#!/usr/bin/env bash
# Resume POC deployment after cluster reconnect.
# Assumes OSSM 3.4.1 (Sail Operator) / Istio 1.30.3 already deployed.
#
# Usage:
#   oc login --token=<token> --server=<api-url>
#   ./scripts/resume-after-reconnect.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== Verifying cluster connection ==="
oc whoami || { echo "Not logged in. Run: oc login --token=... --server=..."; exit 1; }
echo "  Cluster: $(oc whoami --show-server)"

echo ""
echo "=== Verifying OSSM 3.4.1 / Istio 1.30.3 is intact ==="
oc get istio default &>/dev/null \
  && echo "✓ Istio CR ($(oc get istio default -o jsonpath='{.spec.version}'))" \
  || echo "✗ Istio CR missing — run scripts/00-prereqs.sh first"

oc get istiocni default &>/dev/null \
  && echo "✓ IstioCNI" \
  || echo "✗ IstioCNI missing — run scripts/00-prereqs.sh first"

oc get pods -n istio-system -l app=istiod --no-headers 2>/dev/null | grep -q Running \
  && echo "✓ istiod running" \
  || echo "✗ istiod not running"

oc get namespace guardrails &>/dev/null && echo "✓ guardrails namespace" || echo "✗ guardrails namespace missing"
oc get namespace app-ns &>/dev/null && echo "✓ app-ns namespace" || echo "✗ app-ns namespace missing"

echo ""
echo "=== Step 1: Deploy NeMo (ConfigMap + CR + AuthorizationPolicy) ==="
oc apply -f "$REPO_ROOT/deploy/nemo/00-namespace.yaml"
oc apply -f "$REPO_ROOT/deploy/nemo/01-configmap-pii.yaml"
oc apply -f "$REPO_ROOT/deploy/nemo/02-nemoguardrails-cr.yaml"
oc apply -f "$REPO_ROOT/deploy/nemo/03-authorizationpolicy.yaml"

echo ""
echo "=== Step 2: Deploy mock model + mesh-probe in app-ns ==="
oc apply -f "$REPO_ROOT/deploy/app-ns/mock-model.yaml"
oc apply -f "$REPO_ROOT/deploy/app-ns/test-app.yaml"

echo ""
echo "=== Step 3: Wait for NeMo (up to 5 min) ==="
oc wait nemoguardrails/nemo-pii -n guardrails \
  --for=jsonpath='{.status.phase}'=Ready --timeout=300s \
  && echo "✓ NeMo Ready" \
  || { echo "Not ready — check:"; oc get nemoguardrails -n guardrails; oc get pods -n guardrails; }

echo ""
echo "=== Step 4: Wait for app-ns pods ==="
oc rollout status deployment/mock-model -n app-ns --timeout=120s
oc rollout status deployment/test-app -n app-ns --timeout=120s

echo ""
echo "=== Step 5: Deploy TrafficExtension (Lua input guardrail) ==="
oc apply -f "$REPO_ROOT/deploy/ossm/phase1-lua/traffic-extension-lua.yaml"
sleep 6  # allow xDS push

MOCK_POD=$(oc get pod -n app-ns -l app=mock-model -o jsonpath='{.items[0].metadata.name}')
LUA_COUNT=$(oc exec -n app-ns "$MOCK_POD" -c istio-proxy -- \
  pilot-agent request GET /config_dump 2>/dev/null \
  | grep -c "envoy.filters.http.lua" || echo 0)
echo "  Lua filter entries in Envoy: $LUA_COUNT"

echo ""
echo "=== Step 6: Run validation tests ==="
bash "$REPO_ROOT/scripts/test/test-blocked.sh" http://mock-model.app-ns.svc.cluster.local:8080
bash "$REPO_ROOT/scripts/test/test-allowed.sh" http://mock-model.app-ns.svc.cluster.local:8080

echo ""
echo "=== Resume complete ==="
echo "  TrafficExtension: $(oc get trafficextension -n app-ns --no-headers 2>/dev/null | awk '{print $1}')"
echo "  NeMo: $(oc get pod -n guardrails -l app=nemo-pii --no-headers | awk '{print $1, $2, $3}')"
