# Platform Layer — README

Provisions the observability platform: AMP workspace, AMG workspace, Kinesis
Firehose delivery stream, CloudWatch metric stream, IAM roles, and the Lambda
that writes metrics to AMP.

---

## Metric flow

```
CloudWatch metric stream (JSON)
        │
        ▼  PutRecord
Kinesis Firehose (extended_s3)
        │
        ▼  Lambda transformation (synchronous)
ai-observability-amp-writer Lambda
        │  - base64 decode + gzip decompress records
        │  - parse CloudWatch JSON
        │  - encode Prometheus remote write protobuf
        │  - snappy compress (cramjam)
        │  - SigV4 sign with botocore
        │  POST → AMP remote_write
        │
        ▼  S3 archive (raw CloudWatch JSON)
ai-observability-firehose-buffer S3 bucket
```

---

## Architecture decision: Firehose `extended_s3` + Lambda, not `http_endpoint`

**Do not use `http_endpoint` destination to write directly to AMP.**

Kinesis Firehose `http_endpoint` destinations do NOT support SigV4 request
signing. The `role_arn` field in `http_endpoint_configuration` controls S3
backup permissions only — it is not used to sign HTTP requests to the
endpoint. AMP requires SigV4-signed requests with the `aps` service name.
Firehose will always receive a 403 from AMP with `http_endpoint`.

The correct architecture (per AWS documentation) is:
- Firehose `extended_s3` destination
- Lambda transformation processor attached to the delivery stream
- Lambda performs the CloudWatch JSON → Prometheus protobuf conversion,
  snappy compression, SigV4 signing, and HTTP POST to AMP
- Firehose archives the raw CloudWatch JSON to S3 as a replay buffer

Reference implementation:
https://github.com/aws-observability/observability-best-practices/tree/main/sandbox/CWMetricStreamExporter

---

## CloudWatch metric stream output format

The metric stream uses `output_format = "json"` (newline-delimited CloudWatch
JSON records). The Lambda parser is written for this format.

Do NOT switch to `opentelemetry1.0` — that format produces binary OTLP
protobuf which the Lambda cannot parse as text. The project-observer module
also uses `output_format = "json"` for its per-project streams.

---

## Lambda (`lambda/`)

`handler.py` — hand-coded Prometheus remote write protobuf encoder, no
external protobuf library. Uses cramjam for snappy compression and botocore
for SigV4 signing.

`requirements.txt` — `cramjam==2.9.1` only. All other dependencies
(boto3, botocore) are included in the Lambda runtime.

The Lambda build is managed by a `null_resource` in `main.tf` that runs pip
with `--platform manylinux2014_x86_64` to produce Linux-compatible wheels on
macOS. The build hash triggers on changes to `handler.py` or
`requirements.txt`.

---

## IAM

Three service roles are defined here (not in foundation) so their policies
can reference exact same-layer resource ARNs — no wildcards required.
See CLAUDE.md IAM Requirements section for full rationale.

The Lambda execution role (`ai-observability-lambda-amp-writer-dev`) requires
`kms:GenerateDataKey` and `kms:Decrypt` on the foundation KMS key because the
AMP workspace is encrypted with a customer-managed key. `aps:RemoteWrite`
alone is not sufficient — AMP enforces KMS authorization for all writes to
CMK-encrypted workspaces.

---

## Apply

```bash
cd terraform/dev/platform
terraform init
terraform plan -var-file=terraform.tfvars -out=tfplan
terraform apply tfplan
```

`terraform.tfvars` is git-ignored. Copy `terraform.tfvars.example` and set
`account_id` to the sandbox account ID.

After any apply that modifies `grafana_data_source.amp`, open
**Connections → Data sources → Amazon Managed Prometheus — dev → Save & test**
in the Grafana UI. Grafana's frontend datasource registry caches the prior
state; dashboard panels show "Datasource amp-dev does not exist" until the
cache is flushed by Save & test.

---

## Known limitations

**`grafana-amazonprometheus-datasource` plugin unavailable**
AMG network restrictions prevent external plugin installation. The
`grafana-amazonprometheus-datasource` plugin (the recommended replacement
for SigV4 in Grafana 10+) cannot be installed via the Grafana plugin API.
The workspace uses the core `prometheus` plugin with `sigV4Auth = true`
and `sigV4AuthType = "default"`. This configuration is deprecated in
Grafana 10 but remains functional.

Future: when AWS makes `grafana-amazonprometheus-datasource` available
natively in AMG, migrate by:
1. Changing `type` in `grafana_data_source.amp` from `"prometheus"` to
   `"grafana-amazonprometheus-datasource"` and replacing sigV4 fields
   with `authType = "default"` and `defaultRegion`.
2. Updating all registered project dashboard JSON files to change their
   datasource panel `"type"` from `"prometheus"` to
   `"grafana-amazonprometheus-datasource"`.
3. Running Save & test after apply.

**`sigV4AuthType = "workspace_iam_role"` is invalid**
This value is not a valid sigV4AuthType. Use `"default"` which resolves
to the workspace IAM role via the AWS SDK default credential chain.
Do not reuse `"workspace_iam_role"` — it causes the datasource to fail
silently (health check may pass via API while dashboard panels report
"Datasource does not exist").

**`pluginAdminEnabled = true`**
Plugin admin was enabled on the workspace to attempt installation of
`grafana-amazonprometheus-datasource`. The installation was blocked by
network restrictions but the setting is harmless and left enabled.

**AMG customer-managed KMS**
`aws_grafana_workspace` in hashicorp/aws 5.x does not expose a
`kms_key_arn` argument. AMG workspaces use AWS-owned encryption by
default. Track the upstream provider issue and add `kms_key_arn` once
the provider exposes it.

---

## Troubleshooting

### Dashboard panels show "Datasource does not exist"

Run **Save & test** on the AMP data source in the Grafana UI
(**Connections → Data sources → Amazon Managed Prometheus — dev →
Save & test**). Grafana caches the prior datasource state in its
frontend registry. This must be done after every `terraform apply`
that modifies `grafana_data_source.amp`.

If Save & test itself fails with a 403, check:
- The `amg_datasource` IAM role has `aps:QueryMetrics` on the AMP workspace
- `sigV4AuthType` is `"default"` not `"workspace_iam_role"` (invalid)
- The workspace region matches the AMP workspace region

### Metrics not appearing in dashboards after 10+ minutes

Check in this order:

1. **CloudWatch** — confirm the metric exists in the source namespace
   using the CloudWatch console Metrics browser.
2. **Metric stream** — confirm RUNNING state in the console; check the
   stream error metrics in CloudWatch (`MetricStreamErrors` alarm).
3. **Firehose** — check Lambda transformation errors in the delivery
   stream **Monitoring** tab in the AWS console. Look for
   `DeliveryToS3.DataFreshness` and `SucceedProcessing.Records`.
4. **Lambda logs** — check CloudWatch Logs at
   `/aws/lambda/ai-observability-amp-writer-dev` for AMP write errors.
5. **AMP direct query** — use AMG **Explore** → select the Prometheus
   data source → query `{__name__=~".+"}` to confirm whether metrics
   exist in AMP independent of dashboard rendering.

### Lambda transformation errors

Common causes:

- **CloudWatch JSON format changed** — check `handler.py` parser against
  the current metric stream record format.
- **cramjam version mismatch** — verify `requirements.txt` specifies
  `cramjam==2.9.1` and the Lambda package was built with
  `--platform manylinux2014_x86_64`.
- **AMP remote write endpoint changed** — check the `AMP_REMOTE_WRITE_URL`
  environment variable against the current workspace endpoint in
  Terraform outputs.
- **KMS permissions** — the Lambda execution role requires both
  `aps:RemoteWrite` AND `kms:GenerateDataKey`/`kms:Decrypt`. AMP
  enforces KMS authorisation for CMK-encrypted workspaces.
  `aps:RemoteWrite` alone is insufficient.
