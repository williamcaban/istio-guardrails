# NeMo Guardrails × OSSM TrafficExtension

## What this is

A proof-of-concept that lets application owners activate **NeMo Guardrails PII detection** on an AI workload by adding a **single Kubernetes label** — with no application code changes and no gateway dependency.

```bash
kubectl label deployment my-ai-app guardrails.trustyai.io/config=pii
```

An Istio `TrafficExtension` with inline Lua intercepts every inbound request, calls NeMo's `/v1/guardrail/checks` endpoint, and blocks PII before it reaches the model.

---

## Phase 1 results (confirmed 2026-08-12)

| Test | Request content | HTTP status |
|---|---|---|
| Clean request | "Explain Kubernetes networking" | **200** ✅ |
| Email PII | "Contact john.doe@example.com" | **403** ✅ |
| Phone PII | "Call me at 555-123-4567" | **403** ✅ |
| Credential (regex) | "my api_key is abc123xyz" | **403** ✅ |

---

## Architecture

```
Inference request
  │
  ▼
Envoy sidecar (OSSM 3.4.1 / Istio 1.30.3)
  └── TrafficExtension: nemo-input-guard (phase: AUTHZ, Lua — no Wasm build needed)
       │
       ├── POST /v1/guardrail/checks → nemo-pii.guardrails:80
       │    ├── status: "success"  → forward to model ─────────────► Model
       │    └── status: "blocked"  → return 403 ──────────────────► Client
       │
       └── On NeMo error → return 403 (fail-closed)

[Phase 2: Wasm extends this to intercept response body as well]
```

---

## Prerequisites

| Requirement | Check |
|---|---|
| OCP 4.20+ | `oc version` |
| OSSM 3 Operator (Sail Operator) | `oc get csv -n openshift-operators \| grep servicemeshoperator3` |
| TrustyAI Operator | `oc get crd nemoguardrails.trustyai.opendatahub.io` |
| `oc` CLI, `cluster-admin` role | `oc whoami` |

> **Not required**: `istioctl`, Docker, Wasm build toolchain (Lua needs none of these).

---

## Quick start

```bash
# Clone
git clone https://github.com/williamcaban/istio-guardrails
cd istio-guardrails

# Full install (~8 min)
./scripts/00-prereqs.sh          # deploy OSSM control plane + label namespaces
./scripts/01-deploy-nemo.sh      # deploy NeMo + validate endpoint
./scripts/02-get-cluster-name.sh # retrieve Envoy cluster name
./scripts/03-deploy-phase1.sh    # deploy TrafficExtension + run tests
```

---

## Manifests

```
deploy/
├── ossm/
│   ├── 00-istio.yaml                      # Istio CR (v1.30.3, discoverySelectors)
│   ├── 01-istiocni.yaml                   # IstioCNI CR
│   ├── phase1-lua/
│   │   └── traffic-extension-lua.yaml     # TrafficExtension — Lua input guardrail ✅ ACTIVE
│   └── phase2-wasm/
│       └── traffic-extension-wasm.yaml    # TrafficExtension — Wasm full duplex (Phase 2)
├── nemo/
│   ├── 00-namespace.yaml                  # guardrails namespace
│   ├── 01-configmap-pii.yaml              # NeMo PII + regex rails config
│   ├── 02-nemoguardrails-cr.yaml          # NemoGuardrails CR (TrustyAI Operator)
│   └── 03-authorizationpolicy.yaml        # Restricts NeMo to mesh-internal access
└── app-ns/
    ├── 00-namespace.yaml                  # app-ns namespace
    ├── mock-model.yaml                    # Python HTTP echo server (test target)
    └── test-app.yaml                      # curl probe pod
```

---

## Step-by-step deployment

### Step 1 — Deploy OSSM control plane

> **Critical**: create namespaces **before** applying the Istio CR.
> The Sail Operator returns `ReconcileError: namespace does not exist` if absent.

```bash
oc create namespace istio-system
oc create namespace istio-cni

oc apply -f deploy/ossm/00-istio.yaml
oc apply -f deploy/ossm/01-istiocni.yaml

oc wait --for=condition=Ready istios/default --timeout=5m
oc wait --for=condition=Ready IstioCNI/default --timeout=5m
```

### Step 2 — Create and label namespaces

The Istio CR uses `discoverySelectors` — every mesh namespace must have `istio-discovery=enabled`.
IstioRevision name is `default`, so use `istio-injection=enabled` for sidecar injection.

```bash
oc create namespace guardrails
oc create namespace app-ns

for ns in istio-system istio-cni guardrails app-ns; do
  oc label namespace $ns istio-discovery=enabled --overwrite
done

# Sidecar injection for app-ns only (NeMo in guardrails does NOT get a sidecar)
oc label namespace app-ns istio-injection=enabled --overwrite
```

> If IstioRevision name differs from `default` (check with `oc get istiorevisions`),
> use `istio.io/rev=<revision-name>` instead of `istio-injection=enabled`.

### Step 3 — Deploy NeMo Guardrails

```bash
oc apply -f deploy/nemo/01-configmap-pii.yaml
oc apply -f deploy/nemo/02-nemoguardrails-cr.yaml

oc wait nemoguardrails/nemo-pii -n guardrails \
  --for=jsonpath='{.status.phase}'=Ready --timeout=5m

oc apply -f deploy/nemo/03-authorizationpolicy.yaml
```

### Step 4 — Validate NeMo endpoint

```bash
# Service port is 80 (→ container port 8000)
oc -n guardrails port-forward svc/nemo-pii 18000:80 &

# Clean — expect {"status":"success",...}
curl -s http://localhost:18000/v1/guardrail/checks \
  -H "Content-Type: application/json" \
  -d '{"model":"","messages":[{"role":"user","content":"What is Kubernetes?"}]}'

# PII — expect {"status":"blocked",...}
curl -s http://localhost:18000/v1/guardrail/checks \
  -H "Content-Type: application/json" \
  -d '{"model":"","messages":[{"role":"user","content":"Contact john@example.com"}]}'

kill %1
```

### Step 5 — Get Envoy cluster name

The Lua filter needs the exact Envoy cluster name. It uses the **service port (80)**, not the container port (8000).

```bash
oc apply -f deploy/app-ns/mock-model.yaml
MOCK_POD=$(oc get pod -n app-ns -l app=mock-model -o jsonpath='{.items[0].metadata.name}')

oc exec -n app-ns "$MOCK_POD" -c istio-proxy -- \
  pilot-agent request GET /clusters | grep nemo-pii | head -1
# Confirmed: outbound|80||nemo-pii.guardrails.svc.cluster.local
```

### Step 6 — Deploy TrafficExtension

```bash
oc apply -f deploy/ossm/phase1-lua/traffic-extension-lua.yaml
sleep 6  # allow xDS push

# Verify Lua filter is programmed
oc exec -n app-ns "$MOCK_POD" -c istio-proxy -- \
  pilot-agent request GET /config_dump | grep -c "envoy.filters.http.lua"
# Expected: 2
```

### Step 7 — Test

```bash
oc apply -f deploy/app-ns/test-app.yaml
PROBE=$(oc get pod -n app-ns -l app=test-app -o jsonpath='{.items[0].metadata.name}')

# Clean — expect 200
oc exec -n app-ns "$PROBE" -- curl -s -w "\nHTTP:%{http_code}" \
  -X POST http://mock-model.app-ns.svc.cluster.local:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3-8b","messages":[{"role":"user","content":"Explain Kubernetes"}]}'

# PII — expect 403
oc exec -n app-ns "$PROBE" -- curl -s -w "\nHTTP:%{http_code}" \
  -X POST http://mock-model.app-ns.svc.cluster.local:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3-8b","messages":[{"role":"user","content":"My email is test@example.com"}]}'
```

---

## Configuration reference

### NeMo config.yaml (key requirements)

```yaml
models: []                  # prevents LLM calls on clean requests — required
rails:
  config:
    sensitive_data_detection:
      input:
        entities: [EMAIL_ADDRESS, PHONE_NUMBER, US_SSN, CREDIT_CARD, PERSON]
    regex_detection:
      input:
        patterns: ["\\b(password|secret|api[_-]?key|token)\\b"]
        case_insensitive: true
  input:
    flows:
      - detect sensitive data on input
      - regex check input
  output:
    flows: []               # disables output rail processing — required
```

### NemoGuardrails CR (key fields)

```yaml
spec:
  nemoConfigs:
  - name: pii               # config DIRECTORY name — NOT the ConfigMap name
    configMaps:
    - nemo-pii-config
    default: true
  env:
  - name: OPENAI_API_KEY
    value: not-used         # required env var; models: [] prevents actual LLM calls
```

### TrafficExtension (key values)

```yaml
spec:
  selector:
    matchLabels:
      guardrails.trustyai.io/config: pii   # matches pod template labels only
  phase: AUTHZ
  lua:
    inlineCode: |
      local NEMO_CLUSTER = "outbound|80||nemo-pii.guardrails.svc.cluster.local"
      local TIMEOUT_MS   = 3000            # minimum 1500ms; NeMo cold-start ~1.2s
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `ReconcileError: namespace does not exist` | Applied Istio CR before creating `istio-system` | Create namespace first, then apply CR |
| 504 on clean requests | NeMo trying LLM generation | Add `models: []` + `output.flows: []` to config.yaml; restart NeMo |
| 503 on clean (allowed) requests | Target server not proper HTTP/1.1 | Use Python HTTPServer or nginx, not `nc -l` |
| TrafficExtension has no effect | Wrong istiod revision watching the namespace | Verify `istio-injection=enabled` or `istio.io/rev=default` on namespace |
| Wrong Envoy cluster name | Using container port 8000 instead of service port 80 | Verify with `pilot-agent request GET /clusters \| grep nemo-pii` |
| `503` — RHOAI istiod ignores CR | `openshift-gateway` istiod has `X_PILOT_IGNORE_RESOURCES=*.istio.io` | Use `default` revision (1.30.3), not RHOAI AI Gateway revision |

---

## Teardown

```bash
oc delete trafficextension nemo-input-guard -n app-ns
oc delete -f deploy/app-ns/ --ignore-not-found
oc delete -f deploy/nemo/ --ignore-not-found
oc delete -f deploy/ossm/01-istiocni.yaml --ignore-not-found
oc delete -f deploy/ossm/00-istio.yaml --ignore-not-found
oc delete namespace guardrails app-ns istio-system istio-cni --ignore-not-found
```

---

## Key implementation notes

| Item | Confirmed value |
|---|---|
| OSSM version | 3.4.1 (Sail Operator / `servicemeshoperator3`) |
| Istio version | 1.30.3 |
| IstioRevision name | `default` |
| Sidecar injection label | `istio-injection=enabled` |
| NeMo service port | **80** (ClusterIP → targetPort 8000) |
| Envoy cluster name | `outbound|80||nemo-pii.guardrails.svc.cluster.local` |
| Lua timeout | **3000ms** (NeMo cold-start ~1.2s) |
| TrafficExtension phase | **AUTHZ** |
| TrafficExtension status | Tech preview in OSSM 3.4.1 |
| Fail mode | Closed — any NeMo error returns 403 |

---

## Phase 2 — Wasm full-duplex guardrail

Phase 2 adds response interception via a Wasm module (`wasm/main.go`).
The `TrafficExtension` switches from `lua:` to `wasm:` block.
See `deploy/ossm/phase2-wasm/traffic-extension-wasm.yaml` and `wasm/` for build instructions.

## Ambient mode (future)

Requires `routingViaHost: true` in OVN-Kubernetes (currently `false` on this cluster).
Once enabled, ZTunnel + Waypoint proxies handle L4/L7 without per-pod sidecar injection.
