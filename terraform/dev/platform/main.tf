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
