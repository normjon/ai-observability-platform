# CLAUDE.md — AI Observability Platform

## Primary Audience
Claude Code agents. Human engineers are the secondary audience.
All instructions are imperative commands. When these instructions
conflict with a simpler or more obvious approach, follow these
instructions — the simpler approach was considered and rejected.

---

## Project Purpose
This repository provisions the observability infrastructure for all
enterprise AI projects. It provides a shared AMP and AMG platform
that any project can register against by dropping a configuration
file into the projects/ directory.

The observability platform owns the infrastructure and the standards.
Each project team owns their observability definitions — metric
catalogues, dashboard JSON, and alert thresholds. The platform
applies what projects define. It never authors observability
content on behalf of another team.

---

## Authoritative Knowledge Sources

### 1 — ADR Library
Repository: https://github.com/normjon/claude-foundation-best-practice
Read the relevant domain folder CLAUDE.md before writing any code.
Domain routing:
- Provisioning AWS resources          → security/ then infrastructure/
- Setting up logging or monitoring    → observability/
- Creating branches or pipeline jobs  → process/

Critical rules from the ADR library (read the full ADR for rationale):
- ADR-001 (security/):       Use IRSA for all AWS credential delivery.
                             Never use node instance profiles or env vars.
- ADR-003 (observability/):  All logs must be structured JSON to stdout.
- ADR-005 (infrastructure/): Use staged Terraform apply for
                             CRD-dependent resources.
- ADR-013 (process/):        GitFlow branching. Never commit directly
                             to main.
- ADR-015 (process/):        Update README.md and CLAUDE.md in the
                             same PR as any change that affects
                             infrastructure behaviour.
- ADR-017 (infrastructure/): One state file per deployment layer per
                             account in S3 with DynamoDB locking.
                             Never share state across layers.

### 2 — Specification Documents
Location: specs/
Read the relevant spec before implementing any platform component.
Specs are the authoritative design reference for complex components.
When a spec exists it takes precedence over conversational instructions.

Key specs:
- specs/project-yaml-schema.md            — Authoritative schema for
                                            project.yaml with field
                                            definitions and validation rules
- specs/dashboard-standards.md            — PromQL conventions, panel
                                            standards, template variable
                                            requirements
- specs/project-registration-workflow.md  — End-to-end registration
                                            workflow for agents and
                                            project teams

---

## External Reference Libraries
Read these before generating AMP or AMG resource definitions:
- AWS Managed Prometheus Terraform docs:
  https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/prometheus_workspace
- AWS Managed Grafana Terraform docs:
  https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/grafana_workspace
- Grafana Terraform provider docs:
  https://registry.terraform.io/providers/grafana/grafana/latest/docs
- CloudWatch metric streams to AMP:
  https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch-metric-streams-formats-opentelemetry.html

---

## Ownership Model

Three distinct layers of ownership. Read this before touching
any file in this repository.

### Layer 1 — Platform infrastructure (observability platform team)
Owns: terraform/dev/foundation/, terraform/dev/platform/, modules/
Foundation contains: VPC, KMS key, S3 Firehose buffer bucket.
Platform contains: AMP workspace, AMG workspace, Kinesis Firehose,
CloudWatch metric stream, IAM roles, AMG data source configuration,
Grafana organisation. IAM roles live in platform (not foundation)
so their policies can reference exact same-layer resource ARNs —
see IAM Requirements section for full rationale.
Changes: require observability platform team review and approval.

### Layer 2 — Standards (jointly owned, ADR-governed)
Owns: specs/project-yaml-schema.md, specs/dashboard-standards.md,
      specs/project-registration-workflow.md
Contains: The contracts that define what a valid project.yaml
looks like, what dashboard JSON must conform to, and how the
registration workflow operates.
Changes: require ADR in the ADR library before modification.

### Layer 3 — Project definitions (each project team)
Owns: terraform/<env>/projects/<project-id>/
Contains: project.yaml, generated main.tf, backend.tf.
Changes: made by the project team's Claude Code agent, reviewed
by the observability platform team for schema compliance only —
never for content.

### Responsibility matrix

The observability platform team owns:
- Foundation and platform Terraform layers
- CloudWatch metric stream configuration
- Kinesis Firehose delivery stream
- AMP workspace
- AMG workspace and data sources
- project-observer Terraform module
- Standards specs and schema validation

The project team owns:
- Pushing custom metrics to CloudWatch using the correct namespace
- Creating CloudWatch Metric Filters that transform log events
  into CloudWatch Metrics — this is mandatory for any operational
  signal that originates in application logs
- Writing the metric catalogue spec in their own repository
- Writing dashboard JSON in their own repository
- Submitting project.yaml to register with this platform
- Maintaining their catalogue and dashboards as their platform evolves

The observability platform team never:
- Authors dashboard JSON for another team's project
- Creates CloudWatch Metric Filters in another team's account layer
- Parses application logs directly
- Queries application log groups via CloudWatch Logs Insights

---

## How Metrics Flow — Push Model

The observability platform uses a push model. Application teams
push metrics to CloudWatch. The observability platform streams
those metrics from CloudWatch into AMP via Kinesis Firehose.
Application teams do not need an ARN, endpoint, or target —
the stream is transparent to them.

```
Application team pushes                Observability platform streams
──────────────────────────             ──────────────────────────────
Explicit put_metric_data()    →        CloudWatch (account-level)
AWS service auto-metrics      →        CloudWatch (account-level)
Metric Filter transforms      →        CloudWatch (account-level)
                                              │
                                              ▼  CloudWatch metric stream
                                       Kinesis Firehose
                                              │
                                              ▼  remote write
                                       AMP workspace
                                              │
                                              ▼  PromQL query
                                       AMG dashboards
```

### What the application team must do

1. Push custom metrics to CloudWatch using the agreed namespace
   convention (see Namespace Convention below).

2. Create CloudWatch Metric Filters in their own Terraform layer
   for any operational signal that originates in log data. The
   observability platform does not parse application logs.
   Metric filters live in the application repository — not here.

3. Write a metric catalogue spec in their repository documenting
   what they emit.

4. Write dashboard JSON in their repository.

5. Submit project.yaml to register (see Registration Workflow).

### What the application team does not need to do

- Configure any Kinesis Firehose target or delivery stream
- Provision any AMP remote write endpoint
- Create any CloudWatch Logs subscription filter
- Know anything about the observability platform's internal
  infrastructure

### CloudWatch metric stream — account-level

One CloudWatch metric stream exists per account per environment.
It is an account-level resource that streams all metrics in the
configured namespaces to the observability Kinesis Firehose.
When a project registers via project.yaml the observability
platform adds their namespaces to the stream filter on next apply.
From that point all metrics in those namespaces flow automatically.

The stream carries numeric CloudWatch Metrics only — not log events.
CloudWatch Logs never enter the observability platform.

---

## Namespace Naming Convention

Application teams must use the agreed namespace convention for
all custom metrics. This is what the observability platform adds
to the stream filter when a project registers.

Convention: `<ProjectId>/<SubSystem>`

Examples:
  AIPlatform/Quality      — AI platform quality scorer metrics
  AIPlatform/AgentCore    — AI platform agent runtime metrics
  DataPipeline/Ingestion  — hypothetical future project

AWS-native namespaces (AWS/Lambda, AWS/Bedrock, AWS/DynamoDB, etc.)
are also streamed and do not require a naming convention — AWS
defines these and they are standardised.

Custom metrics that do not follow this convention will be streamed
if their namespace is registered, but they will not be discoverable
from the project-id in the metric catalogue and dashboards will be
harder to maintain.

---

## Per-Account Per-Environment Model

One observability platform deployment per AWS account per
environment. A CloudWatch metric stream is scoped to a single
AWS account and region — it cannot aggregate across accounts.

```
sandbox account (096305373014)
  └── dev AI platform     ←── dev observability platform
                                 (this repository, dev/)

staging account (future)
  └── staging AI platform ←── staging observability platform
                                 (this repository, staging/)

production account (future)
  └── prod AI platform    ←── prod observability platform
                                 (this repository, production/)
```

The repository supports this via environment-level directories
sharing the same modules:

```
terraform/
  dev/
    foundation/
    platform/
    projects/
  staging/             # Same structure — different account
    foundation/
    platform/
    projects/
  production/          # Same structure — different account
    foundation/
    platform/
    projects/
  modules/             # Shared across all environments
    networking/
    amp/
    amg/
    metric-streams/
    project-observer/
```

Account ID is always passed as a variable. Never hardcoded in
any Terraform resource, data source, or backend configuration.

### Cross-environment unified view — out of scope for dev

Cross-account metric aggregation and multi-environment unified
dashboards are out of scope. Two future options exist when needed:

Option A: Multi-account AMG data sources — a management-account
AMG workspace connects to each environment's AMP workspace as
a separate data source. Dashboard template variables filter
by environment.

Option B: CloudWatch cross-account observability — AWS
Organizations account-level metric sharing to a central
monitoring account running a single aggregated stream.

These are deferred to when staging and production environments
exist. Do not implement either in dev.

---

## Project Registration Workflow

Read specs/project-registration-workflow.md for the complete
workflow narrative. This is the summary.

### Entry point — project team's Claude Code agent

The registration workflow is initiated and executed by the
project team's Claude Code agent working in the project
repository. The agent does the discovery work before touching
this repository.

The project owner gives a single instruction:
"Register <project-name> with the observability platform."

### Phase 1 — Discovery (in project repository)

The agent reads the project codebase to discover what is
being emitted to CloudWatch:

1. Read CLAUDE.md — approved model ARNs, namespace conventions
2. Read all specs/ — find metric definitions and custom namespaces
3. Read Terraform modules — find explicit put_metric_data calls,
   CloudWatch Metric Filter resources, and registered namespaces
4. Read Lambda handler code — find put_metric_data calls and
   their exact metric names and dimensions
5. Read container code — find any custom metric emissions
6. Synthesise findings into the metric catalogue and dashboards

The agent never asks the project owner to describe their metrics
manually. It discovers them from the codebase.

### Phase 2 — Artefact creation (in project repository)

The agent creates on a new branch in the project repository:

  specs/observability-metric-catalogue.md
  specs/dashboards/<dashboard-name>.json  (one per dashboard)

Branch naming: obs/register-<project-id>-catalogue

The metric catalogue format is defined in Section "Metric
Catalogue Format" below. Dashboard JSON must conform to
specs/dashboard-standards.md in this repository.

The agent commits and opens a PR in the project repository.

### Phase 3 — Registration (in this repository)

After Phase 2 the agent switches to this repository and:

1. Creates branch: obs/register-<project-id>
2. Creates terraform/<env>/projects/<project-id>/project.yaml
   referencing the catalogue and dashboard URLs from the
   Phase 2 PR (raw GitHub URLs to the committed files)
3. Reads the catalogue to validate namespace and metric names
4. Generates terraform/<env>/projects/<project-id>/main.tf
   by instantiating the project-observer module
5. Generates backend.tf, variables.tf, outputs.tf,
   terraform.tfvars.example
6. Runs terraform init, validate, and plan
7. Opens PR in this repository with:
   - Project ID, display name, owner
   - Namespaces being registered
   - Number of dashboards and alerts
   - terraform plan summary (resources to add)
   - Link to Phase 2 PR in project repository
   - Link to metric catalogue

### Phase 4 — Review and merge

Both PRs are reviewed together. Neither is merged before the
other. The observability platform team reviews the project.yaml
for schema compliance only — not dashboard content.

On merge of both PRs:
- CI/CD applies projects/<project-id> terraform layer
- Namespaces added to stream filter
- Grafana folder and dashboards created in AMG
- Alerts provisioned

### Agent rules for registration

- Do not open the PR if terraform validate fails
- Do not open the PR if terraform plan shows destroy operations
- Do not open the PR if project.yaml fails schema validation
- Do not hardcode metric names — derive them from the codebase
- Do not invent metrics that are not found in the codebase
- If a namespace or metric cannot be found, surface the gap
  explicitly rather than guessing

---

## Metric Catalogue Format

The metric catalogue lives in the project repository at
specs/observability-metric-catalogue.md. It documents every
CloudWatch metric the project emits. The observability platform
reads it during registration to understand what to expect.

CloudWatch already carries granularity, unit, and dimensions
in the metric stream payload — these do not need to be
documented in the catalogue. The catalogue documents only
what CloudWatch cannot provide: human intent and display
guidance.

### Catalogue entry format

```yaml
metrics:
  - name: QualityScore
    namespace: AIPlatform/Quality
    source: LLM-as-Judge scorer Lambda (explicit put_metric_data)
    visualisation: line
    dashboard: quality-trending
    description: Per-dimension quality score for each scored
                 agent interaction. Six dimensions — correctness,
                 relevance, groundedness, completeness, tone,
                 and overall (mean of five).

  - name: InvocationLatency
    namespace: AIPlatform/AgentCore
    source: CloudWatch Metric Filter on AgentCore runtime log group
    visualisation: line
    dashboard: agent-operational-health
    description: End-to-end latency per agent invocation in
                 milliseconds. Used for P50/P95/P99 panels.

  - name: InputTokenCount
    namespace: AWS/Bedrock
    source: AWS native — emitted automatically by Bedrock service
    visualisation: bar
    dashboard: cost-token-consumption
    description: Input tokens consumed per Bedrock model invocation.
                 Combined with OutputTokenCount for cost estimation.
```

Four fields per metric. Nothing more. The agent discovers
these values from the codebase — the project owner does not
fill them in manually.

---

## project.yaml Schema

Every project.yaml must conform to specs/project-yaml-schema.md.
This is a summary — read the full spec before generating or
validating a project.yaml.

```yaml
project_id: string          # Unique — lowercase, hyphens only
display_name: string        # Human-readable — shown in Grafana
owner: string               # Team name
environment: string         # dev | staging | production

metric_namespaces:          # CloudWatch namespaces to add to stream
  - string

metric_catalogue_url: string  # Raw GitHub URL to catalogue in
                              # project repository

dashboards:
  - name: string            # Dashboard name without .json
    source_url: string      # Raw GitHub URL to dashboard JSON

alerts:
  - metric_namespace: string
    metric_name: string
    dimensions:
      key: value
    statistic: string       # Sum | Average | Maximum | Minimum
    period: number          # Seconds
    threshold: number
    comparison: string
    description: string
```

---

## Terraform Structure

Three-layer isolated state per environment. Use this exactly:

```
terraform/
  dev/
    foundation/               # Layer 1 — VPC, KMS, IAM
      backend.tf              # State: dev/foundation/terraform.tfstate
      main.tf
      variables.tf
      outputs.tf
      terraform.tfvars.example
    platform/                 # Layer 2 — AMP, AMG, Firehose, stream
      backend.tf              # State: dev/platform/terraform.tfstate
      main.tf
      variables.tf
      outputs.tf
      terraform.tfvars.example
    projects/
      <project-id>/           # Layer 3 — per-project observability
        project.yaml          # Written by project team's agent
        main.tf               # Generated by Claude Code agent
        backend.tf            # State: dev/projects/<id>/terraform.tfstate
        variables.tf
        outputs.tf
        terraform.tfvars.example
  staging/                    # Same structure — staging account
    foundation/
    platform/
    projects/
  production/                 # Same structure — production account
    foundation/
    platform/
    projects/
  modules/                    # Shared across all environments
    networking/
    amp/
    amg/
    metric-streams/
    project-observer/
```

### Layer responsibilities

**Foundation** — long-lived, destroyed only on decommission:
- VPC (10.1.0.0/16) — isolated from all other platform VPCs
- KMS key for AMP and AMG encryption
- IAM roles for metric stream delivery, Firehose delivery,
  and AMG data source access
- S3 bucket for Kinesis Firehose buffer

**Platform** — freely destroyable and reapplyable:
- AMP workspace
- AMG workspace and Grafana organisation
- Kinesis Firehose delivery stream
- CloudWatch metric stream (account-level, namespace-filtered)
- AMG data source configuration (AMP + CloudWatch for alarms only)

**Projects/<project-id>** — owned and applied per project:
- Instantiates project-observer module with project.yaml values
- Provisions: namespace filter addition, Grafana folder,
  dashboard resources, project-level alarms
- Reads platform remote state for AMP and AMG workspace IDs
- Never reads foundation remote state directly

### Dependency direction
  foundation ← platform ← projects/<project-id>

### Apply order
  1. foundation
  2. platform
  3. projects/<project-id> (each independently)

### Destroy order
  1. projects/<project-id>
  2. platform
  3. foundation

---

## project-observer Module

Reusable module instantiated once per registered project.
Location: modules/project-observer/

### Inputs

| Variable              | Type         | Description                          |
|-----------------------|--------------|--------------------------------------|
| project_id            | string       | Unique project identifier            |
| display_name          | string       | Grafana folder name                  |
| owner                 | string       | Team name                            |
| metric_namespaces     | list(string) | Namespaces to register               |
| dashboard_definitions | list(object) | name + source_url per dashboard      |
| alert_definitions     | list(object) | Alert specs from project.yaml        |
| amg_workspace_id      | string       | From platform remote state           |
| grafana_url           | string       | AMG workspace HTTPS endpoint         |
| firehose_stream_arn   | string       | From platform remote state           |
| account_id            | string       | AWS account ID                       |
| environment           | string       | dev / staging / production           |
| tags                  | map(string)  | Standard tags                        |

Note: amp_workspace_id and kms_key_arn are NOT module inputs. The module
does not configure AMP directly — metrics flow through the platform
Firehose. The workflow spec example that lists kms_key_arn is incorrect.

### What it provisions
- grafana_folder — project folder in AMG (uid = project_id)
- grafana_dashboard — one per dashboard in project.yaml,
  JSON fetched from source_url at plan time via http data source
- aws_iam_role + aws_cloudwatch_metric_stream — per-project metric
  stream for custom namespaces only (see Namespace Filter below)
- aws_cloudwatch_metric_alarm — one per alert definition

### Namespace filter approach (Option A)

The platform-level CloudWatch metric stream covers AWS/* namespaces.
Custom project namespaces (e.g. AIPlatform/Quality) require a separate
per-project metric stream targeting the same platform Firehose ARN.

Decision: Option A — per-project stream for custom namespaces.
Rationale: Avoids cross-state dependency. The platform stream state
cannot be modified by a project-layer apply without sharing state,
which violates ADR-017. Each project stream is independently
destroyable without affecting other projects.

The module creates the per-project stream only when
`local.custom_namespaces` (namespaces not starting with "AWS/")
is non-empty. Projects that register only AWS/* namespaces get no
additional metric stream.

### Dashboard JSON fetching
Dashboard JSON is fetched from source_url at plan time using the
Terraform http data source. If a source_url is unreachable at plan
time the plan fails. This is intentional — broken URLs are caught
before apply, not after.

---

## Terraform State Configuration

  S3 bucket:       ai-observability-terraform-state-<env>-<account-id>
  DynamoDB table:  ai-observability-terraform-lock-<env>
  Region:          us-east-2

  Foundation:      <env>/foundation/terraform.tfstate
  Platform:        <env>/platform/terraform.tfstate
  Projects:        <env>/projects/<project-id>/terraform.tfstate

Create the S3 bucket and DynamoDB table manually before terraform init.
Never share state buckets with any other repository.
Account ID is always a variable — never hardcoded.

---

## Networking

Own VPC per environment, isolated from all other platform VPCs.
No VPC peering between platforms. Metric flow uses AWS service
endpoints only — no VPC-level connectivity required.

CIDR allocation convention for sandbox account:
  10.0.0.0/16  — AI platform (ai-platform-demo)
  10.1.0.0/16  — Observability platform (this repository)
  10.2.0.0/16  — Reserved for next platform

Dev environment:
  VPC CIDR:        10.1.0.0/16
  Private subnets: 10.1.1.0/24, 10.1.2.0/24 (us-east-2a/2b)

Never overlap CIDRs with other platforms.

---

## IAM Requirements

All roles inline per layer. IRSA always. No long-lived credentials.

### Layer placement — IAM roles live in the platform layer

The three service-to-service IAM roles are defined in
terraform/<env>/platform/main.tf, not in foundation.

Rationale: the Firehose delivery role requires aps:RemoteWrite
scoped to the exact AMP workspace ARN, and the CW stream role
requires firehose:PutRecord scoped to the exact Firehose stream
ARN. Both of those resources are created in the platform layer.
If the roles lived in foundation, their policies would need
account-scoped wildcard ARNs (arn:aws:aps:...:workspace/*) because
the exact workspace ARN does not exist until platform applies.
Moving the roles into the platform layer breaks this dependency
and allows all three policies to reference exact resource ARNs —
no wildcards except the CloudWatch service limitation below.

### Role definitions

**ai-observability-cw-stream-<env>**
Layer: platform
Trust: streams.metrics.cloudwatch.amazonaws.com
Permissions: firehose:PutRecord, firehose:PutRecordBatch
  on exact Firehose delivery stream ARN (same-layer resource)

**ai-observability-firehose-delivery-<env>**
Layer: platform
Trust: firehose.amazonaws.com
Permissions:
- aps:RemoteWrite on exact AMP workspace ARN (same-layer resource)
- s3:PutObject on exact Firehose buffer bucket ARN (foundation
  remote state output)
- kms:GenerateDataKey, kms:Decrypt on exact KMS key ARN
  (foundation remote state output)

**ai-observability-amg-datasource-<env>**
Layer: platform
Trust: grafana.amazonaws.com
Permissions:
- aps:QueryMetrics, aps:GetLabels, aps:GetSeries,
  aps:GetMetricMetadata on exact AMP workspace ARN (same-layer)
- cloudwatch:GetMetricData, cloudwatch:ListMetrics,
  cloudwatch:DescribeAlarmsForMetric on * (CW limitation)

Note: AMG CloudWatch data source is used for alarm state
visualisation only — not for log queries. Application logs
are never queried by the observability platform.

Note: CloudWatch metric APIs do not support resource-level ARN
scoping. The * on CloudWatch actions is a documented AWS service
limitation, not a policy gap.

---

## Dashboard Standards

All dashboard JSON must conform to specs/dashboard-standards.md.
Summary of mandatory requirements:

Template variables — every dashboard must include:
  $project_id    — filter by project
  $environment   — dev / staging / production
  $time_range    — Grafana time range picker

PromQL conventions:
- All metric names exactly as in the project's metric catalogue
- Filter by environment label on every query
- Use rate() for counter metrics
- P95 latency: histogram_quantile(0.95, ...)

Panel standards:
- Time series: include legend with last/min/max values
- Stat panels: include threshold colour coding
- Bar charts: include value labels
- All panels include description tooltip

Naming:
- Dashboard title: "<Display Name> — <Category>"
- Grafana folder: matches project_id exactly
- Panel titles: sentence case, no abbreviations

Dashboard JSON is the source of truth. Any edits made in the
AMG console are overwritten on next terraform apply.

---

## Branch and PR Conventions

### Branch naming
  Platform infrastructure:   feat/foundation-<description>
                             feat/platform-<description>
                             fix/<layer>-<description>
  Project registration:      obs/register-<project-id>
  Project update:            obs/update-<project-id>-<description>

### PR description — project registration must include
- Project ID and display name
- Owner team
- Namespaces being registered (list)
- Number of dashboards and number of alerts
- terraform plan summary (resources to add — no destroys)
- Link to Phase 2 PR in project repository
- Link to metric catalogue in project repository

### PR rules
- Never open a PR if terraform validate fails
- Never open a PR if terraform plan shows any destroy operations
- Never open a PR if project.yaml fails schema validation
  per specs/project-yaml-schema.md
- Always attach plan output to PR description

---

## File Conventions

Committed as real files:
- terraform/<env>/foundation/backend.tf     — Real values
- terraform/<env>/platform/backend.tf       — Real values
- terraform/<env>/projects/*/backend.tf     — Real values
- All *.tf module files                      — Always real
- terraform.tfvars.example                  — Placeholders
- .terraform.lock.hcl                       — Committed per layer

Git-ignored, never committed:
- */terraform.tfvars
- .terraform/
- *.tfstate and *.tfstate.backup
- crash.log
- override.tf

---

## Terraform Working Directory and Commands

Always run from the layer directory. Never from repo root.

```bash
# Foundation (platform team)
cd terraform/dev/foundation
terraform init
terraform plan -out=tfplan
terraform apply tfplan

# Platform (platform team)
cd terraform/dev/platform
terraform init
terraform plan -out=tfplan
terraform apply tfplan

# Project (project team's agent)
cd terraform/dev/projects/<project-id>
terraform init
terraform plan -out=tfplan
terraform apply tfplan

# Teardown
cd terraform/dev/projects/<id> && terraform destroy -auto-approve
cd terraform/dev/platform      && terraform destroy -auto-approve
cd terraform/dev/foundation    && terraform destroy -auto-approve
```

Never run terraform apply autonomously. Always plan first,
present output, and wait for explicit human approval.

---

## Commit Granularity

  feat(foundation): description
  feat(platform): description
  feat(projects/<id>): description
  feat(modules/project-observer): description
  fix(<layer>): description
  docs(scope): documentation only

---

## Documentation Gap Resolution

If guidance is missing from this CLAUDE.md, the ADR library,
or a spec document:

1. Stop. Do not make assumptions.
2. Surface the gap explicitly.
3. Generate a documentation update before proceeding.
4. Do not carry undocumented decisions forward.

---

## AMG Datasource Configuration — Known Constraints

Read this before modifying `grafana_data_source.amp` in the platform layer.

### Plugin availability

`grafana-amazonprometheus-datasource` is NOT available in this AMG workspace.
AMG network restrictions block external plugin installation. The only
available Prometheus plugin is the core `prometheus` plugin.

Do NOT attempt to use `type = "grafana-amazonprometheus-datasource"` in
`grafana_data_source` — the health check returns "Plugin not registered"
and dashboard panels report "Datasource does not exist".

### Correct datasource configuration

```hcl
resource "grafana_data_source" "amp" {
  type = "prometheus"                          # NOT grafana-amazonprometheus-datasource
  uid  = "amp-${var.environment}"
  url  = aws_prometheus_workspace.this.prometheus_endpoint

  json_data_encoded = jsonencode({
    sigV4Auth     = true
    sigV4AuthType = "default"                  # NOT "workspace_iam_role" — invalid value
    sigV4Region   = var.aws_region
    httpMethod    = "POST"
    timeInterval  = "60s"
  })
}
```

`sigV4AuthType = "default"` uses the AMG workspace IAM role via the AWS
SDK default credential chain. `"workspace_iam_role"` is not a valid value —
it causes the datasource to fail silently.

### Dashboard JSON datasource type

All dashboard JSON panels must use `"type": "prometheus"` when referencing
the AMP datasource:

```json
"datasource": {
  "type": "prometheus",
  "uid": "amp-dev"
}
```

Using `"type": "grafana-amazonprometheus-datasource"` causes "Datasource
does not exist" in panels because the plugin is not installed.

### Frontend cache flush after apply

After any Terraform apply that modifies `grafana_data_source.amp`, the
Grafana frontend datasource registry must be flushed manually:

1. Open **Connections → Data sources → Amazon Managed Prometheus — dev**
2. Click **Save & test**

Without this step, dashboard panels continue to report "Datasource
amp-dev does not exist" even after a successful apply.

### Future migration path

When AMG makes `grafana-amazonprometheus-datasource` available natively:
1. Change `type` to `"grafana-amazonprometheus-datasource"` and replace
   sigV4 fields with `authType = "default"` and `defaultRegion`.
2. Update dashboard JSON in all registered project repositories to change
   `"type": "prometheus"` → `"type": "grafana-amazonprometheus-datasource"`.
3. Re-apply platform and all project layers, then run Save & test.

---

## Definition of Done — Dev Environment

**Platform layer:**
- terraform apply completes with zero errors for both layers
- AMP workspace is ACTIVE
- AMG workspace is ACTIVE with AMP data source queryable
- Kinesis Firehose delivery stream is ACTIVE
- CloudWatch metric stream is ACTIVE streaming configured namespaces

**First project (ai-platform):**
- projects/ai-platform terraform apply completes with zero errors
- All three AI platform dashboards render in AMG without errors
- Quality trending dashboard shows LLM-as-Judge scores
- Agent operational health shows HR Assistant metrics
- Cost dashboard shows token consumption from AWS/Bedrock
- All alerts created and in OK state

**Standards:**
- VPC confirmed isolated — 10.1.0.0/16, no peering
- All IAM roles use IRSA — no long-lived credentials
- All dashboard JSON managed via Terraform — none manually created
- project.yaml validated against specs/project-yaml-schema.md
