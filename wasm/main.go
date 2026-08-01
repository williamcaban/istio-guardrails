// NeMo Guardrails Wasm plugin for Envoy.
// Built with: GOOS=wasip1 GOARCH=wasm go build -buildmode=c-shared -o plugin.wasm ./...
// SDK: github.com/proxy-wasm/proxy-wasm-go-sdk (requires Go 1.24+)
//
// Intercepts outbound LLM request bodies, calls NeMo /v1/guardrail/checks,
// blocks on "blocked" response (RHOAI 3.4.2 status values: "success" | "blocked").
// Fail-closed: any error reaching NeMo returns 403.
package main

import (
	"bytes"
	"encoding/json"

	"github.com/proxy-wasm/proxy-wasm-go-sdk/proxywasm"
	"github.com/proxy-wasm/proxy-wasm-go-sdk/proxywasm/types"
)

// pluginConfig is parsed from the WasmPlugin.spec.pluginConfig field.
type pluginConfig struct {
	NemoCluster string `json:"nemoCluster"`
	NemoHost    string `json:"nemoHost"`
	NemoPath    string `json:"nemoPath"`
	TimeoutMs   uint32 `json:"timeoutMs"`
	FailMode    string `json:"failMode"` // "closed" (default) | "open"
}

// Global config — loaded once at plugin start.
var cfg pluginConfig

func main() {}

func init() {
	proxywasm.SetVMContext(&vmContext{})
}

// --- VM context ---

type vmContext struct{}

func (*vmContext) OnVMStart(vmConfigSize int) types.OnVMStartStatus {
	return types.OnVMStartStatusOK
}

func (*vmContext) NewPluginContext(contextID uint32) types.PluginContext {
	return &pluginContext{}
}

// --- Plugin context (one per WasmPlugin instance) ---

type pluginContext struct {
	types.DefaultPluginContext
}

func (p *pluginContext) OnPluginStart(pluginConfigSize int) types.OnPluginStartStatus {
	raw, err := proxywasm.GetPluginConfiguration()
	if err != nil || len(raw) == 0 {
		// Safe defaults — must match whatever is in the WasmPlugin CR
		cfg = pluginConfig{
			NemoCluster: "outbound|80||nemo-pii.guardrails.svc.cluster.local",
			NemoHost:    "nemo-pii.guardrails.svc.cluster.local",
			NemoPath:    "/v1/guardrail/checks",
			TimeoutMs:   300,
			FailMode:    "closed",
		}
		proxywasm.LogWarn("nemo-guard: no plugin config found, using defaults")
		return types.OnPluginStartStatusOK
	}
	if err := json.Unmarshal(raw, &cfg); err != nil {
		proxywasm.LogErrorf("nemo-guard: invalid plugin config: %v", err)
		return types.OnPluginStartStatusFailed
	}
	if cfg.TimeoutMs == 0 {
		cfg.TimeoutMs = 300
	}
	if cfg.FailMode == "" {
		cfg.FailMode = "closed"
	}
	proxywasm.LogInfof("nemo-guard: config loaded — cluster=%s path=%s timeout=%dms failMode=%s",
		cfg.NemoCluster, cfg.NemoPath, cfg.TimeoutMs, cfg.FailMode)
	return types.OnPluginStartStatusOK
}

func (p *pluginContext) NewHttpContext(contextID uint32) types.HttpContext {
	return &httpContext{contextID: contextID}
}

// --- HTTP context (one per request/response pair) ---

type httpContext struct {
	types.DefaultHttpContext
	contextID uint32
}

// OnHttpRequestBody intercepts the outbound request body before it reaches the model.
func (ctx *httpContext) OnHttpRequestBody(bodySize int, endOfStream bool) types.Action {
	if !endOfStream {
		return types.ActionPause // buffer until full body received
	}
	body, err := proxywasm.GetHttpRequestBody(0, bodySize)
	if err != nil || len(body) == 0 {
		return types.ActionContinue
	}
	return ctx.checkWithNemo(body, true)
}

// OnHttpResponseBody intercepts the model response before it reaches the caller.
func (ctx *httpContext) OnHttpResponseBody(bodySize int, endOfStream bool) types.Action {
	if !endOfStream {
		return types.ActionPause
	}
	body, err := proxywasm.GetHttpResponseBody(0, bodySize)
	if err != nil || len(body) == 0 {
		return types.ActionContinue
	}
	// Wrap model output in NeMo check format with role: assistant
	checkPayload := []byte(`{"model":"","messages":[{"role":"assistant","content":` + jsonString(string(body)) + `}]}`)
	return ctx.checkWithNemo(checkPayload, false)
}

// checkWithNemo calls /v1/guardrail/checks and blocks on "blocked" status.
func (ctx *httpContext) checkWithNemo(body []byte, isRequest bool) types.Action {
	headers := [][2]string{
		{":method", "POST"},
		{":path", cfg.NemoPath},
		{":authority", cfg.NemoHost},
		{"content-type", "application/json"},
	}

	_, err := proxywasm.DispatchHttpCall(
		cfg.NemoCluster, headers, body, nil, cfg.TimeoutMs,
		func(numHeaders, bodySize, numTrailers int) {
			resp, err := proxywasm.GetHttpCallResponseBody(0, bodySize)
			if err != nil {
				proxywasm.LogWarnf("nemo-guard: failed to read NeMo response: %v", err)
				ctx.onError(isRequest)
				return
			}
			if bytes.Contains(resp, []byte(`"status":"blocked"`)) {
				proxywasm.LogInfo("nemo-guard: request blocked by guardrail")
				_ = proxywasm.SendHttpResponse(
					403,
					[][2]string{{"content-type", "application/json"}},
					[]byte(`{"error":"blocked_by_guardrail","message":"Content blocked by safety guardrails"}`),
					-1,
				)
				return
			}
			// "success" — allow through
			if isRequest {
				_ = proxywasm.ResumeHttpRequest()
			} else {
				_ = proxywasm.ResumeHttpResponse()
			}
		},
	)

	if err != nil {
		proxywasm.LogErrorf("nemo-guard: DispatchHttpCall failed: %v", err)
		return ctx.onError(isRequest)
	}
	return types.ActionPause
}

func (ctx *httpContext) onError(isRequest bool) types.Action {
	if cfg.FailMode == "open" {
		proxywasm.LogWarn("nemo-guard: NeMo unreachable, fail-open")
		return types.ActionContinue
	}
	_ = proxywasm.SendHttpResponse(
		403,
		[][2]string{{"content-type", "application/json"}},
		[]byte(`{"error":"guardrail_unavailable","message":"Guardrail service unreachable"}`),
		-1,
	)
	return types.ActionPause
}

// jsonString wraps s as a JSON string literal.
func jsonString(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}
