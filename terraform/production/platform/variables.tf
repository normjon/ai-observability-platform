variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-2"
}

variable "environment" {
  description = "Deployment environment (dev | staging | production)"
  type        = string
  default     = "production"
}

variable "account_id" {
  description = "AWS account ID — never hardcoded in resources"
  type        = string
}
