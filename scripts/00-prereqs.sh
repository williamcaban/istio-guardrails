#!/usr/bin/env bash
# Phase 0, Tasks 0.1-0.2: Deploy OSSM control plane and label namespaces
# Verified on: OCP 4.20.32 / OSSM 3.4.1 (Sail Operator) / Istio 1.30.3
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== Phase 0: OSSM Control Plane + Prerequisites ==="

# --- Check required tools ---
for tool in oc jq; do
  if ! command -v "$tool" &>/dev/null; then
    echo "ERROR: $tool not found. Install it before proceeding."
    exit 1
  fi
done
echo "✓ Required tools present"

# --- Verify Operators installed ---
echo ""
echo "--- Checking installed operators ---"

oc get crd trafficextensions.extensions.istio.io &>/dev/null \
  || { echo "ERROR: OSSM Operator (servicemeshoperator3) not installed — TrafficExtension CRD missing"; exit 1; }
echo "✓ OSSM Operator present (TrafficExtension CRD found)"

oc get crd nemoguardrails.trustyai.opendatahub.io &>/dev/null \
  || { echo "ERROR: TrustyAI Operator not installed — NemoGuardrails CRD missing"; exit 1; }
echo "✓ TrustyAI Operator present (NemoGuardrails CRD found)"

# --- Create namespaces ---
# CRITICAL: istio-system and istio-cni must exist BEFORE applying Istio/IstioCNI CRs.
# The Sail Operator returns ReconcileError: "namespace does not exist" if absent.
echo ""
echo "--- Creating namespaces ---"
for ns in istio-system istio-cni guardrails app-ns; do
  if oc get namespace "$ns" &>/dev/null; then
    echo "  namespace/$ns already exists"
  else
    oc create namespace "$ns"
    echo "✓ namespace/$ns created"
  fi
done

# --- Deploy OSSM control plane ---
echo ""
echo "--- Deploying Istio control plane (OSSM 3.4.1 / Istio 1.30.3) ---"
oc apply -f "$REPO_ROOT/deploy/ossm/00-istio.yaml"
oc apply -f "$REPO_ROOT/deploy/ossm/01-istiocni.yaml"

echo "  Waiting for Istio control plane (up to 5 min)..."
oc wait --for=condition=Ready istios/default --timeout=5m
oc wait --for=condition=Ready IstioCNI/default --timeout=5m
echo "✓ Istio 1.30.3 and CNI ready"

# --- Get revision name ---
ISTIO_REV=$(oc get istiorevision -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "default")
echo "  IstioRevision name: $ISTIO_REV"

# --- Label namespaces ---
# discoverySelectors in the Istio CR requires istio-discovery=enabled on all mesh namespaces.
echo ""
echo "--- Labeling namespaces for mesh discovery and injection ---"

oc label namespace istio-system istio-discovery=enabled --overwrite
oc label namespace istio-cni    istio-discovery=enabled --overwrite
oc label namespace guardrails   istio-discovery=enabled --overwrite
oc label namespace app-ns       istio-discovery=enabled --overwrite
echo "✓ Discovery labels applied"

# Sidecar injection label depends on revision name
if [ "$ISTIO_REV" = "default" ]; then
  oc label namespace app-ns istio-injection=enabled --overwrite
  echo "✓ app-ns labeled with istio-injection=enabled (default revision)"
else
  oc label namespace app-ns "istio.io/rev=$ISTIO_REV" --overwrite
  echo "✓ app-ns labeled with istio.io/rev=$ISTIO_REV"
fi

# --- Verify ---
echo ""
echo "--- Cluster state ---"
oc get pods -n istio-system
oc get pods -n istio-cni
echo ""
oc get istio,istiocni,istiorevision -A

echo ""
echo "=== OSSM prerequisites complete ==="
echo "Next step: scripts/01-deploy-nemo.sh"
