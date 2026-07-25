# OPA (Open Policy Agent) in the LLM Router

## What is OPA?

OPA is a policy engine. It answers one question: **"Is this action allowed?"**

You write rules in a language called Rego. You send OPA the context of what's happening, and it tells you yes or no (and why not). The rules are separate from your application code — you can change policies without changing code.

Think of it like a bouncer at a club. The bouncer has a list of rules (dress code, guest list, capacity). When someone shows up, the bouncer checks the rules and makes a decision. The bouncer doesn't care what happens inside the club — they just enforce the entry policy.

## Why OPA in This Project?

Before OPA, routing decisions were enforced by Python if/else statements scattered throughout `app.py`. That works, but:

- **Hard to audit**: An auditor has to read Python code to understand what's enforced
- **Hard to test**: Policy logic is tangled with business logic
- **Hard to change**: Modifying a policy rule means changing application code and redeploying
- **No single source of truth**: Same rule might be enforced differently in different places

With OPA:

- **Policies are declarative files** — readable even by non-developers
- **Testable independently** — `opa test policies/opa/ -v` runs in seconds
- **Auditable** — the `.rego` file IS the policy, not a code comment claiming a policy exists
- **Changeable without code changes** — update the `.rego` file, rebuild container, done

## How It Works in This Project

```
 User Request
      │
      ▼
 ┌─────────────────────────────────────────────┐
 │ Agent Container                              │
 │                                              │
 │  1. Classify complexity                      │
 │  2. Select candidate model                   │
 │  3. Ask OPA: "Can I use this model          │
 │     for this user with this budget?"         │
 │         │                                    │
 │         ▼                                    │
 │  ┌──────────────┐                           │
 │  │ OPA Sidecar  │ ← evaluates routing.rego  │
 │  │ (port 8181)  │                           │
 │  └──────┬───────┘                           │
 │         │                                    │
 │         ▼                                    │
 │  4. OPA says ALLOW → invoke the model       │
 │     OPA says DENY  → return error/fallback  │
 │                                              │
 └─────────────────────────────────────────────┘
```

OPA runs as a background process inside the same container. The agent talks to it over `localhost:8181` — no network hop, sub-millisecond response.

## What OPA Enforces

Every time the agent is about to invoke a model, it sends OPA this context:

```json
{
  "system_active": true,
  "selected_model": "us.amazon.nova-pro-v1:0",
  "models_enabled": {"us.amazon.nova-pro-v1:0": true},
  "policy_id": "default",
  "complexity": "moderate",
  "provider": "bedrock",
  "estimated_cost": 0.003,
  "max_cost_per_request": 0.05,
  "data_consent": "internal-only",
  "user_request_count_1h": 42
}
```

OPA evaluates this against the rules and responds:

```json
{
  "allow": true,
  "model_allowed": true,
  "within_budget": true,
  "requires_review": false,
  "deny_reasons": []
}
```

If any rule denies the request, the agent doesn't invoke the model.

## The Rules (in Plain English)

| Rule | What It Checks | What Happens If Violated |
|------|---------------|--------------------------|
| **Kill Switch** | Is the system active? | All requests blocked |
| **Model Enabled** | Is this specific model turned on? | Try next model in tier |
| **External Consent** | Did the user consent to external providers? | Force internal routing |
| **PII Block** | Was PII detected in the prompt? | Block external routing |
| **Budget** | Does this request's cost exceed the per-request limit? | Block or downgrade model |
| **Human Review** | Is this a sensitive category (medical/legal/financial)? | Flag for human review |
| **Tier Access** | Does the user's policy allow this model tier? | Block complex models for budget users |
| **Rate Limit** | Has this user exceeded their hourly quota? | Block request |

## Where the Rules Live

```
policies/opa/
├── routing.rego          ← The actual rules (source of truth)
└── routing_test.rego     ← Unit tests for the rules
```

These files are copied into the Docker image at build time and loaded by OPA on startup.

## Changing a Policy

Example: You want to lower the rate limit for budget users from 100 to 50 requests/hour.

**Edit `policies/opa/routing.rego`:**
```rego
# Before
rate_limit_exceeded if {
    input.user_request_count_1h > 100
    input.policy_id == "budget_conscious"
}

# After
rate_limit_exceeded if {
    input.user_request_count_1h > 50
    input.policy_id == "budget_conscious"
}
```

**Test it:**
```bash
opa test policies/opa/ -v
```

**Deploy it:**
```bash
./scripts/deploy.sh
```

The new rule takes effect when the container restarts. No Python code changed.

## Testing Policies

```bash
# Run all policy unit tests
opa test policies/opa/ -v

# Example output:
# data.llmrouter.routing.test_system_active_allows: PASS (1.2ms)
# data.llmrouter.routing.test_system_disabled_blocks: PASS (0.8ms)
# data.llmrouter.routing.test_within_budget: PASS (0.5ms)
# ...
# 14/14 tests passed
```

Each test in `routing_test.rego` validates one scenario. You can add new tests for new rules.

## OPA vs AppConfig

Both control behavior without code changes. They serve different purposes:

| | OPA | AppConfig |
|---|---|---|
| **What it controls** | Whether an action is allowed | What value a setting has |
| **Decision type** | Allow/Deny | On/Off, percentage, threshold |
| **Evaluation** | Per-request, real-time | Polled every 30 seconds |
| **Examples** | "Can this user use Opus?" | "Is Opus enabled globally?" |
| **Change speed** | Requires container rebuild | Instant (no rebuild) |
| **Testable** | `opa test` with unit tests | Manual verification |

They work together: AppConfig says "Opus is enabled," OPA says "but this user's policy doesn't allow complex tier models."

## Terraform Validation (Bonus)

OPA also validates Terraform plans before deployment via Conftest:

```bash
terraform plan -out=plan.tfplan
terraform show -json plan.tfplan > plan.json
conftest test plan.json -p policies/terraform/
```

This catches infrastructure misconfigurations:
- DynamoDB tables without Point-in-Time Recovery
- Lambda functions without X-Ray tracing
- S3 buckets with public access
- Kinesis without KMS encryption
- IAM with unnecessary wildcard permissions

## Key Takeaway

OPA gives you **policy-as-code**: your routing rules are versioned, tested, auditable, and separate from application logic. When an ISO 42001 or SOC 2 auditor asks "how do you enforce budget limits?" — you point them at a 3-line Rego rule, not a 500-line Python file.
