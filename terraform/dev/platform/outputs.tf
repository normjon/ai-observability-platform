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
