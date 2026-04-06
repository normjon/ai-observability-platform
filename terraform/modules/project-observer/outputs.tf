output "grafana_folder_uid" {
  description = "UID of the Grafana folder created for this project"
  value       = grafana_folder.project.uid
}

output "grafana_folder_url" {
  description = "URL of the Grafana folder in AMG"
  value       = "${var.grafana_url}/dashboards/f/${grafana_folder.project.uid}"
}

output "dashboard_uids" {
  description = "Map of dashboard name to Grafana dashboard UID"
  value       = { for k, v in grafana_dashboard.project : k => v.uid }
}
