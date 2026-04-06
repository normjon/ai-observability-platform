# Foundation outputs consumed by platform layer via remote state

output "vpc_id" {
  description = "ID of the observability platform VPC"
  value       = module.networking.vpc_id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets"
  value       = module.networking.private_subnet_ids
}

output "kms_key_arn" {
  description = "ARN of the KMS key for AMP and AMG encryption"
  value       = aws_kms_key.observability.arn
}

output "kms_key_id" {
  description = "ID of the KMS key"
  value       = aws_kms_key.observability.key_id
}

output "firehose_buffer_bucket_arn" {
  description = "ARN of the S3 bucket used as Kinesis Firehose buffer"
  value       = aws_s3_bucket.firehose_buffer.arn
}

output "firehose_buffer_bucket_id" {
  description = "Name of the S3 bucket used as Kinesis Firehose buffer"
  value       = aws_s3_bucket.firehose_buffer.id
}

