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

# ── Component 3: Kinesis Firehose + firehose_delivery IAM role ───────────────
# Delivers CloudWatch metric stream records to AMP via remote_write.
# S3 backup captures only FailedDataOnly — successful records are not
# duplicated to S3. S3 backup is encrypted with the foundation KMS key.
#
# URL: AMP prometheus_endpoint already ends with "/"; appending
# "api/v1/remote_write" produces the correct remote write path.

resource "aws_iam_role" "firehose_delivery" {
  name = "ai-observability-firehose-delivery-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "firehose.amazonaws.com" }
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

resource "aws_iam_role_policy" "firehose_delivery" {
  name = "amp-s3-kms-delivery"
  role = aws_iam_role.firehose_delivery.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AMPRemoteWrite"
        Effect   = "Allow"
        Action   = ["aps:RemoteWrite"]
        Resource = aws_prometheus_workspace.this.arn
      },
      {
        Sid    = "FirehoseBufferS3"
        Effect = "Allow"
        Action = ["s3:PutObject"]
        Resource = "${data.terraform_remote_state.foundation.outputs.firehose_buffer_bucket_arn}/*"
      },
      {
        Sid    = "KMSEncryption"
        Effect = "Allow"
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt"
        ]
        Resource = data.terraform_remote_state.foundation.outputs.kms_key_arn
      }
    ]
  })
}

resource "aws_kinesis_firehose_delivery_stream" "this" {
  name        = "ai-observability-amp-delivery-${var.environment}"
  destination = "http_endpoint"

  http_endpoint_configuration {
    url                = "${aws_prometheus_workspace.this.prometheus_endpoint}api/v1/remote_write"
    name               = "AMP Remote Write"
    role_arn           = aws_iam_role.firehose_delivery.arn
    buffering_size     = 5
    buffering_interval = 60
    retry_duration     = 30
    s3_backup_mode     = "FailedDataOnly"

    request_configuration {
      content_encoding = "GZIP"
    }

    s3_configuration {
      role_arn           = aws_iam_role.firehose_delivery.arn
      bucket_arn         = data.terraform_remote_state.foundation.outputs.firehose_buffer_bucket_arn
      buffering_size     = 5
      buffering_interval = 300
      compression_format = "GZIP"
      kms_key_arn        = data.terraform_remote_state.foundation.outputs.kms_key_arn
    }
  }

  tags = merge(local.tags, {
    Name      = "ai-observability-amp-delivery-${var.environment}"
    Component = "firehose"
  })
}

# ── Component 4: CloudWatch Metric Stream + cw_stream IAM role ───────────────
# Account-level metric stream in opentelemetry1.0 format — the only format
# AMP's remote write endpoint accepts from Firehose.
#
# Initial namespace filter: five AWS-native namespaces. Project-specific
# namespaces (e.g. AIPlatform/Quality) are added by the project-observer
# module when a project registers. Do not hardcode project namespaces here.

resource "aws_iam_role" "cw_stream" {
  name = "ai-observability-cw-stream-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "streams.metrics.cloudwatch.amazonaws.com" }
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

resource "aws_iam_role_policy" "cw_stream" {
  name = "firehose-put-record"
  role = aws_iam_role.cw_stream.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "FirehosePutRecord"
      Effect = "Allow"
      Action = [
        "firehose:PutRecord",
        "firehose:PutRecordBatch"
      ]
      Resource = aws_kinesis_firehose_delivery_stream.this.arn
    }]
  })
}

resource "aws_cloudwatch_metric_stream" "this" {
  name          = "ai-observability-metric-stream-${var.environment}"
  role_arn      = aws_iam_role.cw_stream.arn
  firehose_arn  = aws_kinesis_firehose_delivery_stream.this.arn
  output_format = "opentelemetry1.0"

  # AWS-native namespaces streamed at platform level.
  # Project namespaces added per-project by project-observer module.
  include_filter { namespace = "AWS/Lambda" }
  include_filter { namespace = "AWS/DynamoDB" }
  include_filter { namespace = "AWS/Bedrock" }
  include_filter { namespace = "AWS/AOSS" }
  include_filter { namespace = "AWS/States" }

  tags = merge(local.tags, {
    Name      = "ai-observability-metric-stream-${var.environment}"
    Component = "metric-stream"
  })
}
