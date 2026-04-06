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
    Layer       = "foundation"
  }
}

# ── Networking ────────────────────────────────────────────────────────────────
# Isolated VPC: 10.1.0.0/16. No peering. No internet gateway.
# See CLAUDE.md Networking section for CIDR allocation conventions.

module "networking" {
  source = "../../modules/networking"

  environment = var.environment
  vpc_cidr    = "10.1.0.0/16"

  private_subnets = {
    "us-east-2a" = "10.1.1.0/24"
    "us-east-2b" = "10.1.2.0/24"
  }

  tags = local.tags
}

# ── KMS key ───────────────────────────────────────────────────────────────────
# Single symmetric key used for AMP workspace and AMG workspace encryption.
# Automatic rotation enabled. ARN exported for use by the platform layer.

resource "aws_kms_key" "observability" {
  description             = "AI observability platform encryption key — ${var.environment}"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = merge(local.tags, {
    Name = "ai-observability-kms-${var.environment}"
  })
}

resource "aws_kms_alias" "observability" {
  name          = "alias/ai-observability-${var.environment}"
  target_key_id = aws_kms_key.observability.key_id
}

# ── S3 Firehose buffer bucket ─────────────────────────────────────────────────
# Kinesis Firehose requires an S3 buffer for failed or backed-up delivery.
# Foundation owns this bucket; the platform layer Firehose resource references
# the ARN via remote state. Versioning and server-side encryption enabled.

resource "aws_s3_bucket" "firehose_buffer" {
  bucket = "ai-observability-firehose-buffer-${var.environment}-${var.account_id}"

  tags = merge(local.tags, {
    Name    = "ai-observability-firehose-buffer-${var.environment}"
    Purpose = "kinesis-firehose-buffer"
  })
}

resource "aws_s3_bucket_versioning" "firehose_buffer" {
  bucket = aws_s3_bucket.firehose_buffer.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "firehose_buffer" {
  bucket = aws_s3_bucket.firehose_buffer.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.observability.arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "firehose_buffer" {
  bucket                  = aws_s3_bucket.firehose_buffer.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

# ── IAM role: CloudWatch metric stream delivery ───────────────────────────────
# Trust: CloudWatch Streams service. Allows the account-level metric stream
# to put records into the Kinesis Firehose delivery stream.
#
# ARN scope note: The Firehose delivery stream ARN is created in the platform
# layer (applies after foundation). Scoped to account-level wildcard
# (arn:aws:firehose:region:account:deliverystream/*) as a known gap.
# Tighten to exact stream ARN in a follow-up PR once platform outputs are known.
# ADR-012: Upstream gap pattern — document and patch; do not use bare "*".

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
      # Scoped to this account's Firehose streams. Exact stream ARN will be
      # locked in once the platform layer delivery stream is created. (ADR-012)
      Resource = "arn:aws:firehose:${var.aws_region}:${var.account_id}:deliverystream/*"
    }]
  })
}

# ── IAM role: Kinesis Firehose delivery to AMP ────────────────────────────────
# Trust: Firehose service. Allows the delivery stream to remote-write into
# AMP, buffer to S3, and use KMS for encryption.
#
# ARN scope note: The AMP workspace ARN is created in the platform layer.
# Scoped to account-level wildcard for aps:RemoteWrite. (ADR-012 gap pattern)
# Tighten to exact workspace ARN in a follow-up PR after platform apply.

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
        Sid    = "AMPRemoteWrite"
        Effect = "Allow"
        Action = ["aps:RemoteWrite"]
        # AMP workspace ARN created in platform layer. Account-scoped wildcard
        # until exact workspace ARN is available post-platform apply. (ADR-012)
        Resource = "arn:aws:aps:${var.aws_region}:${var.account_id}:workspace/*"
      },
      {
        Sid    = "FirehoseBufferS3"
        Effect = "Allow"
        Action = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.firehose_buffer.arn}/*"
      },
      {
        Sid    = "KMSEncryption"
        Effect = "Allow"
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt"
        ]
        Resource = aws_kms_key.observability.arn
      }
    ]
  })
}

# ── IAM role: AMG data source access ─────────────────────────────────────────
# Trust: Grafana service. Allows AMG to query AMP metrics and read
# CloudWatch alarm state.
#
# ARN scope note: The AMP workspace ARN is created in the platform layer.
# Scoped to account-level wildcard for APS actions. (ADR-012 gap pattern)
# CloudWatch actions on "*" is a documented CW service limitation — all
# CloudWatch metric APIs require account-level scope (CLAUDE.md IAM section).

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
        # AMP workspace ARN created in platform layer. Account-scoped wildcard
        # until exact workspace ARN is available post-platform apply. (ADR-012)
        Resource = "arn:aws:aps:${var.aws_region}:${var.account_id}:workspace/*"
      },
      {
        Sid    = "CloudWatchAlarmState"
        Effect = "Allow"
        Action = [
          "cloudwatch:GetMetricData",
          "cloudwatch:ListMetrics",
          "cloudwatch:DescribeAlarmsForMetric"
        ]
        # CloudWatch metric APIs do not support resource-level scoping.
        # This is a documented AWS service limitation — see CLAUDE.md IAM section.
        Resource = "*"
      }
    ]
  })
}
