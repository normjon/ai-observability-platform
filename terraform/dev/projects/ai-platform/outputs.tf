# Project outputs — consumed for verification and cross-project reference

output "grafana_folder_uid" {
  description = "UID of the Grafana folder in AMG"
  value       = module.ai_platform_observer.grafana_folder_uid
}

output "grafana_folder_url" {
  description = "URL of the Grafana project folder in AMG"
  value       = module.ai_platform_observer.grafana_folder_url
}

output "dashboard_uids" {
  description = "Map of dashboard name to Grafana dashboard UID"
  value       = module.ai_platform_observer.dashboard_uids
}
