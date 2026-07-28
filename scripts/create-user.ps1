# =============================================================================
# Create a Cognito test user for the LLM Router (Windows PowerShell)
# =============================================================================

param(
    [string]$Username,
    [string]$Email,
    [string]$TempPassword = "TempPass123!"
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir

# Get Cognito User Pool ID from Terraform
Push-Location "$ProjectRoot\terraform"
$UserPoolId = terraform output -raw cognito_user_pool_id 2>$null
Pop-Location

if (-not $UserPoolId) {
    Write-Host "[ERROR] Could not get cognito_user_pool_id from Terraform outputs. Is the infrastructure deployed?" -ForegroundColor Red
    exit 1
}

# Prompt for values if not provided
if (-not $Username) {
    $Username = Read-Host "Username (not an email)"
}
if (-not $Email) {
    $Email = Read-Host "Email address"
}

Write-Host ""
Write-Host "Creating user in Cognito..."
Write-Host "  User Pool: $UserPoolId"
Write-Host "  Username:  $Username"
Write-Host "  Email:     $Email"
Write-Host "  Temp Pass: $TempPassword"
Write-Host ""

$ErrorActionPreference = "Continue"
$Result = aws cognito-idp admin-create-user `
    --region us-east-1 `
    --user-pool-id $UserPoolId `
    --username $Username `
    --user-attributes "Name=email,Value=$Email" `
    --temporary-password $TempPassword 2>&1
$ErrorActionPreference = "Stop"

if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] User '$Username' created successfully!" -ForegroundColor Green
    Write-Host ""
    Write-Host "Next steps:"
    Write-Host "  1. Run: .\scripts\get-token.ps1"
    Write-Host "  2. Log in with username '$Username' and password '$TempPassword'"
    Write-Host "  3. You will be prompted to set a new password on first login"
}
else {
    $ErrorMsg = ($Result | Where-Object { $_ -match "error|Error|already exists" }) -join " "
    if ($ErrorMsg -match "UsernameExistsException") {
        Write-Host "[WARN] User '$Username' already exists." -ForegroundColor Yellow
    }
    else {
        Write-Host "[ERROR] Failed to create user:" -ForegroundColor Red
        Write-Host "  $Result"
    }
}
