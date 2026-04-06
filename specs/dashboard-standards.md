# Dashboard Standards

**Version:** 1.0
**Status:** Approved
**Repository:** ai-observability-platform
**Location:** specs/dashboard-standards.md
**Last updated:** April 2026

---

## 1. Overview

This document defines the standards that all Grafana dashboard JSON
files must conform to before being accepted into the observability
platform. These standards ensure dashboards are consistent, maintainable,
and functional across all registered projects.

Dashboard JSON files live in the project repository under
`specs/dashboards/<dashboard-name>.json`. They are applied to AMG
via the Grafana Terraform provider. Any dashboard that does not meet
these standards will be rejected at PR review.

The Claude Code agent reads this spec before generating any dashboard
JSON. All generated dashboards must conform to these standards without
exception.

---

## 2. File Conventions

### Naming
Dashboard JSON files must use lowercase letters, numbers, and hyphens.
No spaces, no uppercase, no special characters.

```
specs/dashboards/agent-operational-health.json   ✓
specs/dashboards/quality-trending.json           ✓
specs/dashboards/cost-token-consumption.json     ✓
specs/dashboards/Quality Trending.json           ✗ spaces not permitted
specs/dashboards/qualityTrending.json            ✗ camelCase not permitted
```

### Format
Valid JSON only. No comments. No trailing commas.
Validate with `python3 -m json.tool <file>` before committing.
Invalid JSON produces broken dashboards silently in AMG — the
dashboard renders empty rather than showing an error.

### Source of truth
The JSON file in the project repository is the source of truth.
Edits made in the AMG console are overwritten on next terraform apply.
All dashboard changes must go through the project repository PR workflow.

---

## 3. Required Top-Level Fields

Every dashboard JSON must include these top-level fields:

```json
{
  "title": "string",
  "uid": "string",
  "version": 1,
  "schemaVersion": 36,
  "timezone": "utc",
  "refresh": "1m",
  "time": {
    "from": "now-3h",
    "to": "now"
  },
  "templating": { "list": [] },
  "panels": [],
  "tags": [],
  "editable": true,
  "graphTooltip": 1
}
```

### title
Format: `"<Display Name> — <Category>"`
The display name comes from the project's display_name in project.yaml.
Category is a short descriptor of the dashboard's focus.

```
"Enterprise AI Platform — Quality Trending"      ✓
"Enterprise AI Platform — Agent Operational Health" ✓
"Quality Dashboard"                              ✗ missing display name
"enterprise ai platform quality"                 ✗ wrong case and format
```

### uid
A stable unique identifier for this dashboard across environments.
Format: `"<project-id>-<dashboard-name>"`
Maximum 40 characters. Lowercase letters, numbers, and hyphens only.
The uid must never change after the dashboard is first deployed —
changing it creates a duplicate dashboard rather than updating the
existing one.

```
"uid": "ai-platform-quality-trending"            ✓
"uid": "ai-platform-agent-operational-health"    ✓
"uid": "dashboard-1"                             ✗ not descriptive
```

### schemaVersion
Must be 36. This is the Grafana 9.x schema version compatible
with AMG.

### timezone
Must be "utc". Never use browser local time — dashboards must
display identically regardless of where they are viewed.

### refresh
Must be "1m" for operational dashboards.
May be "5m" for cost dashboards where data changes slowly.
Never disable auto-refresh (do not set to "").

### time
Default time range must be "now-3h" to "now".
This gives enough context to see trends without loading excessive
data on initial load.

---

## 4. Template Variables

Every dashboard must include these template variables in the
`templating.list` array. Variables allow engineers to filter
dashboards without editing them.

### Required variables

#### $environment
```json
{
  "name": "environment",
  "label": "Environment",
  "type": "custom",
  "query": "dev,staging,production",
  "current": { "value": "dev", "text": "dev" },
  "options": [
    { "value": "dev", "text": "dev", "selected": true },
    { "value": "staging", "text": "staging", "selected": false },
    { "value": "production", "text": "production", "selected": false }
  ],
  "hide": 0,
  "includeAll": false,
  "multi": false
}
```

#### $project_id
```json
{
  "name": "project_id",
  "label": "Project",
  "type": "custom",
  "query": "<project-id>",
  "current": { "value": "<project-id>", "text": "<project-id>" },
  "hide": 2,
  "includeAll": false,
  "multi": false
}
```

Note: `"hide": 2` makes this variable invisible in the UI but
available for use in queries. The value is fixed to the project's
own project_id — dashboards never display another project's data.

#### $agent_id (AI platform projects only)
Projects that have an AgentId dimension on their metrics must
include this variable:

```json
{
  "name": "agent_id",
  "label": "Agent",
  "type": "query",
  "datasource": { "type": "prometheus", "uid": "${datasource}" },
  "query": "label_values(QualityScore{environment=\"$environment\"}, AgentId)",
  "refresh": 2,
  "hide": 0,
  "includeAll": true,
  "allValue": ".*",
  "multi": false
}
```

### Variable usage in queries
Every PromQL query must filter by environment using the variable:

```
# Correct — filters by environment
QualityScore{environment="$environment", AgentId="$agent_id"}

# Wrong — no environment filter
QualityScore{AgentId="$agent_id"}

# Wrong — hardcoded environment
QualityScore{environment="dev"}
```

---

## 5. Panel Standards

### 5.1 Panel types and when to use them

| Panel type | Grafana type string | Use for |
|---|---|---|
| Time series | `timeseries` | Metrics that change over time — latency, scores, rates |
| Bar chart | `barchart` | Aggregated counts over discrete periods — tokens per day |
| Stat | `stat` | Single current values — error count, P95 latency now |
| Histogram | `histogram` | Score distributions, latency distributions |
| Table | `table` | Recent records, structured data from log queries |
| Gauge | `gauge` | Percentages and ratios with min/max bounds |

Never use the deprecated `graph` type — use `timeseries` instead.

### 5.2 Required panel fields

Every panel must include:

```json
{
  "type": "timeseries",
  "title": "string",
  "description": "string",
  "gridPos": { "x": 0, "y": 0, "w": 12, "h": 8 },
  "datasource": { "type": "prometheus", "uid": "${datasource}" },
  "targets": [],
  "options": {},
  "fieldConfig": {}
}
```

#### title
Sentence case. No abbreviations. Describes what the panel shows.
```
"Overall Quality Score per Agent"        ✓
"Latency P95 (ms)"                       ✓
"qual score"                             ✗ abbreviated
"LATENCY P95"                            ✗ all caps
```

#### description
One to three sentences explaining what the panel shows, why it
matters, and what action to take if the metric looks wrong.
Shown as a tooltip when hovering the panel title.

```json
"description": "Overall quality score per agent averaged across
                all five dimensions. Scores below 0.70 trigger
                the below-threshold alarm. If trending down,
                review recent below-threshold records in the
                quality scorer log group."
```

### 5.3 Time series panels

```json
{
  "type": "timeseries",
  "options": {
    "legend": {
      "displayMode": "table",
      "placement": "bottom",
      "calcs": ["last", "min", "max"]
    },
    "tooltip": { "mode": "multi" }
  },
  "fieldConfig": {
    "defaults": {
      "custom": {
        "lineWidth": 2,
        "fillOpacity": 10
      }
    }
  }
}
```

Legend must show last, min, and max values in table format.
This allows engineers to see at a glance whether a metric is
trending, without requiring time range analysis.

### 5.4 Stat panels

```json
{
  "type": "stat",
  "options": {
    "reduceOptions": {
      "calcs": ["lastNotNull"]
    },
    "colorMode": "background",
    "graphMode": "area",
    "textMode": "auto"
  },
  "fieldConfig": {
    "defaults": {
      "thresholds": {
        "mode": "absolute",
        "steps": []
      }
    }
  }
}
```

Stat panels must include threshold colour coding. Green/amber/red
thresholds calibrated to the metric's acceptable range. Use
`"colorMode": "background"` so the threshold colour is obvious.

### 5.5 Bar chart panels

```json
{
  "type": "barchart",
  "options": {
    "xField": "time",
    "stacking": "none",
    "legend": {
      "displayMode": "list",
      "placement": "bottom"
    }
  }
}
```

Bar charts used for daily aggregations must use a step of 86400
seconds (one day) in the PromQL query:

```
sum(increase(InputTokenCount{environment="$environment"}[1d]))
```

### 5.6 Grid layout

Dashboards use a 24-column grid. Standard panel sizes:

| Panel content | Width | Height |
|---|---|---|
| Full-width time series | 24 | 8 |
| Half-width time series | 12 | 8 |
| Quarter-width stat | 6 | 4 |
| Full-width table | 24 | 10 |
| Full-width histogram | 24 | 8 |

Stack panels vertically with no gaps. The first row must be
stat panels giving at-a-glance current values. Time series
panels follow below.

---

## 6. PromQL Query Standards

### 6.1 Metric name format
The observability platform encodes CloudWatch metric names in AMP
using this convention:

```
cloudwatch_{sanitized_namespace}_{sanitized_metric_name}_{value_type}
```

Where:
- `sanitized_namespace`: CloudWatch namespace with `/` and non-alphanumeric
  characters replaced by `_` (e.g. `AWS/Lambda` → `AWS_Lambda`,
  `AIPlatform/Quality` → `AIPlatform_Quality`)
- `sanitized_metric_name`: metric name with non-alphanumeric characters
  replaced by `_` (e.g. `InputTokenCount` → `InputTokenCount`)
- `value_type`: one of `sum`, `count`, `max`, `min` (CloudWatch statistics)

Examples:
```
# AWS/Lambda → Invocations → sum
cloudwatch_AWS_Lambda_Invocations_sum

# AWS/Bedrock → InputTokenCount → sum
cloudwatch_AWS_Bedrock_InputTokenCount_sum

# AIPlatform/Quality → QualityScore → sum
cloudwatch_AIPlatform_Quality_QualityScore_sum
```

All metric names in dashboard PromQL must use this format exactly.
Derive metric names from the project's metric catalogue — do not assume.

```
# Correct — uses platform naming convention
cloudwatch_AIPlatform_Quality_QualityScore_sum{environment="$environment", Dimension="overall"}

# Wrong — bare CloudWatch name without namespace prefix
QualityScore{environment="$environment"}

# Wrong — lowercase convention (not what the platform produces)
aws_lambda_invocations_sum{environment="$environment"}
```

Note: CloudWatch streams provide `sum`, `count`, `max`, `min` aggregations
only. Percentile metrics (p95, p99) are NOT available from CloudWatch metric
streams. Use `max` as a proxy for peak values or use `avg_over_time` on
the `sum`/`count` ratio.

### 6.2 Required label filters
Every query must filter by environment. All metrics emitted by the platform
Lambda include an `environment` label matching the deployment environment
(`dev`, `staging`, `production`).

```
# Correct
rate(cloudwatch_AWS_Lambda_Errors_sum{environment="$environment"}[5m])

# Wrong — missing environment filter
rate(cloudwatch_AWS_Lambda_Errors_sum[5m])
```

### 6.3 Rate vs instant
Use `rate()` for counter metrics. Use instant value for gauge
metrics. Never use raw counter values in time series panels.

```
# Counters — use rate()
rate(cloudwatch_AWS_Lambda_Invocations_sum{environment="$environment"}[5m])

# Gauges — use instant value
cloudwatch_AIPlatform_Quality_QualityScore_sum{environment="$environment", Dimension="overall"}
```

### 6.4 Percentile latency
CloudWatch metric streams do not produce histogram buckets or percentiles.
Use `max` for peak latency or `avg_over_time` for smoothed average. Never
reference `_p50`, `_p95`, or `_bucket` metric names — these do not exist
in AMP for CloudWatch-sourced metrics.

```
# Correct — use max as peak proxy
cloudwatch_AWS_Bedrock_InvocationLatency_max{environment="$environment"}

# Correct — smoothed average
avg_over_time(
  cloudwatch_AWS_Lambda_Duration_sum{environment="$environment"}[5m]
)

# Wrong — histogram_quantile requires _bucket metrics that don't exist
histogram_quantile(0.95,
  rate(InvocationLatency_bucket{environment="$environment"}[5m])
)

```
# If histogram available
histogram_quantile(0.95,
  rate(InvocationLatency_bucket{environment="$environment"}[5m])
)

# If only average available
avg_over_time(
  InvocationLatency{environment="$environment"}[5m]
)
```

Document in the panel description which approach is being used
and why.

### 6.5 Legend formatting
Use `{{label_name}}` in the legend field to show dimension values:

```json
"legendFormat": "{{AgentId}} — {{Dimension}}"
```

Never use `"legendFormat": ""` — this produces unhelpful
auto-generated legend labels.

---

## 7. Dashboard Layouts by Type

### 7.1 Agent operational health layout

```
Row 1 (stats, y=0):
  [Request Rate — last 1h] [Error Rate %] [P95 Latency ms] [Guardrail Blocks]
  w=6, h=4 each

Row 2 (time series, y=4):
  [Request Rate over time]
  w=24, h=8

Row 3 (time series, y=12):
  [Latency P50/P95/P99 over time]
  w=24, h=8

Row 4 (time series, y=20):
  [Error rate over time] [Guardrail block rate over time]
  w=12, h=8 each
```

### 7.2 Quality trending layout

```
Row 1 (stats, y=0):
  [Overall Score — last] [Below Threshold — last 24h]
  [Scorer Invocations — last 24h] [Scorer Errors — last 24h]
  w=6, h=4 each

Row 2 (time series, y=4):
  [Overall quality score over time per agent]
  w=24, h=8

Row 3 (time series, y=12):
  [Per-dimension scores over time]
  w=24, h=8

Row 4 (bar chart + histogram, y=20):
  [Below-threshold count per hour] [Score distribution]
  w=12, h=8 each
```

### 7.3 Cost and token consumption layout

```
Row 1 (stats, y=0):
  [Input tokens today] [Output tokens today]
  [Estimated cost today] [KB retrievals today]
  w=6, h=4 each

Row 2 (bar chart, y=4):
  [Input + output tokens per agent per day]
  w=24, h=8

Row 3 (time series, y=12):
  [Estimated cost per agent over time]
  w=24, h=8

Row 4 (time series, y=20):
  [KB retrieval count over time] [Scorer token consumption]
  w=12, h=8 each
```

---

## 8. Threshold Configuration

### 8.1 Quality score thresholds (0.0–1.0 metrics)

```json
"thresholds": {
  "mode": "absolute",
  "steps": [
    { "color": "red",    "value": null },
    { "color": "orange", "value": 0.50 },
    { "color": "yellow", "value": 0.70 },
    { "color": "green",  "value": 0.80 }
  ]
}
```

### 8.2 Error rate thresholds (percentage)

```json
"thresholds": {
  "mode": "absolute",
  "steps": [
    { "color": "green",  "value": null },
    { "color": "yellow", "value": 1 },
    { "color": "orange", "value": 5 },
    { "color": "red",    "value": 10 }
  ]
}
```

### 8.3 Latency thresholds (milliseconds)

```json
"thresholds": {
  "mode": "absolute",
  "steps": [
    { "color": "green",  "value": null },
    { "color": "yellow", "value": 3000 },
    { "color": "orange", "value": 8000 },
    { "color": "red",    "value": 15000 }
  ]
}
```

Adjust thresholds based on the SLA defined in the project's
agent manifest or architecture document. Document the threshold
values and their rationale in the panel description.

---

## 9. Validation Checklist

Before committing dashboard JSON, verify all of the following:

### File validity
- [ ] Valid JSON — passes `python3 -m json.tool <file>` with no errors
- [ ] Filename is lowercase-hyphens.json format
- [ ] uid is stable, unique, and follows `<project-id>-<dashboard-name>`

### Required fields
- [ ] title follows `"<Display Name> — <Category>"` format
- [ ] schemaVersion is 36
- [ ] timezone is "utc"
- [ ] refresh is set (not empty)
- [ ] time.from and time.to are set

### Template variables
- [ ] $environment variable present with dev/staging/production options
- [ ] $project_id variable present and hidden (hide: 2)
- [ ] $agent_id variable present if AgentId dimension is used
- [ ] Every PromQL query filters by environment="$environment"

### Panels
- [ ] Every panel has a title in sentence case
- [ ] Every panel has a description (1-3 sentences)
- [ ] No deprecated `graph` panel type used
- [ ] Time series panels have legend with last/min/max
- [ ] Stat panels have threshold colour coding
- [ ] All metric names match the project's metric catalogue exactly
- [ ] No hardcoded environment strings in queries

### Layout
- [ ] Row 1 contains stat panels for at-a-glance current values
- [ ] Panel gridPos values do not overlap
- [ ] Total grid width per row does not exceed 24

---

## 10. Standards Evolution

Changes to these standards require:

1. An ADR in the ADR library documenting the change and rationale
2. A version bump in the version field at the top of this document
3. Assessment of whether existing dashboards need updating
4. Update to the validation checklist in Section 9

Existing dashboards that predate a standards change are
grandfathered until their next update. New dashboards and
updated dashboards must always meet the current standard.
