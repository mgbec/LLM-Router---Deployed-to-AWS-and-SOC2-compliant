package terraform.validation

# =============================================================================
# Terraform Plan Validation Policies (Conftest)
# Validates Terraform plans before apply to prevent misconfigurations.
#
# Usage:
#   terraform plan -out=plan.tfplan
#   terraform show -json plan.tfplan > plan.json
#   conftest test plan.json -p policies/terraform/
# =============================================================================

import future.keywords.in
import future.keywords.if

# Helper: get all resources of a type from planned values
resources_by_type(type) = resources if {
    resources := [r |
        r := input.planned_values.root_module.resources[_]
        r.type == type
    ]
}

# =============================================================================
# RULE: All DynamoDB tables must have Point-in-Time Recovery enabled
# =============================================================================

deny[msg] if {
    tables := resources_by_type("aws_dynamodb_table")
    table := tables[_]
    pitr := table.values.point_in_time_recovery
    not pitr[_].enabled == true
    msg := sprintf("DynamoDB table '%s' must have Point-in-Time Recovery enabled", [table.values.name])
}

# =============================================================================
# RULE: All Lambda functions must have X-Ray tracing enabled
# =============================================================================

deny[msg] if {
    lambdas := resources_by_type("aws_lambda_function")
    lambda := lambdas[_]
    tracing := lambda.values.tracing_config
    not tracing[_].mode == "Active"
    msg := sprintf("Lambda '%s' must have X-Ray active tracing enabled", [lambda.values.function_name])
}

# =============================================================================
# RULE: No S3 buckets with public access
# =============================================================================

deny[msg] if {
    blocks := resources_by_type("aws_s3_bucket_public_access_block")
    block := blocks[_]
    block.values.block_public_acls != true
    msg := "S3 bucket public access block must block public ACLs"
}

deny[msg] if {
    blocks := resources_by_type("aws_s3_bucket_public_access_block")
    block := blocks[_]
    block.values.block_public_policy != true
    msg := "S3 bucket public access block must block public policies"
}

# =============================================================================
# RULE: KMS encryption on Kinesis streams
# =============================================================================

deny[msg] if {
    streams := resources_by_type("aws_kinesis_stream")
    stream := streams[_]
    stream.values.encryption_type != "KMS"
    msg := sprintf("Kinesis stream '%s' must use KMS encryption", [stream.values.name])
}

# =============================================================================
# RULE: IAM policies must not use wildcard resources (except for specific actions)
# =============================================================================

# Allowed wildcards (CloudWatch PutMetricData, X-Ray, etc. require *)
allowed_wildcard_actions := {
    "cloudwatch:PutMetricData",
    "xray:PutTraceSegments",
    "xray:PutTelemetryRecords",
    "xray:GetSamplingRules",
    "xray:GetSamplingTargets",
    "xray:GetSamplingStatisticSummaries",
    "xray:GetTraceSummaries",
    "xray:BatchGetTraces",
    "xray:GetServiceGraph",
    "xray:GetTraceGraph",
    "xray:GetInsight",
    "xray:GetInsightSummaries",
    "xray:GetGroup",
    "xray:GetGroups",
    "ecr:GetAuthorizationToken",
    "cloudwatch:GetMetricData",
    "cloudwatch:GetMetricStatistics",
    "cloudwatch:ListMetrics",
    "cloudwatch:GetDashboard",
    "cloudwatch:ListDashboards",
    "cloudwatch:DescribeAlarms",
}

warn[msg] if {
    policies := resources_by_type("aws_iam_role_policy")
    policy := policies[_]
    
    # Parse the policy document
    doc := json.unmarshal(policy.values.policy)
    statement := doc.Statement[_]
    
    # Check for wildcard resource
    statement.Resource == "*"
    
    # Check if any action is NOT in the allowed list
    action := statement.Action[_]
    not action in allowed_wildcard_actions
    
    msg := sprintf("IAM policy '%s' uses wildcard resource with action '%s'", [policy.values.name, action])
}

# =============================================================================
# RULE: AgentCore Runtime must use ARM64 (enforced by ECR image)
# =============================================================================

warn[msg] if {
    runtimes := resources_by_type("aws_bedrockagentcore_agent_runtime")
    runtime := runtimes[_]
    not contains(runtime.values.agent_runtime_artifact[_].container_configuration[_].container_uri, "arm64")
    msg := "AgentCore Runtime image should be built for ARM64 architecture"
}

# =============================================================================
# RULE: CloudWatch log groups must have retention set
# =============================================================================

deny[msg] if {
    groups := resources_by_type("aws_cloudwatch_log_group")
    group := groups[_]
    group.values.retention_in_days == 0
    msg := sprintf("CloudWatch log group '%s' must have retention_in_days set (not indefinite)", [group.values.name])
}

# =============================================================================
# RULE: API Gateway must have CORS configured
# =============================================================================

warn[msg] if {
    apis := resources_by_type("aws_apigatewayv2_api")
    api := apis[_]
    not api.values.cors_configuration
    msg := sprintf("API Gateway '%s' should have CORS configuration", [api.values.name])
}

# =============================================================================
# RULE: Secrets Manager must have recovery window
# =============================================================================

deny[msg] if {
    secrets := resources_by_type("aws_secretsmanager_secret")
    secret := secrets[_]
    secret.values.recovery_window_in_days < 7
    msg := sprintf("Secret '%s' must have at least 7-day recovery window", [secret.values.name])
}
