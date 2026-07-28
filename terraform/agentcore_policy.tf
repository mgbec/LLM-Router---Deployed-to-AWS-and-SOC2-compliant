# =============================================================================
# AgentCore Policy Engine (Cedar-based tool authorization)
# =============================================================================
# Provides fine-grained, deterministic access control over Gateway tool calls.
# Cedar policies are evaluated on every tool invocation — independent of OPA
# routing policies which handle business logic (cost, complexity, etc.).
#
# OPA = "Should we route this request?" (business logic)
# Cedar = "Is this agent allowed to call this tool?" (access control)
# =============================================================================

# -----------------------------------------------------------------------------
# Policy Engine
# A collection of Cedar policies attached to the Gateway
# -----------------------------------------------------------------------------

resource "aws_bedrockagentcore_policy_engine" "router" {
  name        = "${replace(local.name_prefix, "-", "_")}_policy_engine"
  description = "Cedar-based authorization for LLM Router gateway tool calls"

  tags = merge(local.common_tags, {
    Purpose = "gateway-tool-authorization"
  })
}

# -----------------------------------------------------------------------------
# Cedar Policies
# Each policy defines a permit or forbid rule for tool access
# -----------------------------------------------------------------------------

# Policy 1: Allow the router agent to call classification tools
resource "aws_bedrockagentcore_policy" "allow_classification" {
  name             = "allow_classification_tools"
  description      = "Permit the router agent to call complexity classification and data classification tools"
  policy_engine_id = aws_bedrockagentcore_policy_engine.router.policy_engine_id
  validation_mode  = "IGNORE_ALL_FINDINGS"

  definition {
    cedar {
      statement = <<-CEDAR
        permit(
          principal is AgentCore::IamEntity,
          action in [
            AgentCore::Action::"complexity-classifier___classify_complexity",
            AgentCore::Action::"data-classifier___classify_data_sensitivity"
          ],
          resource == AgentCore::Gateway::"${aws_bedrockagentcore_gateway.router.gateway_arn}"
        );
      CEDAR
    }
  }
}

# Policy 2: Allow the router agent to record feedback
resource "aws_bedrockagentcore_policy" "allow_feedback" {
  name             = "allow_feedback_recording"
  description      = "Permit the router agent to record quality feedback metrics"
  policy_engine_id = aws_bedrockagentcore_policy_engine.router.policy_engine_id
  validation_mode  = "IGNORE_ALL_FINDINGS"

  definition {
    cedar {
      statement = <<-CEDAR
        permit(
          principal is AgentCore::IamEntity,
          action == AgentCore::Action::"feedback-collector___record_feedback",
          resource == AgentCore::Gateway::"${aws_bedrockagentcore_gateway.router.gateway_arn}"
        );
      CEDAR
    }
  }
}

# Policy 3: Restrict model invocation tool to specific conditions
resource "aws_bedrockagentcore_policy" "restrict_model_invoke" {
  name             = "restrict_model_invocation"
  description      = "Permit model invocation tool only when provider is bedrock"
  policy_engine_id = aws_bedrockagentcore_policy_engine.router.policy_engine_id
  validation_mode  = "IGNORE_ALL_FINDINGS"

  definition {
    cedar {
      statement = <<-CEDAR
        permit(
          principal is AgentCore::IamEntity,
          action == AgentCore::Action::"model-invoker___invoke_model",
          resource == AgentCore::Gateway::"${aws_bedrockagentcore_gateway.router.gateway_arn}"
        ) when {
          context.input has provider &&
          context.input.provider == "bedrock"
        };
      CEDAR
    }
  }
}

# Policy 4: Forbid external model invocation without explicit flag
resource "aws_bedrockagentcore_policy" "forbid_external_without_flag" {
  name             = "forbid_external_without_consent"
  description      = "Deny model invocation to external providers unless explicitly enabled"
  policy_engine_id = aws_bedrockagentcore_policy_engine.router.policy_engine_id
  validation_mode  = "IGNORE_ALL_FINDINGS"

  definition {
    cedar {
      statement = <<-CEDAR
        forbid(
          principal is AgentCore::IamEntity,
          action == AgentCore::Action::"model-invoker___invoke_model",
          resource == AgentCore::Gateway::"${aws_bedrockagentcore_gateway.router.gateway_arn}"
        ) when {
          context.input has provider &&
          context.input.provider == "external"
        } unless {
          context.input has x_data_consent &&
          context.input.x_data_consent == "all-providers"
        };
      CEDAR
    }
  }
}

# Policy 5: Default deny (catch-all) - uncomment to enforce strict mode
# resource "aws_bedrockagentcore_policy" "default_deny" {
#   name             = "default-deny"
#   description      = "Deny all tool calls not explicitly permitted"
#   policy_engine_id = aws_bedrockagentcore_policy_engine.router.id
#
#   policy_statement = <<-CEDAR
#     forbid(
#       principal,
#       action,
#       resource
#     );
#   CEDAR
#
#   tags = local.common_tags
# }

# -----------------------------------------------------------------------------
# Attach Policy Engine to Gateway
# Start in LOG_ONLY mode to validate before enforcing
# -----------------------------------------------------------------------------

# Note: This requires the gateway to be recreated or updated.
# The policy_engine_configuration is set on the gateway resource.
# Uncomment the block below in agentcore.tf to activate:
#
#   policy_engine_configuration {
#     arn  = aws_bedrockagentcore_policy_engine.router.arn
#     mode = "LOG_ONLY"  # Change to "ENFORCE" after validation
#   }

# For now, output the policy engine ARN for manual attachment
output "policy_engine_arn" {
  description = "AgentCore Policy Engine ARN (attach to gateway for Cedar enforcement)"
  value       = aws_bedrockagentcore_policy_engine.router.policy_engine_arn
}
