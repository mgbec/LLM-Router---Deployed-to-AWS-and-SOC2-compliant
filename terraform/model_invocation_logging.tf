# =============================================================================
# Bedrock Model Invocation Logging
# Logs all model invocations (prompts + responses) to S3 and CloudWatch
# =============================================================================
# Provides:
#   - Full input/output for every Bedrock converse() call
#   - Which guardrail filters triggered and confidence scores
#   - Token usage and latency per invocation
#   - Required for detailed guardrail observability
#
# PRIVACY NOTE: This logs raw prompts and responses. Ensure this bucket
# has strict access controls. Only enable in environments where this is
# acceptable under your data retention and privacy policies.
# =============================================================================

# -----------------------------------------------------------------------------
# S3 Bucket for Model Invocation Logs
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "model_invocation_logs" {
  bucket = "${local.name_prefix}-model-invocation-logs-${local.account_id}"

  tags = merge(local.common_tags, {
    Purpose     = "bedrock-model-invocation-logging"
    DataClass   = "sensitive"
    Encryption  = "required"
  })
}

resource "aws_s3_bucket_versioning" "model_invocation_logs" {
  bucket = aws_s3_bucket.model_invocation_logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "model_invocation_logs" {
  bucket = aws_s3_bucket.model_invocation_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "model_invocation_logs" {
  bucket                  = aws_s3_bucket.model_invocation_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "model_invocation_logs" {
  bucket = aws_s3_bucket.model_invocation_logs.id

  rule {
    id     = "expire-old-logs"
    status = "Enabled"

    # Move to cheaper storage after 30 days
    transition {
      days          = 30
      storage_class = "GLACIER"
    }

    # Delete after 90 days (align with audit log retention)
    expiration {
      days = 90
    }
  }
}

# -----------------------------------------------------------------------------
# CloudWatch Log Group for Model Invocation Logs
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "model_invocation" {
  name              = "/aws/bedrock/model-invocation-logs/${local.name_prefix}"
  retention_in_days = var.log_retention_days

  tags = merge(local.common_tags, {
    Purpose = "bedrock-model-invocation-logging"
  })
}

# -----------------------------------------------------------------------------
# IAM Role for Bedrock to write logs
# -----------------------------------------------------------------------------

resource "aws_iam_role" "bedrock_logging" {
  name = "${local.name_prefix}-bedrock-logging-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "bedrock.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = local.account_id
          }
        }
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "bedrock_logging" {
  name = "${local.name_prefix}-bedrock-logging-policy"
  role = aws_iam_role.bedrock_logging.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3Write"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetBucketLocation"
        ]
        Resource = [
          aws_s3_bucket.model_invocation_logs.arn,
          "${aws_s3_bucket.model_invocation_logs.arn}/*"
        ]
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = [
          "${aws_cloudwatch_log_group.model_invocation.arn}:*"
        ]
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Bedrock Model Invocation Logging Configuration
# -----------------------------------------------------------------------------

resource "aws_bedrock_model_invocation_logging_configuration" "router" {
  logging_config {
    embedding_data_delivery_enabled = false
    image_data_delivery_enabled     = false
    text_data_delivery_enabled      = true

    s3_config {
      bucket_name = aws_s3_bucket.model_invocation_logs.id
      key_prefix  = "invocations/"
    }

    cloudwatch_config {
      log_group_name = aws_cloudwatch_log_group.model_invocation.name
      role_arn       = aws_iam_role.bedrock_logging.arn

      large_data_delivery_s3_config {
        bucket_name = aws_s3_bucket.model_invocation_logs.id
        key_prefix  = "large-payloads/"
      }
    }
  }
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "model_invocation_logs_bucket" {
  description = "S3 bucket containing Bedrock model invocation logs (prompts + responses)"
  value       = aws_s3_bucket.model_invocation_logs.id
}

output "model_invocation_log_group" {
  description = "CloudWatch log group for model invocation logs"
  value       = aws_cloudwatch_log_group.model_invocation.name
}
