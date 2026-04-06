terraform {
  backend "s3" {
    bucket         = "ai-observability-terraform-state-production-<account-id>"
    key            = "production/foundation/terraform.tfstate"
    region         = "us-east-2"
    dynamodb_table = "ai-observability-terraform-lock-production"
    encrypt        = true
  }
}
