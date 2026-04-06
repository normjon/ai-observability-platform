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
# Read foundation outputs (KMS key ARN, S3 buffer bucket ARN, VPC/subnet IDs).
# IAM roles live in this layer so they can reference Firehose and AMP workspace
# ARNs directly — eliminating the account-scoped wildcard that would be required
# if they lived in foundation. See CLAUDE.md IAM Requirements for rationale.

data "terraform_remote_state" "foundation" {
  backend = "s3"
  config = {
    bucket = "ai-observability-terraform-state-dev-${var.account_id}"
    key    = "dev/foundation/terraform.tfstate"
    region = "us-east-2"
  }
}

# ── AMP workspace ─────────────────────────────────────────────────────────────
# Defined here — IAM roles below reference this ARN directly.
# (Resource body to be completed in the platform layer build PR)

resource "aws_prometheus_workspace" "this" {
  alias = "ai-observability-${var.environment}"

  kms_key_arn = data.terraform_remote_state.foundation.outputs.kms_key_arn

  tags = merge(local.tags, {
    Name = "ai-observability-amp-${var.environment}"
  })
}

# ── Kinesis Firehose delivery stream ─────────────────────────────────────────
# Defined here — the CW stream IAM role references this ARN directly.
# (Resource body to be completed in the platform layer build PR)

resource "aws_kinesis_firehose_delivery_stream" "this" {
  name        = "ai-observability-firehose-${var.environment}"
  destination = "http_endpoint"

  http_endpoint_configuration {
    url                = aws_prometheus_workspace.this.prometheus_endpoint
    name               = "AMP remote write"
    buffering_size     = 1
    buffering_interval = 60
    role_arn           = aws_iam_role.firehose_delivery.arn
    retry_duration     = 60
    s3_backup_mode     = "FailedDataOnly"

    request_configuration {
      content_encoding = "GZIP"
    }
  }

  s3_configuration {
    role_arn           = aws_iam_role.firehose_delivery.arn
    bucket_arn         = data.terraform_remote_state.foundation.outputs.firehose_buffer_bucket_arn
    buffering_size     = 5
    buffering_interval = 300
    compression_format = "GZIP"
  }

  tags = merge(local.tags, {
    Name = "ai-observability-firehose-${var.environment}"
  })
}

# ── IAM role: CloudWatch metric stream delivery ───────────────────────────────
# Trust: CloudWatch Streams service. Allows the account-level metric stream
# to put records into the Kinesis Firehose delivery stream.
# Exact Firehose ARN available here — no wildcard required.

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

# ── IAM role: Kinesis Firehose delivery to AMP ────────────────────────────────
# Trust: Firehose service. Allows the delivery stream to remote-write into
# AMP, buffer to S3, and use KMS for encryption.
# Exact AMP workspace ARN and S3 bucket ARN available here — no wildcards.

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

# ── IAM role: AMG data source access ─────────────────────────────────────────
# Trust: Grafana service. Allows AMG to query AMP metrics and read
# CloudWatch alarm state.
# Exact AMP workspace ARN available here — no wildcard required.
# CloudWatch actions on "*" is a documented AWS service limitation — the
# CloudWatch metric APIs do not support resource-level ARN scoping.

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
  name = "amp-cloudwatch-query"
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
      }
    ]
  })
}
