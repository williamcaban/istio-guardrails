REGISTRY  ?= image-registry.openshift-image-registry.svc:5000
NAMESPACE ?= app-ns
IMAGE     ?= nemo-wasm-guard
TAG       ?= latest
FULL_IMG  := $(REGISTRY)/$(NAMESPACE)/$(IMAGE):$(TAG)
WASM_BIN  := plugin.wasm

.PHONY: build build-local push clean

## build-oc: Build and push to internal OpenShift registry via oc new-build
build-oc:
	oc start-build nemo-wasm-guard --from-dir=. --follow -n $(NAMESPACE)
	@echo ""
	@echo "Image pushed to: $(FULL_IMG)"
	@echo "Use in WasmPlugin: oci://$(FULL_IMG)"

## build-local: Build Wasm locally (requires Go 1.24+ on host)
build-local:
	GOOS=wasip1 GOARCH=wasm go build -buildmode=c-shared -o $(WASM_BIN) ./...
	@echo "Built: $(WASM_BIN)"

## clean: Remove local build artifacts
clean:
	rm -f $(WASM_BIN)
