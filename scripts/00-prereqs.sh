#!/usr/bin/env bash
# Phase 0, Task 0.1-0.2: Verify prerequisites and label namespaces
set -euo pipefail

echo "=== Phase 0: Prerequisites ==="

# --- Check required tools ---
for tool in oc kubectl istioctl jq; do
  if ! command -v $tool &>/dev/null; then
    echo "ERROR: $tool not found. Install it before proceeding."
    exit 1
  fi
done
echo "✓ Required tools present"

# --- Verify OSSM installed ---
echo ""
echo "--- Checking OSSM and Istio revision ---"
oc get istiorevisions 2>/dev/null || {
  echo "ERROR: No IstioRevisions found. Is OSSM installed?"
  exit 1
}

ISTIO_REV=$(oc get istiorevisions -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
ISTIO_VER=$(oc get istiorevisions -o jsonpath='{.items[0].status.observedValues[0]}' 2>/dev/null || echo "unknown")
echo "✓ Istio revision: $ISTIO_REV"

# --- Verify TrafficExtension CRD ---
echo ""
echo "--- Checking TrafficExtension CRD ---"
if ! oc get crd trafficextensions.extensions.istio.io &>/dev/null; then
  echo "ERROR: TrafficExtension CRD not found in cluster."
  echo "       Contact Jamie Longmuir (jlongmui) — OSSM PM."
  echo "       Fallback: use WasmPlugin (deploy/ossm/phase1-lua/ won't work)."
  exit 1
fi
echo "✓ TrafficExtension CRD present"

# --- Label namespaces ---
echo ""
echo "--- Labeling namespaces ---"

# guardrails namespace
if ! oc get namespace guardrails &>/dev/null; then
  echo "Creating guardrails namespace..."
  oc new-project guardrails
fi
oc label namespace guardrails istio-discovery=enabled --overwrite
echo "✓ guardrails namespace labeled"

# app-ns namespace
if ! oc get namespace app-ns &>/dev/null; then
  echo "Creating app-ns namespace..."
  oc new-project app-ns
fi

if [ "$ISTIO_REV" = "default" ]; then
  oc label namespace app-ns istio-discovery=enabled istio-injection=enabled --overwrite
  echo "✓ app-ns labeled with istio-injection=enabled (default revision)"
else
  oc label namespace app-ns istio-discovery=enabled "istio.io/rev=$ISTIO_REV" --overwrite
  echo "✓ app-ns labeled with istio.io/rev=$ISTIO_REV"
fi

echo ""
echo "=== Prerequisites complete ==="
echo "Next step: scripts/01-deploy-nemo.sh"
