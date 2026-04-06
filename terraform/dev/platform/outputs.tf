# Platform outputs consumed by project layers via remote state

output "amp_workspace_id" {
  description = "ID of the AMP workspace"
  value       = aws_prometheus_workspace.this.id
}

output "amp_workspace_arn" {
  description = "ARN of the AMP workspace"
  value       = aws_prometheus_workspace.this.arn
}

output "amp_workspace_endpoint" {
  description = "Prometheus remote write endpoint for the AMP workspace"
  value       = aws_prometheus_workspace.this.prometheus_endpoint
}

output "firehose_stream_name" {
  description = "Name of the Kinesis Firehose delivery stream"
  value       = aws_kinesis_firehose_delivery_stream.this.name
}

output "firehose_stream_arn" {
  description = "ARN of the Kinesis Firehose delivery stream"
  value       = aws_kinesis_firehose_delivery_stream.this.arn
}

output "iam_role_cw_stream_arn" {
  description = "ARN of the CloudWatch metric stream delivery IAM role"
  value       = aws_iam_role.cw_stream.arn
}

output "iam_role_firehose_delivery_arn" {
  description = "ARN of the Kinesis Firehose delivery IAM role"
  value       = aws_iam_role.firehose_delivery.arn
}

output "iam_role_amg_datasource_arn" {
  description = "ARN of the AMG data source IAM role"
  value       = aws_iam_role.amg_datasource.arn
}
