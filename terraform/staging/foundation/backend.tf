terraform {
  backend "s3" {
    bucket         = "ai-observability-terraform-state-staging-<account-id>"
    key            = "staging/foundation/terraform.tfstate"
    region         = "us-east-2"
    dynamodb_table = "ai-observability-terraform-lock-staging"
    encrypt        = true
  }
}
