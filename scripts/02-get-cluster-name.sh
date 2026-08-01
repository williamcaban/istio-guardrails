#!/usr/bin/env bash
# Phase 0, Task 0.5: Deploy test pod and capture Envoy cluster name for NeMo
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== Phase 0: Capture Envoy cluster name ==="

# --- Deploy test pod ---
echo ""
echo "--- Deploying test pod in app-ns ---"
oc apply -f "$REPO_ROOT/deploy/app-ns/00-namespace.yaml"
oc apply -f "$REPO_ROOT/deploy/app-ns/test-app.yaml"

oc rollout status deployment/test-app -n app-ns --timeout=120s
echo "✓ Test pod ready"

# Check sidecar injected (2/2 containers)
READY=$(oc get pod -n app-ns -l app=test-app \
  -o jsonpath='{.items[0].status.containerStatuses[*].ready}' 2>/dev/null || echo "")
if [[ "$READY" != *"true true"* ]]; then
  echo "WARNING: Pod may not have sidecar injected. Check namespace labels."
  echo "  oc describe pod -n app-ns -l app=test-app"
fi

# --- Get cluster name ---
echo ""
echo "--- Querying Envoy cluster name for nemo-pii ---"
CLUSTER_NAME=$(oc exec -n app-ns deploy/test-app -c istio-proxy -- \
  pilot-agent request GET /clusters 2>/dev/null \
  | grep "nemo-pii.guardrails" \
  | head -1 \
  | cut -d: -f1)

if [ -z "$CLUSTER_NAME" ]; then
  echo "ERROR: Could not find nemo-pii cluster in Envoy config."
  echo "  Possible causes:"
  echo "  - guardrails namespace not labeled with istio-discovery=enabled"
  echo "  - NeMo service not yet discovered by control plane (wait 30s and retry)"
  echo "  - app-ns pod does not have a sidecar"
  exit 1
fi

echo ""
echo "✓ Envoy cluster name found: $CLUSTER_NAME"
echo ""
echo "ACTION REQUIRED: Update the following files with this cluster name:"
echo "  lua/nemo-input-guard.lua              → NEMO_CLUSTER = \"$CLUSTER_NAME\""
echo "  deploy/ossm/phase1-lua/traffic-extension-lua.yaml  → NEMO_CLUSTER value"
echo "  deploy/ossm/phase2-wasm/traffic-extension-wasm.yaml → nemoCluster value"
echo ""
echo "Expected default: outbound|8000||nemo-pii.guardrails.svc.cluster.local"
if [ "$CLUSTER_NAME" = "outbound|8000||nemo-pii.guardrails.svc.cluster.local" ]; then
  echo "✓ Cluster name matches default — no updates needed."
else
  echo "⚠ Cluster name differs from default — update the files above before Phase 1."
fi
echo ""
echo "=== Cluster name captured ==="
echo "Next step: scripts/03-deploy-phase1.sh"
