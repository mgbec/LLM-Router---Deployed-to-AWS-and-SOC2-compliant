# Auditor Guide — Reviewing Compliance Evidence

This guide walks auditors through accessing and interpreting the actual data produced by the LLM Router's compliance controls. All commands use the read-only auditor IAM role — no write access is granted.

## Prerequisites

### Assume the Auditor Role

```bash
# Get the auditor role ARN
AUDITOR_ROLE=$(cd terraform && terraform output -raw auditor_role_arn)

# Assume the role (session lasts 1 hour)
CREDS=$(aws sts assume-role \
  --role-arn "$AUDITOR_ROLE" \
  --role-session-name "compliance-review-$(date +%Y%m%d)" \
  --external-id "iso42001-audit-2026" \
  --output json)

# Export credentials
export AWS_ACCESS_KEY_ID=$(echo $CREDS | jq -r '.Credentials.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(echo $CREDS | jq -r '.Credentials.SecretAccessKey')
export AWS_SESSION_TOKEN=$(echo $CREDS | jq -r '.Credentials.SessionToken')
```

**Windows PowerShell:**
```powershell
Push-Location terraform
$AuditorRole = terraform output -raw auditor_role_arn
Pop-Location

$Creds = aws sts assume-role --role-arn $AuditorRole --role-session-name "compliance-review" --external-id "iso42001-audit-2026" --output json | ConvertFrom-Json

$env:AWS_ACCESS_KEY_ID = $Creds.Credentials.AccessKeyId
$env:AWS_SECRET_ACCESS_KEY = $Creds.Credentials.SecretAccessKey
$env:AWS_SESSION_TOKEN = $Creds.Credentials.SessionToken
```

---

## 1. Routing Audit Log (Provenance — ISO 42001 A.7.6, SOC 2 PI1.4)

**What it proves:** Every routing decision is recorded with full lineage — who made the request, which model was selected, why, and what data flowed where.

### View Recent Records

```bash
aws dynamodb scan \
  --table-name llm-router-opa-dev-routing-audit-log \
  --limit 5 \
  --scan-filter '{}' \
  --output json | jq '.Items[] | {
    request_id: .request_id.S,
    timestamp: .timestamp.N,
    user_id: .user_id.S,
    model_id: .model_id.S,
    complexity: .complexity.S,
    policy_id: .policy_id.S,
    latency_ms: .latency_ms.N,
    estimated_cost: .estimated_cost.N,
    classification_method: .classification_method.S,
    escalated: .escalated.BOOL,
    is_async: .is_async.BOOL,
    data_residency: .data_residency.S,
    external_provider: .external_provider.BOOL
  }'
```

### What to Look For

| Field | Evidence of |
|-------|-------------|
| `user_id` | Request attribution (CC6.1 — who accessed what) |
| `model_id` + `policy_id` | Policy-driven selection (CC5.1 — control activities) |
| `complexity` + `classification_method` | Automated classification (PI1.2 — processing integrity) |
| `data_residency` | Data stayed within AWS (C1.1 — confidentiality) |
| `external_provider: false` | No data sent externally without consent (CC6.7) |
| `estimated_cost` | Budget enforcement evidence (CC5.1) |
| `escalated` | Quality cascade triggered (PI1.5) |
| `prompt_hash` | Prompt recorded as hash, not plaintext (privacy) |

### Query by User

```bash
aws dynamodb query \
  --table-name llm-router-opa-dev-routing-audit-log \
  --index-name user-index \
  --key-condition-expression "user_id = :uid" \
  --expression-attribute-values '{":uid":{"S":"USER_SUB_HERE"}}' \
  --limit 20 \
  --scan-index-forward false \
  --output json | jq '.Items | length'
```

---

## 2. Data Flow Log (Data Classification — ISO 42001 A.7.5, SOC 2 C1.1)

**What it proves:** Every time data is evaluated for sensitivity, the decision is logged — what was detected, whether routing was allowed, and why.

### View Recent Decisions

```bash
aws dynamodb scan \
  --table-name llm-router-opa-dev-data-flow-log \
  --limit 10 \
  --output json | jq '.Items[] | {
    request_id: .request_id.S,
    timestamp: .timestamp.N,
    target_provider: .target_provider.S,
    routing_allowed: .routing_allowed.BOOL,
    detected_categories: .detected_categories.L,
    detected_patterns: .detected_patterns.L,
    decision: .decision.S
  }'
```

### What to Look For

| Field | Evidence of |
|-------|-------------|
| `routing_allowed: false` | PII/sensitive data blocked from external routing |
| `detected_patterns: ["ssn", "email"]` | Specific PII types caught |
| `detected_categories: ["pii", "financial"]` | Regulated content identified |
| `target_provider: "external"` + `decision: "blocked"` | Data residency enforced |
| `expires_at` | 90-day retention applied (C1.3) |

### Count Blocked vs Allowed

```bash
# How many requests were blocked from external routing
aws dynamodb scan \
  --table-name llm-router-opa-dev-data-flow-log \
  --filter-expression "routing_allowed = :blocked" \
  --expression-attribute-values '{":blocked":{"BOOL":false}}' \
  --select COUNT \
  --output json | jq '.Count'
```

---

## 3. Human Oversight Records (ISO 42001 A.9.5, SOC 2 CC9.1)

**What it proves:** Humans can override, disable, or flag the AI system. All actions are logged.

### View Concerns Reported

```bash
aws dynamodb scan \
  --table-name llm-router-opa-dev-human-review \
  --filter-expression "#t = :concern" \
  --expression-attribute-names '{"#t":"type"}' \
  --expression-attribute-values '{":concern":{"S":"general"}}' \
  --limit 10 \
  --output json | jq '.Items[] | {
    review_id: .review_id.S,
    created_at: .created_at.N,
    user_id: .user_id.S,
    type: .type.S,
    severity: .severity.S,
    status: .status.S,
    description: .description.S
  }'
```

### View Admin Overrides (Kill Switch, Model Blocks)

```bash
aws dynamodb scan \
  --table-name llm-router-opa-dev-human-review \
  --filter-expression "#t = :override" \
  --expression-attribute-names '{"#t":"type"}' \
  --expression-attribute-values '{":override":{"S":"override"}}' \
  --limit 10 \
  --output json | jq '.Items[] | {
    review_id: .review_id.S,
    created_at: .created_at.N,
    user_id: .user_id.S,
    action: .action.S,
    reason: .reason.S,
    parameters: .parameters.M
  }'
```

### What to Look For

| Evidence | SOC 2 Criteria |
|----------|---------------|
| Concerns exist with `status: "pending"` or `"resolved"` | CC9.1 — process exists and is used |
| Override records with `reason` field populated | CC9.1 — documented justification |
| Kill switch activations with timestamps | A1.2 — availability controls |
| SLA compliance: critical concerns < 4 hours | P8.1 — resolution timeliness |

---

## 4. OPA Policy Decisions (ISO 42001 A.9.4, SOC 2 CC5.1)

**What it proves:** Every routing decision is evaluated against testable, versioned policies. Denials are logged with reasons.

### View OPA Logs (Last Hour)

```bash
aws logs filter-log-events \
  --log-group-name "/llm-router/dev/agent" \
  --start-time $(date -d '1 hour ago' +%s)000 \
  --filter-pattern "OPA" \
  --limit 20 \
  --output json | jq '.events[].message'
```

**Windows:**
```powershell
$StartTime = [DateTimeOffset]::UtcNow.AddHours(-1).ToUnixTimeMilliseconds()
aws logs filter-log-events --log-group-name "/llm-router/dev/agent" --start-time $StartTime --filter-pattern "OPA" --limit 20 --query "events[].message" --output text
```

### View Denied Requests

```bash
aws logs filter-log-events \
  --log-group-name "/llm-router/dev/agent" \
  --start-time $(date -d '24 hours ago' +%s)000 \
  --filter-pattern "OPA DENY" \
  --output json | jq '.events[].message'
```

### What to Look For

| Log Entry | Evidence of |
|-----------|-------------|
| `OPA ALLOW (2.1ms)` | Policy evaluated and permitted — fast, automated |
| `OPA DENY: ["budget exceeded"]` | Budget control enforced |
| `OPA DENY: ["model disabled"]` | Kill switch / model flag working |
| `OPA DENY: ["external routing not consented"]` | Data consent enforced |
| Evaluation time (ms) | Policy adds minimal latency |

### Verify Policy Source

```bash
# The actual policy file (single source of truth)
cat policies/opa/routing.rego

# Run unit tests to prove policies work as documented
opa test policies/opa/ -v
```

---

## 5. Cedar Policy Decisions (SOC 2 CC6.1, CC6.2)

**What it proves:** Tool-level access control is enforced independently of application code by AWS infrastructure.

### List Active Policies

```bash
POLICY_ENGINE_ID=$(cd terraform && terraform output -raw policy_engine_arn | awk -F/ '{print $NF}')

aws bedrock-agentcore-control list-policies \
  --policy-engine-id "$POLICY_ENGINE_ID" \
  --output json | jq '.policies[] | {name, status, policyId}'
```

### Read a Specific Policy Statement

```bash
POLICY_ID="<from list above>"

aws bedrock-agentcore-control get-policy \
  --policy-engine-id "$POLICY_ENGINE_ID" \
  --policy-id "$POLICY_ID" \
  --output json | jq '.definition.cedar.statement'
```

### Verify Gateway Attachment

```bash
GATEWAY_ID=$(cd terraform && terraform output -raw agentcore_gateway_id)

aws bedrock-agentcore-control get-gateway \
  --gateway-identifier "$GATEWAY_ID" \
  --output json | jq '{
    policyEngine: .policyEngineConfiguration.arn,
    mode: .policyEngineConfiguration.mode,
    status: .status
  }'
```

### What to Look For

| Evidence | Confirms |
|----------|----------|
| All policies `status: "ACTIVE"` | Controls are deployed and running |
| `mode: "LOG_ONLY"` or `"ENFORCE"` | Either testing or actively blocking |
| Cedar statements match documented intent | Policies do what they claim |
| Gateway has policy engine attached | No bypass possible |

---

## 6. Bedrock Guardrails (SOC 2 PI1.2, PI1.3)

**What it proves:** Content is filtered for harmful/sensitive topics before reaching end users.

### View Guardrail Configuration

```bash
GUARDRAIL_ID=$(cd terraform && terraform output -raw guardrail_id)

aws bedrock get-guardrail \
  --guardrail-identifier "$GUARDRAIL_ID" \
  --output json | jq '{
    name: .name,
    status: .status,
    blockedTopics: .topicPolicy.topics[].name,
    contentFilters: .contentPolicy.filters[].type
  }'
```

### View Model Invocation Logs (Guardrail Triggers)

```bash
# List recent log files in S3
aws s3 ls s3://llm-router-opa-dev-model-invocation-logs/ --recursive | tail -5

# Download and inspect a log file
aws s3 cp s3://llm-router-opa-dev-model-invocation-logs/<path> - | jq '{
  modelId: .modelId,
  guardrailAction: .guardrailAction,
  guardrailOutputs: .guardrailOutputs
}'
```

### CloudWatch Guardrail Metrics

```bash
aws cloudwatch get-metric-statistics \
  --namespace "AWS/Bedrock" \
  --metric-name "GuardrailsIntervened" \
  --dimensions Name=GuardrailId,Value=$GUARDRAIL_ID \
  --start-time $(date -d '7 days ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date +%Y-%m-%dT%H:%M:%S) \
  --period 86400 \
  --statistics Sum \
  --output json | jq '.Datapoints | sort_by(.Timestamp)'
```

### What to Look For

| Evidence | Confirms |
|----------|----------|
| Guardrail `status: "READY"` | Active and operational |
| Topics blocked: medical, legal, etc. | Appropriate categories configured |
| S3 logs show `guardrailAction: "BLOCKED"` | Filtering works in production |
| CloudWatch metric > 0 | Guardrails have triggered (system is effective) |

---

## 7. Encryption & Access Controls (SOC 2 CC6.1, C1.2)

### Verify Kinesis KMS Encryption

```bash
aws kinesis describe-stream \
  --stream-name llm-router-opa-dev-routing-events \
  --query "StreamDescription.EncryptionType" \
  --output text
# Expected: KMS
```

### Verify S3 Public Access Block

```bash
aws s3api get-public-access-block \
  --bucket llm-router-opa-dev-governance-docs \
  --output json | jq '.PublicAccessBlockConfiguration'
# Expected: all true
```

### Verify DynamoDB Encryption

```bash
aws dynamodb describe-table \
  --table-name llm-router-opa-dev-routing-audit-log \
  --query "Table.SSEDescription" \
  --output json
```

### Verify Secrets Manager Recovery Window

```bash
aws secretsmanager list-secrets \
  --filter Key=name,Values=llm-router \
  --query "SecretList[].{Name:Name,RecoveryWindow:RecoveryWindowInDays}" \
  --output table
```

---

## 8. AppConfig Kill Switch State (SOC 2 A1.2, CC9.1)

**What it proves:** Operators can instantly disable the system without code changes.

### View Current Feature Flags

```bash
APP_ID=$(cd terraform && terraform output -json | jq -r '.[]' 2>/dev/null | head -1)
# Or check Terraform state:
cd terraform && terraform state show aws_appconfig_application.router | grep " id"
```

### Verify Kill Switch Is Accessible

```bash
# The API endpoint for emergency shutdown
echo "POST /v1/admin/override"
echo "Body: {\"action\":\"kill_switch\",\"parameters\":{\"target\":\"system\",\"enabled\":false}}"
```

---

## 9. Change Management Evidence (SOC 2 CC8.1)

### Git History for Policy Changes

```bash
# When were routing policies last modified?
git log --oneline -10 -- policies/opa/routing.rego

# When were Cedar policies last changed?
git log --oneline -10 -- terraform/agentcore_policy.tf

# When was infrastructure last modified?
git log --oneline -10 -- terraform/

# Who approved the last policy change?
git log -1 --format="%H %an %ad %s" -- policies/
```

### Conftest Validation (Automated Gate)

```bash
# Prove that Terraform changes are validated before apply
conftest test terraform/plan.json -p policies/terraform/ --no-color
```

---

## 10. Availability & Resilience (SOC 2 A1.2, A1.3)

### DynamoDB Point-in-Time Recovery

```bash
for TABLE in routing-audit-log routing-policies routing-metrics data-flow-log async-requests; do
  echo -n "llm-router-opa-dev-$TABLE: "
  aws dynamodb describe-continuous-backups \
    --table-name "llm-router-opa-dev-$TABLE" \
    --query "ContinuousBackupsDescription.PointInTimeRecoveryDescription.PointInTimeRecoveryStatus" \
    --output text
done
# Expected: ENABLED for all
```

### AgentCore Runtime Health

```bash
RUNTIME_ARN=$(cd terraform && terraform output -raw agentcore_runtime_arn)
RUNTIME_ID=$(echo $RUNTIME_ARN | awk -F/ '{print $NF}')

aws bedrock-agentcore-control get-agent-runtime \
  --agent-runtime-id "$RUNTIME_ID" \
  --query "{status:status,instances:lifecycleConfiguration}" \
  --output json
```

### CloudWatch Alarms (Active Monitoring)

```bash
aws cloudwatch describe-alarms \
  --alarm-name-prefix "llm-router-opa-dev" \
  --query "MetricAlarms[].{Name:AlarmName,State:StateValue}" \
  --output table
# Expected: all OK (no ALARM state unless actively triggered)
```

---

## Summary Checklist for Auditors

| # | Control Area | What to Verify | Command Section |
|---|---|---|---|
| 1 | Provenance/Lineage | Records exist for all requests | Section 1 |
| 2 | Data Classification | PII blocked from external routing | Section 2 |
| 3 | Human Oversight | Concerns logged, overrides documented | Section 3 |
| 4 | Policy Enforcement (OPA) | Denials logged with reasons | Section 4 |
| 5 | Access Control (Cedar) | Policies active, gateway attached | Section 5 |
| 6 | Content Filtering | Guardrails triggered in production | Section 6 |
| 7 | Encryption | KMS on streams, AES-256 on storage | Section 7 |
| 8 | Kill Switch | Accessible, operational | Section 8 |
| 9 | Change Management | Git history, automated validation | Section 9 |
| 10 | Availability | PITR enabled, alarms healthy | Section 10 |
