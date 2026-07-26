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
  name        = "${local.name_prefix}-policy-engine"
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
  name             = "allow-classification-tools"
  description      = "Permit the router agent to call complexity classification and data classification tools"
  policy_engine_id = aws_bedrockagentcore_policy_engine.router.id

  policy_statement = <<-CEDAR
    permit(
      principal,
      action == Action::"InvokeTool",
      resource in [
        Tool::"complexity-classifier___classify_complexity",
        Tool::"data-classifier___classify_data_sensitivity"
      ]
    );
  CEDAR

  tags = local.common_tags
}

# Policy 2: Allow the router agent to record feedback
resource "aws_bedrockagentcore_policy" "allow_feedback" {
  name             = "allow-feedback-recording"
  description      = "Permit the router agent to record quality feedback metrics"
  policy_engine_id = aws_bedrockagentcore_policy_engine.router.id

  policy_statement = <<-CEDAR
    permit(
      principal,
      action == Action::"InvokeTool",
      resource == Tool::"feedback-collector___record_feedback"
    );
  CEDAR

  tags = local.common_tags
}

# Policy 3: Restrict model invocation tool to specific conditions
resource "aws_bedrockagentcore_policy" "restrict_model_invoke" {
  name             = "restrict-model-invocation"
  description      = "Permit model invocation tool only when provider is bedrock"
  policy_engine_id = aws_bedrockagentcore_policy_engine.router.id

  policy_statement = <<-CEDAR
    permit(
      principal,
      action == Action::"InvokeTool",
      resource == Tool::"model-invoker___invoke_model"
    ) when {
      context.arguments.provider == "bedrock"
    };
  CEDAR

  tags = local.common_tags
}

# Policy 4: Forbid external model invocation without explicit flag
resource "aws_bedrockagentcore_policy" "forbid_external_without_flag" {
  name             = "forbid-external-without-consent"
  description      = "Deny model invocation to external providers unless explicitly enabled"
  policy_engine_id = aws_bedrockagentcore_policy_engine.router.id

  policy_statement = <<-CEDAR
    forbid(
      principal,
      action == Action::"InvokeTool",
      resource == Tool::"model-invoker___invoke_model"
    ) when {
      context.arguments.provider == "external"
    } unless {
      context.headers.x_data_consent == "all-providers"
    };
  CEDAR

  tags = local.common_tags
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
  value       = aws_bedrockagentcore_policy_engine.router.arn
}
