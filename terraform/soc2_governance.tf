# =============================================================================
# SOC 2 Governance Documentation
# Closes gaps identified in the SOC 2 Trust Services Criteria assessment
# =============================================================================

# -----------------------------------------------------------------------------
# Gap 1: Disaster Recovery Plan (Availability A1.3)
# -----------------------------------------------------------------------------

resource "aws_s3_object" "disaster_recovery_plan" {
  bucket       = aws_s3_bucket.governance_docs.id
  key          = "operations/disaster-recovery-plan.md"
  content_type = "text/markdown"
  content      = <<-EOT
# Disaster Recovery Plan — LLM Router

## Version
- Version: 1.0
- Last Updated: ${timestamp()}
- Owner: Platform Engineering
- Review Frequency: Quarterly

## Recovery Objectives

| Metric | Target | Justification |
|--------|--------|---------------|
| RTO (Recovery Time Objective) | 30 minutes | Router is not life-critical; users can retry after brief outage |
| RPO (Recovery Point Objective) | 5 minutes | Kinesis retains events for 24h; DynamoDB has PITR enabled |
| MTTR (Mean Time to Recover) | 15 minutes | Terraform re-apply from clean state |

## Failure Scenarios and Recovery

### Scenario 1: AgentCore Runtime Failure
- **Detection**: CloudWatch alarm on 5xx error rate
- **Impact**: Sync requests fail; async requests queue but don't process
- **Recovery**: `terraform destroy -target=runtime && terraform apply` (4-5 min)
- **Data Loss**: None (state is in DynamoDB, not the container)

### Scenario 2: Single Model Provider Outage (Bedrock)
- **Detection**: Circuit breaker opens after 3 consecutive failures
- **Impact**: Requests automatically route to fallback model
- **Recovery**: Automatic via circuit breaker half-open probe
- **Data Loss**: None

### Scenario 3: Regional AWS Outage (us-east-1)
- **Detection**: Route 53 health check (if multi-region deployed)
- **Impact**: Complete service unavailable
- **Recovery**: Deploy to secondary region via Terraform workspace
- **Data Loss**: Up to RPO (5 min of routing metrics)

### Scenario 4: DynamoDB Table Corruption/Deletion
- **Detection**: Application errors on DynamoDB reads
- **Impact**: Routing policies unavailable (defaults used), audit log lost
- **Recovery**: DynamoDB Point-in-Time Recovery (restore to any second within 35 days)
- **Data Loss**: None (PITR enabled on all critical tables)

### Scenario 5: ECR Image Corruption
- **Detection**: Runtime fails to start
- **Impact**: Cannot deploy new runtime versions
- **Recovery**: Rebuild and push from source (`docker build && docker push`)
- **Data Loss**: None

### Scenario 6: Secrets Compromised (API Keys)
- **Detection**: Unusual external provider usage in metrics
- **Impact**: Potential unauthorized use of external providers
- **Recovery**: Rotate secret in Secrets Manager, kill switch external providers via AppConfig
- **Data Loss**: None

## Recovery Procedures

### Quick Recovery (< 5 min)
1. Kill switch: Disable affected component via AppConfig
2. Verify: Run `./scripts/get-token.sh` to confirm system responds

### Full Redeploy (< 30 min)
1. `cd terraform && terraform apply` (recreates all resources)
2. Push agent image: `./scripts/deploy.sh`
3. Wait 4 min for runtime startup
4. Verify: `./scripts/run-tests.sh`

### Cross-Region Failover (< 60 min)
1. Update `region` in terraform.tfvars
2. `terraform init && terraform apply` in new region
3. Update DNS/client configuration
4. Verify: full test suite

## Testing Schedule
- **Monthly**: Simulate model provider failure (disable via AppConfig, verify fallback)
- **Quarterly**: Full Terraform destroy + redeploy in dev environment
- **Annually**: Cross-region failover test
  EOT

  tags = merge(local.common_tags, { Document = "disaster-recovery-plan" })
}

# -----------------------------------------------------------------------------
# Gap 2: Backup/Restore Procedure (Availability A1.4)
# -----------------------------------------------------------------------------

resource "aws_s3_object" "backup_restore_procedure" {
  bucket       = aws_s3_bucket.governance_docs.id
  key          = "operations/backup-restore-procedure.md"
  content_type = "text/markdown"
  content      = <<-EOT
# Backup & Restore Procedure — LLM Router

## Version
- Version: 1.0
- Last Updated: ${timestamp()}
- Owner: Platform Engineering

## What's Backed Up

| Resource | Backup Method | Retention | Restore Time |
|----------|--------------|-----------|--------------|
| DynamoDB Tables (all) | Point-in-Time Recovery (PITR) | 35 days | 5-30 minutes |
| S3 Governance Docs | Versioning + Glacier archival | 365 days (versions) | Instant (current), minutes (old) |
| Terraform State | S3 backend (if configured) | Indefinite | Instant |
| Agent Source Code | Git repository | Indefinite | Instant |
| AppConfig Versions | AppConfig native versioning | All versions retained | Instant |

## DynamoDB Restore Procedure

### Restore a table to a specific point in time:
```bash
aws dynamodb restore-table-to-point-in-time \
  --source-table-name llm-router-dev-routing-audit-log \
  --target-table-name llm-router-dev-routing-audit-log-restored \
  --restore-date-time "2026-07-15T10:00:00Z" \
  --region us-east-1
```

### After restore:
1. Verify data: `aws dynamodb scan --table-name <restored-table> --limit 5`
2. If replacing original: update Terraform to point to restored table, or rename

## S3 Governance Docs Restore

### Restore a previous version:
```bash
# List versions
aws s3api list-object-versions \
  --bucket llm-router-dev-governance-docs-339712707840 \
  --prefix policies/ai-policy.md

# Restore specific version
aws s3api get-object \
  --bucket llm-router-dev-governance-docs-339712707840 \
  --key policies/ai-policy.md \
  --version-id <version-id> \
  restored-ai-policy.md
```

## Full System Restore (from scratch)

1. Ensure Git repo is available
2. `cd terraform && terraform init && terraform apply`
3. Push agent image: `./scripts/deploy.sh`
4. Create Cognito users
5. Run tests: `./scripts/run-tests.sh`

Total time: ~15 minutes (most is waiting for AgentCore Runtime startup)

## Testing Schedule
- **Quarterly**: Restore one DynamoDB table from PITR in dev, verify data integrity
- **Semi-annually**: Full system restore from scratch in a clean account
  EOT

  tags = merge(local.common_tags, { Document = "backup-restore-procedure" })
}

# -----------------------------------------------------------------------------
# Gap 3: Access Offboarding Procedure (Security CC6.3)
# -----------------------------------------------------------------------------

resource "aws_s3_object" "access_offboarding" {
  bucket       = aws_s3_bucket.governance_docs.id
  key          = "operations/access-offboarding-procedure.md"
  content_type = "text/markdown"
  content      = <<-EOT
# Access Offboarding Procedure — LLM Router

## Version
- Version: 1.0
- Last Updated: ${timestamp()}
- Owner: Security / Platform Engineering

## When to Execute
- Employee leaves the organization
- Contractor engagement ends
- Role change removes need for system access
- Security incident requires immediate revocation

## Steps

### 1. Disable Cognito User (Immediate)
```bash
aws cognito-idp admin-disable-user \
  --region us-east-1 \
  --user-pool-id <pool-id> \
  --username <username>
```
This immediately invalidates all active sessions and prevents new logins.

### 2. Revoke Active Tokens
```bash
aws cognito-idp admin-user-global-sign-out \
  --region us-east-1 \
  --user-pool-id <pool-id> \
  --username <username>
```

### 3. Delete User (after confirmation period)
```bash
aws cognito-idp admin-delete-user \
  --region us-east-1 \
  --user-pool-id <pool-id> \
  --username <username>
```

### 4. Revoke IAM Access (if applicable)
- Remove user from any IAM groups with system access
- Delete any personal IAM access keys
- If using the auditor role: change the external_id in Terraform

### 5. Review Audit Log
- Check `GET /v1/audit/my-requests` for the user's recent activity
- Document any anomalous patterns

### 6. Record
- Log the offboarding date and actions taken
- Retain for compliance audit (12 months minimum)

## Emergency Revocation (Security Incident)
1. Disable user immediately (Step 1)
2. Global sign-out (Step 2)
3. If compromised credentials: rotate any shared secrets
4. If API key compromised: rotate in Secrets Manager, redeploy Lambda
5. Engage incident response team

## Verification
After offboarding, verify:
```bash
# Attempt login — should fail
aws cognito-idp initiate-auth \
  --auth-flow USER_PASSWORD_AUTH \
  --client-id <client-id> \
  --auth-parameters USERNAME=<removed-user>,PASSWORD=<any>
# Expected: NotAuthorizedException
```
  EOT

  tags = merge(local.common_tags, { Document = "access-offboarding" })
}

# -----------------------------------------------------------------------------
# Gap 4: Data Retention Policy (Confidentiality C1.3)
# -----------------------------------------------------------------------------

resource "aws_s3_object" "data_retention_policy" {
  bucket       = aws_s3_bucket.governance_docs.id
  key          = "policies/data-retention-policy.md"
  content_type = "text/markdown"
  content      = <<-EOT
# Data Retention Policy — LLM Router

## Version
- Version: 1.0
- Last Updated: ${timestamp()}
- Owner: Data Protection Officer
- Review Frequency: Annually

## Principles
- Retain data only as long as needed for its stated purpose
- Apply automatic deletion (TTL) where possible
- Never store raw user prompts — only hashed representations
- Comply with applicable regulations (GDPR right to erasure, etc.)

## Retention Schedule

| Data Type | Location | Retention | Deletion Method | Purpose |
|-----------|----------|-----------|-----------------|---------|
| Routing audit log (provenance) | DynamoDB | 90 days | TTL auto-delete | ISO 42001 A.7.6 compliance |
| Data flow log (PII decisions) | DynamoDB | 90 days | TTL auto-delete | Data governance audit |
| Human review queue | DynamoDB | 90 days | TTL auto-delete | Oversight tracking |
| Async request state | DynamoDB | 24 hours | TTL auto-delete | Polling completion |
| Routing metrics | DynamoDB | 7 days | TTL auto-delete | Weight adjustment |
| Routing policies | DynamoDB | Indefinite | Manual | Active configuration |
| Governance documents | S3 | Indefinite (current), 1 year (old versions) | Lifecycle → Glacier → Expire | Compliance evidence |
| CloudWatch logs | CloudWatch | 30 days | Log group retention | Debugging |
| Kinesis events | Kinesis | 24 hours | Stream retention | Real-time processing |
| X-Ray traces | X-Ray | 30 days | Service default | Performance analysis |
| User prompts | NOT STORED | N/A | N/A | Only SHA-256 hash stored in audit log |
| Model responses | NOT STORED | N/A | N/A | Only returned to client, not persisted |

## Data Subject Rights

### Right to Access
Users can query their own routing history via `GET /v1/audit/my-requests`.

### Right to Erasure
To delete a user's audit records before TTL expiry:
```bash
# Query user's records
aws dynamodb query --table-name llm-router-dev-routing-audit-log \
  --index-name user-index --key-condition-expression "user_id = :uid" \
  --expression-attribute-values '{":uid":{"S":"<cognito-sub>"}}'

# Delete each record
aws dynamodb delete-item --table-name llm-router-dev-routing-audit-log \
  --key '{"request_id":{"S":"<id>"},"timestamp":{"N":"<ts>"}}'
```

### Right to Portability
Export user records via DynamoDB scan filtered by user_id.

## Enforcement
- TTL is enforced automatically by DynamoDB (cannot be bypassed)
- S3 lifecycle rules managed by Terraform
- Log retention enforced by CloudWatch log group settings
- Changes to retention periods require Terraform update and approval
  EOT

  tags = merge(local.common_tags, { Document = "data-retention-policy" })
}

# -----------------------------------------------------------------------------
# Gap 5: Data Processing Consent (Privacy P2.1)
# Implemented as a consent-check header the client must send
# -----------------------------------------------------------------------------

# This is documented here; the code enforcement is in the API proxy Lambda
resource "aws_s3_object" "consent_policy" {
  bucket       = aws_s3_bucket.governance_docs.id
  key          = "policies/data-processing-consent.md"
  content_type = "text/markdown"
  content      = <<-EOT
# Data Processing Consent — LLM Router

## Version
- Version: 1.0
- Last Updated: ${timestamp()}
- Owner: Data Protection Officer

## Consent Model

The LLM Router uses an **implicit consent via usage** model combined with a
**disclosure-at-point-of-interaction** approach:

1. **Disclosure**: Every response includes an `X-AI-Disclosure` header and the
   frontend displays an AI disclosure footer informing users that model selection
   is dynamic.

2. **Transparency**: Users can check which model served them via response headers
   and the audit log API.

3. **Opt-in for external providers**: When external providers are enabled, the
   API supports an optional `X-Data-Consent` header:
   - `X-Data-Consent: internal-only` — forces routing to internal models only
   - `X-Data-Consent: all-providers` — allows external routing (with PII still blocked)
   - Default (no header): routes to internal models only (safe default)

4. **Policy-level control**: The `budget_conscious` and `default` policies only
   use internal (Bedrock) models. External routing only occurs if:
   - `enable_external_providers = true` in Terraform
   - The selected model is external
   - Data classification passes (no PII detected)
   - User hasn't sent `X-Data-Consent: internal-only`

## What Users Consent To By Using the Service
- Their prompts will be processed by AI models (disclosed)
- Model selection is dynamic (disclosed in headers)
- A SHA-256 hash of their prompt is logged for audit (not the raw text)
- Response metadata (model, latency, tokens) is logged for quality improvement
- Their Cognito user_id is associated with routing records

## What Users Do NOT Consent To (and we don't do)
- Raw prompt storage
- Response storage
- Sharing prompt content with third parties (unless external providers enabled + consent)
- Training models on their data (Bedrock does not retain prompts)
- Profiling based on prompt content
  EOT

  tags = merge(local.common_tags, { Document = "data-processing-consent" })
}

# -----------------------------------------------------------------------------
# Gap 6: Organizational Structure (Security CC1.1)
# -----------------------------------------------------------------------------

resource "aws_s3_object" "org_structure" {
  bucket       = aws_s3_bucket.governance_docs.id
  key          = "governance/organizational-structure.md"
  content_type = "text/markdown"
  content      = <<-EOT
# Organizational Structure — LLM Router Governance

## Version
- Version: 1.0
- Last Updated: ${timestamp()}
- Review Frequency: Annually or on organizational change

## RACI Matrix

| Activity | AI Governance Board | Platform Engineering | Data Protection Officer | AI Safety Lead | Vendor Management |
|----------|:---:|:---:|:---:|:---:|:---:|
| AI Policy approval | A | C | C | C | I |
| Model onboarding | A | R | C | C | C |
| Model retirement | A | R | I | C | I |
| Routing policy changes | A | R | I | I | I |
| Kill switch activation | I | R | I | A | I |
| Incident response | I | R | C | A | I |
| External provider evaluation | A | C | R | C | R |
| Bias testing | A | R | I | R | I |
| Compliance audit support | A | R | R | R | C |
| Data retention decisions | I | C | A | I | I |

Legend: R=Responsible, A=Accountable, C=Consulted, I=Informed

## Roles

### AI Governance Board
- **Composition**: Senior leadership, engineering lead, legal, compliance
- **Cadence**: Quarterly review meetings
- **Authority**: Final approval on policies, model additions, risk acceptance

### Platform Engineering
- **Responsibilities**: System operation, deployment, monitoring, incident response
- **On-call**: 24/7 for critical alerts (circuit breaker, kill switch triggers)

### Data Protection Officer
- **Responsibilities**: Data residency compliance, consent framework, GDPR/privacy
- **Authority**: Can block external provider routing on privacy grounds

### AI Safety Lead
- **Responsibilities**: Guardrail configuration, bias monitoring, content policy
- **Authority**: Can activate kill switch for safety incidents

### Vendor Management
- **Responsibilities**: External provider contracts, SLA monitoring, DPA management
- **Authority**: Approves/revokes external provider access

## Oversight Evidence
- Board meeting minutes stored in S3 governance bucket
- Policy approvals tracked via S3 object versioning (who changed what, when)
- Incident reports logged in human review queue
- All configuration changes auditable via Terraform state + AppConfig deployment history
  EOT

  tags = merge(local.common_tags, { Document = "organizational-structure" })
}
