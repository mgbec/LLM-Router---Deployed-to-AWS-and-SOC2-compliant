# =============================================================================
# LLM Router - Deployment Script (Windows PowerShell)
# Two-phase deploy: ECR first (push image), then full infrastructure
# =============================================================================

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir

# --- Helper Functions ---
function Write-Info($msg)  { Write-Host "[INFO] $msg" -ForegroundColor Green }
function Write-Warn($msg)  { Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Write-Err($msg)   { Write-Host "[ERROR] $msg" -ForegroundColor Red; exit 1 }

# --- Configuration ---
$Region      = if ($env:AWS_REGION)    { $env:AWS_REGION }    else { "us-east-1" }
$Environment = if ($env:ENVIRONMENT)   { $env:ENVIRONMENT }   else { "dev" }
$ProjectName = if ($env:PROJECT_NAME)  { $env:PROJECT_NAME }  else { "llm-router" }

Write-Info "LLM Router Deployment - $Environment"
Write-Info "Region: $Region"

# --- Step 1: Get AWS Account ID ---
$AccountId = aws sts get-caller-identity --query Account --output text
if ($LASTEXITCODE -ne 0) { Write-Err "Failed to get AWS account ID. Is AWS CLI configured?" }
Write-Info "AWS Account: $AccountId"

# --- Step 2: Initialize Terraform ---
Write-Info "Initializing Terraform..."
Push-Location "$ProjectRoot\terraform"
try {
    terraform init -upgrade
    if ($LASTEXITCODE -ne 0) { Write-Err "Terraform init failed." }

    # --- Step 3: Apply ONLY the ECR repository first ---
    Write-Info "Phase 1: Creating ECR repository..."
    $tfArgsEcr = @(
        "apply",
        "-var", "region=$Region",
        "-var", "environment=$Environment",
        "-var", "router_agent_image_tag=latest",
        "-target=aws_ecr_repository.router_agent",
        "-auto-approve"
    )
    & terraform $tfArgsEcr
    if ($LASTEXITCODE -ne 0) { Write-Err "Terraform apply (ECR) failed." }

    # --- Step 4: Get the ECR repository URL ---
    $EcrRepo = terraform output -raw ecr_repository_url
    if ($LASTEXITCODE -ne 0) { Write-Err "Failed to get ECR repository URL from Terraform output." }
    Write-Info "ECR Repository: $EcrRepo"

    # --- Step 5: Authenticate Docker to ECR ---
    Write-Info "Authenticating Docker to ECR..."
    $EcrEndpoint = "$AccountId.dkr.ecr.$Region.amazonaws.com"
    $LoginPassword = aws ecr get-login-password --region $Region
    if ($LASTEXITCODE -ne 0) { Write-Err "Failed to get ECR login password." }
    # Use --password flag directly to avoid pipe encoding issues on Windows
    docker login --username AWS --password $LoginPassword $EcrEndpoint
    if ($LASTEXITCODE -ne 0) { Write-Err "Docker login to ECR failed." }

    # --- Step 6: Build and push the router agent image ---
    Write-Info "Copying OPA policies into agent build context..."
    $PoliciesSrc  = "$ProjectRoot\policies\opa"
    $PoliciesDest = "$ProjectRoot\agent\policies"
    if (Test-Path $PoliciesDest) { Remove-Item -Recurse -Force $PoliciesDest }
    Copy-Item -Recurse -Force $PoliciesSrc $PoliciesDest

    Write-Info "Building router agent image (linux/arm64)..."
    docker build --platform linux/arm64 -t "${ProjectName}-router-agent:latest" "$ProjectRoot\agent"
    if ($LASTEXITCODE -ne 0) {
        Remove-Item -Recurse -Force $PoliciesDest -ErrorAction SilentlyContinue
        Write-Err "Docker build failed."
    }

    # Clean up copied policies
    Remove-Item -Recurse -Force $PoliciesDest -ErrorAction SilentlyContinue

    Write-Info "Pushing image to ECR..."
    docker tag "${ProjectName}-router-agent:latest" "${EcrRepo}:latest"
    if ($LASTEXITCODE -ne 0) { Write-Err "Docker tag failed." }
    docker push "${EcrRepo}:latest"
    if ($LASTEXITCODE -ne 0) { Write-Err "Docker push failed." }
    Write-Info "Image pushed: ${EcrRepo}:latest"

    # --- Step 7: Apply full Terraform ---
    Write-Info "Phase 2: Deploying full infrastructure..."

    # Import pre-existing resources that may have been created outside Terraform
    Write-Info "Importing pre-existing resources (if any)..."
    $tfArgsImport = @(
        "import",
        "-var", "region=$Region",
        "-var", "environment=$Environment",
        "-var", "router_agent_image_tag=latest",
        "aws_cloudwatch_log_group.router_agent",
        "/llm-router/$Environment/agent"
    )
    $ErrorActionPreference = "Continue"
    & terraform $tfArgsImport 2>&1 | Out-Null
    $ErrorActionPreference = "Stop"
    # Ignore import errors (resource may already be in state or not exist)

    $tfArgsFull = @(
        "apply",
        "-var", "region=$Region",
        "-var", "environment=$Environment",
        "-var", "router_agent_image_tag=latest",
        "-auto-approve"
    )
    & terraform $tfArgsFull
    if ($LASTEXITCODE -ne 0) { Write-Err "Terraform apply (full) failed." }

    # --- Step 8: Print outputs ---
    Write-Info "Deployment complete!"
    Write-Host ""
    Write-Host "========================================="
    Write-Host "  LLM Router - Deployment Outputs"
    Write-Host "========================================="
    terraform output
    Write-Host ""

    $ChatUrl = terraform output -raw chat_completions_url 2>$null
    if ($ChatUrl) {
        Write-Info "To test:"
        Write-Host "  curl -X POST $ChatUrl -H 'Authorization: Bearer <token>' -H 'Content-Type: application/json' -d '{""messages"": [{""role"": ""user"", ""content"": ""Hello""}]}'"
    }
}
finally {
    Pop-Location
}
