package llmrouter.routing

# =============================================================================
# LLM Router - OPA Routing Policies
# These policies are evaluated before every routing decision.
# =============================================================================

import future.keywords.in
import future.keywords.if

default allow_request = true
default allow_external_routing = false
default requires_human_review = false
default model_allowed = true

# -----------------------------------------------------------------------------
# Input Schema (provided by the agent at decision time):
# {
#   "prompt": "user prompt text",
#   "user_id": "cognito-sub-id",
#   "policy_id": "default",
#   "selected_model": "us.amazon.nova-pro-v1:0",
#   "complexity": "moderate",
#   "provider": "bedrock",
#   "estimated_cost": 0.003,
#   "system_active": true,
#   "models_enabled": {"us.amazon.nova-lite-v1:0": true, ...},
#   "data_consent": "internal-only"
# }
# -----------------------------------------------------------------------------

# =============================================================================
# RULE: System Kill Switch
# =============================================================================

allow_request = false if {
    not input.system_active
}

deny_reason["System is disabled by operator"] if {
    not input.system_active
}

# =============================================================================
# RULE: Model Must Be Enabled
# =============================================================================

model_allowed = false if {
    model := input.selected_model
    input.models_enabled[model] == false
}

deny_reason[msg] if {
    model := input.selected_model
    input.models_enabled[model] == false
    msg := sprintf("Model %s is disabled", [model])
}

# =============================================================================
# RULE: External Routing Requires Consent
# =============================================================================

allow_external_routing if {
    input.data_consent == "all-providers"
    not pii_detected
}

pii_detected if {
    input.pii_scan_result == "blocked"
}

deny_reason["External routing blocked: no consent"] if {
    input.provider == "external"
    input.data_consent != "all-providers"
}

deny_reason["External routing blocked: PII detected"] if {
    input.provider == "external"
    pii_detected
}

# =============================================================================
# RULE: Budget Enforcement
# =============================================================================

within_budget if {
    input.estimated_cost <= input.max_cost_per_request
}

deny_reason[msg] if {
    input.estimated_cost > input.max_cost_per_request
    msg := sprintf("Cost $%.4f exceeds budget $%.4f", [input.estimated_cost, input.max_cost_per_request])
}

# =============================================================================
# RULE: Human Review Required
# =============================================================================

requires_human_review if {
    input.complexity == "specialized"
    some category in input.sensitive_categories
    category in {"medical", "legal", "financial"}
}

requires_human_review if {
    input.quality_score < 0.5
    input.quality_score > 0
}

# =============================================================================
# RULE: Model Tier Access (user permissions)
# =============================================================================

user_can_access_tier if {
    input.policy_id == "enterprise"
}

user_can_access_tier if {
    input.complexity != "complex"
}

deny_reason["User policy does not permit complex tier models"] if {
    input.complexity == "complex"
    input.policy_id == "budget_conscious"
}

# =============================================================================
# RULE: Rate Limiting (per-user)
# =============================================================================

rate_limit_exceeded if {
    input.user_request_count_1h > 100
    input.policy_id == "budget_conscious"
}

rate_limit_exceeded if {
    input.user_request_count_1h > 1000
    input.policy_id == "default"
}

deny_reason["Rate limit exceeded for your policy tier"] if {
    rate_limit_exceeded
}

# =============================================================================
# FINAL DECISION
# =============================================================================

# Aggregate decision
decision = {
    "allow": allow_request,
    "model_allowed": model_allowed,
    "external_allowed": allow_external_routing,
    "within_budget": within_budget,
    "requires_review": requires_human_review,
    "deny_reasons": deny_reason,
}
