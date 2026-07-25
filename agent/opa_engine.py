"""
Lightweight OPA Policy Engine for the LLM Router Agent.

Evaluates routing policies defined in Rego-compatible logic.
For production, this can be swapped with a full OPA sidecar or
the OPA WASM runtime. This implementation mirrors the Rego policies
in policies/opa/routing.rego for in-process evaluation.

Decision logs are emitted for audit compliance.
"""

import json
import time
import logging
from typing import Any

logger = logging.getLogger(__name__)


class PolicyDecision:
    """Result of a policy evaluation."""

    def __init__(self):
        self.allow = True
        self.model_allowed = True
        self.external_allowed = False
        self.within_budget = True
        self.requires_review = False
        self.deny_reasons: list[str] = []

    @property
    def denied(self) -> bool:
        return not self.allow or not self.model_allowed

    def to_dict(self) -> dict:
        return {
            "allow": self.allow,
            "model_allowed": self.model_allowed,
            "external_allowed": self.external_allowed,
            "within_budget": self.within_budget,
            "requires_review": self.requires_review,
            "deny_reasons": self.deny_reasons,
        }


class OPAPolicyEngine:
    """
    Evaluates routing policies against request context.
    Mirrors the Rego policies in policies/opa/routing.rego.
    """

    def __init__(self):
        self._decision_log: list[dict] = []

    def evaluate(self, input_data: dict) -> PolicyDecision:
        """
        Evaluate all routing policies against the given input.
        
        Expected input:
        {
            "prompt": str,
            "user_id": str,
            "policy_id": str,
            "selected_model": str,
            "complexity": str,
            "provider": str,
            "estimated_cost": float,
            "max_cost_per_request": float,
            "system_active": bool,
            "models_enabled": dict,
            "data_consent": str,
            "sensitive_categories": list,
            "pii_scan_result": str,
            "quality_score": float,
            "user_request_count_1h": int,
        }
        """
        start = time.time()
        decision = PolicyDecision()

        # Rule: System Kill Switch
        if not input_data.get("system_active", True):
            decision.allow = False
            decision.deny_reasons.append("System is disabled by operator")

        # Rule: Model Must Be Enabled
        model = input_data.get("selected_model", "")
        models_enabled = input_data.get("models_enabled", {})
        if model in models_enabled and models_enabled[model] is False:
            decision.model_allowed = False
            decision.deny_reasons.append(f"Model {model} is disabled")

        # Rule: External Routing Requires Consent
        provider = input_data.get("provider", "bedrock")
        consent = input_data.get("data_consent", "internal-only")
        pii_result = input_data.get("pii_scan_result", "clean")

        if provider == "external":
            if consent == "all-providers" and pii_result != "blocked":
                decision.external_allowed = True
            else:
                decision.external_allowed = False
                if consent != "all-providers":
                    decision.deny_reasons.append("External routing blocked: no consent")
                if pii_result == "blocked":
                    decision.deny_reasons.append("External routing blocked: PII detected")

        # Rule: Budget Enforcement
        cost = input_data.get("estimated_cost", 0)
        budget = input_data.get("max_cost_per_request", 0.05)
        if cost > budget:
            decision.within_budget = False
            decision.deny_reasons.append(
                f"Cost ${cost:.4f} exceeds budget ${budget:.4f}"
            )

        # Rule: Human Review Required
        complexity = input_data.get("complexity", "simple")
        categories = input_data.get("sensitive_categories", [])
        quality = input_data.get("quality_score", 1.0)

        if complexity == "specialized":
            sensitive = {"medical", "legal", "financial"}
            if any(c in sensitive for c in categories):
                decision.requires_review = True

        if 0 < quality < 0.5:
            decision.requires_review = True

        # Rule: Model Tier Access
        policy_id = input_data.get("policy_id", "default")
        if complexity == "complex" and policy_id == "budget_conscious":
            decision.deny_reasons.append(
                "User policy does not permit complex tier models"
            )

        # Rule: Rate Limiting
        request_count = input_data.get("user_request_count_1h", 0)
        if policy_id == "budget_conscious" and request_count > 100:
            decision.deny_reasons.append("Rate limit exceeded for your policy tier")
        elif policy_id == "default" and request_count > 1000:
            decision.deny_reasons.append("Rate limit exceeded for your policy tier")

        # Log the decision
        elapsed_ms = (time.time() - start) * 1000
        self._log_decision(input_data, decision, elapsed_ms)

        return decision

    def _log_decision(self, input_data: dict, decision: PolicyDecision, elapsed_ms: float):
        """Log policy decision for audit trail."""
        log_entry = {
            "timestamp": int(time.time()),
            "user_id": input_data.get("user_id", ""),
            "model": input_data.get("selected_model", ""),
            "policy_id": input_data.get("policy_id", ""),
            "decision": decision.to_dict(),
            "evaluation_ms": round(elapsed_ms, 2),
        }

        # Keep last 100 decisions in memory (for debugging)
        self._decision_log.append(log_entry)
        if len(self._decision_log) > 100:
            self._decision_log.pop(0)

        if decision.denied:
            logger.warning(f"OPA DENY: {decision.deny_reasons} (model={input_data.get('selected_model')})")
        else:
            logger.debug(f"OPA ALLOW: model={input_data.get('selected_model')}, cost=${input_data.get('estimated_cost', 0):.4f}")

    def get_recent_decisions(self, limit: int = 10) -> list[dict]:
        """Get recent policy decisions (for debugging/audit)."""
        return self._decision_log[-limit:]
