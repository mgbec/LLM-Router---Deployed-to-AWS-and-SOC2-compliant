# =============================================================================
# Run OPA policy tests and Terraform validation (Windows PowerShell)
# =============================================================================
# Prerequisites:
#   - OPA: https://www.openpolicyagent.org/docs/latest/#1-download-opa
#   - Conftest: https://www.conftest.dev/install/

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir

Write-Host "--- OPA Routing Policy Tests ---" -ForegroundColor Cyan
Write-Host ""

# Test routing policies
if (Get-Command opa -ErrorAction SilentlyContinue) {
    & opa test "$ProjectRoot\policies\opa\" -v
    if ($LASTEXITCODE -eq 0) {
        Write-Host ""
        Write-Host "[PASS] All routing policy tests passed" -ForegroundColor Green
    }
    else {
        Write-Host ""
        Write-Host "[FAIL] Some routing policy tests failed" -ForegroundColor Red
        exit 1
    }
}
else {
    Write-Host "OPA not installed." -ForegroundColor Yellow
    Write-Host "  Download: https://www.openpolicyagent.org/docs/latest/#1-download-opa"
    Write-Host "  Or: winget install OpenPolicyAgent.OPA"
    Write-Host "Skipping OPA tests."
}

Write-Host ""
Write-Host "--- Terraform Plan Validation ---" -ForegroundColor Cyan
Write-Host ""

# Validate Terraform plan with Conftest
if (Get-Command conftest -ErrorAction SilentlyContinue) {
    Push-Location "$ProjectRoot\terraform"
    try {
        # Generate plan JSON if not present
        if (-not (Test-Path "plan.json")) {
            Write-Host "Generating Terraform plan..."
            $tfPlanArgs = @("plan", "-out=plan.tfplan", "-var", "region=us-east-1", "-var", "environment=dev", "-var", "router_agent_image_tag=latest")
            & terraform $tfPlanArgs 2>$null
            & terraform show -json plan.tfplan | Out-File -Encoding utf8 plan.json
            Remove-Item -Force plan.tfplan -ErrorAction SilentlyContinue
        }
        else {
            Write-Host "Using existing plan.json"
        }

        & conftest test plan.json -p "$ProjectRoot\policies\terraform\" --no-color
        if ($LASTEXITCODE -eq 0) {
            Write-Host ""
            Write-Host "[PASS] Terraform plan validation passed" -ForegroundColor Green
        }
        else {
            Write-Host ""
            Write-Host "[FAIL] Terraform plan validation failed" -ForegroundColor Red
        }
    }
    finally {
        Pop-Location
    }
}
else {
    Write-Host "Conftest not installed." -ForegroundColor Yellow
    Write-Host "  Download: https://www.conftest.dev/install/"
    Write-Host "  Or: scoop install conftest"
    Write-Host "Skipping Terraform validation."
}

Write-Host ""
Write-Host "--- Policy Tests Complete ---" -ForegroundColor Cyan
