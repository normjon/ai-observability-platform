terraform {
  backend "s3" {
    bucket         = "ai-observability-terraform-state-dev-096305373014"
    key            = "dev/projects/ai-platform/terraform.tfstate"
    region         = "us-east-2"
    dynamodb_table = "ai-observability-terraform-lock-dev"
    encrypt        = true
  }
}
