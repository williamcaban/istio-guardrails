# Implementation Plan: Istio WasmPlugin × NeMo Guardrails POC

**Version**: 1.0 (Validated)  
**Date**: 2026-08-01  
**Cluster**: OCP 4.21.17, OSSM 3.3.1 (Istio 1.28.5), RHOAI 3.4.2  
**Repo**: https://github.com/williamcaban/istio-guardrails

---

## What changed from the original plan

| Item | Originally planned | What actually happened |
|---|---|---|
| Extension API | `TrafficExtension` (Istio 1.30+) | **`WasmPlugin`** — TrafficExtension not in Istio 1.28.5 |
| Phase 1 mechanism | Inline Lua via TrafficExtension | **Wasm module** via WasmPlugin |
| Wasm serving | `oci://quay.io/...` | **`http://wasm-server.../plugin.wasm`** — Envoy cannot verify internal registry self-signed cert |
| Wasm build | TinyGo locally | **Fedora + Go 1.24 in OpenShift** via `oc new-build` |
| RHOAI version | 3.5 | **3.4.2** — NeMo CRD spec has `default: true` field |
| NeMo service port | 8000 | **80** (operator creates svc port 80 → container 8000) |
| Envoy cluster name | `outbound\|8000\|...` | **`outbound\|80\|...`** |
| Istio mode | Existing mesh | **New Istio CR needed** — existing `openshift-gateway` is gateway-only |
| Internal registry | Assumed enabled | **Had to enable** (`managementState: Removed` → `Managed`) |
| Label placement | Deployment `metadata.labels` | **Pod template** `spec.template.metadata.labels` — WasmPlugin matches pod labels |

---

## Repository Layout (current)

```
istio-guardrails/
├── LICENSE                           ← Apache 2.0
├── README.md                         ← operator guide (run/test/remove)
├── docs/
│   ├── design.md                     ← architecture and design decisions
│   └── implementation-plan.md        ← this file
│
├── deploy/
│   ├── nemo/                         ← NeMo manifests — apply in order (00 → 03)
│   │   ├── 00-namespace.yaml
│   │   ├── 01-configmap-pii.yaml
│   │   ├── 02-nemoguardrails-cr.yaml  ← NemoGuardrails CR with default: true
│   │   └── 03-authorizationpolicy.yaml
│   │
│   ├── ossm/
│   │   ├── phase1-wasm/
│   │   │   └── wasmplugin.yaml       ← WasmPlugin (ACTIVE, validated)
│   │   ├── phase1-lua/
│   │   │   └── traffic-extension-lua.yaml  ← Lua option (requires Istio 1.30+)
│   │   └── phase2-wasm/
│   │       └── traffic-extension-wasm.yaml  ← TrafficExtension (requires Istio 1.30+)
│   │
│   └── app-ns/
│       ├── 00-namespace.yaml
│       ├── httpbin.yaml              ← mock backend (gunicorn -b 0.0.0.0:8080)
│       └── test-app.yaml             ← curl test client
│
├── lua/
│   └── nemo-input-guard.lua          ← Lua script (for future TrafficExtension use)
│
└── wasm/
    ├── main.go                       ← Go Wasm plugin (proxy-wasm/proxy-wasm-go-sdk)
    ├── go.mod                        ← Go 1.24, proxy-wasm/proxy-wasm-go-sdk
    ├── Dockerfile                    ← scratch image (wasm binary only)
    ├── Dockerfile.httpserver         ← Fedora build + UBI Python HTTP server (USED)
    └── Makefile
```

---

## Phase 0 — Prerequisites ✓ DONE

**Cluster**: OCP 4.21.17 / OSSM 3.3.1 (Istio 1.28.5) / RHOAI 3.4.2

### Task 0.1 — Enable internal image registry ✓

The internal registry was `Removed`. Enabled with emptyDir (single-node POC):

```bash
oc patch configs.imageregistry.operator.openshift.io/cluster \
  --type merge \
  -p '{"spec":{"managementState":"Managed","storage":{"emptyDir":{}}}}'
oc rollout status deployment/image-registry -n openshift-image-registry --timeout=180s
```

**Finding**: Always check registry state before attempting builds.

### Task 0.2 — Deploy OSSM Istio service mesh ✓

The existing `openshift-gateway` Istio CR is a gateway-only deployment (not a service mesh) created by the RHOAI AI Gateway — no Sail Operator `Istio` CR exists. A new one was needed:

```bash
oc create namespace istio-system istio-cni

cat <<EOF | oc apply -f -
apiVersion: sailoperator.io/v1
kind: IstioCNI
metadata:
  name: default
spec:
  namespace: istio-cni
EOF

cat <<EOF | oc apply -f -
apiVersion: sailoperator.io/v1
kind: Istio
metadata:
  name: default
spec:
  version: v1.28.5
  namespace: istio-system
  values:
    meshConfig:
      discoverySelectors:
        - matchLabels:
            istio-discovery: enabled
EOF

oc wait istio/default --for=jsonpath='{.status.state}'=Healthy --timeout=180s
```

**Finding**: Do not need `nativeNftables: true` on RHCOS 9.x (only RHCOS 10+).

### Task 0.3 — Label namespaces ✓

```bash
oc create namespace guardrails
oc label namespace guardrails istio-discovery=enabled

oc create namespace app-ns
oc label namespace app-ns istio-discovery=enabled istio-injection=enabled
# Revision name is "default" on this cluster → istio-injection=enabled is correct
```

### Task 0.4 — Deploy NeMo Guardrails ✓

```bash
oc apply -f deploy/nemo/
oc wait nemoguardrails/nemo-pii -n guardrails \
  --for=jsonpath='{.status.phase}'=Ready --timeout=300s
```

**Finding**: The `NemoGuardrails` CR requires `nemoConfigs[].default: true` in RHOAI 3.4.2 (not documented in RHOAI 3.5 quickstart).

**Finding**: NeMo service is created on port **80** (not 8000). Port 80 maps to container port 8000. Port-forward uses `svc/nemo-pii 8080:80`.

### Task 0.5 — Validate NeMo endpoint ✓

```bash
oc -n guardrails port-forward svc/nemo-pii 8080:80 &

curl -s http://localhost:8080/v1/guardrail/checks \
  -H "Content-Type: application/json" \
  -d '{"model":"","messages":[{"role":"user","content":"What is Kubernetes?"}]}' | jq .status
# "success"

curl -s http://localhost:8080/v1/guardrail/checks \
  -H "Content-Type: application/json" \
  -d '{"model":"","messages":[{"role":"user","content":"My SSN is 123-45-6789"}]}' | jq .status
# "blocked"

kill %1
```

### Task 0.6 — Capture Envoy cluster name ✓

```bash
oc apply -f deploy/app-ns/test-app.yaml
oc rollout status deployment/test-app -n app-ns --timeout=60s

oc exec -n app-ns deploy/test-app -c istio-proxy -- \
  pilot-agent request GET /clusters 2>/dev/null | grep nemo-pii | head -1 | cut -d: -f1
# outbound|80||nemo-pii.guardrails.svc.cluster.local
```

**Finding**: Cluster name uses the **service port (80)**, not the container port (8000). This differs from what was expected.

---

## Phase 1 — WasmPlugin: Input Guard ✓ DONE

**Mechanism**: `WasmPlugin` (not TrafficExtension — not available in Istio 1.28.5).  
**Result**: PII requests blocked with 403. Clean requests pass. Validated on 2026-08-01.

### Task 1.1 — Build Wasm module in OpenShift ✓

No local TinyGo required. Built entirely in-cluster using `oc new-build`:

```bash
# Create BuildConfig
oc new-build --strategy=docker --binary --name=nemo-wasm-guard -n app-ns

# Patch to use the HTTP server Dockerfile (Fedora + Go 1.24 + Python http.server)
oc patch bc nemo-wasm-guard -n app-ns \
  --type=merge \
  -p '{"spec":{"strategy":{"dockerStrategy":{"dockerfilePath":"Dockerfile.httpserver"}}}}'

# Build (~4 min first run — downloads Fedora packages + Go dependencies)
cd wasm/
oc start-build nemo-wasm-guard --from-dir=. --follow -n app-ns
cd ..
```

**Build details**:
- Base image: `registry.fedoraproject.org/fedora-minimal:latest` (Go 1.24.x included)
- SDK: `github.com/proxy-wasm/proxy-wasm-go-sdk v0.0.0-20260105142703-44c7d5847745`
- Build command: `GOOS=wasip1 GOARCH=wasm go build -buildmode=c-shared -o plugin.wasm ./...`
- Output binary: ~3.4 MB

**Finding**: `tetratelabs/proxy-wasm-go-sdk` (archived) is TinyGo-only. Use `proxy-wasm/proxy-wasm-go-sdk` for standard Go 1.24+.

### Task 1.2 — Deploy wasm-server ✓

Envoy cannot pull from `oci://` using the internal registry's self-signed certificate. `ISTIO_META_INSECURE_REGISTRIES` does not bypass TLS in Istio 1.28.5. Solved by serving the binary over plain HTTP:

```bash
cat <<'EOF' | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: wasm-server
  namespace: app-ns
spec:
  replicas: 1
  selector:
    matchLabels:
      app: wasm-server
  template:
    metadata:
      labels:
        app: wasm-server
      annotations:
        sidecar.istio.io/inject: "false"   # infrastructure pod, no guardrail
    spec:
      containers:
      - name: wasm-server
        image: image-registry.openshift-image-registry.svc:5000/app-ns/nemo-wasm-guard:latest
        ports:
        - containerPort: 8080
        resources:
          requests: {cpu: 10m, memory: 32Mi}
          limits: {cpu: 100m, memory: 64Mi}
---
apiVersion: v1
kind: Service
metadata:
  name: wasm-server
  namespace: app-ns
spec:
  selector:
    app: wasm-server
  ports:
  - port: 8080
    targetPort: 8080
EOF
oc rollout status deployment/wasm-server -n app-ns --timeout=60s
```

### Task 1.3 — Deploy WasmPlugin ✓

```bash
cat <<'EOF' | oc apply -f -
apiVersion: extensions.istio.io/v1alpha1
kind: WasmPlugin
metadata:
  name: nemo-input-guard
  namespace: app-ns
spec:
  selector:
    matchLabels:
      guardrails.trustyai.io/config: pii
  phase: AUTHN
  priority: 10
  url: http://wasm-server.app-ns.svc:8080/plugin.wasm
  pluginConfig:
    nemoCluster: "outbound|80||nemo-pii.guardrails.svc.cluster.local"
    nemoHost: "nemo-pii.guardrails.svc.cluster.local"
    nemoPath: "/v1/guardrail/checks"
    timeoutMs: 300
    failMode: "closed"
EOF
```

### Task 1.4 — Label test application ✓

**Critical**: the label must be on the **pod template**, not the `Deployment` resource's own labels:

```bash
# Wrong — does nothing for WasmPlugin:
kubectl label deployment test-app guardrails.trustyai.io/config=pii -n app-ns

# Correct — patches pod template labels:
kubectl patch deployment test-app -n app-ns \
  --type=merge \
  -p '{"spec":{"template":{"metadata":{"labels":{"guardrails.trustyai.io/config":"pii"}}}}}'
```

Also deploy the mock backend:

```bash
oc apply -f deploy/app-ns/httpbin.yaml
```

**Finding**: httpbin image binds to port 80 by default, which requires root — blocked by OpenShift's restricted SCC. Solution: override with `gunicorn -b 0.0.0.0:8080` in the Deployment command.

### Task 1.5 — Validate Phase 1 ✓

All tests passed on 2026-08-01:

```bash
MODEL_SVC="http://httpbin.app-ns.svc:8080"

# Test 1: SSN → 403 ✓
oc exec -n app-ns deploy/test-app -- \
  curl -s -w "\nHTTP: %{http_code}\n" \
  -H "Content-Type: application/json" \
  -d '{"model":"llama3","messages":[{"role":"user","content":"My SSN is 123-45-6789"}]}' \
  $MODEL_SVC/post
# {"error":"blocked_by_guardrail","message":"Content blocked by safety guardrails"}
# HTTP: 403

# Test 2: Email → 403 ✓
oc exec -n app-ns deploy/test-app -- \
  curl -s -w "\nHTTP: %{http_code}\n" \
  -H "Content-Type: application/json" \
  -d '{"model":"llama3","messages":[{"role":"user","content":"Contact alice@example.com"}]}' \
  $MODEL_SVC/post
# HTTP: 403

# Test 3: api_key keyword → 403 ✓
oc exec -n app-ns deploy/test-app -- \
  curl -s -w "\nHTTP: %{http_code}\n" \
  -H "Content-Type: application/json" \
  -d '{"model":"llama3","messages":[{"role":"user","content":"My api_key is sk-abc123"}]}' \
  $MODEL_SVC/post
# HTTP: 403

# Test 4: Clean request → 200 ✓
oc exec -n app-ns deploy/test-app -- \
  curl -s -w "\nHTTP: %{http_code}\n" \
  -H "Content-Type: application/json" \
  -d '{"model":"llama3","messages":[{"role":"user","content":"Explain Kubernetes networking"}]}' \
  $MODEL_SVC/post
# HTTP: 200

# Test 5: Unlabeled pod — WasmPlugin does NOT apply ✓
oc get pod -n app-ns -l app=httpbin \
  -o jsonpath='{.items[0].metadata.labels}' | grep -q guardrail \
  && echo "UNEXPECTED" || echo "No guardrail label — correct"
```

**NeMo call stats** (from Envoy cluster dump):
```
rq_success: 10   rq_total: 12   rq_timeout: 2
```
2 timeouts are from early probes before the Wasm module finished loading. All subsequent calls succeed.

---

## Phase 2 — Response Guardrail ☐ PENDING

**Goal**: Also intercept and check model response bodies before returning to the caller.

**Status**: The `OnHttpResponseBody` handler is implemented in `wasm/main.go` but has not been tested against a real model that can be prompted to output PII.

### Prerequisites for Phase 2

1. A deployed vLLM or InferenceService endpoint in the cluster (none exists on the test cluster currently)
2. Or a mock that echoes arbitrary content in the response body

### Task 2.1 — Deploy a model endpoint

Options:
- Deploy a small InferenceService using RHOAI KServe (requires GPU or CPU-only model)
- Or patch httpbin to reflect the request body in the response for testing purposes

### Task 2.2 — Validate response blocking

```bash
MODEL_SVC="http://<vllm-or-isvc>.model-ns.svc:8080"

# Prompt the model to echo PII back
oc exec -n app-ns deploy/test-app -- \
  curl -s -w "\nHTTP: %{http_code}\n" \
  -H "Content-Type: application/json" \
  -d '{"model":"llama3","messages":[{"role":"user","content":"Repeat verbatim: My SSN is 123-45-6789"}]}' \
  $MODEL_SVC/v1/chat/completions
# Expected: HTTP: 403 (Wasm intercepts response, calls NeMo, blocks)
```

**Phase 2 acceptance criteria**:
- [ ] Response containing SSN returns 403
- [ ] Clean request + clean response returns 200 end-to-end
- [ ] NeMo `rq_total` increments by 2 per request (one for input, one for output)

---

## Requirements for TrafficExtension Migration (Future)

`TrafficExtension` (`extensions.istio.io/v1alpha1`) supersedes `WasmPlugin` and adds inline Lua as a first-class extension type alongside Wasm. It is not available in Istio 1.28.5 (OSSM 3.3.1). This section documents what is needed to migrate when OSSM ships a compatible version.

### Istio version requirement

| OSSM version | Istio version | TrafficExtension |
|---|---|---|
| 3.3.1 (current) | 1.28.5 | ❌ Not available |
| Future | 1.30+ | ✅ Available (tech preview per Jamie Longmuir, OSSM PM) |

Verify with: `oc get crd trafficextensions.extensions.istio.io`

### API structure

TrafficExtension uses the same API group (`extensions.istio.io/v1alpha1`) and selector mechanism as WasmPlugin. The key difference is the extension type is nested:

```yaml
# WasmPlugin (current)
spec:
  url: http://wasm-server.app-ns.svc:8080/plugin.wasm
  pluginConfig: {...}

# TrafficExtension + Wasm (future — same binary, restructured fields)
spec:
  wasm:
    url: http://wasm-server.app-ns.svc:8080/plugin.wasm
    pluginConfig: {...}

# TrafficExtension + Lua (future — no build needed, input-only recommended)
spec:
  lua:
    inlineCode: |
      local NEMO_CLUSTER = "outbound|80||nemo-pii.guardrails.svc.cluster.local"
      ...
      function envoy_on_request(request_handle)
        ...
      end
```

### Requirements for Lua extension

- **No build toolchain** — Lua script is embedded inline in the YAML
- **Cluster name** — same Envoy cluster name requirement as Wasm (`outbound|80||...`)
- **HTTP callout API** — `request_handle:httpCall(cluster, headers, body, timeout_ms)` returns `(resp_headers, resp_body)` via `pcall`
- **Buffer limit** — default 10 MB; sufficient for typical LLM request bodies (input guardrail). Large LLM response bodies may exceed limit — use Wasm for output guardrail
- **L7 only** — Lua filters operate on HTTP only (no TCP)
- **Recommended scope** — input guardrail (`envoy_on_request`) only; response guardrail (`envoy_on_response`) works but is constrained by buffer limits

Lua extension example for this POC (see `lua/nemo-input-guard.lua` for full script):

```yaml
apiVersion: extensions.istio.io/v1alpha1
kind: TrafficExtension
metadata:
  name: nemo-input-guard
  namespace: app-ns
spec:
  selector:
    matchLabels:
      guardrails.trustyai.io/config: pii
  phase: AUTHZ          # AUTHZ runs before routing — ideal for blocking
  priority: 10
  lua:
    inlineCode: |
      local NEMO_CLUSTER = "outbound|80||nemo-pii.guardrails.svc.cluster.local"
      local NEMO_HOST    = "nemo-pii.guardrails.svc.cluster.local"
      local NEMO_PATH    = "/v1/guardrail/checks"
      local TIMEOUT_MS   = 300

      function envoy_on_request(request_handle)
        local body = request_handle:body(true)
        if body == nil or body:length() == 0 then return end

        local ok, resp_headers, resp_body = pcall(function()
          return request_handle:httpCall(
            NEMO_CLUSTER,
            {[":method"]="POST",[":path"]=NEMO_PATH,
             [":authority"]=NEMO_HOST,["content-type"]="application/json"},
            body:getBytes(0, body:length()), TIMEOUT_MS)
        end)

        if not ok then
          request_handle:respond(
            {[":status"]="403",["content-type"]="application/json"},
            '{"error":"guardrail_unavailable"}')
          return
        end

        if string.find(resp_body, '"status"%s*:%s*"blocked"') then
          request_handle:respond(
            {[":status"]="403",["content-type"]="application/json"},
            '{"error":"blocked_by_guardrail","message":"Request blocked by safety guardrails"}')
        end
      end
```

### Requirements for Wasm extension

- **Same Wasm binary** — `wasm/main.go` compiled with `GOOS=wasip1 GOARCH=wasm -buildmode=c-shared` produces the same binary for both WasmPlugin and TrafficExtension
- **Same OCI TLS issue** — `oci://` URL with the internal registry still fails; continue using HTTP serving (`http://wasm-server.app-ns.svc:8080/plugin.wasm`) or use a registry with a valid certificate
- **Full duplex** — handles both `envoy_on_request` and `envoy_on_response` without buffer limits
- **Phase field** — `AUTHZ` (preferred for blocking) or `AUTHN`; same semantics as WasmPlugin

### Ambient mode (targetRefs)

TrafficExtension adds `targetRefs` for ambient-mode clusters (no sidecar — uses ztunnel + waypoints). If the cluster uses ambient mode instead of sidecar mode, replace `selector` with `targetRefs`:

```yaml
spec:
  # Instead of selector (sidecar):
  targetRefs:
  - kind: Service
    name: my-ai-app-svc
    namespace: app-ns
  # OR for a specific service account:
  - kind: ServiceAccount
    name: my-ai-app
    namespace: app-ns
```

`targetRefs` is not available on the current cluster (sidecar mode, Istio 1.28.5).

### Migration checklist (WasmPlugin → TrafficExtension)

| Step | Action |
|---|---|
| 1 | Verify `oc get crd trafficextensions.extensions.istio.io` returns a result |
| 2 | Delete existing `WasmPlugin/nemo-input-guard` |
| 3 | Apply `deploy/ossm/phase1-wasm/wasmplugin.yaml` converted to `TrafficExtension` (change kind, wrap `url` under `wasm:`) |
| 4 | For Lua option: apply `deploy/ossm/phase1-lua/traffic-extension-lua.yaml` directly |
| 5 | Verify Wasm loads: `oc logs -n app-ns deploy/<app> -c istio-proxy \| grep wasm` |
| 6 | Re-run all Phase 1 tests |

No changes to `wasm/main.go`, NeMo configuration, or label schema are required.

---

## Lessons Learned

| Finding | Impact | Resolution |
|---|---|---|
| `TrafficExtension` not in Istio 1.28.5 | Entire Phase 1 mechanism changed | Use `WasmPlugin` (stable, equivalent) |
| Envoy cannot verify internal registry self-signed cert | `oci://` URL unusable | Serve `.wasm` via HTTP from a pod inside the cluster |
| `ISTIO_META_INSECURE_REGISTRIES` does not skip TLS in 1.28.5 | Spent time on dead end | Confirmed via proxy logs; moved to HTTP approach |
| `NemoGuardrails` CRD has `default: true` field (RHOAI 3.4.2) | CR spec differs from 3.5 docs | Add `default: true` to `nemoConfigs[]` items |
| NeMo service port is 80, not 8000 | Wrong Envoy cluster name | TrustyAI operator maps svc:80 → container:8000 |
| `WasmPlugin` selector matches pod labels, not Deployment labels | All initial tests returned 200 | Patch `spec.template.metadata.labels`, not `metadata.labels` |
| httpbin image tries to bind port 80 (root required) | Pod crashes under OpenShift restricted SCC | Override with `gunicorn -b 0.0.0.0:8080` |
| `tetratelabs/proxy-wasm-go-sdk` is archived | Cannot use TinyGo approach | Use `proxy-wasm/proxy-wasm-go-sdk` with Go 1.24+ |
| Internal registry was disabled (`Removed`) | Builds could not push | Enable with `managementState: Managed, storage: emptyDir` |
| Existing `openshift-gateway` Istio is gateway-only | No sidecar injection by default | Deploy new `Istio` CR in `istio-system` with discovery selectors |

---

## Key Commands Reference

```bash
# Verify WasmPlugin is loaded in sidecar
oc exec -n app-ns deploy/test-app -c istio-proxy -- \
  pilot-agent request GET /config_dump 2>/dev/null | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print('wasm found' if 'plugin.wasm' in json.dumps(d) else 'NOT found')"

# Check NeMo call stats
oc exec -n app-ns deploy/test-app -c istio-proxy -- \
  pilot-agent request GET /clusters 2>/dev/null | grep "nemo-pii.*rq_"

# Watch sidecar logs during a test
oc logs -n app-ns deploy/test-app -c istio-proxy -f | grep -i "wasm\|nemo\|blocked"

# Watch NeMo logs during a test
oc logs -n guardrails deploy/nemo-pii -f

# Validate NeMo directly
oc -n guardrails port-forward svc/nemo-pii 8080:80 &
curl -s http://localhost:8080/v1/guardrail/checks \
  -H "Content-Type: application/json" \
  -d '{"model":"","messages":[{"role":"user","content":"test"}]}' | jq .
kill %1

# Check all WasmPlugin resources
oc get wasmplugin -A

# Check NeMo status
oc get nemoguardrails -n guardrails

# Check wasm-server is serving
oc exec -n app-ns deploy/wasm-server -- \
  curl -sI http://localhost:8080/plugin.wasm | head -3
```

---

## Progress Tracker

| Task | Status | Notes |
|---|---|---|
| **Phase 0** | | |
| 0.1 Enable internal registry | ✅ Done | emptyDir storage, single-node POC |
| 0.2 Deploy OSSM Istio CR + IstioCNI | ✅ Done | v1.28.5, discovery selectors scoped to POC namespaces |
| 0.3 Label namespaces | ✅ Done | guardrails + app-ns |
| 0.4 Deploy NeMo CR | ✅ Done | RHOAI 3.4.2, `default: true` field required |
| 0.5 Validate NeMo endpoint | ✅ Done | Port 80 (svc) → 8000 (container) |
| 0.6 Capture Envoy cluster name | ✅ Done | `outbound\|80\|...` — service port, not container port |
| **Phase 1** | | |
| 1.1 Build Wasm module (in-cluster) | ✅ Done | Fedora + Go 1.24, proxy-wasm/proxy-wasm-go-sdk |
| 1.2 Deploy wasm-server | ✅ Done | HTTP serving — OCI TLS workaround |
| 1.3 Deploy WasmPlugin | ✅ Done | `http://wasm-server.app-ns.svc:8080/plugin.wasm` |
| 1.4 Label test application | ✅ Done | Pod template labels (not Deployment labels) |
| 1.5 Validate Phase 1 | ✅ Done | SSN/email/api_key → 403, clean → 200, unlabeled → 200 |
| **Phase 2** | | |
| 2.1 Deploy model endpoint | ☐ Pending | Needs vLLM or InferenceService on the cluster |
| 2.2 Validate response blocking | ☐ Pending | Depends on 2.1 |
