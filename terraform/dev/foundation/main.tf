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
