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
