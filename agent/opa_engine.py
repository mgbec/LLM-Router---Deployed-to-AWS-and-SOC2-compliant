"""
OPA Policy Engine Client — calls the real OPA sidecar over localhost.

The OPA binary runs as a sidecar process (started in entrypoint.sh),
evaluating the actual Rego policies from policies/opa/routing.rego.

This client sends the routing context as input and receives the
policy decision. No Rego logic is duplicated in Python.
"""

import json
import time
import logging
import urllib.request
import urllib.error

logger = logging.getLogger(__name__)

OPA_URL = "http://localhost:8181/v1/data/llmrouter/routing/decision"


class PolicyDecision:
    """Result of a policy evaluation from OPA."""

    def __init__(self, raw: dict = None):
        if raw:
            self.allow = raw.get("allow", True)
            self.model_allowed = raw.get("model_allowed", True)
            self.external_allowed = raw.get("external_allowed", False)
            self.within_budget = raw.get("within_budget", True)
            self.requires_review = raw.get("requires_review", False)
            self.deny_reasons = raw.get("deny_reasons", [])
        else:
            # Default: allow everything (OPA unavailable fallback)
            self.allow = True
            self.model_allowed = True
            self.external_allowed = False
            self.within_budget = True
            self.requires_review = False
            self.deny_reasons = []

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
    Calls the OPA sidecar at localhost:8181 to evaluate routing policies.
    The Rego policies in /app/policies/ are the single source of truth.
    """

    def __init__(self, opa_url: str = OPA_URL):
        self.opa_url = opa_url
        self._available = None

    def _check_available(self) -> bool:
        """Check if OPA sidecar is running."""
        if self._available is not None:
            return self._available
        try:
            req = urllib.request.Request("http://localhost:8181/health", method="GET")
            with urllib.request.urlopen(req, timeout=1) as resp:
                self._available = resp.status == 200
        except Exception:
            self._available = False
            logger.warning("OPA sidecar not available — policies will not be enforced")
        return self._available

    def evaluate(self, input_data: dict) -> PolicyDecision:
        """
        Send input to OPA and get the policy decision.
        
        Calls: POST http://localhost:8181/v1/data/llmrouter/routing/decision
        Body: {"input": {...}}
        Response: {"result": {"allow": true, "deny_reasons": [], ...}}
        """
        if not self._check_available():
            # OPA not running — allow by default (fail-open)
            # In production, you may want fail-closed instead
            return PolicyDecision()

        start = time.time()

        try:
            body = json.dumps({"input": input_data}).encode("utf-8")
            req = urllib.request.Request(
                self.opa_url,
                data=body,
                headers={"Content-Type": "application/json"},
                method="POST",
            )

            with urllib.request.urlopen(req, timeout=5) as resp:
                result = json.loads(resp.read())
                decision_data = result.get("result", {})
                decision = PolicyDecision(decision_data)

            elapsed_ms = (time.time() - start) * 1000
            
            if decision.denied:
                logger.warning(
                    f"OPA DENY ({elapsed_ms:.1f}ms): {decision.deny_reasons} "
                    f"(model={input_data.get('selected_model')})"
                )
            else:
                logger.debug(f"OPA ALLOW ({elapsed_ms:.1f}ms)")

            return decision

        except urllib.error.URLError as e:
            logger.warning(f"OPA call failed: {e}")
            # Fail-open on OPA errors
            return PolicyDecision()
        except Exception as e:
            logger.warning(f"OPA evaluation error: {e}")
            return PolicyDecision()

    def get_recent_decisions(self, limit: int = 10) -> list[dict]:
        """Get recent decisions from OPA decision log (if configured)."""
        # OPA decision logging requires configuration — not implemented here
        # In production, configure OPA with --decision-logs pointing to a sink
        return []
