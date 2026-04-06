# Generated from project.yaml — do not edit manually.
# To update, modify project.yaml and re-run generation.
# Schema version: 1.0 (specs/project-yaml-schema.md)

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    grafana = {
      source  = "grafana/grafana"
      version = ">= 2.0"
    }
    http = {
      source  = "hashicorp/http"
      version = ">= 3.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Grafana provider uses an API key created from the AMG workspace.
# auth = "sigv4" is not supported in grafana/grafana 2.x.
# The API key is created out-of-band and passed via the GRAFANA_AUTH
# environment variable or the grafana_auth variable in tfvars.
# See modules/project-observer/README.md — Known limitations.
provider "grafana" {
  # AMG workspace endpoint does not include a scheme — prepend https://.
  # The amg_workspace_endpoint output is the bare hostname from aws_grafana_workspace.endpoint.
  url  = "https://${data.terraform_remote_state.platform.outputs.amg_workspace_endpoint}"
  auth = var.grafana_auth
}

provider "http" {}

# ── Platform remote state ─────────────────────────────────────────────────────
# Reads AMP workspace ID, AMG workspace ID, AMG endpoint, and Firehose ARN
# from the platform layer. Never reads foundation state directly.

data "terraform_remote_state" "platform" {
  backend = "s3"
  config = {
    bucket = "ai-observability-terraform-state-dev-${var.account_id}"
    key    = "dev/platform/terraform.tfstate"
    region = "us-east-2"
  }
}

# ── Dashboard definitions ─────────────────────────────────────────────────────
# Source URLs reference the committed files in the project repository.
# These URLs must be publicly reachable at plan time — the http data source
# in the project-observer module fetches them during terraform plan.
# After the Phase 2 PR is merged to main, update these to the main-branch URLs.

locals {
  dashboard_definitions = [
    {
      name       = "agent-operational-health"
      source_url = "https://raw.githubusercontent.com/normjon/ai-platform-demo/obs/register-ai-platform-catalogue/specs/dashboards/agent-operational-health.json"
    },
    {
      name       = "quality-trending"
      source_url = "https://raw.githubusercontent.com/normjon/ai-platform-demo/obs/register-ai-platform-catalogue/specs/dashboards/quality-trending.json"
    },
    {
      name       = "cost-token-consumption"
      source_url = "https://raw.githubusercontent.com/normjon/ai-platform-demo/obs/register-ai-platform-catalogue/specs/dashboards/cost-token-consumption.json"
    }
  ]

  alert_definitions = [
    {
      metric_namespace = "AIPlatform/Quality"
      metric_name      = "BelowThreshold"
      dimensions       = { AgentId = "hr-assistant-dev" }
      statistic        = "Sum"
      period           = 3600
      threshold        = 3
      comparison       = "GreaterThanThreshold"
      description      = "More than 3 HR Assistant responses below quality threshold in the last hour"
    },
    {
      metric_namespace = "AWS/Lambda"
      metric_name      = "Errors"
      dimensions       = { FunctionName = "ai-platform-dev-quality-scorer" }
      statistic        = "Sum"
      period           = 3600
      threshold        = 1
      comparison       = "GreaterThanOrEqualToThreshold"
      description      = "Quality scorer Lambda encountered one or more errors in the last hour"
    }
  ]
}

# ── Project observer module ───────────────────────────────────────────────────

module "ai_platform_observer" {
  source = "../../../modules/project-observer"

  project_id   = var.project_id
  display_name = var.display_name
  owner        = var.owner
  environment  = var.environment
  account_id   = var.account_id

  metric_namespaces     = var.metric_namespaces
  dashboard_definitions = local.dashboard_definitions
  alert_definitions     = local.alert_definitions

  amg_workspace_id    = data.terraform_remote_state.platform.outputs.amg_workspace_id
  grafana_url         = "https://${data.terraform_remote_state.platform.outputs.amg_workspace_endpoint}"
  firehose_stream_arn = data.terraform_remote_state.platform.outputs.firehose_stream_arn

  # Note: amp_workspace_id and kms_key_arn are NOT inputs to project-observer.
  # Metrics flow through the platform Firehose — the module does not write
  # to AMP directly. Custom namespaces get a per-project CloudWatch metric
  # stream targeting the platform Firehose (Option A namespace approach).

  tags = {
    Project     = var.project_id
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = var.owner
    Layer       = "projects"
  }
}
