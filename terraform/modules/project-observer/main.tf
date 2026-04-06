# ── Component 1: Grafana folder ───────────────────────────────────────────────
# One folder per project in AMG. The folder UID is set to project_id so it is
# stable and predictable across applies. Dashboard resources reference this UID.
# The Grafana provider must be configured in the root module — child modules
# never configure providers.

resource "grafana_folder" "project" {
  uid   = var.project_id
  title = var.display_name
}

# ── Component 2: Grafana dashboards ───────────────────────────────────────────
# Dashboard JSON is fetched from source_url at plan time. If a URL is
# unreachable the plan fails — broken URLs are caught before apply.
# overwrite = true ensures Terraform is the source of truth; any console edits
# are overwritten on next apply.

data "http" "dashboard" {
  for_each = { for d in var.dashboard_definitions : d.name => d }

  url = each.value.source_url

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "Dashboard source_url for '${each.key}' returned HTTP ${self.status_code}. Verify the URL is a publicly reachable raw GitHub URL."
    }
  }
}

resource "grafana_dashboard" "project" {
  for_each = { for d in var.dashboard_definitions : d.name => d }

  folder      = grafana_folder.project.uid
  config_json = data.http.dashboard[each.key].response_body
  overwrite   = true
}
