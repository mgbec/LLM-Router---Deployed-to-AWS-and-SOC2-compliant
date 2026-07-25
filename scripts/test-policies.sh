#!/bin/bash
# =============================================================================
# Run OPA policy tests and Terraform validation
# =============================================================================
# Prerequisites:
#   - OPA: https://www.openpolicyagent.org/docs/latest/#1-download-opa
#   - Conftest: https://www.conftest.dev/install/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}━━━ OPA Routing Policy Tests ━━━${NC}"
echo ""

# Test routing policies
if command -v opa &> /dev/null; then
  opa test "${PROJECT_ROOT}/policies/opa/" -v
  echo ""
  echo -e "${GREEN}✓ All routing policy tests passed${NC}"
else
  echo "OPA not installed. Install from: https://www.openpolicyagent.org/docs/latest/#1-download-opa"
  echo "Skipping OPA tests."
fi

echo ""
echo -e "${CYAN}━━━ Terraform Plan Validation ━━━${NC}"
echo ""

# Validate Terraform plan
if command -v conftest &> /dev/null; then
  cd "${PROJECT_ROOT}/terraform"
  
  # Generate plan JSON
  if [ -f "plan.json" ]; then
    echo "Using existing plan.json"
  else
    echo "Generating Terraform plan..."
    terraform plan -out=plan.tfplan -var "region=us-east-1" -var "environment=dev" -var "router_agent_image_tag=latest" 2>/dev/null
    terraform show -json plan.tfplan > plan.json
    rm -f plan.tfplan
  fi

  conftest test plan.json -p "${PROJECT_ROOT}/policies/terraform/" --no-color
  echo ""
  echo -e "${GREEN}✓ Terraform plan validation passed${NC}"
else
  echo "Conftest not installed. Install from: https://www.conftest.dev/install/"
  echo "Skipping Terraform validation."
fi

echo ""
echo -e "${CYAN}━━━ Policy Test Complete ━━━${NC}"
