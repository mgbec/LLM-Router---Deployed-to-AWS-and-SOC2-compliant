# Compliance Comparison: ISO 42001 vs SOC 2

## Overview

This project implements controls for both ISO/IEC 42001:2023 (AI Management Systems) and SOC 2 (Trust Services Criteria). While they address different concerns, there is significant overlap in the technical controls. This document compares coverage across both frameworks.

## At a Glance

| Framework | Total Controls | Fully Covered | Partially Covered | Gaps |
|-----------|---------------|---------------|-------------------|------|
| **ISO 42001** (Annex A) | 39 | 30 | 8 | 1 |
| **SOC 2** (TSC) | 35 | 35 | 0 | 0 |

**ISO 42001** has more remaining partial items because it requires organizational processes (bias testing protocols, formal competency frameworks) that are documented but not yet actively exercised.

**SOC 2** is fully closed because the gaps were all documentation — once we added the DR plan, backup procedure, offboarding process, data retention policy, consent mechanism, and org structure, all TSC controls are addressable.

---

## Where They Overlap

Many components serve both frameworks simultaneously:

| Component | ISO 42001 Control | SOC 2 Control | What It Does |
|-----------|------------------|---------------|--------------|
| Cognito + API Gateway | — | CC6.1, CC6.6, CC6.8 | Authentication and access control |
| IAM Least Privilege | — | CC6.2 | Role-scoped permissions |
| Bedrock Guardrails | A.9.4 (Responsible Use) | PI1.2, PI1.3 | Input/output content filtering |
| Data Classification | A.7.5 (Data Acquisition) | C1.1, CC6.7 | PII detection, data residency |
| Provenance Audit Log | A.7.6 (Data Provenance) | PI1.4, C1.2 | Full lineage per request |
| Human Oversight (Kill Switch) | A.9.5 (Human Oversight) | CC9.1 | Emergency risk mitigation |
| Concern Reporting | A.3.3 (Reporting Concerns) | P8.1 | Privacy/quality monitoring |
| CloudWatch + X-Ray | A.6.2.6 (Monitoring) | CC4.1, CC4.2 | Observability and anomaly detection |
| AppConfig Hot-Swap | A.6.2.5 (Deployment) | CC8.1 | Change management |
| Terraform IaC | A.6.2.5 (Deployment) | CC5.1, CC8.1 | Repeatable, auditable infrastructure |
| Risk Register | A.5.2 (Risk Assessment) | CC3.1-3.4 | Risk identification and mitigation |
| AI Policy | A.2.2 (AI Policy) | CC1.1 | Control environment / governance |
| Acceptable Use Policy | A.6.2.10 (Defined Use) | P4.1 | Data use restrictions |
| Model Cards | A.6.2.9 (Documentation) | CC2.1 | Communication about system |
| Circuit Breakers | A.6.2.6 (Operation) | A1.1, CC7.1 | Availability and resilience |
| Encryption (KMS, HTTPS) | — | C1.4 | Confidentiality in transit/rest |
| Auditor Role | Clause 9 (Performance Eval) | CC4.2 | Independent audit access |
| DynamoDB PITR | — | A1.3, A1.4 | Backup and recovery |
| S3 Versioning | A.6.2.9 (Documentation) | A1.4 | Document history and recovery |
| OPA Routing Policies | A.9.3, A.9.4, A.9.5 | CC5.1, CC6.7, P2.1 | Testable business rules as code — budget, consent, rate limits |
| Cedar Tool Policies | A.9.5, A.6.2.8 | CC6.1, CC6.2, CC6.8, C1.5 | Infrastructure-level tool authorization (cannot be bypassed in code) |

---

## Policy Enforcement Layers (Defense-in-Depth)

Both frameworks benefit from the dual-layer policy architecture:

```
Request → OPA (Rego)     → "Should this routing decision happen?"
              ↓ ALLOW
         → Gateway       → Cedar  → "Is this tool call authorized?"
              ↓ ALLOW
         → Tool executes
```

| Property | OPA (Business Logic) | Cedar (Access Control) |
|----------|---------------------|----------------------|
| Language | Rego | Cedar |
| Runs at | Inside container (sidecar) | AWS-managed (Gateway) |
| Can be bypassed by code change? | Yes (if someone modifies agent) | No (enforced by AWS) |
| Unit testable? | Yes (`opa test`) | Yes (Cedar validation) |
| Audit evidence | Decision logs in container | AgentCore Observability |
| Fail mode | Configurable (we use fail-open) | Always enforced (fail-closed in ENFORCE mode) |

**For auditors**: OPA provides evidence that business rules are tested and enforceable. Cedar provides evidence that access controls are enforced at the infrastructure layer regardless of application code correctness. Together they demonstrate defense-in-depth — a core security principle for both frameworks.

**Controls this strengthens**:
- ISO A.9.5 (Human Oversight): Policies can NEVER be bypassed — even if agent code is modified
- SOC CC5.1 (Control Activities): Policies-as-code = documented, tested, version-controlled controls
- SOC CC6.8 (Prevent Unauthorized): Cedar prevents tool access even if IAM allows gateway access

---

## Where They Differ

### ISO 42001 — Unique Requirements (AI-Specific)

These controls exist ONLY in ISO 42001 and have no direct SOC 2 equivalent:

| ISO 42001 Control | What It Requires | Our Implementation |
|-------------------|-----------------|-------------------|
| A.5.3 Impact Assessment | Assess impact on individuals/society | Impact assessment document in S3 |
| A.6.2.3 Training & Testing | Bias testing of AI models | Partial — test suite exists, no formal bias protocol |
| A.6.2.7 Retirement | Decommissioning AI systems | Partial — AppConfig can disable, no formal process |
| A.7.3 Data Quality | Quality of data used for AI | Partial — weight bounds exist, no formal validation |
| A.7.6 Data Provenance | Track origin of AI outputs | Full provenance per request (WHO/WHAT/WHY/HOW/WHERE) |
| A.8.2 AI Disclosure | Inform users of AI interaction | Mandatory headers + frontend disclosure |
| A.8.3 Explain Outcomes | Explain AI decisions | `/v1/routing/explain/{id}` API |
| A.9.3 Intended Use | Define AI system boundaries | Acceptable Use Policy with prohibited uses |
| A.10.3 Shared Models | Manage pre-trained model risks | Model cards with provenance per model |

### SOC 2 — Unique Requirements (Operational/Security)

These TSC controls exist ONLY in SOC 2 and have no direct ISO 42001 equivalent:

| SOC 2 Control | What It Requires | Our Implementation |
|---------------|-----------------|-------------------|
| A1.3 Recovery (RTO/RPO) | Defined recovery objectives | DR plan with 30 min RTO, 5 min RPO |
| A1.4 Backup Testing | Proven restore capability | Documented PITR restore procedure |
| CC6.3 Access Removal | Offboarding procedure | Cognito disable/delete workflow |
| C1.3 Data Disposal | Defined retention and deletion | Data retention policy with TTLs |
| P2.1 Consent | User choice on data processing | `X-Data-Consent` header, consent policy |
| CC1.1 Control Environment | Org structure and oversight | RACI matrix, role definitions |

---

## Shared Evidence Locations

An auditor reviewing either framework can find evidence in the same places:

| Evidence Type | Location | Serves |
|---------------|----------|--------|
| Policies (AI, acceptable use, retention, consent) | S3 governance bucket → `policies/` | Both |
| Risk assessment + impact assessment | S3 → `risk-assessment/` | Both |
| Org structure + RACI | S3 → `governance/` | Both |
| Operational procedures (DR, backup, offboarding) | S3 → `operations/` | SOC 2 |
| Model cards | S3 → `model-cards/` | ISO 42001 |
| Routing decisions (provenance) | DynamoDB `routing-audit-log` | Both |
| Data flow decisions | DynamoDB `data-flow-log` | Both |
| Human oversight actions | DynamoDB `human-review-queue` | Both |
| Configuration state | AppConfig deployment history | Both |
| Change history | Terraform state + Git history | Both |
| Monitoring | CloudWatch dashboard + alarms | Both |
| Traces | X-Ray | Both |
| Access controls | Terraform IAM definitions | Both |

---

## Effort Comparison

| Activity | ISO 42001 Remaining | SOC 2 Remaining |
|----------|--------------------|-----------------| 
| Formal bias testing protocol | Needed (1 week) | Not required |
| Model retirement procedure | Needed (1 day) | Not required |
| Stakeholder consultation process | Needed (1 day) | Not required |
| Internal audit schedule | Recommended (1 day) | Recommended (1 day) |
| Board sign-off on policies | Needed for certification | Needed for Type II |
| Annual DR test | Not required | Needed |
| Annual penetration test | Not required | Recommended |
| Formal competency framework | Needed (2 days) | Not required |

---

## Recommendation

If pursuing **both certifications**:
1. Address ISO 42001 remaining items first (bias testing, model retirement, competency framework) — these are harder and more AI-specific
2. SOC 2 then comes almost for free since all technical controls and documentation are already in place
3. The shared evidence base means a single governance S3 bucket serves both auditors
4. The read-only auditor IAM role works for both reviews

If pursuing **one first**:
- **SOC 2** is faster to certify (all gaps closed, standard is well-understood by auditors)
- **ISO 42001** demonstrates more differentiated AI governance (newer standard, shows leadership)
