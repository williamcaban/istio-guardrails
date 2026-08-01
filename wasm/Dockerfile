# Multi-stage build: Fedora Go → Wasm binary → OCI artifact
# Uses standard Go with GOOS=wasip1 GOARCH=wasm (Go 1.21+)
#
# Build in OpenShift:
#   oc new-build --strategy=docker --binary --name=nemo-wasm-guard -n app-ns
#   oc start-build nemo-wasm-guard --from-dir=. --follow -n app-ns
#
# Reference in WasmPlugin:
#   url: oci://image-registry.openshift-image-registry.svc:5000/app-ns/nemo-wasm-guard:latest

FROM registry.fedoraproject.org/fedora-minimal:latest AS builder

# Install Go compiler and tools
RUN microdnf install -y golang && microdnf clean all

WORKDIR /app
COPY go.mod main.go ./

# Fetch dependencies
RUN go mod tidy

# Compile to WebAssembly (WASI reactor — required by Envoy proxy-wasm ABI)
# -buildmode=c-shared produces a WASI reactor module (not a command)
RUN GOOS=wasip1 GOARCH=wasm go build -buildmode=c-shared -o plugin.wasm ./...

# Minimal OCI image — Envoy extracts /plugin.wasm from the single layer
FROM scratch
COPY --from=builder /app/plugin.wasm /plugin.wasm
