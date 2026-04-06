variable "environment" {
  description = "Deployment environment (dev | staging | production)"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
}

variable "private_subnets" {
  description = "Map of availability zone to private subnet CIDR"
  type        = map(string)
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default     = {}
}
