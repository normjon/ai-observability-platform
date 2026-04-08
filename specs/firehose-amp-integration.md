# Firehose to AMP Integration

**Version:** 1.0
**Status:** Approved
**Repository:** ai-observability-platform
**Last updated:** April 2026

---

## 1. Overview

This document describes the technical architecture for delivering
CloudWatch metrics to Amazon Managed Prometheus (AMP) via Kinesis
Firehose. It exists to prevent future agents from attempting the
`http_endpoint` approach, which cannot work with AMP.

---

## 2. Why `http_endpoint` Cannot Be Used with AMP

Kinesis Firehose supports two destination types relevant to HTTP
delivery: `http_endpoint` and `extended_s3` with a Lambda processor.

**`http_endpoint` is incompatible with AMP for a fundamental reason:**

AMP's remote write endpoint (`/api/v1/remote_write`) requires every
HTTP request to be signed with AWS Signature Version 4 (SigV4) using
the `aps` service name. Firehose `http_endpoint` does NOT sign HTTP
requests. The `role_arn` field in `http_endpoint_configuration` governs
permissions for S3 backup writes only — it is not used to sign the HTTP
requests sent to the endpoint URL. Firehose will always receive a
`403 Forbidden` response from AMP when using `http_endpoint`.

There is no workaround. SigV4 signing must be performed in code.

**The correct architecture is `extended_s3` + Lambda transformation.**

---

## 3. Architecture

```
CloudWatch metric stream (output_format = "json")
        │
        ▼  PutRecord / PutRecordBatch
Kinesis Firehose delivery stream
  destination: extended_s3
        │
        ▼  synchronous Lambda transformation processor
AMP Writer Lambda (ai-observability-amp-writer-<env>)
  1. base64 decode the Firehose record
  2. gzip decompress
  3. split into newline-delimited JSON records
  4. parse each CloudWatch metric stream JSON record
  5. encode Prometheus remote write protobuf (hand-coded)
  6. snappy compress (cramjam)
  7. SigV4 sign using botocore
  8. POST to AMP remote_write endpoint
  9. return all records as result=Ok to Firehose
        │
        ▼  after Lambda returns
S3 bucket (ai-observability-firehose-buffer)
  prefix: metrics/year=.../month=.../day=.../
  Raw CloudWatch JSON — replay buffer for downstream failures
```

Firehose calls the Lambda synchronously before writing each batch to S3.
The Lambda handles the AMP write; Firehose handles S3 archival. These
are independent — a Lambda write failure raises an exception and Firehose
retries, but the S3 archive always receives the raw records.

---

## 4. Lambda Transformation Processor

### 4.1 Input format

Firehose passes records to the Lambda in this structure:

```json
{
  "records": [
    {
      "recordId": "...",
      "approximateArrivalTimestamp": 1620000000000,
      "data": "<base64-encoded gzip-compressed data>"
    }
  ]
}
```

Each `data` field contains base64-encoded, gzip-compressed,
newline-delimited CloudWatch metric stream JSON records.

### 4.2 CloudWatch metric stream JSON record format

The metric stream `output_format = "json"` produces records in this shape:

```json
{
  "metric_stream_name": "ai-observability-metric-stream-dev",
  "account_id": "096305373014",
  "region": "us-east-2",
  "namespace": "AWS/Lambda",
  "metric_name": "Invocations",
  "dimensions": {"FunctionName": "my-function"},
  "timestamp": 1620000000000,
  "value": {"max": 1.0, "min": 0.0, "sum": 5.0, "count": 5.0},
  "unit": "Count"
}
```

Each record expands to four Prometheus timeseries:
`cloudwatch_{namespace}_{metric_name}_{sum|count|max|min}`.

Namespace and metric name characters that are not alphanumeric or
underscore are replaced with underscores. For example,
`AWS/Lambda` → `AWS_Lambda`.

### 4.3 Prometheus remote write protobuf

The Prometheus remote write format is:

```protobuf
WriteRequest {
  repeated TimeSeries timeseries = 1;
}
TimeSeries {
  repeated Label  labels  = 1;
  repeated Sample samples = 2;
}
Label  { string name = 1; string value = 2; }
Sample { double value = 1; int64 timestamp = 2; }
```

The handler uses a hand-coded minimal protobuf encoder. No external
protobuf library is used — binary compatibility with the Firehose
execution environment is the reason. The encoder covers only the
wire types required: varint (type 0), 64-bit fixed (type 1), and
length-delimited (type 2).

### 4.4 Snappy compression

AMP remote write requires snappy-compressed protobuf bodies with the
header `Content-Encoding: snappy`.

The handler uses `cramjam.snappy.compress_raw()` (raw snappy, not
framed snappy). `cramjam` is the only external dependency.

### 4.5 SigV4 signing pattern

```python
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
import boto3

session = boto3.Session()
credentials = session.get_credentials().get_frozen_credentials()

aws_req = AWSRequest(
    method='POST',
    url=amp_remote_write_url,
    data=snappy_compressed_body,
    headers={
        'Content-Type': 'application/x-protobuf',
        'Content-Encoding': 'snappy',
        'X-Prometheus-Remote-Write-Version': '0.1.0',
    },
)
SigV4Auth(credentials, 'aps', region).add_auth(aws_req)
```

The service name is `aps` (not `aps-remote-write` or `prometheus`).
The region must match the AMP workspace region.

Credentials come from `boto3.Session().get_credentials()` which resolves
via the standard AWS credential chain — in Lambda this is the execution
role. No explicit credential configuration is required.

### 4.6 Lambda return value

The Lambda returns all records as `Ok` regardless of whether the AMP
write succeeded:

```python
return {
    'records': [
        {'recordId': r['recordId'], 'result': 'Ok', 'data': r['data']}
        for r in event['records']
    ]
}
```

Returning `Ok` ensures Firehose archives the original records to S3.
Returning `ProcessingFailed` would cause Firehose to write the records
to the error prefix — which means they would not be archived in the
normal metrics prefix and would not be retried by Firehose.

AMP write failures raise exceptions, which Firehose handles as Lambda
invocation errors. Firehose retries the invocation according to its
retry configuration.

---

## 5. x86_64 Architecture Requirement

The Firehose Lambda MUST use `x86_64` architecture, not `arm64`.

Kinesis Firehose transformation processors run on x86 infrastructure.
If the Lambda is deployed with `arm64`, the execution environment
architecture mismatch causes silent transformation failures. Records
are not written to AMP and no actionable error is surfaced.

This is the only Lambda in the observability platform exempt from the
ADR-004 arm64/Graviton requirement.

Build the Lambda package with the manylinux x86 target:

```bash
pip install \
  --platform manylinux2014_x86_64 \
  --target=lambda/package/ \
  --only-binary=:all: \
  --python-version 3.12 \
  --implementation cp \
  -r lambda/requirements.txt
```

In Terraform, the `null_resource.lambda_build` uses a `local-exec`
provisioner that runs this command automatically when `handler.py`
or `requirements.txt` changes.

---

## 6. cramjam Dependency

`cramjam==2.9.1` is the only external dependency in `requirements.txt`.

`cramjam` provides Rust-backed snappy compression. It is preferred over
`python-snappy` because it ships as a pre-compiled wheel for the
manylinux2014_x86_64 platform without requiring native library headers
at install time.

All other dependencies (boto3, botocore, urllib) are included in the
Python 3.12 Lambda runtime.

Do not add protobuf libraries (`protobuf`, `grpcio-tools`, etc.). The
hand-coded protobuf encoder in `handler.py` covers the minimal schema
needed for Prometheus remote write and avoids binary compatibility
issues in the Lambda execution environment.

---

## 7. Operational Considerations

### 7.1 Lambda timeout

The Lambda timeout is set to 300 seconds (5 minutes). The default 3
minutes is sufficient for typical Firehose batch sizes. Do not reduce
below 60 seconds — large metric batches during initial stream activation
can require significant processing time.

### 7.2 Firehose buffering and metric latency

The Firehose delivery stream is configured with:
- `buffering_size = 5` MB
- `buffering_interval = 60` seconds

Firehose triggers a delivery when either threshold is reached. This
introduces up to 60 seconds of latency between a metric being emitted
to CloudWatch and it appearing in AMP. Dashboard time ranges should
account for this — a 1-minute minimum time range is recommended.

### 7.3 S3 archive as replay buffer

The `extended_s3` destination archives every CloudWatch JSON record to
the Firehose buffer S3 bucket at:

```
metrics/year=YYYY/month=MM/day=DD/
```

This archive can be used to replay metrics into AMP if:
- The AMP workspace is recreated after a destroy
- The Lambda had a bug that dropped metric values
- The metric stream was misconfigured for a period

To replay: read records from S3, decompress, re-process through the
Lambda transformation logic, and POST to AMP remote write.

### 7.4 Debugging with CloudWatch Logs

The Lambda logs to CloudWatch Logs at:
```
/aws/lambda/ai-observability-amp-writer-<env>
```

Log entries include:
- Successful writes: `Wrote N timeseries to AMP`
- AMP rejections: `AMP write rejected: HTTP NNN — <body>`
- Malformed record skips: `Skipping malformed record: <error>`

A single malformed record does not stop processing of the batch.
Skipped records are still archived to S3.

---

## 8. PromQL Query Patterns for CloudWatch Gauge Metrics

This section explains a critical distinction that affects every dashboard
panel querying CloudWatch-sourced metrics in AMP.

### 8.1 CloudWatch metrics are gauges in AMP, not counters

When the AMP writer Lambda writes a CloudWatch metric stream record to AMP
via remote write, each CloudWatch aggregation period (typically 1 minute)
produces a **single independent gauge sample**. The value represents what
CloudWatch measured in that one period — it does not accumulate across periods.

This is fundamentally different from native Prometheus counters, which are
monotonically increasing and designed for `rate()` and `increase()`.

| Prometheus function | Works on counters | Works on CloudWatch gauges |
|---|---|---|
| `rate(metric[5m])` | Yes | **No** — always returns 0 |
| `increase(metric[window])` | Yes | **No** — always returns 0 |
| `sum_over_time(metric[window])` | Rarely useful | **Yes** — correct for totals |
| `metric_sum / metric_count` | N/A | **Yes** — correct for averages |
| `metric_max` | N/A | **Yes** — correct for peaks |

### 8.2 Correct patterns

```promql
# Summing counts over a time window (e.g. invocations in 24h)
sum(sum_over_time(cloudwatch_AWS_Bedrock_Invocations_sum{environment="$environment"}[24h]))

# Per-record average (e.g. quality scores, latency averages)
cloudwatch_AIPlatform_Quality_QualityScore_sum{environment="$environment", Dimension="overall"}
  / cloudwatch_AIPlatform_Quality_QualityScore_count{environment="$environment", Dimension="overall"}

# Peak value (e.g. max document count, max latency)
cloudwatch_AWS_AOSS_SearchableDocuments_max{environment="$environment"}

# Rate of events per minute (approximation — not true rate())
sum_over_time(cloudwatch_AWS_Lambda_Invocations_sum{environment="$environment"}[5m]) / 5
```

### 8.3 Why `increase()` returns 0

`increase()` computes `(last_value - first_value)` over the window, adjusted
for counter resets. For a gauge that emits `5` in period 1 and `5` in period 2,
`increase()` returns `5 - 5 = 0`. The metric has not increased — it emits
the same value each period. This is correct gauge behaviour, not a bug.

### 8.4 Prometheus staleness window

AMP applies a 5-minute staleness window to instant queries. If the most recent
sample for a metric is older than 5 minutes, the query returns no data. This
affects batch-driven metrics (e.g. the quality scorer runs hourly):

- **Stat panels** (`lastNotNull`) show "No data" when the last scorer run was
  more than 5 minutes ago.
- **Timeseries panels** display the full historical record regardless of staleness.

This is expected behaviour. Document it in affected panel descriptions.

---

## 9. Known Limitations

### 8.1 `opentelemetry1.0` format incompatible with Lambda parser

The CloudWatch metric stream `output_format` must be `"json"`.

The `opentelemetry1.0` format produces binary OTLP protobuf records.
The Lambda handler parses records as UTF-8 text. Binary OTLP records
cause `UnicodeDecodeError` and are silently skipped with a warning log.
Do not switch the metric stream or any per-project metric stream to
`opentelemetry1.0`.

### 8.2 AMG plugin restrictions

The `grafana-amazonprometheus-datasource` Grafana plugin (recommended
for AMP in Grafana 10+) is not available for installation in this AMG
workspace. AMG network restrictions block external plugin downloads.
See `CLAUDE.md — AMG Datasource Configuration` and the platform
`README.md — Known limitations` for the current datasource configuration
and future migration path.

### 8.3 AMP KMS encryption — Lambda permission requirement

The AMP workspace is encrypted with a customer-managed KMS key (CMK)
provisioned in the foundation layer. AMP enforces KMS authorisation for
all remote write operations on CMK-encrypted workspaces.

The Lambda execution role requires **both**:
- `aps:RemoteWrite` on the AMP workspace ARN
- `kms:GenerateDataKey` and `kms:Decrypt` on the KMS key ARN

`aps:RemoteWrite` alone is insufficient and will result in a 403 from AMP
with a KMS authorisation error in the response body.
