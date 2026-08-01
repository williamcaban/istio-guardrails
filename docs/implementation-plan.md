# Implementation Plan: Istio TrafficExtension × NeMo Guardrails POC

**Version**: 0.1  
**Date**: 2026-07-31  
**Repo**: `/Users/williamcaban/Documents/devel/wc-knowledge-base/istio-guardrails/`

---

## Repository Layout

```
istio-guardrails/
├── docs/
│   ├── design.md               ← this repo's architecture (read first)
│   └── implementation-plan.md  ← this file
│
├── deploy/
│   ├── nemo/                   ← NeMo Guardrails manifests
│   │   ├── 00-namespace.yaml
│   │   ├── 01-configmap-pii.yaml
│   │   ├── 02-nemoguardrails-cr.yaml
│   │   └── 03-authorizationpolicy.yaml
│   │
│   ├── ossm/
│   │   ├── phase1-lua/
│   │   │   └── traffic-extension-lua.yaml
│   │   └── phase2-wasm/
│   │       └── traffic-extension-wasm.yaml
│   │
│   └── app-ns/
│       ├── 00-namespace.yaml
│       └── test-app.yaml       ← minimal curl-based test pod
│
├── lua/
│   └── nemo-input-guard.lua    ← standalone Lua script (also embedded in YAML)
│
├── wasm/
│   ├── main.go                 ← proxy-wasm-go-sdk plugin
│   ├── go.mod
│   └── Makefile
│
└── scripts/
    ├── 00-prereqs.sh           ← Phase 0: verify CRDs, label namespaces
    ├── 01-deploy-nemo.sh       ← Phase 0: deploy NeMo + validate
    ├── 02-get-cluster-name.sh  ← Phase 0: extract Envoy cluster name
    ├── 03-deploy-phase1.sh     ← Phase 1: deploy TrafficExtension + Lua
    ├── 04-deploy-phase2.sh     ← Phase 2: build Wasm + deploy
    └── test/
        ├── test-blocked.sh     ← assert 403 on PII input
        ├── test-allowed.sh     ← assert 200 on clean input
        └── test-response.sh    ← Phase 2: assert 403 on PII in response
```

---

## Phase 0 — Prerequisites (Day 1)

**Goal**: Cluster is ready, NeMo is deployed and validated, Envoy cluster name captured.

### Task 0.1 — Verify OSSM and TrafficExtension

```bash
# Run scripts/00-prereqs.sh

# 1. Verify OSSM installed
oc get istiorevisions
# NAME      TYPE    READY   STATUS    VERSION   AGE
# default   Local   True    Healthy   v1.24.x   ...

# 2. Verify TrafficExtension CRD present (STOP if absent — escalate to OSSM team)
oc get crd trafficextensions.extensions.istio.io
# If absent: contact Jamie Longmuir (jlongmui)

# 3. Get Istio revision name (needed for namespace labels)
export ISTIO_REV=$(oc get istiorevisions -o jsonpath='{.items[0].metadata.name}')
echo "Revision: $ISTIO_REV"
# If "default" → use istio-injection=enabled
# If other name → use istio.io/rev=$ISTIO_REV
```

**Acceptance criteria**: CRD present. Revision name known.

---

### Task 0.2 — Label namespaces

```bash
# NeMo namespace (mesh-visible, no sidecar injection)
oc new-project guardrails || true
oc label namespace guardrails istio-discovery=enabled --overwrite

# App namespace (mesh-visible + sidecar injection)
oc new-project app-ns || true
if [ "$ISTIO_REV" = "default" ]; then
  oc label namespace app-ns istio-discovery=enabled istio-injection=enabled --overwrite
else
  oc label namespace app-ns istio-discovery=enabled istio.io/rev=$ISTIO_REV --overwrite
fi

# Model namespace (if separate — label for mesh visibility)
# oc label namespace model-ns istio-discovery=enabled istio-injection=enabled --overwrite
```

**Acceptance criteria**: All namespaces labeled. Pods in `app-ns` show 2/2 containers after rollout.

---

### Task 0.3 — Deploy NeMo Guardrails

Apply `deploy/nemo/` in order:

```bash
# 1. Namespace (if not already created above)
oc apply -f deploy/nemo/00-namespace.yaml

# 2. ConfigMap with PII detection rails
oc apply -f deploy/nemo/01-configmap-pii.yaml

# 3. NemoGuardrails CR (TrustyAI Operator creates Service, Deployment, Route)
oc apply -f deploy/nemo/02-nemoguardrails-cr.yaml

# 4. Wait for Ready
oc wait nemoguardrails/nemo-pii -n guardrails \
  --for=jsonpath='{.status.phase}'=Ready --timeout=300s

# 5. AuthorizationPolicy
oc apply -f deploy/nemo/03-authorizationpolicy.yaml
```

**Acceptance criteria**: `oc get nemoguardrails nemo-pii -n guardrails` shows `PHASE: Ready`.

---

### Task 0.4 — Validate NeMo endpoint

```bash
# Run scripts/01-deploy-nemo.sh (includes validation)

oc -n guardrails port-forward svc/nemo-pii 8000:8000 &
sleep 2

# Should return: "success"
STATUS=$(curl -s http://localhost:8000/v1/guardrail/checks \
  -H "Content-Type: application/json" \
  -d '{"model":"","messages":[{"role":"user","content":"What is Kubernetes?"}]}' \
  | jq -r .status)
echo "Clean request: $STATUS"   # expected: success

# Should return: "blocked"
STATUS=$(curl -s http://localhost:8000/v1/guardrail/checks \
  -H "Content-Type: application/json" \
  -d '{"model":"","messages":[{"role":"user","content":"My SSN is 123-45-6789"}]}' \
  | jq -r .status)
echo "PII request: $STATUS"     # expected: blocked

kill %1
```

**Acceptance criteria**: `"success"` and `"blocked"` returned correctly. **Do not proceed to Phase 1 if either fails.**

---

### Task 0.5 — Capture Envoy cluster name

```bash
# Run scripts/02-get-cluster-name.sh

# Deploy a minimal test pod in app-ns (needs sidecar to query clusters)
oc apply -f deploy/app-ns/test-app.yaml
oc wait pod -n app-ns -l app=test-app --for=condition=Ready --timeout=60s

# Get exact Envoy cluster name for NeMo service
oc exec -n app-ns deploy/test-app -c istio-proxy -- \
  pilot-agent request GET /clusters 2>/dev/null \
  | grep "nemo-pii.guardrails"

# Save output — it looks like:
# outbound|8000||nemo-pii.guardrails.svc.cluster.local

export NEMO_CLUSTER="outbound|8000||nemo-pii.guardrails.svc.cluster.local"
echo "NEMO_CLUSTER=$NEMO_CLUSTER"
```

**Acceptance criteria**: Cluster name captured and matches the expected pattern.

> ⚠️ **Critical**: Update the cluster name string in `lua/nemo-input-guard.lua` and `deploy/ossm/phase1-lua/traffic-extension-lua.yaml` before Phase 1 if the captured name differs from the default.

---

## Phase 1 — TrafficExtension + Lua: Input Guard (Days 2-4)

**Goal**: A labeled pod's LLM requests are intercepted. PII in the request body returns 403 before the request reaches the model.

### Task 1.1 — Review and update Lua script

File: `lua/nemo-input-guard.lua`

Verify the `NEMO_CLUSTER` constant matches what was captured in Task 0.5. If it differs, update both the standalone file and the embedded version in `deploy/ossm/phase1-lua/traffic-extension-lua.yaml`.

```lua
-- Top of file: verify these match your cluster
local NEMO_CLUSTER = "outbound|8000||nemo-pii.guardrails.svc.cluster.local"
local NEMO_HOST    = "nemo-pii.guardrails.svc.cluster.local"
local NEMO_PATH    = "/v1/guardrail/checks"   -- RHOAI 3.5
local TIMEOUT_MS   = 300
```

### Task 1.2 — Deploy TrafficExtension

```bash
# Run scripts/03-deploy-phase1.sh
oc apply -f deploy/ossm/phase1-lua/traffic-extension-lua.yaml

# Verify resource created
oc get trafficextension -n app-ns
```

### Task 1.3 — Label test app

```bash
kubectl label deployment test-app \
  guardrails.trustyai.io/config=pii -n app-ns

# Restart to ensure filter picks up
oc rollout restart deployment/test-app -n app-ns
oc rollout status deployment/test-app -n app-ns
```

### Task 1.4 — Verify filter is loaded in Envoy

```bash
istioctl proxy-config listener -n app-ns deploy/test-app \
  --port 8080 -o json | grep -i "lua\|envoy.filters.http.lua"
# Must return a match — if empty, filter is not applied
```

### Task 1.5 — Run tests

```bash
# From test pod in app-ns (replace <model-svc> with actual model service URL)
MODEL_SVC="http://vllm-svc.model-ns.svc:8080"

# Test 1: SSN in request → expect 403
bash scripts/test/test-blocked.sh $MODEL_SVC

# Test 2: Clean request → expect 200
bash scripts/test/test-allowed.sh $MODEL_SVC

# Test 3: Measure latency overhead (run 5 times, average)
for i in $(seq 5); do
  time curl -s -o /dev/null \
    -H "Content-Type: application/json" \
    -d '{"model":"llama3","messages":[{"role":"user","content":"Hello"}]}' \
    $MODEL_SVC/v1/chat/completions
done
```

**Phase 1 acceptance criteria**:
- [ ] PII request (SSN, email, credit card) returns 403
- [ ] Clean request returns 200 and reaches the model
- [ ] Unlabeled pod is NOT intercepted (verify same clean request from unlabeled pod returns 200 without TrafficExtension latency)
- [ ] Latency overhead documented (target: < 400ms)
- [ ] Filter visible in Envoy listener config

---

## Phase 2 — TrafficExtension + Wasm: Full Duplex (Days 5-10)

**Goal**: Both request and response are checked. A model that outputs PII is also blocked.

### Task 2.1 — Set up Wasm build environment

```bash
cd wasm/

# Verify Go installed (1.21+)
go version

# Install TinyGo (needed for WASI/Wasm target)
# macOS: brew install tinygo
tinygo version

# Install proxy-wasm-go-sdk
go mod download
```

### Task 2.2 — Build Wasm module

```bash
cd wasm/
make build
# Output: nemo-guard.wasm

# Verify binary
file nemo-guard.wasm
# nemo-guard.wasm: WebAssembly (wasm) binary module version 0x1
```

### Task 2.3 — Push to OCI registry

```bash
cd wasm/

# Log into Quay.io (or internal registry)
docker login quay.io

# Build and push OCI artifact
make push REGISTRY=quay.io/rhai-guardrails TAG=0.1.0-poc
# Pushes: quay.io/rhai-guardrails/nemo-wasm-guard:0.1.0-poc
```

Update the `url` field in `deploy/ossm/phase2-wasm/traffic-extension-wasm.yaml` with the actual registry path before deploying.

### Task 2.4 — Deploy TrafficExtension with Wasm

```bash
# Remove Phase 1 Lua extension first
oc delete trafficextension nemo-input-guard -n app-ns

# Deploy Phase 2 Wasm extension
oc apply -f deploy/ossm/phase2-wasm/traffic-extension-wasm.yaml

# Verify Wasm plugin pulled and loaded (may take 30-60s for OCI pull)
oc logs -n app-ns deploy/test-app -c istio-proxy | grep -i "wasm\|nemo"
```

### Task 2.5 — Run full duplex tests

```bash
MODEL_SVC="http://vllm-svc.model-ns.svc:8080"

# Test 1: PII in request → expect 403 (same as Phase 1)
bash scripts/test/test-blocked.sh $MODEL_SVC

# Test 2: Clean request → expect 200
bash scripts/test/test-allowed.sh $MODEL_SVC

# Test 3: PII in model response → expect 403
# Requires a prompt that causes the model to echo PII
bash scripts/test/test-response.sh $MODEL_SVC
```

**Phase 2 acceptance criteria**:
- [ ] Input PII blocked: 403
- [ ] Output PII blocked: 403
- [ ] Clean request + clean response: 200 end-to-end
- [ ] Wasm load confirmed in Envoy logs
- [ ] Latency overhead documented for both input + output check

---

## Troubleshooting Guide

### TrafficExtension not intercepting traffic

```bash
# 1. Verify pod has the label
oc get pod -n app-ns -l guardrails.trustyai.io/config=pii

# 2. Verify TrafficExtension selector matches
oc get trafficextension -n app-ns -o yaml | grep -A5 selector

# 3. Verify namespace has sidecar injection
oc get namespace app-ns -o yaml | grep istio

# 4. Verify pod has sidecar (2/2 containers)
oc get pods -n app-ns

# 5. Check Envoy listeners
istioctl proxy-config listener -n app-ns deploy/test-app --port 8080
```

### NeMo not reachable from Envoy

```bash
# 1. Verify NeMo service exists and has endpoints
oc get svc,endpoints nemo-pii -n guardrails

# 2. Verify AuthorizationPolicy isn't too restrictive
oc get authorizationpolicy -n guardrails -o yaml

# 3. Verify Envoy cluster name matches
oc exec -n app-ns deploy/test-app -c istio-proxy -- \
  pilot-agent request GET /clusters | grep nemo-pii

# 4. Test direct connectivity from app pod (bypasses TrafficExtension)
oc exec -n app-ns deploy/test-app -- \
  curl -s http://nemo-pii.guardrails.svc:8000/v1/guardrail/checks \
  -H "Content-Type: application/json" \
  -d '{"model":"","messages":[{"role":"user","content":"test"}]}'
```

### Wasm plugin not loading (Phase 2)

```bash
# 1. Check istio-proxy logs for pull errors
oc logs -n app-ns deploy/test-app -c istio-proxy | grep -i wasm

# 2. Verify OCI image is accessible from cluster
oc exec -n app-ns deploy/test-app -- \
  curl -s https://quay.io/v2/rhai-guardrails/nemo-wasm-guard/tags/list

# 3. Check TrafficExtension status
oc describe trafficextension nemo-full-guard -n app-ns
```

### 403 on clean requests (over-blocking)

```bash
# 1. Check NeMo response directly for the same payload
oc -n guardrails port-forward svc/nemo-pii 8000:8000 &
curl -s http://localhost:8000/v1/guardrail/checks \
  -H "Content-Type: application/json" \
  -d '{"model":"","messages":[{"role":"user","content":"<your-clean-content>"}]}' | jq .
kill %1

# 2. Check rails_status to see which rail is triggering
# Adjust ConfigMap thresholds if needed (score_threshold, regex patterns)
```

---

## Key Commands Reference

```bash
# Get Envoy cluster name
oc exec -n app-ns deploy/test-app -c istio-proxy -- \
  pilot-agent request GET /clusters | grep nemo

# Check Envoy listeners on port 8080
istioctl proxy-config listener -n app-ns deploy/test-app --port 8080

# Watch NeMo logs during test
oc logs -n guardrails deploy/nemo-pii -f

# Watch app sidecar logs
oc logs -n app-ns deploy/test-app -c istio-proxy -f

# Check TrafficExtension resources
oc get trafficextension -A

# NeMo status
oc get nemoguardrails -n guardrails

# Validate NeMo manually
oc -n guardrails port-forward svc/nemo-pii 8000:8000 &
curl -s http://localhost:8000/v1/guardrail/checks \
  -d '{"model":"","messages":[{"role":"user","content":"test"}]}' \
  -H "Content-Type: application/json" | jq .
```

---

## Progress Tracker

| Task | Status | Notes |
|---|---|---|
| 0.1 Verify TrafficExtension CRD | ☐ | Blocking — do not proceed if absent |
| 0.2 Label namespaces | ☐ | |
| 0.3 Deploy NeMo CR | ☐ | |
| 0.4 Validate NeMo endpoint | ☐ | Blocking — must return "success"/"blocked" correctly |
| 0.5 Capture Envoy cluster name | ☐ | Update Lua/Wasm config with actual value |
| 1.1 Review Lua script | ☐ | Update NEMO_CLUSTER constant |
| 1.2 Deploy TrafficExtension Lua | ☐ | |
| 1.3 Label test app | ☐ | |
| 1.4 Verify filter in Envoy | ☐ | |
| 1.5 Run Phase 1 tests | ☐ | All 3 tests must pass |
| 2.1 Set up Wasm build env | ☐ | |
| 2.2 Build Wasm module | ☐ | |
| 2.3 Push to OCI registry | ☐ | Update TrafficExtension YAML with registry URL |
| 2.4 Deploy TrafficExtension Wasm | ☐ | |
| 2.5 Run Phase 2 tests | ☐ | All 3 tests must pass |
