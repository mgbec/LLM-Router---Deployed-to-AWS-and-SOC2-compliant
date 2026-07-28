# =============================================================================
# Test Async Processing (Windows PowerShell)
# Submits a complex prompt, polls for result, displays output
# =============================================================================

param(
    [string]$Prompt = "Write a comprehensive comparison of event-driven architecture versus request-response architecture. Cover scalability, debugging complexity, consistency guarantees, and provide code examples for each pattern."
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir

# --- Setup ---
Push-Location "$ProjectRoot\terraform"
$ApiEndpoint = terraform output -raw api_endpoint 2>$null
Pop-Location

if (-not $ApiEndpoint) {
    Write-Host "[ERROR] Could not get API endpoint." -ForegroundColor Red
    exit 1
}

if (-not $env:LLM_ROUTER_TOKEN) {
    Write-Host "[ERROR] No `$env:LLM_ROUTER_TOKEN set. Run get-token.ps1 first." -ForegroundColor Red
    exit 1
}

$Token = $env:LLM_ROUTER_TOKEN
$Headers = @{ Authorization = "Bearer $Token"; "Content-Type" = "application/json" }

Write-Host "========================================="
Write-Host "  Async Request Test"
Write-Host "========================================="
Write-Host ""
Write-Host "Prompt: $($Prompt.Substring(0, [Math]::Min(100, $Prompt.Length)))..."
Write-Host ""

# --- Submit ---
Write-Host "[1/3] Submitting async request..."

$Body = @{
    messages = @(@{ role = "user"; content = $Prompt })
    routing  = @{ async = $true }
} | ConvertTo-Json -Depth 5

$Response = Invoke-RestMethod -Uri "$ApiEndpoint/v1/chat/completions" -Method POST -Headers $Headers -Body $Body

if ($Response.status -ne "pending" -or -not $Response.request_id) {
    Write-Host "[ERROR] Expected 202 pending response" -ForegroundColor Red
    $Response | ConvertTo-Json -Depth 5
    exit 1
}

$RequestId = $Response.request_id
Write-Host "  [OK] Accepted (request_id: $RequestId)" -ForegroundColor Green
Write-Host ""

# --- Poll ---
Write-Host "[2/3] Polling for result..."

$StartTime = Get-Date
$MaxWait = 180  # 3 minutes

while ($true) {
    $Elapsed = ((Get-Date) - $StartTime).TotalSeconds

    if ($Elapsed -gt $MaxWait) {
        Write-Host ""
        Write-Host "  [TIMEOUT] Timed out after ${MaxWait}s" -ForegroundColor Yellow
        Write-Host "  Continue manually:"
        Write-Host "  Invoke-RestMethod -Uri '$ApiEndpoint/v1/requests/$RequestId' -Headers @{Authorization='Bearer `$env:LLM_ROUTER_TOKEN'}"
        exit 1
    }

    Start-Sleep -Seconds 5
    
    try {
        $PollResponse = Invoke-RestMethod -Uri "$ApiEndpoint/v1/requests/$RequestId" -Method GET -Headers @{ Authorization = "Bearer $Token" }
    }
    catch {
        Write-Host "  Poll error: $($_.Exception.Message)" -ForegroundColor Yellow
        continue
    }

    $PollStatus = $PollResponse.status

    if ($PollStatus -eq "completed") {
        $ElapsedRounded = [Math]::Round($Elapsed)
        Write-Host "  [OK] Completed after ${ElapsedRounded}s" -ForegroundColor Green
        Write-Host ""
        break
    }
    elseif ($PollStatus -eq "failed") {
        Write-Host "  [FAILED] after $([Math]::Round($Elapsed))s" -ForegroundColor Red
        Write-Host "  Error: $($PollResponse.error)" -ForegroundColor Red
        exit 1
    }
    else {
        Write-Host "  ...processing ($([Math]::Round($Elapsed))s)" -NoNewline
        Write-Host "`r" -NoNewline
    }
}

# --- Display ---
Write-Host "[3/3] Result:"
Write-Host "========================================="
Write-Host ""

$Content = $PollResponse.choices[0].message.content
$Model = $PollResponse.routing.model_selected
$Complexity = $PollResponse.routing.complexity
$Latency = $PollResponse.routing.latency_ms

Write-Host "Model: $Model" -ForegroundColor Cyan
Write-Host "Complexity: $Complexity" -ForegroundColor Cyan
Write-Host "Latency: ${Latency}ms" -ForegroundColor Cyan
Write-Host ""
Write-Host $Content
Write-Host ""
Write-Host "========================================="
