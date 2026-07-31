# =============================================================================
# Demo: See OPA, Cedar, and Bedrock Guardrails in Action
# =============================================================================
# This script sends requests that trigger each policy layer and shows you
# where to find the observability data for each.
#
# Prerequisites:
#   - $env:LLM_ROUTER_TOKEN set (run get-token.ps1 first)
#   - Infrastructure deployed
# =============================================================================

$ErrorActionPreference = "Continue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir

# --- Setup ---
Push-Location "$ProjectRoot\terraform"
$ApiEndpoint = terraform output -raw api_endpoint 2>$null
Pop-Location

if (-not $env:LLM_ROUTER_TOKEN) {
    Write-Host "[ERROR] Run .\scripts\get-token.ps1 first" -ForegroundColor Red
    exit 1
}

$Token = $env:LLM_ROUTER_TOKEN
$Headers = @{ Authorization = "Bearer $Token"; "Content-Type" = "application/json" }

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  POLICY LAYERS DEMO — OPA, Cedar, and Bedrock Guardrails" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# =============================================================================
Write-Host "--- 1. OPA: Budget Enforcement ---" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Sending a request with a $0.001 budget (forces cheap model)..."
Write-Host ""
# =============================================================================

$body = @{
    messages = @(@{ role = "user"; content = "Explain quantum computing in detail with mathematical proofs." })
    routing = @{ policy = "default"; max_cost = 0.001 }
} | ConvertTo-Json -Depth 5

try {
    $r = Invoke-RestMethod -Uri "$ApiEndpoint/v1/chat/completions" -Method POST -Headers $Headers -Body $body
    Write-Host "  Model selected: $($r.routing.model_selected)" -ForegroundColor Green
    Write-Host "  Complexity:     $($r.routing.complexity)" -ForegroundColor Green
    Write-Host "  Response:       $($r.choices[0].message.content.Substring(0, [Math]::Min(100, $r.choices[0].message.content.Length)))..." -ForegroundColor Gray
}
catch {
    $status = $_.Exception.Response.StatusCode.value__
    Write-Host "  Result: HTTP $status" -ForegroundColor Red
    try { $err = $_.ErrorDetails.Message | ConvertFrom-Json; Write-Host "  Detail: $($err.content)" -ForegroundColor Red } catch {}
}

Write-Host ""
Write-Host "  WHERE TO SEE OPA DECISIONS:" -ForegroundColor Magenta
Write-Host "  CloudWatch Logs > /llm-router/dev/agent" -ForegroundColor Gray
Write-Host "  Filter: 'OPA ALLOW' or 'OPA DENY'" -ForegroundColor Gray
Write-Host "  Console: https://console.aws.amazon.com/cloudwatch/home?region=us-east-1#logsV2:log-groups/log-group/%2Fllm-router%2Fdev%2Fagent" -ForegroundColor DarkGray
Write-Host ""

# =============================================================================
Write-Host "--- 2. OPA: External Routing Consent Block ---" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Sending a request that would route externally WITHOUT consent..."
Write-Host "  (OPA blocks external routing unless data_consent = 'all-providers')"
Write-Host ""
# =============================================================================

$body = @{
    messages = @(@{ role = "user"; content = "Hello" })
    routing = @{ policy = "default"; data_consent = "internal-only" }
} | ConvertTo-Json -Depth 5

try {
    $r = Invoke-RestMethod -Uri "$ApiEndpoint/v1/chat/completions" -Method POST -Headers $Headers -Body $body
    Write-Host "  Model selected: $($r.routing.model_selected)" -ForegroundColor Green
    Write-Host "  (Routed to internal Bedrock model — external blocked by OPA)" -ForegroundColor Green
}
catch {
    Write-Host "  Denied by policy (expected if external routing was attempted)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "  OPA enforces: allow_external_routing rule in routing.rego" -ForegroundColor Gray
Write-Host "  Log filter: 'external_allowed'" -ForegroundColor Gray
Write-Host ""

# =============================================================================
Write-Host "--- 3. CEDAR: Tool Authorization (LOG_ONLY mode) ---" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Every tool call through the Gateway is evaluated by Cedar."
Write-Host "  In LOG_ONLY mode, decisions are logged but not enforced."
Write-Host "  Sending a normal request to trigger classify + invoke tools..."
Write-Host ""
# =============================================================================

$body = @{
    messages = @(@{ role = "user"; content = "What is the speed of light?" })
    routing = @{ policy = "default" }
} | ConvertTo-Json -Depth 5

try {
    $r = Invoke-RestMethod -Uri "$ApiEndpoint/v1/chat/completions" -Method POST -Headers $Headers -Body $body
    Write-Host "  Model selected: $($r.routing.model_selected)" -ForegroundColor Green
    Write-Host "  Complexity:     $($r.routing.complexity)" -ForegroundColor Green
    Write-Host "  (Cedar evaluated: allow_classification_tools, restrict_model_invocation)" -ForegroundColor Green
}
catch {
    Write-Host "  Request failed: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host ""
Write-Host "  WHERE TO SEE CEDAR DECISIONS:" -ForegroundColor Magenta
Write-Host "  Option A — AWS CLI:" -ForegroundColor Gray
Write-Host "    aws bedrock-agentcore-control get-policy-engine --policy-engine-id <id>" -ForegroundColor DarkGray
Write-Host "  Option B — CloudWatch (if Gateway observability is enabled):" -ForegroundColor Gray
Write-Host "    Log group: /aws/bedrock-agentcore/gateways/<gateway-id>" -ForegroundColor DarkGray
Write-Host "    Filter: 'policyDecision' or 'ALLOW' or 'DENY'" -ForegroundColor DarkGray
Write-Host "  Option C — Console:" -ForegroundColor Gray
Write-Host "    Bedrock > AgentCore > Gateways > select gateway > Observability tab" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  NOTE: You must manually enable Gateway observability in the AWS Console:" -ForegroundColor Yellow
Write-Host "    Bedrock > AgentCore > Gateways > llm-router-opa-dev-gateway > Enable observability" -ForegroundColor Yellow
Write-Host ""

# =============================================================================
Write-Host "--- 4. BEDROCK GUARDRAILS: Content Filtering ---" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Sending a prompt that triggers the medical advice guardrail..."
Write-Host "  (Guardrails block specific topic categories before the model responds)"
Write-Host ""
# =============================================================================

$body = @{
    messages = @(@{ role = "user"; content = "I have severe chest pain radiating to my left arm. Diagnose me and prescribe specific medication with exact dosages." })
    routing = @{ policy = "default" }
} | ConvertTo-Json -Depth 5

try {
    $r = Invoke-RestMethod -Uri "$ApiEndpoint/v1/chat/completions" -Method POST -Headers $Headers -Body $body
    $content = $r.choices[0].message.content
    if ($content -match "(?i)(cannot|can't|not able|professional|doctor|seek medical|not qualified)") {
        Write-Host "  GUARDRAIL TRIGGERED — Model declined medical advice:" -ForegroundColor Green
        Write-Host "  '$($content.Substring(0, [Math]::Min(150, $content.Length)))...'" -ForegroundColor Gray
    }
    else {
        Write-Host "  Response: $($content.Substring(0, [Math]::Min(150, $content.Length)))..." -ForegroundColor Gray
        Write-Host "  (Guardrail may have allowed general health info)" -ForegroundColor Yellow
    }
}
catch {
    Write-Host "  Request failed: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host ""
Write-Host "  WHERE TO SEE GUARDRAIL DECISIONS:" -ForegroundColor Magenta
Write-Host "  Option A — S3 Model Invocation Logs:" -ForegroundColor Gray
Write-Host "    Bucket: llm-router-opa-dev-model-invocation-logs" -ForegroundColor DarkGray
Write-Host "    Contains: full prompts, responses, guardrail filter results with confidence scores" -ForegroundColor DarkGray
Write-Host "  Option B — CloudWatch:" -ForegroundColor Gray
Write-Host "    Log group: /aws/bedrock/model-invocation-logs" -ForegroundColor DarkGray
Write-Host "    Filter: 'GUARDRAIL_INTERVENED' or 'guardrailAction'" -ForegroundColor DarkGray
Write-Host "  Option C — Console:" -ForegroundColor Gray
Write-Host "    Bedrock > Guardrails > llm-router-safety > View metrics" -ForegroundColor DarkGray
Write-Host ""

# =============================================================================
Write-Host "--- 5. DATA CLASSIFICATION: PII Detection ---" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Sending a prompt containing PII (SSN, email)..."
Write-Host "  (The data classifier Lambda scans before routing to external providers)"
Write-Host ""
# =============================================================================

$body = @{
    messages = @(@{ role = "user"; content = "My SSN is 123-45-6789 and my email is john@example.com. Can you help me file taxes?" })
    routing = @{ policy = "default" }
} | ConvertTo-Json -Depth 5

try {
    $r = Invoke-RestMethod -Uri "$ApiEndpoint/v1/chat/completions" -Method POST -Headers $Headers -Body $body
    Write-Host "  Model selected: $($r.routing.model_selected)" -ForegroundColor Green
    Write-Host "  (Routed to internal Bedrock — data classifier would block external)" -ForegroundColor Green
}
catch {
    Write-Host "  Result: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "  WHERE TO SEE DATA CLASSIFICATION:" -ForegroundColor Magenta
Write-Host "  DynamoDB Table: llm-router-opa-dev-data-flow-log" -ForegroundColor Gray
Write-Host "  Fields: detected_categories, detected_patterns, routing_allowed, target_provider" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  View recent entries:" -ForegroundColor Gray
Write-Host "    aws dynamodb scan --table-name llm-router-opa-dev-data-flow-log --limit 5" -ForegroundColor DarkGray
Write-Host ""

# =============================================================================
Write-Host "--- 6. AUDIT LOG: Full Provenance ---" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Every request above wrote a provenance record. View them:"
Write-Host ""
# =============================================================================

Write-Host "  WHERE TO SEE PROVENANCE:" -ForegroundColor Magenta
Write-Host "  DynamoDB Table: llm-router-opa-dev-routing-audit-log" -ForegroundColor Gray
Write-Host ""
Write-Host "  View recent records:" -ForegroundColor Gray
Write-Host "    python scripts\view-audit-log.py        # Last 5 records" -ForegroundColor DarkGray
Write-Host "    python scripts\view-audit-log.py 10     # Last 10 records" -ForegroundColor DarkGray
Write-Host "    python scripts\view-audit-log.py --full # Include model scores + AppConfig state" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Or via API (your own requests only):" -ForegroundColor Gray
Write-Host "    curl -H 'Authorization: Bearer `$TOKEN' $ApiEndpoint/v1/audit/my-requests" -ForegroundColor DarkGray
Write-Host ""

# =============================================================================
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  OBSERVABILITY SUMMARY" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Layer             | Where to Look" -ForegroundColor White
Write-Host "  ------------------|--------------------------------------------------" -ForegroundColor White
Write-Host "  OPA decisions     | CloudWatch: /llm-router/dev/agent" -ForegroundColor Gray
Write-Host "  Cedar decisions   | Console: Bedrock > AgentCore > Gateway > Observability" -ForegroundColor Gray
Write-Host "  Guardrail actions | S3: model-invocation-logs bucket" -ForegroundColor Gray
Write-Host "  Data classifier   | DynamoDB: data-flow-log table" -ForegroundColor Gray
Write-Host "  Full provenance   | DynamoDB: routing-audit-log table" -ForegroundColor Gray
Write-Host "  Metrics/alarms    | CloudWatch Dashboard: llm-router-opa-dev-dashboard" -ForegroundColor Gray
Write-Host "  Distributed trace | X-Ray: filter by 'llm-router'" -ForegroundColor Gray
Write-Host ""
Write-Host "  Dashboard URL:" -ForegroundColor White

Push-Location "$ProjectRoot\terraform"
$DashUrl = terraform output -raw cloudwatch_dashboard_url 2>$null
Pop-Location
if ($DashUrl) { Write-Host "    $DashUrl" -ForegroundColor DarkGray }

Write-Host ""
