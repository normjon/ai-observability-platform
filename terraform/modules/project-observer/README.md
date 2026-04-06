# Module: project-observer

Reusable module instantiated once per registered project.
Instantiated by the project team's Claude Code agent during registration.

## Resources (to be defined)
- aws_grafana_folder — project folder in AMG
- aws_grafana_dashboard — one per dashboard defined in project.yaml
- CloudWatch metric stream namespace filter addition
- aws_cloudwatch_metric_alarm — one per alert definition

## Inputs
See CLAUDE.md project-observer module inputs table.

## Dashboard JSON
Fetched from source_url at plan time via Terraform http data source.
Unreachable URLs fail the plan — intentional.
