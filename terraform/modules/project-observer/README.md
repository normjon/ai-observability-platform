# Module: project-observer

Reusable Terraform module that provisions all observability resources for a
single registered project. Instantiated once per project by the project
team's Claude Code agent during the registration workflow.

## Purpose

Bridges project.yaml declarations into live AWS and Grafana resources:
- Grafana folder and dashboards in AMG
- Per-project CloudWatch metric stream for custom namespaces
- CloudWatch alarms from the project's alert definitions

## Providers required

This module requires three providers configured in the root module:

```hcl
provider "aws" {
  region = var.aws_region
}

provider "grafana" {
  url  = "<amg_workspace_endpoint>"
  auth = "<grafana_api_key>"
}

provider "http" {}
```

The Grafana provider uses an API key (`aws_grafana_workspace_api_key`)
because `auth = "sigv4"` is not supported in grafana/grafana 2.x.
Create the API key in the root module and pass the endpoint as `grafana_url`.

## Inputs

| Variable              | Type           | Required | Description                                     |
|-----------------------|----------------|----------|-------------------------------------------------|
| project_id            | string         | yes      | Unique identifier — lowercase, hyphens only     |
| display_name          | string         | yes      | Grafana folder title                            |
| owner                 | string         | yes      | Owning team name                                |
| environment           | string         | yes      | dev / staging / production                      |
| account_id            | string         | yes      | AWS account ID for IAM trust scoping            |
| metric_namespaces     | list(string)   | yes      | CloudWatch namespaces to register               |
| dashboard_definitions | list(object)   | no       | Dashboard name + source_url pairs               |
| alert_definitions     | list(object)   | no       | Alert specs from project.yaml                   |
| amg_workspace_id      | string         | yes      | AMG workspace ID (from platform remote state)   |
| grafana_url           | string         | yes      | AMG workspace HTTPS endpoint                    |
| firehose_stream_arn   | string         | yes      | Platform Firehose ARN (from platform remote state) |
| tags                  | map(string)    | no       | Tags applied to all AWS resources               |

### alert_definitions object shape

```hcl
{
  metric_namespace = string
  metric_name      = string
  dimensions       = map(string)
  statistic        = string   # Sum | Average | Maximum | Minimum
  period           = number   # seconds
  threshold        = number
  comparison       = string   # GreaterThanOrEqualToThreshold | LessThanThreshold | etc.
  description      = string
}
```

## Outputs

| Output            | Description                                          |
|-------------------|------------------------------------------------------|
| grafana_folder_uid | UID of the Grafana folder (equals project_id)       |
| grafana_folder_url | Full URL to the project folder in AMG               |
| dashboard_uids    | Map of dashboard name → Grafana dashboard UID        |

## Example instantiation

```hcl
module "ai_platform_observer" {
  source = "../../../modules/project-observer"

  project_id   = "ai-platform"
  display_name = "AI Platform"
  owner        = "ai-platform-team"
  environment  = var.environment
  account_id   = var.account_id

  metric_namespaces = [
    "AIPlatform/Quality",
    "AIPlatform/AgentCore",
  ]

  dashboard_definitions = [
    {
      name       = "quality-trending"
      source_url = "https://raw.githubusercontent.com/org/repo/main/specs/dashboards/quality-trending.json"
    },
  ]

  alert_definitions = [
    {
      metric_namespace = "AIPlatform/Quality"
      metric_name      = "QualityScore"
      dimensions       = { Dimension = "overall" }
      statistic        = "Average"
      period           = 300
      threshold        = 0.7
      comparison       = "LessThanThreshold"
      description      = "Overall quality score dropped below 0.7"
    },
  ]

  amg_workspace_id    = data.terraform_remote_state.platform.outputs.amg_workspace_id
  grafana_url         = data.terraform_remote_state.platform.outputs.amg_workspace_endpoint
  firehose_stream_arn = data.terraform_remote_state.platform.outputs.firehose_stream_arn

  tags = {
    Project     = "ai-platform"
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = "ai-platform-team"
  }
}
```

## Namespace filter approach

The platform-level CloudWatch metric stream covers `AWS/*` namespaces
(Lambda, DynamoDB, Bedrock, AOSS, States). Custom project namespaces
require a separate per-project metric stream.

This module uses **Option A**: a per-project `aws_cloudwatch_metric_stream`
targeting the same platform Firehose ARN. Resources are created only when
`metric_namespaces` contains at least one non-`AWS/` namespace.

Rationale: The platform metric stream state cannot be modified from a
project-layer apply without sharing Terraform state across layers, which
violates ADR-017. Per-project streams are independently destroyable.

## Known limitations

**AMG customer-managed KMS**: `aws_grafana_workspace` in hashicorp/aws 5.x
does not expose a `kms_key_arn` argument. AMG workspaces use AWS-owned
encryption by default. Track the upstream provider issue and add
`kms_key_arn` once the provider exposes it.

**Grafana provider SigV4**: `auth = "sigv4"` is not supported in
grafana/grafana 2.x. Use `aws_grafana_workspace_api_key` in the root
module and pass the key as the `auth` value in the Grafana provider block.
The API key must be rotated manually or via a separate automation.

**Dashboard JSON at plan time**: Dashboard `source_url` values must be
publicly reachable when `terraform plan` runs. Private GitHub repositories
require a token passed via the `http` provider's `request_headers`.
