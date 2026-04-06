terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

locals {
  tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
    Repository  = "ai-observability-platform"
    Layer       = "platform"
  }
}

# ── Foundation remote state ───────────────────────────────────────────────────
# IAM roles live in this layer so their policies can reference exact resource
# ARNs (AMP workspace, Firehose stream) — no account-scoped wildcards required.
# Foundation outputs consumed: kms_key_arn, firehose_buffer_bucket_arn,
# vpc_id, private_subnet_ids.

data "terraform_remote_state" "foundation" {
  backend = "s3"
  config = {
    bucket = "ai-observability-terraform-state-dev-${var.account_id}"
    key    = "dev/foundation/terraform.tfstate"
    region = "us-east-2"
  }
}

# ── Component 1: AMP Workspace ────────────────────────────────────────────────
# Single AMP workspace per environment. Encrypted with the foundation KMS key.
# Endpoint output is consumed by the Firehose delivery stream (Component 3)
# and by the project-observer module for each registered project.

resource "aws_prometheus_workspace" "this" {
  alias       = "ai-observability-${var.environment}"
  kms_key_arn = data.terraform_remote_state.foundation.outputs.kms_key_arn

  tags = merge(local.tags, {
    Name      = "ai-observability-amp-${var.environment}"
    Component = "amp"
  })
}

# ── Component 2: AMG Workspace + amg_datasource IAM role ─────────────────────
# The amg_datasource role must exist before the workspace is created —
# Terraform resolves this via the implicit dependency on role_arn.
#
# KMS note: aws_grafana_workspace does not expose a kms_key_arn argument
# in the hashicorp/aws provider 5.x. AMG workspaces use AWS-owned encryption
# by default. Customer-managed KMS for AMG requires manual configuration
# outside Terraform. This is a known provider gap — track upstream issue
# and add kms_key_arn once the provider exposes it.

resource "aws_iam_role" "amg_datasource" {
  name = "ai-observability-amg-datasource-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "grafana.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = var.account_id
        }
      }
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "amg_datasource" {
  name = "amp-cloudwatch-kms-query"
  role = aws_iam_role.amg_datasource.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AMPQuery"
        Effect = "Allow"
        Action = [
          "aps:QueryMetrics",
          "aps:GetLabels",
          "aps:GetSeries",
          "aps:GetMetricMetadata"
        ]
        Resource = aws_prometheus_workspace.this.arn
      },
      {
        Sid    = "CloudWatchAlarmState"
        Effect = "Allow"
        Action = [
          "cloudwatch:GetMetricData",
          "cloudwatch:ListMetrics",
          "cloudwatch:DescribeAlarmsForMetric"
        ]
        # CloudWatch metric APIs do not support resource-level ARN scoping.
        # This is a documented AWS service limitation — see CLAUDE.md IAM section.
        Resource = "*"
      },
      {
        Sid    = "KMSDecrypt"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey"
        ]
        Resource = data.terraform_remote_state.foundation.outputs.kms_key_arn
      }
    ]
  })
}

resource "aws_grafana_workspace" "this" {
  name                      = "ai-observability-${var.environment}"
  account_access_type       = "CURRENT_ACCOUNT"
  authentication_providers  = ["AWS_SSO"]
  permission_type           = "SERVICE_MANAGED"
  data_sources              = ["PROMETHEUS", "CLOUDWATCH"]
  notification_destinations = []
  role_arn                  = aws_iam_role.amg_datasource.arn

  tags = merge(local.tags, {
    Name      = "ai-observability-amg-${var.environment}"
    Component = "amg"
  })
}
