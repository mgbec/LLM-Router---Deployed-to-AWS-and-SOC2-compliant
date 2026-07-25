package llmrouter.routing

import future.keywords.in

# =============================================================================
# Unit Tests for Routing Policies
# Run: opa test policies/opa/ -v
# =============================================================================

# Test: System active allows requests
test_system_active_allows {
    allow_request with input as {"system_active": true}
}

# Test: System disabled blocks requests
test_system_disabled_blocks {
    not allow_request with input as {"system_active": false}
}

# Test: Enabled model is allowed
test_enabled_model_allowed {
    model_allowed with input as {
        "selected_model": "us.amazon.nova-lite-v1:0",
        "models_enabled": {"us.amazon.nova-lite-v1:0": true}
    }
}

# Test: Disabled model is blocked
test_disabled_model_blocked {
    not model_allowed with input as {
        "selected_model": "us.amazon.nova-pro-v1:0",
        "models_enabled": {"us.amazon.nova-pro-v1:0": false}
    }
}

# Test: External routing allowed with consent and no PII
test_external_allowed_with_consent {
    allow_external_routing with input as {
        "data_consent": "all-providers",
        "pii_scan_result": "clean"
    }
}

# Test: External routing blocked without consent
test_external_blocked_no_consent {
    not allow_external_routing with input as {
        "data_consent": "internal-only"
    }
}

# Test: External routing blocked with PII
test_external_blocked_pii {
    not allow_external_routing with input as {
        "data_consent": "all-providers",
        "pii_scan_result": "blocked"
    }
}

# Test: Within budget
test_within_budget {
    within_budget with input as {
        "estimated_cost": 0.003,
        "max_cost_per_request": 0.05
    }
}

# Test: Over budget
test_over_budget {
    not within_budget with input as {
        "estimated_cost": 0.10,
        "max_cost_per_request": 0.05
    }
}

# Test: Human review for specialized medical
test_human_review_medical {
    requires_human_review with input as {
        "complexity": "specialized",
        "sensitive_categories": ["medical"]
    }
}

# Test: No human review for simple
test_no_review_simple {
    not requires_human_review with input as {
        "complexity": "simple",
        "sensitive_categories": [],
        "quality_score": 0.9
    }
}

# Test: Budget-conscious user can't access complex tier
test_budget_user_no_complex {
    count(deny_reason) > 0 with input as {
        "complexity": "complex",
        "policy_id": "budget_conscious",
        "system_active": true,
        "selected_model": "us.anthropic.claude-opus-4-6-v1",
        "models_enabled": {"us.anthropic.claude-opus-4-6-v1": true}
    }
}

# Test: Rate limit for budget user
test_rate_limit_budget {
    rate_limit_exceeded with input as {
        "user_request_count_1h": 150,
        "policy_id": "budget_conscious"
    }
}

# Test: No rate limit under threshold
test_no_rate_limit {
    not rate_limit_exceeded with input as {
        "user_request_count_1h": 50,
        "policy_id": "budget_conscious"
    }
}
