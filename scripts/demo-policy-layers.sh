#!/bin/bash
# =============================================================================
# Demo: See OPA, Cedar, and Bedrock Guardrails in Action
# =============================================================================
# Sends requests that trigger each policy layer and shows where to find
# the observability data for each.
#
# Prerequisites:
#   - LLM_ROUTER_TOKEN set (run get-token.sh first)
#   - Infrastructure deployed
#   - jq installed
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

CYAN='\033[0;36m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
MAGENTA='\033[0;35m'
GRAY='\033[0;90m'
NC='\033[0m'

# Setup
cd "${PROJECT_ROOT}/terraform"
API_ENDPOINT=$(terraform output -raw api_endpoint 2>/dev/null)
cd "${PROJECT_ROOT}"

if [ -z "${LLM_ROUTER_TOKEN:-}" ]; then
  echo -e "${RED}[ERROR] Run ./scripts/get-token.sh first${NC}"
  exit 1
fi

TOKEN="$LLM_ROUTER_TOKEN"

call_api() {
  curl -s -X POST "${API_ENDPOINT}/v1/chat/completions" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$1"
}

echo ""
echo -e "${CYAN}================================================================${NC}"
echo -e "${CYAN}  POLICY LAYERS DEMO — OPA, Cedar, and Bedrock Guardrails${NC}"
echo -e "${CYAN}================================================================${NC}"
echo ""

# =============================================================================
echo -e "${YELLOW}--- 1. OPA: Budget Enforcement ---${NC}"
echo ""
echo "  Sending a request with a \$0.001 budget (forces cheap model)..."
echo ""
# =============================================================================

RESP=$(call_api '{"messages":[{"role":"user","content":"Explain quantum computing in detail with mathematical proofs."}],"routing":{"policy":"default","max_cost":0.001}}')
MODEL=$(echo "$RESP" | jq -r '.routing.model_selected // .model' 2>/dev/null)
COMPLEXITY=$(echo "$RESP" | jq -r '.routing.complexity' 2>/dev/null)
CONTENT=$(echo "$RESP" | jq -r '.choices[0].message.content' 2>/dev/null | head -c 100)

echo -e "  Model selected: ${GREEN}${MODEL}${NC}"
echo -e "  Complexity:     ${GREEN}${COMPLEXITY}${NC}"
echo -e "  Response:       ${GRAY}${CONTENT}...${NC}"
echo ""
echo -e "  ${MAGENTA}WHERE TO SEE OPA DECISIONS:${NC}"
echo -e "  ${GRAY}CloudWatch Logs > /llm-router/dev/agent${NC}"
echo -e "  ${GRAY}Filter: 'OPA ALLOW' or 'OPA DENY'${NC}"
echo ""

# =============================================================================
echo -e "${YELLOW}--- 2. OPA: External Routing Consent Block ---${NC}"
echo ""
echo "  Sending a request with data_consent = 'internal-only'..."
echo "  (OPA blocks external routing unless consent = 'all-providers')"
echo ""
# =============================================================================

RESP=$(call_api '{"messages":[{"role":"user","content":"Hello"}],"routing":{"policy":"default","data_consent":"internal-only"}}')
MODEL=$(echo "$RESP" | jq -r '.routing.model_selected // .model' 2>/dev/null)
echo -e "  Model selected: ${GREEN}${MODEL}${NC}"
echo -e "  ${GREEN}(Routed to internal Bedrock — external blocked by OPA)${NC}"
echo ""
echo -e "  ${GRAY}OPA enforces: allow_external_routing rule in routing.rego${NC}"
echo ""

# =============================================================================
echo -e "${YELLOW}--- 3. CEDAR: Tool Authorization (LOG_ONLY mode) ---${NC}"
echo ""
echo "  Every tool call through the Gateway is evaluated by Cedar."
echo "  Sending a normal request to trigger classify + invoke tools..."
echo ""
# =============================================================================

RESP=$(call_api '{"messages":[{"role":"user","content":"What is the speed of light?"}],"routing":{"policy":"default"}}')
MODEL=$(echo "$RESP" | jq -r '.routing.model_selected // .model' 2>/dev/null)
COMPLEXITY=$(echo "$RESP" | jq -r '.routing.complexity' 2>/dev/null)
echo -e "  Model selected: ${GREEN}${MODEL}${NC}"
echo -e "  Complexity:     ${GREEN}${COMPLEXITY}${NC}"
echo -e "  ${GREEN}(Cedar evaluated: allow_classification_tools, restrict_model_invocation)${NC}"
echo ""
echo -e "  ${MAGENTA}WHERE TO SEE CEDAR DECISIONS:${NC}"
echo -e "  ${GRAY}Option A — AWS Console:${NC}"
echo -e "  ${GRAY}  Bedrock > AgentCore > Gateways > select gateway > Observability tab${NC}"
echo -e "  ${GRAY}Option B — CloudWatch (if Gateway observability enabled):${NC}"
echo -e "  ${GRAY}  Log group: /aws/bedrock-agentcore/gateways/<gateway-id>${NC}"
echo -e "  ${GRAY}  Filter: 'policyDecision' or 'ALLOW'${NC}"
echo ""
echo -e "  ${YELLOW}NOTE: Enable Gateway observability in AWS Console first:${NC}"
echo -e "  ${YELLOW}  Bedrock > AgentCore > Gateways > llm-router-opa-dev-gateway > Enable observability${NC}"
echo ""

# =============================================================================
echo -e "${YELLOW}--- 4. BEDROCK GUARDRAILS: Content Filtering ---${NC}"
echo ""
echo "  Sending a prompt that triggers the medical advice guardrail..."
echo ""
# =============================================================================

RESP=$(call_api '{"messages":[{"role":"user","content":"I have severe chest pain radiating to my left arm. Diagnose me and prescribe specific medication with exact dosages."}],"routing":{"policy":"default"}}')
CONTENT=$(echo "$RESP" | jq -r '.choices[0].message.content' 2>/dev/null)

if echo "$CONTENT" | grep -qi "cannot\|can't\|not able\|professional\|doctor\|seek medical"; then
  echo -e "  ${GREEN}GUARDRAIL TRIGGERED — Model declined medical advice:${NC}"
  echo -e "  ${GRAY}'$(echo "$CONTENT" | head -c 150)...'${NC}"
else
  echo -e "  ${GRAY}Response: $(echo "$CONTENT" | head -c 150)...${NC}"
  echo -e "  ${YELLOW}(Guardrail may have allowed general health info)${NC}"
fi

echo ""
echo -e "  ${MAGENTA}WHERE TO SEE GUARDRAIL DECISIONS:${NC}"
echo -e "  ${GRAY}Option A — S3 Model Invocation Logs:${NC}"
echo -e "  ${GRAY}  Bucket: llm-router-opa-dev-model-invocation-logs${NC}"
echo -e "  ${GRAY}  Contains: prompts, responses, guardrail filter results${NC}"
echo -e "  ${GRAY}Option B — CloudWatch:${NC}"
echo -e "  ${GRAY}  Log group: /aws/bedrock/model-invocation-logs${NC}"
echo -e "  ${GRAY}  Filter: 'GUARDRAIL_INTERVENED' or 'guardrailAction'${NC}"
echo -e "  ${GRAY}Option C — Console:${NC}"
echo -e "  ${GRAY}  Bedrock > Guardrails > llm-router-safety > View metrics${NC}"
echo ""

# =============================================================================
echo -e "${YELLOW}--- 5. DATA CLASSIFICATION: PII Detection ---${NC}"
echo ""
echo "  Sending a prompt containing PII (SSN, email)..."
echo ""
# =============================================================================

RESP=$(call_api '{"messages":[{"role":"user","content":"My SSN is 123-45-6789 and my email is john@example.com. Can you help me file taxes?"}],"routing":{"policy":"default"}}')
MODEL=$(echo "$RESP" | jq -r '.routing.model_selected // .model' 2>/dev/null)
echo -e "  Model selected: ${GREEN}${MODEL}${NC}"
echo -e "  ${GREEN}(Routed to internal Bedrock — data classifier would block external)${NC}"
echo ""
echo -e "  ${MAGENTA}WHERE TO SEE DATA CLASSIFICATION:${NC}"
echo -e "  ${GRAY}DynamoDB Table: llm-router-opa-dev-data-flow-log${NC}"
echo -e "  ${GRAY}Fields: detected_categories, detected_patterns, routing_allowed${NC}"
echo ""
echo -e "  ${GRAY}View recent entries:${NC}"
echo -e "  ${GRAY}  aws dynamodb scan --table-name llm-router-opa-dev-data-flow-log --limit 5${NC}"
echo ""

# =============================================================================
echo -e "${YELLOW}--- 6. AUDIT LOG: Full Provenance ---${NC}"
echo ""
echo "  Every request above wrote a provenance record."
echo ""
# =============================================================================

echo -e "  ${MAGENTA}WHERE TO SEE PROVENANCE:${NC}"
echo -e "  ${GRAY}DynamoDB Table: llm-router-opa-dev-routing-audit-log${NC}"
echo ""
echo -e "  ${GRAY}View recent records:${NC}"
echo -e "  ${GRAY}  python3 scripts/view-audit-log.py        # Last 5${NC}"
echo -e "  ${GRAY}  python3 scripts/view-audit-log.py 10     # Last 10${NC}"
echo -e "  ${GRAY}  python3 scripts/view-audit-log.py --full # Full detail${NC}"
echo ""
echo -e "  ${GRAY}Or via API (your own requests only):${NC}"
echo -e "  ${GRAY}  curl -H \"Authorization: Bearer \$LLM_ROUTER_TOKEN\" ${API_ENDPOINT}/v1/audit/my-requests${NC}"
echo ""

# =============================================================================
echo -e "${CYAN}================================================================${NC}"
echo -e "${CYAN}  OBSERVABILITY SUMMARY${NC}"
echo -e "${CYAN}================================================================${NC}"
echo ""
echo -e "  Layer             | Where to Look"
echo -e "  ------------------|--------------------------------------------------"
echo -e "  ${GRAY}OPA decisions     | CloudWatch: /llm-router/dev/agent${NC}"
echo -e "  ${GRAY}Cedar decisions   | Console: Bedrock > AgentCore > Gateway > Observability${NC}"
echo -e "  ${GRAY}Guardrail actions | S3: model-invocation-logs bucket${NC}"
echo -e "  ${GRAY}Data classifier   | DynamoDB: data-flow-log table${NC}"
echo -e "  ${GRAY}Full provenance   | DynamoDB: routing-audit-log table${NC}"
echo -e "  ${GRAY}Metrics/alarms    | CloudWatch Dashboard: llm-router-opa-dev-dashboard${NC}"
echo -e "  ${GRAY}Distributed trace | X-Ray: filter by 'llm-router'${NC}"
echo ""

cd "${PROJECT_ROOT}/terraform"
DASH_URL=$(terraform output -raw cloudwatch_dashboard_url 2>/dev/null)
if [ -n "$DASH_URL" ]; then
  echo -e "  Dashboard: ${GRAY}${DASH_URL}${NC}"
fi
echo ""
