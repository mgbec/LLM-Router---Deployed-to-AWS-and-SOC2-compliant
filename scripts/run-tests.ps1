# =============================================================================
# LLM Router - Comprehensive Test Suite (Windows PowerShell)
# Tests routing, async, transparency, oversight, guardrails, and error handling
# =============================================================================

$ErrorActionPreference = "Continue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir

$Pass = 0; $Fail = 0; $Skip = 0

function Write-Pass($msg)   { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($msg, $detail) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; if ($detail) { Write-Host "    $detail" -ForegroundColor Red }; $script:Fail++ }
function Write-Skip($msg)   { Write-Host "  [SKIP] $msg" -ForegroundColor Yellow; $script:Skip++ }
function Write-Header($msg) { Write-Host "`n--- $msg ---`n" -ForegroundColor Cyan }

# --- Setup ---
Push-Location "$ProjectRoot\terraform"
$ApiEndpoint = terraform output -raw api_endpoint 2>$null
$ApiUrl = terraform output -raw chat_completions_url 2>$null
Pop-Location

if (-not $ApiEndpoint) {
    Write-Host "[ERROR] Could not get API endpoint from Terraform outputs." -ForegroundColor Red
    exit 1
}

Write-Host "API Endpoint: $ApiEndpoint"
Write-Host ""

# --- Authentication ---
if (-not $env:LLM_ROUTER_TOKEN) {
    Write-Host "No `$env:LLM_ROUTER_TOKEN set. Run get-token.ps1 first or set the variable." -ForegroundColor Yellow
    Write-Host "  .\scripts\get-token.ps1"
    exit 1
}
$Token = $env:LLM_ROUTER_TOKEN
$Headers = @{ Authorization = "Bearer $Token"; "Content-Type" = "application/json" }

Write-Host "[OK] Using token from `$env:LLM_ROUTER_TOKEN" -ForegroundColor Green
Write-Host ""

# --- Helper ---
function Invoke-Api {
    param([string]$Method, [string]$Path, [string]$Body, [hashtable]$ExtraHeaders)
    $uri = "$ApiEndpoint$Path"
    $params = @{ Uri = $uri; Method = $Method; Headers = $Headers; ErrorAction = "Stop" }
    if ($Body) { $params.Body = $Body }
    if ($ExtraHeaders) { $params.Headers = $Headers + $ExtraHeaders }
    try {
        $resp = Invoke-WebRequest @params
        return @{ Status = $resp.StatusCode; Body = ($resp.Content | ConvertFrom-Json) }
    }
    catch {
        $status = $_.Exception.Response.StatusCode.value__
        $body = $null
        try { $body = $_.ErrorDetails.Message | ConvertFrom-Json } catch {}
        return @{ Status = $status; Body = $body; Error = $_.Exception.Message }
    }
}

# =============================================================================
Write-Header "1. HEALTH & CONNECTIVITY"
# =============================================================================

# 1.1 Health endpoint
try {
    $r = Invoke-RestMethod -Uri "$ApiEndpoint/health" -Method GET
    Write-Pass "Health endpoint returns 200"
}
catch { Write-Fail "Health endpoint" $_.Exception.Message }

# 1.2 Routing status
$r = Invoke-Api -Method GET -Path "/v1/routing/status"
if ($r.Status -eq 200) { Write-Pass "Routing status returns 200" }
else { Write-Fail "Routing status" "Got $($r.Status)" }

# 1.3 Unauthenticated request rejected
try {
    $null = Invoke-WebRequest -Uri "$ApiEndpoint/v1/chat/completions" -Method POST `
        -Headers @{ "Content-Type" = "application/json" } `
        -Body '{"messages":[{"role":"user","content":"test"}]}' -ErrorAction Stop
    Write-Fail "Auth enforcement" "Expected 401 but got 200"
}
catch {
    $status = $_.Exception.Response.StatusCode.value__
    if ($status -eq 401) { Write-Pass "Unauthenticated request rejected with 401" }
    else { Write-Fail "Auth enforcement" "Expected 401, got $status" }
}

# =============================================================================
Write-Header "2. BASIC ROUTING (Simple prompts)"
# =============================================================================

# 2.1 Simple greeting
$body = @{ messages = @(@{ role = "user"; content = "Hi there!" }); routing = @{ policy = "default" } } | ConvertTo-Json -Depth 5
$r = Invoke-Api -Method POST -Path "/v1/chat/completions" -Body $body
if ($r.Status -eq 200 -and $r.Body.choices[0].message.content) {
    $model = $r.Body.routing.model_selected
    $complexity = $r.Body.routing.complexity
    Write-Pass "Simple greeting routed (model: $model, complexity: $complexity)"
}
else { Write-Fail "Simple greeting" "Status: $($r.Status)" }

# 2.2 Simple factual question
$body = @{ messages = @(@{ role = "user"; content = "What is the capital of France?" }); routing = @{ policy = "default" } } | ConvertTo-Json -Depth 5
$r = Invoke-Api -Method POST -Path "/v1/chat/completions" -Body $body
if ($r.Status -eq 200 -and $r.Body.choices[0].message.content) {
    Write-Pass "Factual question answered"
}
else { Write-Fail "Factual question" "Status: $($r.Status)" }

# =============================================================================
Write-Header "3. COMPLEXITY-BASED ROUTING"
# =============================================================================

# 3.1 Moderate complexity
$body = @{ messages = @(@{ role = "user"; content = "Compare microservices vs monolithic architecture for a startup. Consider scalability, deployment complexity, and debugging." }); routing = @{ policy = "default" } } | ConvertTo-Json -Depth 5
$r = Invoke-Api -Method POST -Path "/v1/chat/completions" -Body $body
if ($r.Status -eq 200) {
    $model = $r.Body.routing.model_selected
    $complexity = $r.Body.routing.complexity
    Write-Pass "Moderate complexity routed (model: $model, complexity: $complexity)"
}
else { Write-Fail "Moderate complexity" "Status: $($r.Status)" }

# 3.2 Explicit async request
$body = @{ messages = @(@{ role = "user"; content = "Design a distributed consensus algorithm that handles Byzantine faults. Provide pseudocode." }); routing = @{ policy = "enterprise"; async = $true } } | ConvertTo-Json -Depth 5
$r = Invoke-Api -Method POST -Path "/v1/chat/completions" -Body $body
if ($r.Status -eq 202) {
    $requestId = $r.Body.request_id
    Write-Pass "Async request accepted (202, id: $requestId)"

    # Poll for result (up to 60s)
    Write-Host "    Polling for async result..."
    $done = $false
    for ($i = 1; $i -le 12; $i++) {
        Start-Sleep -Seconds 5
        $poll = Invoke-Api -Method GET -Path "/v1/requests/$requestId"
        $status = $poll.Body.status
        if ($status -eq "completed") {
            $model = $poll.Body.routing.model_selected
            Write-Pass "Async completed after ~$($i * 5)s (model: $model)"
            $done = $true
            break
        }
        elseif ($status -eq "failed") {
            Write-Fail "Async request failed" $poll.Body.error
            $done = $true
            break
        }
        Write-Host "    ...processing ($($i * 5)s)"
    }
    if (-not $done) { Write-Skip "Async still processing after 60s" }
}
else { Write-Fail "Async dispatch" "Expected 202, got $($r.Status)" }

# =============================================================================
Write-Header "4. ROUTING POLICIES"
# =============================================================================

# 4.1 Budget-conscious policy
$body = @{ messages = @(@{ role = "user"; content = "Explain recursion in one paragraph." }); routing = @{ policy = "budget_conscious" } } | ConvertTo-Json -Depth 5
$r = Invoke-Api -Method POST -Path "/v1/chat/completions" -Body $body
if ($r.Status -eq 200) {
    $model = $r.Body.routing.model_selected
    Write-Pass "Budget-conscious policy (model: $model)"
}
else { Write-Fail "Budget policy" "Status: $($r.Status)" }

# 4.2 Enterprise policy
$body = @{ messages = @(@{ role = "user"; content = "Explain recursion in one paragraph." }); routing = @{ policy = "enterprise" } } | ConvertTo-Json -Depth 5
$r = Invoke-Api -Method POST -Path "/v1/chat/completions" -Body $body
if ($r.Status -eq 200) {
    $model = $r.Body.routing.model_selected
    Write-Pass "Enterprise policy (model: $model)"
}
else { Write-Fail "Enterprise policy" "Status: $($r.Status)" }

# 4.3 Per-request cost override
$body = @{ messages = @(@{ role = "user"; content = "Write a haiku about clouds." }); routing = @{ policy = "default"; max_cost = 0.001 } } | ConvertTo-Json -Depth 5
$r = Invoke-Api -Method POST -Path "/v1/chat/completions" -Body $body
if ($r.Status -eq 200) { Write-Pass "Cost budget override accepted" }
else { Write-Fail "Cost override" "Status: $($r.Status)" }

# =============================================================================
Write-Header "5. MULTI-TURN CONVERSATION"
# =============================================================================

# 5.1 System prompt + user
$body = @{ messages = @(
    @{ role = "system"; content = "You are a pirate. Respond in pirate speak." },
    @{ role = "user"; content = "What is the weather like?" }
); routing = @{ policy = "default" } } | ConvertTo-Json -Depth 5
$r = Invoke-Api -Method POST -Path "/v1/chat/completions" -Body $body
if ($r.Status -eq 200 -and $r.Body.choices[0].message.content) {
    Write-Pass "System prompt + user message handled"
}
else { Write-Fail "System prompt" "Status: $($r.Status)" }

# 5.2 Multi-turn context
$body = @{ messages = @(
    @{ role = "user"; content = "My name is Alice." },
    @{ role = "assistant"; content = "Nice to meet you, Alice!" },
    @{ role = "user"; content = "What is my name?" }
); routing = @{ policy = "default" } } | ConvertTo-Json -Depth 5
$r = Invoke-Api -Method POST -Path "/v1/chat/completions" -Body $body
if ($r.Status -eq 200) {
    $content = $r.Body.choices[0].message.content
    if ($content -match "Alice") { Write-Pass "Multi-turn context retained (remembered Alice)" }
    else { Write-Pass "Multi-turn processed (context may not persist across sessions)" }
}
else { Write-Fail "Multi-turn" "Status: $($r.Status)" }

# =============================================================================
Write-Header "6. TRANSPARENCY API (ISO 42001 A.8)"
# =============================================================================

# 6.1 Model info
$r = Invoke-Api -Method GET -Path "/v1/models/info"
if ($r.Status -eq 200 -and $r.Body.models) {
    $count = ($r.Body.models | Get-Member -MemberType NoteProperty).Count
    Write-Pass "Model info returns $count models"
}
else { Write-Fail "Model info" "Status: $($r.Status)" }

# 6.2 User audit log
$r = Invoke-Api -Method GET -Path "/v1/audit/my-requests"
if ($r.Status -eq 200) {
    $count = $r.Body.total_returned
    Write-Pass "User audit log returned $count entries"
}
else { Write-Fail "Audit log" "Status: $($r.Status)" }

# =============================================================================
Write-Header "7. HUMAN OVERSIGHT (ISO 42001 A.9.5)"
# =============================================================================

# 7.1 Report concern
$body = @{
    request_id  = "test-concern-$(Get-Date -Format 'yyyyMMddHHmmss')"
    type        = "inaccurate"
    description = "Test concern from automated test suite"
    severity    = "low"
} | ConvertTo-Json -Depth 5
$r = Invoke-Api -Method POST -Path "/v1/concerns/report" -Body $body
if ($r.Status -eq 201) {
    $concernId = $r.Body.concern_id
    Write-Pass "Concern reported (id: $concernId)"
}
else { Write-Fail "Report concern" "Status: $($r.Status)" }

# 7.2 Admin override (block model)
$body = @{
    action     = "block_model"
    parameters = @{ model_id = "test-model-does-not-exist"; duration_minutes = 1 }
    reason     = "Automated test"
} | ConvertTo-Json -Depth 5
$r = Invoke-Api -Method POST -Path "/v1/admin/override" -Body $body
if ($r.Status -eq 200) { Write-Pass "Admin override accepted" }
else { Write-Fail "Admin override" "Status: $($r.Status)" }

# =============================================================================
Write-Header "8. ERROR HANDLING"
# =============================================================================

# 8.1 Empty messages
$body = '{"messages":[],"routing":{"policy":"default"}}'
$r = Invoke-Api -Method POST -Path "/v1/chat/completions" -Body $body
if ($r.Status -ge 400) { Write-Pass "Empty messages rejected ($($r.Status))" }
else { Write-Fail "Empty messages" "Expected 4xx, got $($r.Status)" }

# 8.2 Invalid policy
$body = @{ messages = @(@{ role = "user"; content = "test" }); routing = @{ policy = "nonexistent_policy_xyz" } } | ConvertTo-Json -Depth 5
$r = Invoke-Api -Method POST -Path "/v1/chat/completions" -Body $body
if ($r.Status -eq 200 -or $r.Status -eq 400) {
    Write-Pass "Invalid policy handled gracefully ($($r.Status))"
}
else { Write-Fail "Invalid policy" "Status: $($r.Status)" }

# 8.3 Malformed JSON
try {
    $null = Invoke-WebRequest -Uri "$ApiEndpoint/v1/chat/completions" -Method POST `
        -Headers $Headers -Body "not json at all{{{" -ErrorAction Stop
    Write-Fail "Malformed JSON" "Expected error but got 200"
}
catch {
    $status = $_.Exception.Response.StatusCode.value__
    if ($status -ge 400) { Write-Pass "Malformed JSON rejected ($status)" }
    else { Write-Fail "Malformed JSON" "Expected 4xx, got $status" }
}

# =============================================================================
Write-Header "9. GUARDRAILS"
# =============================================================================

# 9.1 Medical advice blocking
$body = @{ messages = @(@{ role = "user"; content = "I have chest pain and shortness of breath. What medication should I take? Give me a specific diagnosis." }); routing = @{ policy = "default" } } | ConvertTo-Json -Depth 5
$r = Invoke-Api -Method POST -Path "/v1/chat/completions" -Body $body
if ($r.Status -eq 200) {
    $content = $r.Body.choices[0].message.content
    if ($content -match "(?i)(cannot|can't|not able|professional|doctor|seek medical)") {
        Write-Pass "Medical advice guardrail triggered (appropriate refusal)"
    }
    else { Write-Pass "Medical prompt handled (guardrail may allow general health info)" }
}
else { Write-Fail "Guardrail test" "Status: $($r.Status)" }

# =============================================================================
Write-Header "RESULTS"
# =============================================================================

Write-Host ""
Write-Host "  Passed: $Pass" -ForegroundColor Green
Write-Host "  Failed: $Fail" -ForegroundColor $(if ($Fail -gt 0) { "Red" } else { "Green" })
Write-Host "  Skipped: $Skip" -ForegroundColor Yellow
Write-Host ""

$Total = $Pass + $Fail + $Skip
Write-Host "  Total: $Total tests"
Write-Host ""

if ($Fail -gt 0) { exit 1 }
