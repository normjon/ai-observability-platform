# Project Registration Workflow

**Version:** 1.0
**Status:** Approved
**Repository:** ai-observability-platform
**Last updated:** April 2026

---

## 1. Overview

This document describes the end-to-end workflow for registering a
project with the observability platform. The workflow is executed
by a Claude Code agent on behalf of the project owner. The project
owner initiates the workflow with a single instruction. The agent
does all discovery, artefact creation, and registration work
autonomously.

**The project owner's instruction:**
```
Register <project-name> with the observability platform.
```

That is the only input required from the project owner. Everything
else is agent-driven.

---

## 2. Principles

**Discovery over description.** The agent discovers what a project
emits by reading its codebase — CLAUDE.md, specs, Terraform, and
application code. The project owner never describes their metrics
manually. The catalogue and dashboards produced by the agent are
grounded in what actually exists in the codebase.

**Two-repository workflow.** Registration spans two repositories.
The project repository is the source of truth for metrics and
dashboards. The observability platform repository is where the
registration infrastructure lives. Both receive PRs in the same
workflow. Neither is merged before the other.

**Schema compliance is the only review gate.** The observability
platform team reviews the project.yaml for schema compliance only —
not for catalogue content, dashboard design, or alert thresholds.
Content decisions belong to the project team.

**Transparent to application teams.** Application teams push metrics
to CloudWatch using the agreed namespace convention. They do not
configure any Firehose target, AMP endpoint, or observability
infrastructure. The metric stream is account-level and picks up
their namespaces automatically once registered.

---

## 3. Pre-Conditions

Before initiating registration the following must be true:

| Pre-condition | Verified by |
|---|---|
| Observability platform foundation layer applied | Platform team |
| Observability platform platform layer applied | Platform team |
| AMP workspace ACTIVE | Platform team |
| AMG workspace ACTIVE | Platform team |
| Project is pushing custom metrics to CloudWatch | Project team |
| Project has CloudWatch Metric Filters for log-derived metrics | Project team |
| Project metrics are using the agreed namespace convention | Project team |

If any pre-condition is not met the agent must stop and report
which pre-condition is missing before proceeding.

---

## 4. Phase 1 — Discovery

**Executed by:** Project team's Claude Code agent
**Repository:** Project repository (e.g. ai-platform-demo)
**Branch:** Current working branch or main

The agent reads the project codebase to discover every metric
being emitted to CloudWatch. It never asks the project owner
to describe their metrics.

### 4.1 Discovery sources

The agent reads these sources in order:

**Step 1 — CLAUDE.md**
- Approved model ARNs (these map to AWS/Bedrock namespace metrics)
- Namespace conventions and custom namespace names
- Any explicit metric references

**Step 2 — specs/ directory**
- LLM-as-Judge or quality scorer specs for explicit put_metric_data
  calls and their metric names, namespaces, and dimensions
- Any other spec that references CloudWatch metric emission

**Step 3 — Terraform modules and layers**
- Search for aws_cloudwatch_metric_filter resources — these
  produce metrics from log data
- Search for put_metric_data in Lambda handler code references
- Note the namespace and metric_name values found

**Step 4 — Lambda handler code**
- Read every handler.py in the repository
- Search for cloudwatch.put_metric_data() calls
- Extract: Namespace, MetricName, Dimensions, Unit
- Note the source file for each finding

**Step 5 — Container application code**
- Read agent container application code
- Search for any boto3 CloudWatch put_metric_data calls
- Search for any prometheus_client metric registrations

**Step 6 — AWS-native metrics**
- For every Lambda function defined in Terraform, note that
  AWS/Lambda metrics are emitted automatically
- For every Bedrock invocation in the codebase, note that
  AWS/Bedrock metrics are emitted automatically
- For every DynamoDB table, note AWS/DynamoDB metrics
- For every AOSS collection, note AWS/AOSS metrics

### 4.2 Discovery output

The agent produces a discovery report before generating any
artefacts:

```
Discovery complete for <project-id>:

Custom namespaces found:
  - AIPlatform/Quality (4 metrics — explicit put_metric_data)
  - AIPlatform/AgentCore (2 metrics — metric filters)

AWS-native namespaces:
  - AWS/Lambda (7 functions found)
  - AWS/Bedrock (model invocations in 2 Lambda functions)
  - AWS/DynamoDB (3 tables found)
  - AWS/AOSS (1 collection found)

Metric filters found: 2
  - agent_invocation_latency (from AgentCore log group)
  - agent_invocation_errors (from AgentCore log group)

Dashboard candidates:
  - agent-operational-health (latency, error rate, guardrail)
  - quality-trending (quality scores, below-threshold)
  - cost-token-consumption (tokens, estimated cost)

Ready to generate artefacts. Proceeding to Phase 2.
```

If the discovery finds no custom metrics and no metric filters,
stop and report. Do not register a project that has nothing
to observe.

---

## 5. Phase 2 — Artefact Creation

**Executed by:** Project team's Claude Code agent
**Repository:** Project repository
**Branch:** obs/register-<project-id>-catalogue

### 5.1 Create the metric catalogue

File: `specs/observability-metric-catalogue.md`

The agent generates one catalogue entry per metric discovered
in Phase 1. Catalogue entry format:

```yaml
metrics:
  - name: <MetricName exactly as emitted>
    namespace: <CloudWatch namespace>
    source: <how it is emitted — explicit code, metric filter,
             or AWS native>
    visualisation: <line | bar | stat | histogram>
    dashboard: <primary dashboard name>
    description: <one sentence — what this metric represents>
```

Rules for catalogue generation:
- Use the exact metric name as it appears in the code or AWS docs
- Do not invent metrics that were not found in Phase 1
- AWS-native metrics use the exact names from AWS documentation
- One entry per metric — do not combine related metrics

### 5.2 Create dashboard JSON

One JSON file per dashboard identified in discovery:
`specs/dashboards/<dashboard-name>.json`

Dashboard JSON must conform to specs/dashboard-standards.md
in the observability platform repository. The agent reads that
spec before generating any dashboard JSON.

Each dashboard must include:
- Template variables: $project_id, $environment, $time_range
- One panel per metric in the catalogue assigned to this dashboard
- Correct Grafana panel type matching the visualisation field
- PromQL queries referencing exact metric names from the catalogue
- Panel descriptions explaining what each metric shows

### 5.3 Commit and open PR

The agent commits both files and opens a PR in the project
repository:

Branch: `obs/register-<project-id>-catalogue`
PR title: `obs: add observability catalogue and dashboards for <project-id>`
PR description must include:
- Number of metrics in the catalogue
- List of namespaces
- List of dashboards created
- Note that this PR is part of a two-PR registration workflow
  with a corresponding PR in ai-observability-platform

The agent does not merge this PR. It notes the PR number and
raw GitHub URLs of the committed files for use in Phase 3.

---

## 6. Phase 3 — Registration

**Executed by:** Project team's Claude Code agent
**Repository:** ai-observability-platform
**Branch:** obs/register-<project-id>

### 6.1 Create project directory

```
terraform/<env>/projects/<project-id>/
```

### 6.2 Write project.yaml

The agent generates project.yaml from the discovery findings
and the Phase 2 artefacts. The metric_catalogue_url and
dashboard source_url fields reference the raw GitHub URLs
of the files committed in Phase 2.

The agent validates project.yaml against specs/project-yaml-schema.md
before proceeding. If validation fails it reports the errors
and stops. It does not open a PR with an invalid project.yaml.

### 6.3 Generate Terraform

The agent generates:
- `main.tf` — instantiates the project-observer module
- `backend.tf` — state key: <env>/projects/<project-id>/terraform.tfstate
- `variables.tf` — input variables
- `outputs.tf` — relevant outputs
- `terraform.tfvars.example` — placeholder template

main.tf pattern:
```hcl
# Generated from project.yaml — do not edit manually.
# To update, modify project.yaml and re-run generation.

data "terraform_remote_state" "platform" {
  backend = "s3"
  config = {
    bucket = "ai-observability-terraform-state-<env>-<account-id>"
    key    = "<env>/platform/terraform.tfstate"
    region = "us-east-2"
  }
}

module "<project_id>_observer" {
  source = "../../../modules/project-observer"

  project_id            = var.project_id
  display_name          = var.display_name
  owner                 = var.owner
  metric_namespaces     = var.metric_namespaces
  dashboard_definitions = local.dashboard_definitions
  alert_definitions     = var.alert_definitions
  environment           = var.environment
  account_id            = var.account_id

  amg_workspace_id    = data.terraform_remote_state.platform.outputs.amg_workspace_id
  grafana_url         = data.terraform_remote_state.platform.outputs.amg_workspace_endpoint
  firehose_stream_arn = data.terraform_remote_state.platform.outputs.firehose_stream_arn

  # Note: amp_workspace_id and kms_key_arn are NOT inputs to project-observer.
  # Metrics flow through the platform Firehose — the module does not write
  # to AMP directly. Custom namespaces get a per-project CloudWatch metric
  # stream targeting the platform Firehose (Option A namespace approach).

  tags = {
    Project     = var.project_id
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = var.owner
  }
}
```

### 6.4 Validate and plan

```bash
cd terraform/<env>/projects/<project-id>
terraform init
terraform validate
terraform plan -out=tfplan
```

The agent must not open a PR if:
- terraform validate returns any errors
- terraform plan shows any destroy operations
- terraform plan shows any replace operations on existing resources
- terraform plan fails for any reason

On failure: report the full error output and stop. Do not
attempt to fix errors without reporting them first.

### 6.5 Open PR

The agent opens a PR in ai-observability-platform.

Branch: `obs/register-<project-id>`
PR title: `obs: register <display-name> with observability platform`

PR description must include:
```
## Project Registration: <display-name>

**Project ID:** <project-id>
**Owner:** <owner>
**Environment:** <environment>

## Namespaces registered
<list each namespace>

## Dashboards
<list each dashboard name>

## Alerts
<count> alerts configured

## Terraform plan summary
Resources to add: <N>
Resources to change: 0
Resources to destroy: 0

## Related PR
Phase 2 (catalogue and dashboards): <link to project repo PR>

## Metric catalogue
<link to raw catalogue URL>

## Reviewer checklist
- [ ] project.yaml conforms to specs/project-yaml-schema.md
- [ ] All namespaces follow the agreed naming convention
- [ ] No destroy operations in plan
- [ ] Phase 2 PR is open and linked
```

---

## 7. Phase 4 — Review and Merge

**Performed by:** Human reviewers

### 7.1 Review scope

The observability platform team reviews for:
- project.yaml schema compliance
- Namespace naming convention compliance
- No destroy operations in terraform plan
- Phase 2 PR is open and accessible

The observability platform team does NOT review:
- Dashboard design or panel choices
- Metric catalogue content or descriptions
- Alert thresholds or conditions
- Visualisation type choices

Content decisions belong to the project team.

### 7.2 Merge order

Both PRs are reviewed and approved together.
Merge the project repository PR (Phase 2) first.
Merge the observability platform PR (Phase 3) second.

This order ensures the dashboard JSON source URLs are
available when the observability platform applies and
fetches them via the http data source.

### 7.3 Post-merge

CI/CD pipeline applies `terraform/<env>/projects/<project-id>`.

Verify after apply:
- Grafana folder appears in AMG named <project-id>
- All dashboards render without errors
- Metrics appear in dashboard panels within one metric
  stream delivery cycle (typically 1-3 minutes)
- All alerts created and in OK state

---

## 8. Updating an Existing Registration

When a project adds new metrics, changes dashboards, or modifies
alerts after initial registration, the same two-phase workflow
applies with update branches:

Phase 2 branch: `obs/update-<project-id>-catalogue-<description>`
Phase 3 branch: `obs/update-<project-id>-<description>`

The agent re-runs discovery before updating the catalogue to
ensure it reflects the current state of the codebase — not
just the delta from the last registration.

---

## 9. Deregistration

When a project is being decommissioned:

1. Project team opens PR to delete
   `terraform/<env>/projects/<project-id>/`
2. terraform plan shows destroy of Grafana folder, dashboards,
   and alerts — no other resources are destroyed
3. Namespaces are removed from the stream filter
4. Metrics continue to exist in AMP for the retention period
   (default 150 days) before expiring

The platform layer and foundation layer are never modified
as part of a project deregistration.
