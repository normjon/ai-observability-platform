variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-2"
}

variable "account_id" {
  description = "AWS account ID — never hardcoded, always passed via tfvars"
  type        = string
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "dev"
}

variable "project_id" {
  description = "Unique project identifier — must match project.yaml project_id"
  type        = string
  default     = "ai-platform"
}

variable "display_name" {
  description = "Human-readable project name shown in Grafana"
  type        = string
  default     = "Enterprise AI Platform"
}

variable "owner" {
  description = "Team name that owns this project's observability definitions"
  type        = string
  default     = "platform-team"
}

variable "grafana_auth" {
  description = "Grafana API key for the AMG workspace. Pass via TF_VAR_grafana_auth environment variable — do not store in terraform.tfvars."
  type        = string
  sensitive   = true
}

variable "metric_namespaces" {
  description = "CloudWatch namespaces registered for this project"
  type        = list(string)
  default = [
    "AIPlatform/Quality",
    "AWS/Lambda",
    "AWS/Bedrock",
    "AWS/DynamoDB",
    "AWS/AOSS"
  ]
}
