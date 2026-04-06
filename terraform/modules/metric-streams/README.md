# Module: metric-streams

Provisions the Kinesis Firehose delivery stream and CloudWatch
metric stream (account-level, namespace-filtered).

## Resources (to be defined)
- aws_kinesis_firehose_delivery_stream
- aws_cloudwatch_metric_stream
- S3 buffer bucket (from foundation outputs)

## Notes
- One stream per account per environment
- Namespace filter updated when projects register via project-observer
- Streams CloudWatch Metrics only — never log events
