# AgentCore Cedar Policies — Tool Authorization

## Overview

Cedar policies provide **deterministic access control** over Gateway tool calls. Every time an agent calls a tool through the Gateway, the Cedar policy engine evaluates whether the call is permitted.

This is separate from OPA routing policies:

| Layer | Language | Evaluates | Purpose |
|-------|----------|-----------|---------|
| **OPA** | Rego | Before routing | Business logic (cost, complexity, consent, rate limits) |
| **Cedar** | Cedar | At Gateway | Access control (who can call what tool, under what conditions) |

## Architecture

```
Agent → Gateway → Cedar Policy Engine → Allow/Deny → Tool Lambda
                       │
                       ├── Check: Is this principal allowed to call this tool?
                       ├── Check: Are the arguments within permitted bounds?
                       └── Check: Do conditions (context, headers) allow it?
```

## Policies Defined

### 1. Allow Classification Tools
```cedar
permit(
  principal,
  action == Action::"InvokeTool",
  resource in [
    Tool::"complexity-classifier___classify_complexity",
    Tool::"data-classifier___classify_data_sensitivity"
  ]
);
```
Any authenticated principal can classify prompts and check data sensitivity.

### 2. Allow Feedback Recording
```cedar
permit(
  principal,
  action == Action::"InvokeTool",
  resource == Tool::"feedback-collector___record_feedback"
);
```
Any authenticated principal can record quality feedback.

### 3. Restrict Model Invocation to Bedrock
```cedar
permit(
  principal,
  action == Action::"InvokeTool",
  resource == Tool::"model-invoker___invoke_model"
) when {
  context.arguments.provider == "bedrock"
};
```
Model invocation is only permitted when the provider is `bedrock`. External providers need additional authorization.

### 4. Forbid External Without Consent
```cedar
forbid(
  principal,
  action == Action::"InvokeTool",
  resource == Tool::"model-invoker___invoke_model"
) when {
  context.arguments.provider == "external"
} unless {
  context.headers.x_data_consent == "all-providers"
};
```
External provider calls are explicitly forbidden unless the `X-Data-Consent: all-providers` header is present. This is a hard enforcement — even if OPA allows it, Cedar blocks it without consent.

### 5. Default Deny (Optional, Strict Mode)
```cedar
forbid(
  principal,
  action,
  resource
);
```
When enabled, this creates a default-deny posture. Only explicitly permitted tool calls go through. Currently commented out — enable after validating all permit rules are correct.

## Deployment Modes

| Mode | Behavior | Use When |
|------|----------|----------|
| `LOG_ONLY` | Evaluates policies, logs decisions, but allows all calls | Testing new policies, initial deployment |
| `ENFORCE` | Evaluates policies and blocks denied calls | Production, after validation |

Current setting: **LOG_ONLY** (safe to deploy, validates without breaking anything).

To switch to enforcement:
```hcl
# In terraform/agentcore.tf
policy_engine_configuration {
  arn  = aws_bedrockagentcore_policy_engine.router.arn
  mode = "ENFORCE"  # ← change from LOG_ONLY
}
```

## How Cedar Differs from IAM

| | IAM | Cedar (AgentCore Policy) |
|---|---|---|
| Scope | AWS API calls | Tool invocations within a Gateway |
| Granularity | Action + Resource ARN | Tool + Arguments + Context |
| Context | Caller identity, tags | Request headers, tool arguments, OAuth claims |
| Evaluation | Before AWS API | Inside the Gateway, before tool Lambda |

Example: IAM allows the agent's role to call `bedrock-agentcore:InvokeGateway`. But Cedar controls WHICH tools within that gateway the agent can call, and under WHAT conditions.

## Observability

When the policy engine is attached (even in LOG_ONLY mode), you can see:
- Every tool call evaluation in AgentCore Observability
- Allow/deny decisions per tool
- Which policy matched
- The context that was evaluated

## Relevant Files

| File | Purpose |
|------|---------|
| `terraform/agentcore_policy.tf` | Policy engine + Cedar policy definitions |
| `terraform/agentcore.tf` | Gateway with `policy_engine_configuration` |
