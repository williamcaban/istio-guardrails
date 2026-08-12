# Architecture and Design: NeMo Guardrails × OSSM TrafficExtension

**Version**: 2.0 (Phase 1 complete — TrafficExtension Lua confirmed)
**Date**: 2026-08-12
**Status**: Phase 1 validated on cluster (OCP 4.20.32 / OSSM 3.4.1 / Istio 1.30.3)
**Repo**: https://github.com/williamcaban/istio-guardrails
**License**: Apache 2.0

> **v2.0 changes**: Migrated from WasmPlugin to TrafficExtension (Lua).
> OSSM 3.4.1 (Sail Operator) with Istio 1.30.3 is the target platform.
> Phase 1 (Lua input guardrail) confirmed working. Phase 2 (Wasm full-duplex) unchanged.

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

The solution intercepts inbound LLM requests at the Envoy sidecar level using an Istio `TrafficExtension` with inline Lua (Phase 1) or Wasm (Phase 2). When a pod is labeled with a guardrail profile, the filter activates on all inbound HTTP traffic to that pod. The filter calls NeMo Guardrails' check endpoint synchronously and blocks the request with HTTP 403 if content is flagged — before it reaches the model container.

```
Inference request
  │
  ▼
Envoy sidecar (OSSM 3.4.1 / Istio 1.30.3)
  └── TrafficExtension: nemo-input-guard (phase: AUTHZ, Lua — no Wasm build required)
       │
       ├── POST /v1/guardrail/checks → nemo-pii.guardrails:80
       │    ├── "success"  → forward to model container ──────► Model
       │    └── "blocked"  → return 403 ─────────────────────► Client (model never called)
       │
       └── On NeMo error (network/timeout) → return 403 (fail-closed)

[Phase 2: same filter also intercepts response body via Wasm OnHttpResponseBody]
```

### Platform context

Two Istio control planes coexist on the target cluster:

| Revision | Version | Manages | TrafficExtension |
|---|---|---|---|
| `openshift-gateway` | 1.26.8 | RHOAI AI Gateway | ❌ `X_PILOT_IGNORE_RESOURCES=*.istio.io` |
| `default` | **1.30.3** | Our guardrail mesh | ✅ Fully supported |

TrafficExtension only works with the `default` (1.30.3) revision.

---

## 3. Architecture

### 3.1 Component Map

```
┌─────────────────────────────────────────────────────────────────┐
│                     OpenShift Cluster                           │
│                                                                 │
│  ┌─────────── istio-system ─────────┐                           │
│  │  istiod (Istio 1.30.3)           │  ← Sail Operator manages  │
│  │  revision: default               │                           │
│  │  discovery: istio-discovery=enabled                          │
│  └──────────────────────────────────┘                           │
│  ┌─────────── istio-cni ────────────┐                           │
│  │  istio-cni-node (DaemonSet)      │                           │
│  └──────────────────────────────────┘                           │
│                                                                 │
│  ┌─────────── guardrails ───────────────────────────────────┐   │
│  │  NemoGuardrails CR: nemo-pii                             │   │
│  │  ├─ Deployment: nemo-pii (1 pod, containerPort 8000)     │   │
│  │  ├─ Service: nemo-pii (ClusterIP, port 80 → 8000)        │   │
│  │  └─ ConfigMap: nemo-pii-config                           │   │
│  │       ├─ config.yaml (models:[], PII entities, regex)    │   │
│  │       └─ rails.co (built-in rails only)                  │   │
│  │  AuthorizationPolicy: allow only from app-ns             │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                 │
│  ┌─────────── app-ns ───────────────────────────────────────┐   │
│  │  TrafficExtension: nemo-input-guard (Phase 1 — Lua)      │   │
│  │  ├─ selector: guardrails.trustyai.io/config=pii          │   │
│  │  ├─ phase: AUTHZ, priority: 10                           │   │
│  │  └─ lua.inlineCode: calls nemo-pii:80/v1/guardrail/checks│   │
│  │                                                          │   │
│  │  Deployment: mock-model [label: guardrails.../config=pii]│   │
│  │  └─ 2/2 Running (app + Envoy sidecar)                    │   │
│  │       └── TrafficExtension AUTHZ filter active           │   │
│  │                                                          │   │
│  │  Pod: mesh-probe (curl, 2/2 with sidecar)                │   │
│  │       └── sends test requests to mock-model              │   │
│  └──────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

### 3.2 Data Flow — Request Check

```
Step 1  Client sends POST /v1/chat/completions to model pod

Step 2  Envoy sidecar intercepts inbound request (TrafficExtension, phase: AUTHZ)
        Lua filter fires — pod has matching guardrails.trustyai.io/config=pii label

Step 3  Lua: envoy_on_request()
        - Buffers full request body (request_handle:body(true))
        - Calls request_handle:httpCall() to NeMo cluster (timeout: 3000ms)

Step 4  HTTP callout: POST nemo-pii.guardrails.svc:80/v1/guardrail/checks
        Body: {"model":"","messages":[{"role":"user","content":"<request body>"}]}
        Envoy cluster: outbound|80||nemo-pii.guardrails.svc.cluster.local

Step 5a NeMo returns {"status":"success",...}
        Lua falls through — request forwarded to model container

Step 5b NeMo returns {"status":"blocked","guardrails_data":{...}}
        Lua calls request_handle:respond(403, ...)
        Client receives: {"error":"blocked_by_guardrail","message":"..."}
        Model is never called

Step 5c NeMo unreachable / timeout / non-200 (fail-closed)
        Lua calls request_handle:respond(403, ...)
        Client receives: {"error":"guardrail_unavailable",...}
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

Labels go on **pod template** labels, not on the `Deployment` object's own metadata. The `TrafficExtension` selector matches pod labels, not Deployment metadata labels.

```yaml
spec:
  template:
    metadata:
      labels:
        guardrails.trustyai.io/config: pii      # required — profile name
```

The `config` value maps to these cluster resources:

| Resource | Pattern | Namespace |
|---|---|---|
| `NemoGuardrails` CR | `nemo-<name>` | `guardrails` |
| `ConfigMap` | `nemo-<name>-config` | `guardrails` |
| `Service` (operator-created) | `nemo-<name>` (ClusterIP port 80 → targetPort 8000) | `guardrails` |
| `TrafficExtension` | `nemo-<name>-guard` | `app-ns` |
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
  # nemoConfigs[].name is the CONFIG DIRECTORY name (/app/config/<name>/)
  # NOT the ConfigMap name. Must be alphanumeric/dashes/underscores.
  # Confirmed: name: "pii" creates /app/config/pii/ from nemo-pii-config.
  nemoConfigs:
    - name: pii
      configMaps:
        - nemo-pii-config
      default: true
  env:
    - name: OPENAI_API_KEY
      value: not-used   # NeMo requires this env var; models: [] prevents LLM calls
```

The TrustyAI operator creates `service/nemo-pii` on **ClusterIP port 80** (→ targetPort 8000).
The Envoy cluster name uses the service port: `outbound|80||nemo-pii.guardrails.svc.cluster.local`.

---

## 5. Phase 2 — Wasm Plugin Design (Full Duplex)

### TrafficExtension vs WasmPlugin vs Wasm module

`TrafficExtension` **replaces `WasmPlugin`** as the Kubernetes resource kind — it does not eliminate Wasm. The relationship is:

```
TrafficExtension (API resource kind — replaces WasmPlugin)
  ├── spec.lua:   ← NEW in Istio 1.30; inline Lua, no build toolchain (Phase 1)
  └── spec.wasm:  ← same Wasm binary as before, nested under new CR kind (Phase 2)
```

| | `WasmPlugin` | `TrafficExtension` |
|---|---|---|
| API kind | `WasmPlugin` | `TrafficExtension` |
| Extension types | Wasm only | **Lua** or Wasm (mutually exclusive) |
| Status in OSSM 3.4 | Being deprecated | Tech preview (successor) |
| Wasm binary compatibility | Yes | Yes — same `plugin.wasm` binary |

**Migration** from WasmPlugin to TrafficExtension for Wasm is a single CR change:
```yaml
# Before (WasmPlugin)              # After (TrafficExtension)
kind: WasmPlugin                   kind: TrafficExtension
spec:                              spec:
  url: oci://...                     wasm:
  pluginConfig: {...}                  url: oci://...
                                       pluginConfig: {...}
```

The `wasm/main.go` binary is unchanged — only the CR wrapper changes.

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
       └── OnPluginStart()  ← loads JSON pluginConfig from TrafficExtension.spec.wasm.pluginConfig
       └── NewHttpContext(id)
            └── httpContext{}
                 ├── OnHttpRequestBody()   ← buffers body, calls NeMo, blocks or continues
                 └── OnHttpResponseBody()  ← Phase 2: same for response
```

### 5.3 Plugin Configuration

Passed via `TrafficExtension.spec.wasm.pluginConfig` (JSON, parsed in `OnPluginStart`):

```json
{
  "nemoCluster": "outbound|80||nemo-pii.guardrails.svc.cluster.local",
  "nemoHost":    "nemo-pii.guardrails.svc.cluster.local",
  "nemoPath":    "/v1/guardrail/checks",
  "timeoutMs":   3000,
  "failMode":    "closed"
}
```

### 5.4 Wasm Delivery — OCI vs HTTP

`TrafficExtension.spec.wasm.url` supports four schemes: `oci://`, `http://`, `https://`, `file://`.

**Recommended (Istio 1.30+)**: push the binary to an external OCI registry (Quay.io) with a valid cert and use `oci://`:
```yaml
wasm:
  url: oci://quay.io/rhai-guardrails/nemo-wasm-guard:0.1.0
  sha256: <sha256-of-wasm-binary>
```

**Fallback (internal registry / self-signed cert)**: serve the binary over plain HTTP from a sidecar-free pod. This was the workaround required under Istio 1.28.5 where `ISTIO_META_INSECURE_REGISTRIES` did not bypass TLS for OCI pulls. Under Istio 1.30.3, OCI with a valid external cert is the preferred path.

```
# HTTP fallback build (still valid if OCI cert issues arise)
Stage 1: golang → builds plugin.wasm (GOOS=wasip1 GOARCH=wasm)
Stage 2: ubi9/python-39 → serves plugin.wasm via python3 -m http.server 8080
```

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
| `TrafficExtension` API (OSSM) | Tech preview in OSSM 3.4.1 |
| `NemoGuardrails` CRD (RHOAI) | Supported |
| Lua/Wasm plugin code (inline or `wasm/main.go`) | **Not supported** — community / owner-maintained |

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
| Input guardrails only (Phase 1) | Response body check requires Phase 2 Wasm | Phase 2 work |
| Streaming (SSE) incompatible | Lua body buffering incompatible with SSE streaming responses | Disable streaming during POC testing |
| Dialog rails (stateful) | Multi-turn context is not preserved across independent requests | Only stateless input/output rails used |
| One NeMo instance per profile | Each `guardrails.trustyai.io/config` value requires its own `NemoGuardrails` CR | Multi-tenant NeMo is a follow-on |
| Label on pod template | `TrafficExtension` selector matches pod labels. Labeling only `Deployment` metadata has no effect. | Documented |
| NeMo `/v1/guardrail/checks` endpoint | RHOAI 3.6+ changes this to `/v1/checks` (RHAIRFE-2996). Update `NEMO_PATH` when upgrading. | Track RHOAI release notes |
| RHOAI AI Gateway istiod (1.26.8) ignores TrafficExtension | `X_PILOT_IGNORE_RESOURCES=*.istio.io` — gateway-level guardrails require istiod upgrade | File RFE for RHOAI to upgrade gateway istiod to 1.30 |
| NeMo cold-start ~1.2s | First request after pod restart takes ~1.2s (Presidio init). `TIMEOUT_MS < 1500` causes false 504s. | Set `TIMEOUT_MS = 3000` minimum |
| `models: []` required in config.yaml | Without it, NeMo attempts LLM generation on clean requests, causing 504s | Documented in ConfigMap |
| Ambient mode blocked | ZTunnel CRD present but `routingViaHost: false` in OVN-K blocks ambient mode | Requires maintenance window; flag for next cluster provisioning |

---

## 9. Relationship to DAGA Architecture

This POC is a direct instantiation of the Distributed Agentic Guardrail Architecture (DAGA) Tier 1 Sensor pattern:

| DAGA Tier | DAGA Role | This POC |
|---|---|---|
| Tier 1 | Sensor (intercept) | TrafficExtension (Lua/Wasm) on Envoy sidecar |
| Tier 2 | Engine (content analysis) | NeMo Guardrails (`/v1/guardrail/checks`) |
| Tier 3 | Controller (policy distribution) | ConfigMap + pod label (manual; future: operator) |

The label-based pod targeting is the "sensor instantiation" mechanism DAGA needs — deploy enforcement as close to the source as possible without requiring application code changes.

---

## 10. Future Work

| Item | Description |
|---|---|
| **Phase 2: response guardrails** | Validate `OnHttpResponseBody` against a model prompted to output PII. Requires Wasm (Lua has no `envoy_on_response`). |
| **RHOAI gateway istiod upgrade** | File RFE for RHOAI to upgrade `istiod-openshift-gateway` from 1.26.8 to 1.30.3. Unblocks `targetRefs` gateway-level guardrails without per-pod sidecars. |
| **targetRefs gateway targeting** | Once RHOAI istiod is on 1.30, a single `TrafficExtension` targeting `openshift-ai-inference` Gateway covers ALL models with zero per-pod labeling. |
| **Ambient mode** | Eliminates sidecar injection entirely. Requires `routingViaHost: true` in OVN-K. Request new cluster provision with this flag enabled. |
| **Controller** | A Kubernetes controller that watches pod labels and auto-creates/deletes `TrafficExtension` and `NemoGuardrails` CRs. App owners only manage labels. |
| **Streaming support** | Extend Wasm to handle SSE streaming responses incrementally rather than buffering the full body. |
| **Multi-profile routing** | Configure NeMo with multiple rail configs, routing by HTTP header. Eliminates one-NeMo-per-profile constraint. |
| **DAGA Tier 3 integration** | Feed enforcement telemetry (blocked request count, latency) to ASAGO policy control plane (RHAISTRAT-1778). |

---

## 11. References

| Resource | URL |
|---|---|
| Istio TrafficExtension API | https://istio.io/latest/docs/reference/config/proxy_extensions/traffic-extension/ |
| Istio WasmPlugin API (archived) | https://istio.io/latest/docs/reference/config/proxy_extensions/wasm-plugin/ |
| Istio TrafficExtension blog (1.30+) | https://istio.io/latest/blog/2026/traffic-extension-api/ |
| RHOAI NeMo Guardrails docs (3.5) | https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html-single/enabling_ai_safety_with_guardrails/index |
| OSSM 3.4 Installation docs | https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.4/html-single/installing/index |
| proxy-wasm-go-sdk (Go 1.24+) | https://github.com/proxy-wasm/proxy-wasm-go-sdk |
| DAGA architecture | `../trustworthy-ai/knowledge/shared/distributed-agentic-guardrail-architecture.md` |
| POC project memory | `../trustworthy-ai/memory/project_nemo_ossm_guardrail_integration.md` |
