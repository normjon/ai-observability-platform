variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-2"
}

variable "environment" {
  description = "Deployment environment (dev | staging | production)"
  type        = string
  default     = "dev"
}

variable "account_id" {
  description = "AWS account ID — never hardcoded in resources"
  type        = string
}

variable "grafana_auth" {
  description = "Grafana API key for the AMG workspace. Pass via TF_VAR_grafana_auth or terraform.tfvars — do not hardcode."
  type        = string
  sensitive   = true
}
