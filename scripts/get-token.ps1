# =============================================================================
# Get a Cognito access token and test the LLM Router API (Windows)
# =============================================================================

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir

# Get Terraform outputs
Push-Location "$ProjectRoot\terraform"
try {
    $ClientId = terraform output -raw cognito_web_client_id 2>$null
    $UserPoolId = terraform output -raw cognito_user_pool_id 2>$null
    $ApiUrl = terraform output -raw chat_completions_url 2>$null
    $ApiEndpoint = terraform output -raw api_endpoint 2>$null
}
finally {
    Pop-Location
}

$Region = "us-east-1"

if (-not $ClientId -or -not $UserPoolId) {
    Write-Host "[ERROR] Could not get Terraform outputs. Is the infrastructure deployed?" -ForegroundColor Red
    Write-Host "  CLIENT_ID: $ClientId"
    Write-Host "  USER_POOL_ID: $UserPoolId"
    exit 1
}

Write-Host "Cognito User Pool: $UserPoolId"
Write-Host "Client ID: $ClientId"
Write-Host "API URL: $ApiUrl"
Write-Host ""

$Username = Read-Host "Username"
$Password = Read-Host "Password" -AsSecureString
$BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
$PlainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)

Write-Host ""
Write-Host "Authenticating..."

$AuthResponse = aws cognito-idp initiate-auth `
    --region $Region `
    --auth-flow USER_PASSWORD_AUTH `
    --client-id $ClientId `
    --auth-parameters "USERNAME=$Username,PASSWORD=$PlainPassword" 2>&1

$AuthJson = $AuthResponse | ConvertFrom-Json

# Check for NEW_PASSWORD_REQUIRED
if ($AuthJson.ChallengeName -eq "NEW_PASSWORD_REQUIRED") {
    Write-Host "New password required by Cognito."
    $Session = $AuthJson.Session

    $NewPassword = Read-Host "Enter new password" -AsSecureString
    $BSTR2 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($NewPassword)
    $PlainNewPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR2)

    $ChallengeResponse = aws cognito-idp respond-to-auth-challenge `
        --region $Region `
        --client-id $ClientId `
        --challenge-name NEW_PASSWORD_REQUIRED `
        --session $Session `
        --challenge-responses "USERNAME=$Username,NEW_PASSWORD=$PlainNewPassword" 2>&1

    $AuthJson = $ChallengeResponse | ConvertFrom-Json
}

$Token = $AuthJson.AuthenticationResult.AccessToken

if (-not $Token) {
    Write-Host "[ERROR] Could not extract access token" -ForegroundColor Red
    Write-Host $AuthResponse
    exit 1
}

Write-Host "[OK] Authentication successful!" -ForegroundColor Green
Write-Host ""

# Export for other scripts
$env:LLM_ROUTER_TOKEN = $Token
Write-Host "Token exported to `$env:LLM_ROUTER_TOKEN (expires in 1 hour)"
Write-Host ""

# =============================================================================
# Quick Test
# =============================================================================

Write-Host "========================================="
Write-Host "  Testing LLM Router API"
Write-Host "========================================="
Write-Host ""

if (-not $ApiEndpoint) {
    Write-Host "WARNING: No API endpoint found. Skipping tests." -ForegroundColor Yellow
    exit 0
}

# Test 1: Health check
Write-Host "[Test 1] Health check: GET $ApiEndpoint/health"
try {
    $Health = Invoke-RestMethod -Uri "$ApiEndpoint/health" -Method GET
    Write-Host "  Status: 200" -ForegroundColor Green
    Write-Host "  Response: $($Health | ConvertTo-Json -Compress)"
}
catch {
    Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

# Test 2: Chat completion
Write-Host "[Test 2] Chat completion: POST $ApiUrl"
Write-Host "  Prompt: 'What is 2+2? Answer in one sentence.'"
Write-Host ""

try {
    $Body = @{
        messages = @(@{ role = "user"; content = "What is 2+2? Answer in one sentence." })
        routing  = @{ policy = "default" }
    } | ConvertTo-Json -Depth 5

    $ChatResponse = Invoke-RestMethod -Uri $ApiUrl -Method POST `
        -Headers @{ Authorization = "Bearer $Token"; "Content-Type" = "application/json" } `
        -Body $Body

    $Content = $ChatResponse.choices[0].message.content
    $Model = $ChatResponse.routing.model_selected
    $Complexity = $ChatResponse.routing.complexity

    Write-Host "  Model: $Model" -ForegroundColor Cyan
    Write-Host "  Complexity: $Complexity" -ForegroundColor Cyan
    Write-Host "  Response: $Content" -ForegroundColor Green
}
catch {
    Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
}
