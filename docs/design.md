# Architecture and Design: Istio WasmPlugin × NeMo Guardrails

**Version**: 1.0 (Validated POC)  
**Date**: 2026-08-01  
**Status**: Implemented and tested  
**Repo**: https://github.com/williamcaban/istio-guardrails  
**License**: Apache 2.0

---

## 1. Problem Statement

AI application owners on Red Hat OpenShift AI (RHOAI) need to apply safety guardrails to LLM workloads close to the application — without modifying application code and without relying solely on centralized gateway-level enforcement.

Current gateway-level enforcement (IPP plugins on the RHOAI AI Gateway) works well for organization-wide policies but cannot differentiate per-workload guardrail configuration, and all traffic must traverse a central gateway.

**Goal**: A single Kubernetes pod label activates the correct guardrail profile for that specific workload, enforced transparently by the service mesh — no application code changes, no gateway dependency, using mechanisms already familiar to Kubernetes platform administrators.

```bash
# App owner activates PII detection on their AI workload
kubectl patch deployment my-ai-app -n app-ns \
  --type=merge \
  -p '{"spec":{"template":{"metadata":{"labels":{"guardrails.trustyai.io/config":"pii"}}}}}'
```

---

## 2. Solution Overview

The solution intercepts outbound LLM requests at the Envoy sidecar level using an Istio `WasmPlugin`. When a pod is labeled with a guardrail profile, a Wasm filter activates on all outbound HTTP traffic from that pod. The filter calls NeMo Guardrails' check endpoint synchronously and blocks the request with HTTP 403 if content is flagged — before it reaches the model.

```
Labeled App Pod
  │  POST /v1/chat/completions
  │
  └── Envoy sidecar (OSSM)
       │
       └── WasmPlugin filter (active on labeled pod only)
            │
            ├── buffers request body
            ├── POST /v1/guardrail/checks → nemo-pii:80
            │        │
            │        ├── "success" → ActionContinue → model receives request
            │        └── "blocked" → SendHttpResponse(403) → model never called
            │
            └── [Phase 2: same for response body]
```

---

## 3. Architecture

### 3.1 Component Map

```
┌─────────────────────────────────────────────────────────────────┐
│                     OpenShift Cluster                           │
│                                                                 │
│  ┌─────────── istio-system ─────────┐                           │
│  │  istiod (Istio 1.28.5)           │  ← Sail Operator manages  │
│  │  discovery: istio-discovery=enabled                          │
│  └──────────────────────────────────┘                           │
│                                                                 │
│  ┌─────────── guardrails ───────────────────────────────────┐   │
│  │  NemoGuardrails CR: nemo-pii                             │   │
│  │  ├─ Deployment: nemo-pii (1 pod, port 8000)              │   │
│  │  ├─ Service: nemo-pii (ClusterIP, port 80 → 8000)        │   │
│  │  └─ ConfigMap: nemo-pii-config                           │   │
│  │       ├─ config.yaml (PII entities, regex patterns)      │   │
│  │       └─ rails.co (Colang — empty for built-in rails)    │   │
│  │  AuthorizationPolicy: allow only from app-ns             │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                 │
│  ┌─────────── app-ns ───────────────────────────────────────┐   │
│  │  WasmPlugin: nemo-input-guard                            │   │
│  │  ├─ selector: guardrails.trustyai.io/config=pii          │   │
│  │  ├─ phase: AUTHN, priority: 10                           │   │
│  │  └─ url: http://wasm-server.app-ns.svc:8080/plugin.wasm  │   │
│  │                                                          │   │
│  │  Deployment: wasm-server (Python http.server, port 8080) │   │
│  │  ├─ Serves: plugin.wasm (3.4 MB compiled Wasm binary)    │   │
│  │  └─ sidecar.istio.io/inject: "false"                     │   │
│  │                                                          │   │
│  │  Deployment: test-app [label: guardrails.../config=pii]  │   │
│  │  └─ 2/2 Running (app + Envoy sidecar)                    │   │
│  │       └── WasmPlugin active on this pod only             │   │
│  │                                                          │   │
│  │  Deployment: httpbin (mock model backend, port 8080)     │   │
│  │  └─ 2/2 Running (app + Envoy sidecar)                    │   │
│  │       └── NO guardrail label — WasmPlugin does NOT apply │   │
│  └──────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

### 3.2 Data Flow — Request Check

```
Step 1  App pod sends POST /v1/chat/completions to model-svc

Step 2  Envoy outbound listener intercepts (port 8080 in this POC)
        WasmPlugin filter fires — pod has matching label

Step 3  Wasm: OnHttpRequestBody()
        - Buffers until endOfStream=true
        - Calls proxywasm.DispatchHttpCall() to NeMo

Step 4  HTTP callout: POST nemo-pii.guardrails.svc:80/v1/guardrail/checks
        Body: {"model":"","messages":[{"role":"user","content":"<request body>"}]}

Step 5a NeMo returns {"status":"success",...}
        Wasm calls proxywasm.ResumeHttpRequest()
        Request forwarded to model

Step 5b NeMo returns {"status":"blocked","guardrails_data":{...}}
        Wasm calls proxywasm.SendHttpResponse(403, ...)
        App receives: {"error":"blocked_by_guardrail","message":"Content blocked by safety guardrails"}
        Model is never called

Step 5c NeMo unreachable / timeout (failMode=closed)
        Wasm calls proxywasm.SendHttpResponse(403, ...)
        App receives: {"error":"guardrail_unavailable",...}
```

### 3.3 NeMo Check Endpoint

**API**: `POST /v1/guardrail/checks` (RHOAI 3.4.2 path)  
**Future**: `POST /v1/checks` (RHOAI 3.6+, RHAIRFE-2996)

**Request**:
```json
{
  "model": "",
  "messages": [{"role": "user", "content": "<text-to-check>"}]
}
```

**Response — allowed**:
```json
{"status": "success", "rails_status": {"detect sensitive data on input": {"status": "success"}}}
```

**Response — blocked**:
```json
{
  "status": "blocked",
  "rails_status": {"detect sensitive data on input": {"status": "blocked"}},
  "guardrails_data": {"log": {"activated_rails": ["detect sensitive data on input"]}}
}
```

Status values: `"success"` (allow) or `"blocked"` (deny). Not `"passed"`.

---

## 4. Configuration Model

### 4.1 Label Schema

Labels go on **pod template** labels, not on the `Deployment` object's own metadata. The `WasmPlugin` selector matches pod labels.

```yaml
spec:
  template:
    metadata:
      labels:
        guardrails.trustyai.io/config: pii      # required — profile name
        guardrails.trustyai.io/fail-mode: closed # optional — "closed" | "open"
        guardrails.trustyai.io/timeout-ms: "300" # optional — ms timeout
```

The `config` value maps to these cluster resources:

| Resource | Pattern | Namespace |
|---|---|---|
| `NemoGuardrails` CR | `nemo-<name>` | `guardrails` |
| `ConfigMap` | `nemo-<name>-config` | `guardrails` |
| `Service` (operator-created) | `nemo-<name>` (port 80 → 8000) | `guardrails` |
| `WasmPlugin` | `nemo-<name>-guard` | `app-ns` |
| Envoy cluster name | `outbound|80||nemo-<name>.guardrails.svc.cluster.local` | — |

### 4.2 ConfigMap Structure

Both keys are **mandatory** in RHOAI 3.4.2:

```yaml
data:
  config.yaml: |    # NeMo YAML: models + rails configuration
    rails:
      config:
        sensitive_data_detection:
          input:
            entities: [EMAIL_ADDRESS, PHONE_NUMBER, US_SSN, CREDIT_CARD]
            score_threshold: 0.5
        regex_detection:
          input:
            patterns: ["\\b(password|api[_-]?key|token)\\b"]
            case_insensitive: true
      input:
        flows:
          - detect sensitive data on input
          - regex check input
  rails.co: |       # Colang DSL — empty is valid for built-in rails
    # Built-in rails only
```

Optional additional keys: `actions.py` (custom Python rail actions), `prompts.yml` (LLM-as-Judge prompts).

### 4.3 NeMoGuardrails CR

```yaml
apiVersion: trustyai.opendatahub.io/v1alpha1
kind: NemoGuardrails
metadata:
  name: nemo-pii
  namespace: guardrails
spec:
  nemoConfigs:
    - name: nemo-pii-config
      configMaps:
        - nemo-pii-config
      default: true           # required field in RHOAI 3.4.2
  env:
    - name: OPENAI_API_KEY
      value: not-used         # required by NeMo even for check-only (no LLM calls)
```

---

## 5. Wasm Plugin Design

### 5.1 SDK and Build

| Item | Value |
|---|---|
| SDK | `github.com/proxy-wasm/proxy-wasm-go-sdk` |
| Go version | 1.24+ (WASI reactor support) |
| Build target | `GOOS=wasip1 GOARCH=wasm -buildmode=c-shared` |
| Build environment | Fedora minimal + golang via microdnf |
| Output | `plugin.wasm` (~3.4 MB) |

The `tetratelabs/proxy-wasm-go-sdk` (archived) supports only TinyGo. The `proxy-wasm/proxy-wasm-go-sdk` continuation supports standard Go 1.24+ with WASI reactors.

### 5.2 Plugin Architecture

```
main() {}   ← empty; WASI reactor uses init()

init()
  └── proxywasm.SetVMContext(&vmContext{})

vmContext.NewPluginContext(id)
  └── pluginContext{}
       └── OnPluginStart()  ← loads JSON pluginConfig from WasmPlugin CR
       └── NewHttpContext(id)
            └── httpContext{}
                 ├── OnHttpRequestBody()   ← buffers body, calls NeMo, blocks or continues
                 └── OnHttpResponseBody()  ← Phase 2: same for response
```

### 5.3 Plugin Configuration

Passed via `WasmPlugin.spec.pluginConfig` (JSON, parsed in `OnPluginStart`):

```json
{
  "nemoCluster": "outbound|80||nemo-pii.guardrails.svc.cluster.local",
  "nemoHost":    "nemo-pii.guardrails.svc.cluster.local",
  "nemoPath":    "/v1/guardrail/checks",
  "timeoutMs":   300,
  "failMode":    "closed"
}
```

### 5.4 HTTP Serving Instead of OCI

**Problem**: Envoy sidecars cannot pull Wasm plugins from the OpenShift internal image registry via `oci://` because the registry uses a self-signed certificate that Envoy's trust store does not include. `ISTIO_META_INSECURE_REGISTRIES` does not bypass TLS verification in Istio 1.28.5.

**Solution**: A second build stage produces a Python `http.server` image. Envoy fetches `plugin.wasm` over plain HTTP (`url: http://wasm-server.app-ns.svc:8080/plugin.wasm`). HTTP avoids all certificate issues and is functionally equivalent for Wasm delivery.

```
BuildConfig (nemo-wasm-guard via Dockerfile.httpserver)
  Stage 1: fedora-minimal + golang → builds plugin.wasm (GOOS=wasip1)
  Stage 2: ubi9/python-312 → copies plugin.wasm → runs python3 -m http.server 8080
```

The `wasm-server` deployment runs without an Envoy sidecar (`sidecar.istio.io/inject: "false"`) — it is infrastructure, not a workload.

---

## 6. Security Model

### 6.1 NeMo Access Control

NeMo Guardrails has no built-in authentication (confirmed in RHOAI 3.4.2 architecture). Network-level isolation is enforced by Istio `AuthorizationPolicy`:

```yaml
# Only pods in app-ns can reach nemo-pii
spec:
  selector:
    matchLabels:
      app: nemo-pii
  action: ALLOW
  rules:
  - from:
    - source:
        namespaces: ["app-ns", "istio-system"]
```

NeMo is deployed without `security.opendatahub.io/enable-auth: 'true'` for the POC. The `AuthorizationPolicy` provides equivalent access control within the mesh.

### 6.2 Fail Mode

| Mode | Behavior when NeMo unreachable |
|---|---|
| `closed` (default, recommended) | Returns 403. No request reaches the model if the guardrail check cannot complete. |
| `open` | Allows the request through. Use only for non-critical guardrails where availability outweighs enforcement. |

### 6.3 mTLS

All communication between sidecars in the mesh uses mTLS (Istio default). The `AuthorizationPolicy` principal matching relies on mTLS identity. The Wasm filter runs inside Envoy and inherits the pod's SPIFFE identity — no additional auth needed for the NeMo callout since it is mesh-internal.

### 6.4 Support Boundary

| Layer | Red Hat support status |
|---|---|
| `WasmPlugin` API (OSSM) | Supported (stable) |
| `NemoGuardrails` CRD (RHOAI) | Supported |
| Wasm plugin source code (`wasm/main.go`) | **Not supported** — community / owner-maintained |
| Python HTTP server (`wasm-server`) | **Not supported** — POC infrastructure |

Source: Jamie Longmuir (OSSM PM), 2026-07-29: *"We don't support any particular plugin implementations for customers (besides RHCL)."*

---

## 7. OSSM Namespace Requirements

The Istio control plane uses discovery selectors to scope its namespace watch. Every namespace in the POC must opt in:

```bash
oc label namespace guardrails istio-discovery=enabled   # mesh-visible, no sidecar
oc label namespace app-ns    istio-discovery=enabled    # mesh-visible
oc label namespace app-ns    istio-injection=enabled    # enables sidecar injection
```

If the IstioRevision name is not `default` (check with `oc get istiorevisions`), replace `istio-injection=enabled` with `istio.io/rev=<revision-name>`.

---

## 8. Known Limitations

| Limitation | Impact | Status |
|---|---|---|
| `WasmPlugin` not `TrafficExtension` | `TrafficExtension` (Istio 1.30+) is not available in OSSM 3.3.1 (Istio 1.28.5). WasmPlugin is functionally equivalent for this use case. | Acceptable — WasmPlugin is stable |
| HTTP wasm serving | OCI pull from internal registry fails due to self-signed cert. Serving via HTTP is a workaround. | Acceptable for POC; production path: OCI registry with valid cert |
| Input guardrails only (Phase 1) | Response body check (`OnHttpResponseBody`) is implemented in `main.go` but not validated in current test setup | Phase 2 work |
| Streaming (SSE) incompatible | `OnHttpRequestBody` buffers the full body. SSE streaming responses cannot be buffered the same way. | Disable streaming during POC testing |
| Dialog rails (stateful) | Multi-turn context is not preserved across independent requests | Only stateless input/output rails are used |
| One NeMo instance per profile | Each `guardrails.trustyai.io/config` value requires its own `NemoGuardrails` CR | Multi-tenant NeMo is a follow-on |
| Label on pod template | The `WasmPlugin` selector matches pod labels. Labeling only the `Deployment` metadata has no effect. | Documented in README |
| NeMo `/v1/guardrail/checks` endpoint | RHOAI 3.6+ will change this to `/v1/checks` (RHAIRFE-2996). Update `nemoPath` in WasmPlugin config when upgrading. | Track RHOAI release notes |

---

## 9. Relationship to DAGA Architecture

This POC is a direct instantiation of the Distributed Agentic Guardrail Architecture (DAGA) Tier 1 Sensor pattern:

| DAGA Tier | DAGA Role | This POC |
|---|---|---|
| Tier 1 | Sensor (intercept) | WasmPlugin on Envoy sidecar |
| Tier 2 | Engine (content analysis) | NeMo Guardrails (`/v1/guardrail/checks`) |
| Tier 3 | Controller (policy distribution) | ConfigMap + pod label (manual; future: operator) |

The label-based pod targeting is the "sensor instantiation" mechanism DAGA needs — deploy enforcement as close to the source as possible without requiring application code changes.

---

## 10. Future Work

| Item | Description |
|---|---|
| **Controller** | A Kubernetes controller that watches pod labels and automatically creates/deletes WasmPlugin and NemoGuardrails CRs. App owners only manage labels. |
| **TrafficExtension migration** | When OSSM ships Istio 1.30+, migrate from `WasmPlugin` to `TrafficExtension`. The Wasm module binary is unchanged; only the CR resource kind changes. Also unlocks inline Lua as a faster-to-deploy option. |
| **OCI via valid cert** | Configure the internal registry with a trusted certificate, or use Quay.io, to restore the `oci://` URL in WasmPlugin. |
| **Phase 2: response guardrails** | Validate `OnHttpResponseBody` against a model that can be prompted to output PII. |
| **Streaming support** | Extend the Wasm module to handle SSE streaming responses incrementally rather than buffering the full body. |
| **Multi-profile routing** | Configure NeMo with multiple rail configurations, routing by HTTP header. Eliminates one-NeMo-per-profile constraint. |
| **DAGA Tier 3 integration** | Feed enforcement telemetry (NeMo call count, blocked requests, latency) to the ASAGO policy control plane (RHAISTRAT-1778). |
| **RFE** | File RHAIRFE positioning pod-native guardrail enforcement as a complement to gateway-level IPP. |

---

## 11. References

| Resource | URL |
|---|---|
| Istio WasmPlugin API | https://istio.io/latest/docs/reference/config/proxy_extensions/wasm-plugin/ |
| Istio TrafficExtension blog (1.30+) | https://istio.io/latest/blog/2026/traffic-extension-api/ |
| RHOAI NeMo Guardrails docs (3.5) | https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html-single/enabling_ai_safety_with_guardrails/index |
| OSSM 3.3 Installation docs | https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html-single/installing/index |
| proxy-wasm-go-sdk (Go 1.24+) | https://github.com/proxy-wasm/proxy-wasm-go-sdk |
| DAGA architecture | `../trustworthy-ai/knowledge/shared/distributed-agentic-guardrail-architecture.md` |
| POC project memory | `../trustworthy-ai/memory/project_nemo_ossm_guardrail_integration.md` |
