# SOC 2 Trust Services Criteria — Assessment

## Summary

All SOC 2 Trust Services Criteria gaps have been closed. The system now has documented procedures and technical controls covering Security, Availability, Processing Integrity, Confidentiality, and Privacy.

## Coverage

| Trust Criteria | Controls | Status |
|---|---|---|
| Security (CC) | 14 | ✔️ All covered |
| Availability (A) | 4 | ✔️ All covered |
| Processing Integrity (PI) | 5 | ✔️ All covered |
| Confidentiality (C) | 5 | ✔️ All covered |
| Privacy (P) | 7 | ✔️ All covered |

## Gaps Closed

| # | Gap | Resolution | File |
|---|-----|-----------|------|
| 1 | Disaster Recovery Plan | RTO/RPO targets, failure scenarios, recovery procedures, testing schedule | `operations/disaster-recovery-plan.md` (S3) |
| 2 | Backup/Restore Procedure | DynamoDB PITR restore steps, S3 version restore, full system rebuild | `operations/backup-restore-procedure.md` (S3) |
| 3 | Access Offboarding | Step-by-step user disable/delete, emergency revocation, verification | `operations/access-offboarding-procedure.md` (S3) |
| 4 | Data Retention Policy | Full retention schedule per data type, subject rights (access/erasure/portability) | `policies/data-retention-policy.md` (S3) |
| 5 | Data Processing Consent | `X-Data-Consent` header support, implicit consent model, disclosure | `policies/data-processing-consent.md` (S3) + API code |
| 6 | Organizational Structure | RACI matrix, role definitions, oversight evidence | `governance/organizational-structure.md` (S3) |

## Evidence Locations

| What an Auditor Needs | Where to Find It |
|---|---|
| AI/Security policies | S3: `governance-docs` bucket → `policies/` |
| Risk assessment | S3: `governance-docs` → `risk-assessment/` |
| Org structure & RACI | S3: `governance-docs` → `governance/` |
| Operational procedures | S3: `governance-docs` → `operations/` |
| Change history | Terraform state + AppConfig deployment history |
| Access controls | Terraform IAM definitions (`iam.tf`, `auditor_role.tf`) |
| Monitoring evidence | CloudWatch dashboard + alarms |
| Incident handling | DynamoDB human_review_queue + SQS concerns queue |
| Data processing records | DynamoDB routing_audit_log + data_flow_log |
| Encryption evidence | KMS on Kinesis, S3 SSE, HTTPS on all endpoints |
| Availability evidence | Circuit breakers, fallback chains, auto-scaling config |
| Backup/recovery evidence | DynamoDB PITR enabled, S3 versioning, Terraform IaC |
