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
