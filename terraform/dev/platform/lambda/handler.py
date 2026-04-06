"""
AMP writer — Kinesis Firehose transformation handler.

Firehose calls this Lambda as a data processor before writing records to S3.
The Lambda converts each CloudWatch metric stream JSON record to Prometheus
remote write format (protobuf + snappy), signs the write request with SigV4,
and POSTs it to the AMP remote_write endpoint.

Records are returned to Firehose as-is with result=Ok so Firehose archives
the raw CloudWatch JSON to S3 for replay in case of downstream failures.

Required environment variables:
  AMP_REMOTE_WRITE_URL  Full URL: https://aps-workspaces.{region}.amazonaws.com/
                        workspaces/{workspace_id}/api/v1/remote_write
  AMP_REGION            AWS region of the AMP workspace (e.g. us-east-2)

IAM requirements:
  Lambda execution role must have aps:RemoteWrite on the AMP workspace ARN.
"""

import base64
import gzip
import json
import logging
import os
import struct
import urllib.error
import urllib.request

import boto3
import cramjam
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest

logger = logging.getLogger()
logger.setLevel(logging.INFO)


# ─── Minimal Prometheus remote write protobuf encoder ────────────────────────
#
# Schema: WriteRequest { repeated TimeSeries timeseries = 1; }
#         TimeSeries  { repeated Label labels = 1; repeated Sample samples = 2; }
#         Label       { string name = 1; string value = 2; }
#         Sample      { double value = 1; int64 timestamp = 2; }
#
# Wire types used: 1 = 64-bit fixed, 2 = LEN (length-delimited).

def _varint(v: int) -> bytes:
    out = []
    while True:
        b = v & 0x7F
        v >>= 7
        if v:
            out.append(b | 0x80)
        else:
            out.append(b)
            break
    return bytes(out)


def _len_field(field_number: int, data: bytes) -> bytes:
    tag = _varint((field_number << 3) | 2)
    return tag + _varint(len(data)) + data


def _str_field(field_number: int, s: str) -> bytes:
    return _len_field(field_number, s.encode())


def _double_field(field_number: int, v: float) -> bytes:
    return _varint((field_number << 3) | 1) + struct.pack('<d', v)


def _int64_field(field_number: int, v: int) -> bytes:
    # int64 uses wire type 0 (varint), not wire type 1 (fixed64)
    tag = _varint((field_number << 3) | 0)
    # Treat as unsigned 64-bit for varint encoding (handles negative values too)
    if v < 0:
        v += 1 << 64
    return tag + _varint(v)


def _encode_label(name: str, value: str) -> bytes:
    return _str_field(1, name) + _str_field(2, value)


def _encode_sample(value: float, timestamp_ms: int) -> bytes:
    return _double_field(1, value) + _int64_field(2, timestamp_ms)


def _encode_timeseries(labels: list, value: float, timestamp_ms: int) -> bytes:
    data = b''.join(_len_field(1, _encode_label(n, v)) for n, v in labels)
    data += _len_field(2, _encode_sample(value, timestamp_ms))
    return data


def _encode_write_request(timeseries: list) -> bytes:
    return b''.join(_len_field(1, ts) for ts in timeseries)


# ─── CloudWatch JSON → Prometheus timeseries ─────────────────────────────────
#
# CloudWatch metric stream JSON format (output_format = "json"):
# {
#   "metric_stream_name": "...",
#   "account_id": "...",
#   "region": "...",
#   "namespace": "AWS/Lambda",
#   "metric_name": "Invocations",
#   "dimensions": {"FunctionName": "my-function"},
#   "timestamp": 1620000000000,
#   "value": {"max": 1.0, "min": 0.0, "sum": 5.0, "count": 5.0},
#   "unit": "Count"
# }
#
# Each record expands to 4 Prometheus timeseries: sum, count, max, min.
# Metric name: cloudwatch_{sanitized_namespace}_{sanitized_metric_name}_{value_type}

_VALUE_TYPES = ('sum', 'count', 'max', 'min')


def _sanitize(s: str) -> str:
    """Replace non-alphanumeric (except underscore) characters with underscores."""
    return ''.join(c if (c.isalnum() or c == '_') else '_' for c in s)


def _cw_record_to_timeseries(record: dict) -> list:
    ts_ms = int(record['timestamp'])
    ns = _sanitize(record['namespace'])
    metric = _sanitize(record['metric_name'])
    region = record.get('region', '')

    base_labels = [
        ('namespace', ns),
        ('metric_name', metric),
        ('region', region),
    ]
    for k, v in record.get('dimensions', {}).items():
        base_labels.append((_sanitize(k), str(v)))

    timeseries = []
    for vtype in _VALUE_TYPES:
        val = record['value'].get(vtype)
        if val is None:
            continue
        labels = [('__name__', f'cloudwatch_{ns}_{metric}_{vtype}')] + base_labels
        timeseries.append(_encode_timeseries(labels, float(val), ts_ms))
    return timeseries


# ─── SigV4-signed POST to AMP ─────────────────────────────────────────────────

def _send_to_amp(protobuf_body: bytes, url: str, region: str) -> None:
    compressed = bytes(cramjam.snappy.compress_raw(protobuf_body))

    session = boto3.Session()
    credentials = session.get_credentials().get_frozen_credentials()

    aws_req = AWSRequest(
        method='POST',
        url=url,
        data=compressed,
        headers={
            'Content-Type': 'application/x-protobuf',
            'Content-Encoding': 'snappy',
            'X-Prometheus-Remote-Write-Version': '0.1.0',
        },
    )
    SigV4Auth(credentials, 'aps', region).add_auth(aws_req)
    prepped = aws_req.prepare()

    http_req = urllib.request.Request(
        url,
        data=compressed,
        headers=dict(prepped.headers),
        method='POST',
    )
    try:
        with urllib.request.urlopen(http_req, timeout=15) as resp:
            logger.info("AMP write accepted: HTTP %d", resp.status)
    except urllib.error.HTTPError as exc:
        body = exc.read().decode(errors='replace')
        logger.error("AMP write rejected: HTTP %d — %s", exc.code, body)
        raise


# ─── Handler ──────────────────────────────────────────────────────────────────

def handler(event, context):
    amp_url = os.environ['AMP_REMOTE_WRITE_URL']
    amp_region = os.environ.get('AMP_REGION', os.environ.get('AWS_REGION', 'us-east-2'))

    timeseries = []

    for record in event.get('records', []):
        raw = base64.b64decode(record['data'])
        try:
            text = gzip.decompress(raw).decode()
        except OSError:
            try:
                text = raw.decode()
            except UnicodeDecodeError:
                logger.warning("Skipping non-UTF-8 record (likely pre-format-switch OTLP binary)")
                continue

        for line in text.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                cw = json.loads(line)
                timeseries.extend(_cw_record_to_timeseries(cw))
            except (json.JSONDecodeError, KeyError, ValueError) as exc:
                logger.warning("Skipping malformed record: %s", exc)

    if timeseries:
        write_request = _encode_write_request(timeseries)
        _send_to_amp(write_request, amp_url, amp_region)
        logger.info("Wrote %d timeseries to AMP", len(timeseries))

    # Return all records as Ok — Firehose archives them to S3 unchanged.
    return {
        'records': [
            {'recordId': r['recordId'], 'result': 'Ok', 'data': r['data']}
            for r in event.get('records', [])
        ]
    }
