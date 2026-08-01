-- NeMo Guardrails input check via Envoy Lua filter
-- Used in TrafficExtension phase1-lua deployment.
--
-- BEFORE DEPLOYING: verify NEMO_CLUSTER matches your cluster.
-- Run: oc exec -n app-ns deploy/test-app -c istio-proxy -- \
--        pilot-agent request GET /clusters | grep nemo-pii
--
-- Endpoint: /v1/guardrail/checks (RHOAI 3.5)
-- Status values: "success" (allow) | "blocked" (deny)
-- Fail mode: closed — any error returns 403

local NEMO_CLUSTER = "outbound|8000||nemo-pii.guardrails.svc.cluster.local"
local NEMO_HOST    = "nemo-pii.guardrails.svc.cluster.local"
local NEMO_PATH    = "/v1/guardrail/checks"
local TIMEOUT_MS   = 300

function envoy_on_request(request_handle)
  local body = request_handle:body(true)
  if body == nil or body:length() == 0 then
    return
  end

  local ok, resp_headers, resp_body = pcall(function()
    return request_handle:httpCall(
      NEMO_CLUSTER,
      {
        [":method"]      = "POST",
        [":path"]        = NEMO_PATH,
        [":authority"]   = NEMO_HOST,
        ["content-type"] = "application/json",
      },
      body:getBytes(0, body:length()),
      TIMEOUT_MS
    )
  end)

  -- Fail-closed: any pcall error means NeMo unreachable or timed out
  if not ok then
    request_handle:respond(
      {[":status"] = "403", ["content-type"] = "application/json"},
      '{"error":"guardrail_unavailable","message":"Guardrail service unreachable"}'
    )
    return
  end

  local http_status = resp_headers[":status"]
  if http_status ~= "200" then
    request_handle:respond(
      {[":status"] = "403", ["content-type"] = "application/json"},
      string.format(
        '{"error":"guardrail_error","message":"NeMo returned HTTP %s"}',
        http_status
      )
    )
    return
  end

  -- RHOAI 3.5: status field is "success" (not "passed") or "blocked"
  if string.find(resp_body, '"status"%s*:%s*"blocked"') then
    request_handle:respond(
      {[":status"] = "403", ["content-type"] = "application/json"},
      '{"error":"blocked_by_guardrail","message":"Request blocked by safety guardrails"}'
    )
  end
  -- "success" → fall through, request forwarded to upstream
end

-- Response interception is handled in Phase 2 (Wasm module)
-- Lua response body buffering is limited to 10MB default — not suitable for LLM responses
