# ── Locals ────────────────────────────────────────────────────────────────────
# Separate project namespaces into custom (non-AWS/) vs AWS-native.
# AWS/* namespaces are already streamed by the platform-level metric stream —
# no per-project stream is created for them. Custom namespaces require a
# dedicated per-project metric stream (Option A approach) because the platform
# stream cannot be modified per-project without cross-state dependencies.

locals {
  custom_namespaces = [
    for ns in var.metric_namespaces : ns
    if !startswith(ns, "AWS/")
  ]
  has_custom_namespaces = length(local.custom_namespaces) > 0
}

# ── Component 1: Grafana folder ───────────────────────────────────────────────
# One folder per project in AMG. The folder UID is set to project_id so it is
# stable and predictable across applies. Dashboard resources reference this UID.
# The Grafana provider must be configured in the root module — child modules
# never configure providers.

resource "grafana_folder" "project" {
  uid   = var.project_id
  title = var.display_name
}

# ── Component 2: Grafana dashboards ───────────────────────────────────────────
# Dashboard JSON is fetched from source_url at plan time. If a URL is
# unreachable the plan fails — broken URLs are caught before apply.
# overwrite = true ensures Terraform is the source of truth; any console edits
# are overwritten on next apply.

data "http" "dashboard" {
  for_each = { for d in var.dashboard_definitions : d.name => d }

  url = each.value.source_url

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "Dashboard source_url for '${each.key}' returned HTTP ${self.status_code}. Verify the URL is a publicly reachable raw GitHub URL."
    }
  }
}

resource "grafana_dashboard" "project" {
  for_each = { for d in var.dashboard_definitions : d.name => d }

  folder      = grafana_folder.project.uid
  config_json = data.http.dashboard[each.key].response_body
  overwrite   = true
}

# ── Component 3: Per-project metric stream (custom namespaces only) ───────────
# Created only when the project registers custom namespaces (non-AWS/).
# This stream targets the same platform Firehose — metrics flow through the
# same delivery pipeline into AMP. Each project stream is independently
# destroyable without affecting other projects or the platform stream.
#
# The cw_stream_project role reuses the same trust/permission pattern as the
# platform cw_stream role but is scoped to this project's stream ARN.

resource "aws_iam_role" "cw_stream_project" {
  count = local.has_custom_namespaces ? 1 : 0

  name = "ai-observability-cw-stream-${var.project_id}-${var.environment}"

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

  tags = merge(var.tags, {
    Project = var.project_id
    Owner   = var.owner
  })
}

resource "aws_iam_role_policy" "cw_stream_project" {
  count = local.has_custom_namespaces ? 1 : 0

  name = "firehose-put-record"
  role = aws_iam_role.cw_stream_project[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "FirehosePutRecord"
      Effect = "Allow"
      Action = [
        "firehose:PutRecord",
        "firehose:PutRecordBatch"
      ]
      Resource = var.firehose_stream_arn
    }]
  })
}

resource "aws_cloudwatch_metric_stream" "project" {
  count = local.has_custom_namespaces ? 1 : 0

  name          = "ai-observability-${var.project_id}-stream-${var.environment}"
  role_arn      = aws_iam_role.cw_stream_project[0].arn
  firehose_arn  = var.firehose_stream_arn
  output_format = "json"

  dynamic "include_filter" {
    for_each = local.custom_namespaces
    content {
      namespace = include_filter.value
    }
  }

  tags = merge(var.tags, {
    Project   = var.project_id
    Owner     = var.owner
    Component = "metric-stream"
  })
}

# ── Component 4: CloudWatch alarms ────────────────────────────────────────────
# One alarm per alert_definition in project.yaml. treat_missing_data defaults
# to "notBreaching" — new projects have no history and should not false-alarm.
# Alarm names are scoped to project_id to avoid collision across projects.

resource "aws_cloudwatch_metric_alarm" "project" {
  for_each = {
    for idx, a in var.alert_definitions :
    "${var.project_id}-${a.metric_name}-${idx}" => a
  }

  alarm_name          = "ai-observability-${var.project_id}-${each.value.metric_name}-${var.environment}"
  alarm_description   = each.value.description
  comparison_operator = each.value.comparison
  evaluation_periods  = 1
  metric_name         = each.value.metric_name
  namespace           = each.value.metric_namespace
  period              = each.value.period
  statistic           = each.value.statistic
  threshold           = each.value.threshold
  treat_missing_data  = "notBreaching"
  dimensions          = each.value.dimensions

  tags = merge(var.tags, {
    Project = var.project_id
    Owner   = var.owner
  })
}
