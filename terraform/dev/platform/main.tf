terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.0"
    }
    grafana = {
      source  = "grafana/grafana"
      version = ">= 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

provider "grafana" {
  url  = "https://${aws_grafana_workspace.this.endpoint}"
  auth = var.grafana_auth
}

locals {
  tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
    Repository  = "ai-observability-platform"
    Layer       = "platform"
  }
}

# ── Foundation remote state ───────────────────────────────────────────────────
# IAM roles live in this layer so their policies can reference exact resource
# ARNs (AMP workspace, Firehose stream) — no account-scoped wildcards required.
# Foundation outputs consumed: kms_key_arn, firehose_buffer_bucket_arn,
# vpc_id, private_subnet_ids.

data "terraform_remote_state" "foundation" {
  backend = "s3"
  config = {
    bucket = "ai-observability-terraform-state-dev-${var.account_id}"
    key    = "dev/foundation/terraform.tfstate"
    region = "us-east-2"
  }
}

# ── Component 1: AMP Workspace ────────────────────────────────────────────────
# Single AMP workspace per environment. Encrypted with the foundation KMS key.

resource "aws_prometheus_workspace" "this" {
  alias       = "ai-observability-${var.environment}"
  kms_key_arn = data.terraform_remote_state.foundation.outputs.kms_key_arn

  tags = merge(local.tags, {
    Name      = "ai-observability-amp-${var.environment}"
    Component = "amp"
  })
}

# ── Component 2: AMG Workspace + amg_datasource IAM role ─────────────────────
# The amg_datasource role must exist before the workspace is created —
# Terraform resolves this via the implicit dependency on role_arn.
#
# KMS note: aws_grafana_workspace does not expose a kms_key_arn argument
# in the hashicorp/aws provider 5.x. AMG workspaces use AWS-owned encryption
# by default. Customer-managed KMS for AMG requires manual configuration
# outside Terraform. This is a known provider gap — track upstream issue
# and add kms_key_arn once the provider exposes it.

resource "aws_iam_role" "amg_datasource" {
  name = "ai-observability-amg-datasource-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "grafana.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = var.account_id
        }
      }
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "amg_datasource" {
  name = "amp-cloudwatch-kms-query"
  role = aws_iam_role.amg_datasource.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AMPQuery"
        Effect = "Allow"
        Action = [
          "aps:QueryMetrics",
          "aps:GetLabels",
          "aps:GetSeries",
          "aps:GetMetricMetadata"
        ]
        Resource = aws_prometheus_workspace.this.arn
      },
      {
        Sid    = "CloudWatchAlarmState"
        Effect = "Allow"
        Action = [
          "cloudwatch:GetMetricData",
          "cloudwatch:ListMetrics",
          "cloudwatch:DescribeAlarmsForMetric"
        ]
        # CloudWatch metric APIs do not support resource-level ARN scoping.
        # This is a documented AWS service limitation — see CLAUDE.md IAM section.
        Resource = "*"
      },
      {
        Sid    = "KMSDecrypt"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey"
        ]
        Resource = data.terraform_remote_state.foundation.outputs.kms_key_arn
      }
    ]
  })
}

resource "aws_grafana_workspace" "this" {
  name                      = "ai-observability-${var.environment}"
  account_access_type       = "CURRENT_ACCOUNT"
  authentication_providers  = ["AWS_SSO"]
  permission_type           = "SERVICE_MANAGED"
  data_sources              = ["PROMETHEUS", "CLOUDWATCH"]
  notification_destinations = []
  role_arn                  = aws_iam_role.amg_datasource.arn

  tags = merge(local.tags, {
    Name      = "ai-observability-amg-${var.environment}"
    Component = "amg"
  })
}

# ── AMG data source: AMP ──────────────────────────────────────────────────────
# Configures the Prometheus data source in AMG pointing to the AMP workspace.
# Uses SigV4 auth via the workspace IAM role (amg_datasource).
# UID is deterministic: amp-<environment> so dashboards can reference it
# without dynamic lookup.
# The Grafana provider uses an API key (var.grafana_auth) created out-of-band.

resource "grafana_data_source" "amp" {
  type = "prometheus"
  name = "Amazon Managed Prometheus — ${var.environment}"
  uid  = "amp-${var.environment}"
  url  = aws_prometheus_workspace.this.prometheus_endpoint

  json_data_encoded = jsonencode({
    sigV4Auth        = true
    sigV4AuthType    = "workspace_iam_role"
    sigV4Region      = var.aws_region
    httpMethod       = "POST"
    timeInterval     = "60s"
  })
}

# ── Component 3: AMP writer Lambda ───────────────────────────────────────────
#
# Firehose http_endpoint destination does NOT sign HTTP requests with SigV4 —
# the role_arn in http_endpoint_configuration only governs S3 backup writes,
# not the HTTP calls to the endpoint. AMP requires SigV4 on every request.
#
# Architecture: CloudWatch metric stream → Firehose (extended_s3 destination)
#   → Lambda transformation → AMP remote_write (SigV4-signed by Lambda)
#
# Firehose calls this Lambda synchronously as a data processor. The Lambda
# converts CloudWatch JSON records to Prometheus remote write format
# (protobuf + snappy), signs with SigV4 using its execution role, and POSTs
# to AMP. It returns all records as Ok so Firehose archives them to S3.
#
# Source: lambda/handler.py
# See README.md — Known limitations — for the full diagnostic narrative.

resource "null_resource" "lambda_build" {
  triggers = {
    handler_hash      = filemd5("${path.module}/lambda/handler.py")
    requirements_hash = filemd5("${path.module}/lambda/requirements.txt")
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      rm -rf "${path.module}/lambda/package"
      mkdir -p "${path.module}/lambda/package"
      python3 -m pip install \
        --quiet \
        --target "${path.module}/lambda/package" \
        --platform manylinux2014_x86_64 \
        --only-binary=:all: \
        --python-version 3.12 \
        --implementation cp \
        -r "${path.module}/lambda/requirements.txt"
      cp "${path.module}/lambda/handler.py" "${path.module}/lambda/package/"
    EOT
  }
}

data "archive_file" "lambda_amp_writer" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/package"
  output_path = "${path.module}/lambda/amp_writer.zip"
  depends_on  = [null_resource.lambda_build]
}

resource "aws_iam_role" "lambda_amp_writer" {
  name = "ai-observability-lambda-amp-writer-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "lambda_amp_writer" {
  name = "amp-write-logs"
  role = aws_iam_role.lambda_amp_writer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AMPRemoteWrite"
        Effect   = "Allow"
        Action   = ["aps:RemoteWrite"]
        Resource = aws_prometheus_workspace.this.arn
      },
      {
        Sid    = "KMSForAMP"
        Effect = "Allow"
        Action = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = data.terraform_remote_state.foundation.outputs.kms_key_arn
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/aws/lambda/ai-observability-amp-writer-${var.environment}:*"
      }
    ]
  })
}

resource "aws_lambda_function" "amp_writer" {
  filename         = data.archive_file.lambda_amp_writer.output_path
  source_code_hash = data.archive_file.lambda_amp_writer.output_base64sha256
  function_name    = "ai-observability-amp-writer-${var.environment}"
  role             = aws_iam_role.lambda_amp_writer.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 300
  memory_size      = 256

  environment {
    variables = {
      AMP_REMOTE_WRITE_URL = "${aws_prometheus_workspace.this.prometheus_endpoint}api/v1/remote_write"
      AMP_REGION           = var.aws_region
      ENVIRONMENT          = var.environment
    }
  }

  tags = merge(local.tags, {
    Name      = "ai-observability-amp-writer-${var.environment}"
    Component = "amp-writer"
  })

  depends_on = [data.archive_file.lambda_amp_writer]
}

# Break the Firehose ↔ Lambda permission circular dependency by computing
# the Firehose ARN from its known name rather than referencing the resource.
resource "aws_lambda_permission" "firehose_invoke" {
  statement_id  = "AllowFirehoseInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.amp_writer.function_name
  principal     = "firehose.amazonaws.com"
  source_arn    = "arn:aws:firehose:${var.aws_region}:${var.account_id}:deliverystream/ai-observability-amp-delivery-${var.environment}"
}

# ── Component 4: Kinesis Firehose + firehose_delivery IAM role ───────────────
#
# Destination: extended_s3. Firehose writes every record to S3 after invoking
# the Lambda transformation. S3 is the archive; AMP ingestion is via Lambda.
#
# The Firehose delivery role no longer needs aps:RemoteWrite — the Lambda
# execution role (aws_iam_role.lambda_amp_writer) holds that permission.
# The delivery role needs lambda:InvokeFunction to call the transformation.

resource "aws_iam_role" "firehose_delivery" {
  name = "ai-observability-firehose-delivery-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "firehose.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = var.account_id
        }
        ArnLike = {
          "aws:SourceArn" = "arn:aws:firehose:${var.aws_region}:${var.account_id}:deliverystream/ai-observability-amp-delivery-${var.environment}"
        }
      }
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "firehose_delivery" {
  name = "s3-kms-lambda-delivery"
  role = aws_iam_role.firehose_delivery.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "LambdaInvoke"
        Effect = "Allow"
        Action = ["lambda:InvokeFunction"]
        # Lambda ARN with :* to cover all versions and $LATEST.
        Resource = "${aws_lambda_function.amp_writer.arn}:*"
      },
      {
        Sid    = "FirehoseBufferS3"
        Effect = "Allow"
        Action = ["s3:PutObject"]
        Resource = "${data.terraform_remote_state.foundation.outputs.firehose_buffer_bucket_arn}/*"
      },
      {
        Sid    = "KMSEncryption"
        Effect = "Allow"
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt"
        ]
        Resource = data.terraform_remote_state.foundation.outputs.kms_key_arn
      }
    ]
  })
}

resource "aws_kinesis_firehose_delivery_stream" "this" {
  name        = "ai-observability-amp-delivery-${var.environment}"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn           = aws_iam_role.firehose_delivery.arn
    bucket_arn         = data.terraform_remote_state.foundation.outputs.firehose_buffer_bucket_arn
    prefix             = "metrics/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
    error_output_prefix = "errors/!{firehose:error-output-type}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
    buffering_size     = 5
    buffering_interval = 60
    compression_format = "GZIP"
    kms_key_arn        = data.terraform_remote_state.foundation.outputs.kms_key_arn

    processing_configuration {
      enabled = true

      processors {
        type = "Lambda"

        parameters {
          parameter_name  = "LambdaArn"
          parameter_value = "${aws_lambda_function.amp_writer.arn}:$LATEST"
        }
      }
    }
  }

  tags = merge(local.tags, {
    Name      = "ai-observability-amp-delivery-${var.environment}"
    Component = "firehose"
  })
}

# ── Component 5: CloudWatch Metric Stream + cw_stream IAM role ───────────────
# Account-level metric stream in json format.
# json format outputs newline-delimited CloudWatch JSON that the Lambda can
# parse directly without protobuf decoding.
#
# Note: output_format changed from opentelemetry1.0 to json to match the
# Lambda handler's CloudWatch JSON parser. Per-project streams in the
# project-observer module use the same format.

resource "aws_iam_role" "cw_stream" {
  name = "ai-observability-cw-stream-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "streams.metrics.cloudwatch.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = var.account_id
        }
      }
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "cw_stream" {
  name = "firehose-put-record"
  role = aws_iam_role.cw_stream.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "FirehosePutRecord"
      Effect = "Allow"
      Action = [
        "firehose:PutRecord",
        "firehose:PutRecordBatch"
      ]
      Resource = aws_kinesis_firehose_delivery_stream.this.arn
    }]
  })
}

resource "aws_cloudwatch_metric_stream" "this" {
  name          = "ai-observability-metric-stream-${var.environment}"
  role_arn      = aws_iam_role.cw_stream.arn
  firehose_arn  = aws_kinesis_firehose_delivery_stream.this.arn
  output_format = "json"

  # AWS-native namespaces streamed at platform level.
  # Project namespaces added per-project by project-observer module.
  include_filter { namespace = "AWS/Lambda" }
  include_filter { namespace = "AWS/DynamoDB" }
  include_filter { namespace = "AWS/Bedrock" }
  include_filter { namespace = "AWS/AOSS" }
  include_filter { namespace = "AWS/States" }

  tags = merge(local.tags, {
    Name      = "ai-observability-metric-stream-${var.environment}"
    Component = "metric-stream"
  })
}

# ── Component 6: Platform infrastructure alarms ───────────────────────────────
# Self-monitoring alarms on the observability platform itself.
# treat_missing_data = "notBreaching" prevents false alarms during periods
# with no stream activity (e.g. before the first project registers).

resource "aws_cloudwatch_metric_alarm" "firehose_s3_delivery_errors" {
  alarm_name          = "ai-observability-firehose-s3-errors-${var.environment}"
  alarm_description   = "Firehose S3 delivery success rate below 100%"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "DeliveryToS3.Success"
  namespace           = "AWS/Firehose"
  period              = 300
  statistic           = "Average"
  threshold           = 1
  treat_missing_data  = "notBreaching"

  dimensions = {
    DeliveryStreamName = aws_kinesis_firehose_delivery_stream.this.name
  }

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "lambda_amp_writer_errors" {
  alarm_name          = "ai-observability-amp-writer-errors-${var.environment}"
  alarm_description   = "AMP writer Lambda encountered invocation errors"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.amp_writer.function_name
  }

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "metric_stream_errors" {
  alarm_name          = "ai-observability-metric-stream-errors-${var.environment}"
  alarm_description   = "CloudWatch metric stream encountered delivery errors"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "MetricStreamErrors"
  namespace           = "AWS/CloudWatch/MetricStream"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"

  dimensions = {
    MetricStreamName = aws_cloudwatch_metric_stream.this.name
  }

  tags = local.tags
}
