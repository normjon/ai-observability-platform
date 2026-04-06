# Platform outputs consumed by project layers via remote state

# ── AMP ───────────────────────────────────────────────────────────────────────

output "amp_workspace_id" {
  description = "ID of the AMP workspace"
  value       = aws_prometheus_workspace.this.id
}

output "amp_workspace_arn" {
  description = "ARN of the AMP workspace"
  value       = aws_prometheus_workspace.this.arn
}

output "amp_workspace_endpoint" {
  description = "Prometheus remote write base URL for the AMP workspace"
  value       = aws_prometheus_workspace.this.prometheus_endpoint
}

# ── AMG ───────────────────────────────────────────────────────────────────────

output "amg_workspace_id" {
  description = "ID of the AMG workspace"
  value       = aws_grafana_workspace.this.id
}

output "amg_workspace_endpoint" {
  description = "Endpoint URL of the AMG workspace"
  value       = aws_grafana_workspace.this.endpoint
}

output "amg_datasource_role_arn" {
  description = "ARN of the AMG datasource IAM role"
  value       = aws_iam_role.amg_datasource.arn
}

output "amp_grafana_datasource_uid" {
  description = "UID of the AMP Prometheus data source in AMG — reference in dashboard JSON panel datasource fields"
  value       = grafana_data_source.amp.uid
}

# ── Firehose ──────────────────────────────────────────────────────────────────

output "firehose_stream_name" {
  description = "Name of the Kinesis Firehose delivery stream"
  value       = aws_kinesis_firehose_delivery_stream.this.name
}

output "firehose_stream_arn" {
  description = "ARN of the Kinesis Firehose delivery stream"
  value       = aws_kinesis_firehose_delivery_stream.this.arn
}

output "firehose_delivery_role_arn" {
  description = "ARN of the Firehose delivery IAM role"
  value       = aws_iam_role.firehose_delivery.arn
}

# ── CloudWatch metric stream ───────────────────────────────────────────────────

output "metric_stream_name" {
  description = "Name of the CloudWatch metric stream"
  value       = aws_cloudwatch_metric_stream.this.name
}

output "metric_stream_arn" {
  description = "ARN of the CloudWatch metric stream"
  value       = aws_cloudwatch_metric_stream.this.arn
}

output "cw_stream_role_arn" {
  description = "ARN of the CloudWatch metric stream delivery IAM role"
  value       = aws_iam_role.cw_stream.arn
}
