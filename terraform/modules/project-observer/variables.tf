variable "project_id" {
  description = "Unique project identifier — lowercase, hyphens only. Used as Grafana folder UID and resource name prefix."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.project_id))
    error_message = "project_id must be lowercase alphanumeric and hyphens, starting with a letter."
  }
}

variable "display_name" {
  description = "Human-readable project name shown as the Grafana folder title."
  type        = string
}

variable "owner" {
  description = "Team name that owns this project registration."
  type        = string
}

variable "environment" {
  description = "Deployment environment — dev, staging, or production."
  type        = string
  validation {
    condition     = contains(["dev", "staging", "production"], var.environment)
    error_message = "environment must be dev, staging, or production."
  }
}

variable "metric_namespaces" {
  description = "CloudWatch metric namespaces to stream for this project. AWS/* namespaces are already covered by the platform stream — list only custom namespaces here unless you need to ensure AWS/* are also scoped to this project."
  type        = list(string)
}

variable "dashboard_definitions" {
  description = "List of dashboards to provision. Each entry must have a unique name and a publicly reachable source_url pointing to dashboard JSON."
  type = list(object({
    name       = string
    source_url = string
  }))
  default = []
}

variable "alert_definitions" {
  description = "List of CloudWatch alarms to create for this project."
  type = list(object({
    metric_namespace = string
    metric_name      = string
    dimensions       = map(string)
    statistic        = string
    period           = number
    threshold        = number
    comparison       = string
    description      = string
  }))
  default = []
}

variable "amg_workspace_id" {
  description = "ID of the AMG workspace. Used to create the Grafana API key."
  type        = string
}

variable "grafana_url" {
  description = "HTTPS endpoint of the AMG workspace (e.g. https://<id>.grafana-workspace.us-east-2.amazonaws.com). Used to construct folder URL output."
  type        = string
}

variable "firehose_stream_arn" {
  description = "ARN of the platform Kinesis Firehose delivery stream. Custom-namespace metric streams target this stream."
  type        = string
}

variable "account_id" {
  description = "AWS account ID. Used to scope IAM role trust policies."
  type        = string
}

variable "tags" {
  description = "Tags to apply to all AWS resources created by this module."
  type        = map(string)
  default     = {}
}
