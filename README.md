# Istio WasmPlugin × NeMo Guardrails POC

Pod-label-driven AI safety guardrails using OpenShift Service Mesh (OSSM) and Red Hat OpenShift AI (RHOAI) NeMo Guardrails. A single label on an application pod activates transparent guardrail enforcement — no application code changes required.

```bash
# This single label activates guardrails on any AI workload
kubectl patch deployment my-ai-app -n app-ns \
  --type=merge \
  -p '{"spec":{"template":{"metadata":{"labels":{"guardrails.trustyai.io/config":"pii"}}}}}'
```

After labeling, PII in requests is blocked with HTTP 403. Clean requests pass through unchanged.

---

## Validated environment

| Component | Version |
|---|---|
| OpenShift Container Platform | 4.21.17 |
| Red Hat OpenShift Service Mesh | 3.3.1 (Istio 1.28.5) |
| Red Hat OpenShift AI | 3.4.2 |
| TrustyAI Operator | v1.37.0 |
| Wasm SDK | proxy-wasm/proxy-wasm-go-sdk (Go 1.24, GOOS=wasip1) |

**Extension API used**: `WasmPlugin` (`extensions.istio.io/v1alpha1`).  
`TrafficExtension` is not available in Istio 1.28 — it requires 1.30+. WasmPlugin is the equivalent stable API.

---

## Prerequisites

Before running, verify:

```bash
# OSSM operator installed
oc get csv -n openshift-operators | grep servicemeshoperator3

# TrustyAI operator running (provides NemoGuardrails CRD)
oc get pods -n redhat-ods-applications | grep trustyai

# NemoGuardrails CRD present
oc get crd nemoguardrails.trustyai.opendatahub.io

# WasmPlugin CRD present
oc get crd wasmplugins.extensions.istio.io

# oc and istioctl on PATH
oc version --short && istioctl version
```

---

## Setup

### Step 1 — Enable the internal image registry

The Wasm plugin is built and served from the OpenShift internal registry. Enable it if not already active:

```bash
oc get configs.imageregistry.operator.openshift.io/cluster \
  -o jsonpath='{.spec.managementState}'
# If output is "Removed", enable it:
oc patch configs.imageregistry.operator.openshift.io/cluster \
  --type merge \
  -p '{"spec":{"managementState":"Managed","storage":{"emptyDir":{}}}}'

oc rollout status deployment/image-registry \
  -n openshift-image-registry --timeout=180s
```

> **Note**: `emptyDir` storage is suitable for a single-node cluster or POC. For production, use PVC or object storage.

### Step 2 — Deploy the OSSM service mesh

This creates a new Istio service mesh instance in `istio-system`, separate from any existing gateway configuration.

```bash
# Create namespaces
oc create namespace istio-system
oc create namespace istio-cni

# Deploy Istio CNI (enables sidecar injection without hostNetwork)
cat <<EOF | oc apply -f -
apiVersion: sailoperator.io/v1
kind: IstioCNI
metadata:
  name: default
spec:
  namespace: istio-cni
EOF

# Deploy Istio control plane scoped to POC namespaces only
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

# Wait for healthy
oc wait istio/default --for=jsonpath='{.status.state}'=Healthy --timeout=180s
```

### Step 3 — Create and label namespaces

```bash
# NeMo namespace — mesh-visible, no sidecar injection needed
oc create namespace guardrails
oc label namespace guardrails istio-discovery=enabled

# App namespace — mesh-visible + sidecar injection
oc create namespace app-ns
oc label namespace app-ns istio-discovery=enabled istio-injection=enabled
# If your Istio revision name is NOT "default":
#   oc label namespace app-ns istio-discovery=enabled istio.io/rev=<revision>
```

> Verify your revision name with: `oc get istiorevisions`

### Step 4 — Deploy NeMo Guardrails

```bash
# Apply all NeMo manifests (namespace, ConfigMap, CR, AuthorizationPolicy)
oc apply -f deploy/nemo/
```

Wait for NeMo to be ready:

```bash
oc wait nemoguardrails/nemo-pii -n guardrails \
  --for=jsonpath='{.status.phase}'=Ready --timeout=300s
```

Validate the endpoint:

```bash
oc -n guardrails port-forward svc/nemo-pii 8080:80 &

# Should return "success"
curl -s http://localhost:8080/v1/guardrail/checks \
  -H "Content-Type: application/json" \
  -d '{"model":"","messages":[{"role":"user","content":"What is Kubernetes?"}]}' | jq .status

# Should return "blocked"
curl -s http://localhost:8080/v1/guardrail/checks \
  -H "Content-Type: application/json" \
  -d '{"model":"","messages":[{"role":"user","content":"My SSN is 123-45-6789"}]}' | jq .status

kill %1
```

### Step 5 — Build the Wasm plugin

The Wasm plugin is built entirely inside OpenShift using a Fedora-based Go build. No local toolchain required.

```bash
# Create the BuildConfig (only needed once)
oc new-build \
  --strategy=docker \
  --binary \
  --name=nemo-wasm-guard \
  -n app-ns

# Patch to use the HTTP server Dockerfile
oc patch bc nemo-wasm-guard -n app-ns \
  --type=merge \
  -p '{"spec":{"strategy":{"dockerStrategy":{"dockerfilePath":"Dockerfile.httpserver"}}}}'

# Build and push (runs in the cluster, takes ~4 min on first run)
cd wasm/
oc start-build nemo-wasm-guard --from-dir=. --follow -n app-ns
cd ..
```

The build produces an image that serves `plugin.wasm` via HTTP on port 8080 (Python `http.server`). This avoids the OCI TLS issue with the internal registry — Envoy fetches the Wasm binary over plain HTTP.

> **Why not `oci://`?** The Envoy sidecar cannot verify the internal registry's self-signed certificate. `ISTIO_META_INSECURE_REGISTRIES` does not bypass TLS verification in Istio 1.28.5. Serving via HTTP sidesteps this entirely.

### Step 6 — Deploy the Wasm server

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
        sidecar.istio.io/inject: "false"
    spec:
      containers:
      - name: wasm-server
        image: image-registry.openshift-image-registry.svc:5000/app-ns/nemo-wasm-guard:latest
        ports:
        - containerPort: 8080
        resources:
          requests:
            cpu: 10m
            memory: 32Mi
          limits:
            cpu: 100m
            memory: 64Mi
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

### Step 7 — Get the Envoy cluster name for NeMo

The WasmPlugin must reference the exact Envoy-internal cluster name for NeMo. First deploy a pod with a sidecar:

```bash
oc apply -f deploy/app-ns/test-app.yaml
oc rollout status deployment/test-app -n app-ns --timeout=60s

oc exec -n app-ns deploy/test-app -c istio-proxy -- \
  pilot-agent request GET /clusters 2>/dev/null | grep nemo-pii | head -1 | cut -d: -f1
# Expected: outbound|80||nemo-pii.guardrails.svc.cluster.local
```

> **Note**: The NeMo service exposes port **80** (mapped to container port 8000 by the TrustyAI operator). The Envoy cluster name uses the service port, so it is `outbound|80||...` not `outbound|8000||...`.

### Step 8 — Deploy the WasmPlugin

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

---

## Activating guardrails on an application

Add the label to the **pod template** of any deployment (not the deployment's own metadata):

```bash
kubectl patch deployment <your-app> -n app-ns \
  --type=merge \
  -p '{"spec":{"template":{"metadata":{"labels":{"guardrails.trustyai.io/config":"pii"}}}}}'
```

The WasmPlugin selector matches pod labels. Labels on the `Deployment` object itself are ignored by Istio.

The label change triggers a rolling restart. After the new pod is up, all outbound HTTP requests from it are checked by NeMo before reaching the model endpoint.

---

## Testing

### Deploy the mock backend (httpbin)

```bash
oc apply -f deploy/app-ns/httpbin.yaml
oc rollout status deployment/httpbin -n app-ns --timeout=60s
```

> httpbin is deployed with `gunicorn -b 0.0.0.0:8080` to avoid OpenShift's restriction on binding ports below 1024.

### Test 1: PII in request — expect 403

```bash
oc exec -n app-ns deploy/test-app -- \
  curl -s -w "\nHTTP: %{http_code}\n" \
  -H "Content-Type: application/json" \
  -d '{"model":"llama3","messages":[{"role":"user","content":"My SSN is 123-45-6789"}]}' \
  http://httpbin.app-ns.svc:8080/post
# Expected: {"error":"blocked_by_guardrail",...}  HTTP: 403
```

### Test 2: Email address — expect 403

```bash
oc exec -n app-ns deploy/test-app -- \
  curl -s -w "\nHTTP: %{http_code}\n" \
  -H "Content-Type: application/json" \
  -d '{"model":"llama3","messages":[{"role":"user","content":"Send results to alice@example.com"}]}' \
  http://httpbin.app-ns.svc:8080/post
# Expected: HTTP: 403
```

### Test 3: API key keyword — expect 403

```bash
oc exec -n app-ns deploy/test-app -- \
  curl -s -w "\nHTTP: %{http_code}\n" \
  -H "Content-Type: application/json" \
  -d '{"model":"llama3","messages":[{"role":"user","content":"Here is my api_key: sk-abc123"}]}' \
  http://httpbin.app-ns.svc:8080/post
# Expected: HTTP: 403
```

### Test 4: Clean request — expect 200

```bash
oc exec -n app-ns deploy/test-app -- \
  curl -s -w "\nHTTP: %{http_code}\n" \
  -H "Content-Type: application/json" \
  -d '{"model":"llama3","messages":[{"role":"user","content":"Explain Kubernetes networking"}]}' \
  http://httpbin.app-ns.svc:8080/post
# Expected: HTTP: 200 (full httpbin echo response)
```

### Test 5: Unlabeled pod — expect 200 (no guardrail)

```bash
# httpbin deployment has no guardrails.trustyai.io/config label
# Its outbound traffic is NOT intercepted by the WasmPlugin
oc get pod -n app-ns -l app=httpbin \
  -o jsonpath='{.items[0].metadata.labels}' | grep -q guardrail \
  && echo "LABEL FOUND - unexpected" \
  || echo "No guardrail label on httpbin pod - correct"
```

### Verify NeMo is being called

```bash
oc exec -n app-ns deploy/test-app -c istio-proxy -- \
  pilot-agent request GET /clusters 2>/dev/null \
  | grep "nemo-pii.*rq_"
# rq_success should increment with each test run
```

---

## Label schema reference

| Label | Required | Values | Effect |
|---|---|---|---|
| `guardrails.trustyai.io/config` | Yes | `pii` (or other profile name) | Activates guardrail enforcement |
| `guardrails.trustyai.io/fail-mode` | No | `closed` (default) / `open` | What to do when NeMo is unreachable |
| `guardrails.trustyai.io/timeout-ms` | No | Milliseconds (default: `300`) | NeMo callout timeout |

Profile name maps to:
- `NemoGuardrails` CR: `nemo-<name>` in `guardrails` namespace
- `ConfigMap`: `nemo-<name>-config` in `guardrails` namespace
- Envoy cluster: `outbound|80||nemo-<name>.guardrails.svc.cluster.local`

---

## Adding a new guardrail profile

1. Create a ConfigMap with the NeMo rails configuration:

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: nemo-toxicity-config
  namespace: guardrails
data:
  config.yaml: |
    rails:
      input:
        flows:
          - self check input
      output:
        flows:
          - self check output
    models:
      - type: main
        engine: openai
        parameters:
          openai_api_base: "http://vllm-svc.model-ns.svc:8080/v1"
          model_name: "llama3"
  rails.co: |
    # Built-in self-check rails
EOF
```

2. Create the NemoGuardrails CR:

```bash
cat <<EOF | oc apply -f -
apiVersion: trustyai.opendatahub.io/v1alpha1
kind: NemoGuardrails
metadata:
  name: nemo-toxicity
  namespace: guardrails
spec:
  nemoConfigs:
    - name: nemo-toxicity-config
      configMaps:
        - nemo-toxicity-config
      default: true
  env:
    - name: OPENAI_API_KEY
      value: not-used
EOF
```

3. Update the WasmPlugin or create a new one for the new profile:

```bash
cat <<EOF | oc apply -f -
apiVersion: extensions.istio.io/v1alpha1
kind: WasmPlugin
metadata:
  name: nemo-toxicity-guard
  namespace: app-ns
spec:
  selector:
    matchLabels:
      guardrails.trustyai.io/config: toxicity
  phase: AUTHN
  priority: 10
  url: http://wasm-server.app-ns.svc:8080/plugin.wasm
  pluginConfig:
    nemoCluster: "outbound|80||nemo-toxicity.guardrails.svc.cluster.local"
    nemoHost: "nemo-toxicity.guardrails.svc.cluster.local"
    nemoPath: "/v1/guardrail/checks"
    timeoutMs: 500
    failMode: "closed"
EOF
```

4. Label the target deployment:

```bash
kubectl patch deployment my-app -n app-ns \
  --type=merge \
  -p '{"spec":{"template":{"metadata":{"labels":{"guardrails.trustyai.io/config":"toxicity"}}}}}'
```

---

## Troubleshooting

### Wasm plugin not blocking (HTTP 200 on PII input)

```bash
# 1. Check sidecar logs for Wasm load errors
oc logs -n app-ns deploy/<your-app> -c istio-proxy | grep -i wasm

# 2. Verify pod has the guardrail label in the pod (not just the deployment)
oc get pod -n app-ns -l app=<your-app> \
  -o jsonpath='{.items[0].metadata.labels}' | python3 -m json.tool | grep guardrail

# 3. Verify wasm-server is reachable (from a pod WITHOUT the guardrail label)
oc exec -n app-ns deploy/wasm-server -- \
  curl -sI http://localhost:8080/plugin.wasm | head -3
# Expected: HTTP/1.0 200 OK, Content-type: application/wasm

# 4. Verify NeMo is being called
oc exec -n app-ns deploy/<your-app> -c istio-proxy -- \
  pilot-agent request GET /clusters | grep "nemo.*rq_total"
```

### All requests return 403 including clean ones

The Wasm plugin is loaded but NeMo is unreachable or timing out:

```bash
# Check NeMo pod is running
oc get pods -n guardrails

# Check NeMo timeout stats
oc exec -n app-ns deploy/<your-app> -c istio-proxy -- \
  pilot-agent request GET /clusters | grep "nemo.*rq_timeout"

# If timeouts: increase timeoutMs in WasmPlugin pluginConfig
oc patch wasmplugin nemo-input-guard -n app-ns --type=merge \
  -p '{"spec":{"pluginConfig":{"timeoutMs":1000}}}'
```

### Namespace not picked up by OSSM

```bash
# Verify namespace has discovery label
oc get namespace <ns> -o jsonpath='{.metadata.labels}' | python3 -m json.tool | grep istio

# Check discovery selector in Istio CR
oc get istio default -o jsonpath='{.spec.values.meshConfig.discoverySelectors}'
```

### Pod has 1/1 containers (no sidecar injected)

```bash
# Verify injection label is on namespace
oc get namespace app-ns -o jsonpath='{.metadata.labels.istio-injection}'
# Should return: enabled

# Check IstioRevision name (if not "default", use istio.io/rev instead)
oc get istiorevisions
# NAME      ...  — if not "default", run:
# oc label namespace app-ns istio.io/rev=<name> --overwrite
# oc label namespace app-ns istio-injection- --overwrite  # remove the other label

# Restart pods to trigger sidecar injection
oc rollout restart deployment/<your-app> -n app-ns
```

---

## Removing the POC

### Remove guardrail from a specific application

```bash
# Remove the label — guardrail immediately stops applying after pod restart
kubectl patch deployment <your-app> -n app-ns \
  --type=json \
  -p='[{"op":"remove","path":"/spec/template/metadata/labels/guardrails.trustyai.io~1config"}]'
```

### Remove all POC resources

```bash
# WasmPlugin
oc delete wasmplugin nemo-input-guard -n app-ns

# Wasm server
oc delete deployment,service wasm-server -n app-ns
oc delete buildconfig,imagestream nemo-wasm-guard -n app-ns
oc delete buildconfig,imagestream wasm-server -n app-ns 2>/dev/null || true

# NeMo Guardrails
oc delete -f deploy/nemo/

# Test workloads
oc delete -f deploy/app-ns/

# OSSM service mesh (Istio + CNI)
oc delete istio default
oc delete istiocni default
oc delete namespace istio-system istio-cni guardrails app-ns

# If you enabled the internal registry for this POC and want to disable it
oc patch configs.imageregistry.operator.openshift.io/cluster \
  --type merge -p '{"spec":{"managementState":"Removed"}}'
```

> The Sail Operator (OSSM) and TrustyAI Operator remain installed — only the resources created for this POC are removed.

---

## Repository layout

```
.
├── README.md                         ← this file
├── docs/
│   ├── design.md                     ← architecture and design decisions
│   └── implementation-plan.md        ← step-by-step task tracker
├── deploy/
│   ├── nemo/                         ← NeMo Guardrails manifests (apply in order 00→03)
│   │   ├── 00-namespace.yaml
│   │   ├── 01-configmap-pii.yaml
│   │   ├── 02-nemoguardrails-cr.yaml
│   │   └── 03-authorizationpolicy.yaml
│   ├── ossm/
│   │   └── phase1-wasm/
│   │       └── wasmplugin.yaml       ← WasmPlugin (the active mechanism)
│   └── app-ns/
│       ├── 00-namespace.yaml
│       ├── httpbin.yaml              ← mock LLM backend (port 8080)
│       └── test-app.yaml             ← curl-based test client
└── wasm/
    ├── main.go                       ← Go Wasm plugin (proxy-wasm-go-sdk)
    ├── go.mod                        ← Go 1.24, proxy-wasm/proxy-wasm-go-sdk
    ├── Dockerfile                    ← Wasm binary only (FROM scratch)
    ├── Dockerfile.httpserver         ← Wasm + Python HTTP server (used for build)
    └── Makefile
```
