################################################################################
# main.tf — Certificate Platform Infrastructure
# Services: S3 · DynamoDB · API Gateway · IAM · Lambda
################################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

################################################################################
# Variables
################################################################################

variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment (dev / staging / prod)"
  type        = string
  default     = "prod"
}

variable "project" {
  description = "Project name prefix applied to all resource names"
  type        = string
  default     = "certplatform"
}

locals {
  prefix = "${var.project}-${var.environment}"

  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

################################################################################
# Data Sources
################################################################################

data "aws_caller_identity" "current" {}

################################################################################
# DynamoDB — Companies Table
################################################################################

resource "aws_dynamodb_table" "kopera-company" {
  name         = "kopera-company"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "companyId"

  attribute {
    name = "companyId"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  tags = merge(local.common_tags, { Name = "kopera-company" })
}

################################################################################
# DynamoDB — Members Table
################################################################################

resource "aws_dynamodb_table" "kopera-member" {
  name         = "kopera-member"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "memberId"
  range_key    = "companyId"

  attribute {
    name = "memberId"
    type = "S"
  }

  attribute {
    name = "companyId"
    type = "S"
  }

  attribute {
    name = "issued_date"
    type = "S"
  }

  # GSI — all members belonging to a company
  global_secondary_index {
    name            = "CompanyMembersIndex"
    hash_key        = "companyId"
    projection_type = "ALL"
  }

  # GSI — all certificates sorted by issue date
  global_secondary_index {
    name            = "CertificateIssuedDateIndex"
    hash_key        = "memberId"
    range_key       = "issued_date"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  tags = merge(local.common_tags, { Name = "kopera-member" })
}

################################################################################
# S3 — Kopera Certificate Bucket
################################################################################

resource "aws_s3_bucket" "kopera-certificate" {
  bucket        = "kopera-certificate"
  force_destroy = false

  tags = merge(local.common_tags, { Name = "kopera-certificate" })
}

resource "aws_s3_bucket_versioning" "kopera-certificate" {
  bucket = aws_s3_bucket.kopera-certificate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "kopera-certificate" {
  bucket = aws_s3_bucket.kopera-certificate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "kopera-certificate" {
  bucket                  = aws_s3_bucket.kopera-certificate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "kopera-certificate" {
  bucket = aws_s3_bucket.kopera-certificate.id

  rule {
    id     = "certificates-transition-to-ia"
    status = "Enabled"

    filter {
      prefix = "certificates/"
    }

    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }

    noncurrent_version_expiration {
      noncurrent_days = 365
    }
  }
}

################################################################################
# S3 — Kopera Private Assets Bucket
################################################################################

resource "aws_s3_bucket" "kopera-asset" {
  bucket        = "kopera-asset"
  force_destroy = false

  tags = merge(local.common_tags, { Name = "kopera-asset" })
}

resource "aws_s3_bucket_versioning" "kopera-asset" {
  bucket = aws_s3_bucket.kopera-asset.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "kopera-asset" {
  bucket = aws_s3_bucket.kopera-asset.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "kopera-asset" {
  bucket                  = aws_s3_bucket.kopera-asset.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

################################################################################
# API Gateway — REST API
################################################################################

resource "aws_api_gateway_rest_api" "kopera-apigw" {
  name        = "kopera-apigw"
  description = "KAFA certificate platform backend API"

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = local.common_tags
}

# ── /certificates ─────────────────────────────────────────────────────────────

resource "aws_api_gateway_resource" "certificates" {
  rest_api_id = aws_api_gateway_rest_api.kopera-apigw.id
  parent_id   = aws_api_gateway_rest_api.kopera-apigw.root_resource_id
  path_part   = "certificates"
}

resource "aws_api_gateway_method" "certificates_post" {
  rest_api_id   = aws_api_gateway_rest_api.kopera-apigw.id
  resource_id   = aws_api_gateway_resource.certificates.id
  http_method   = "POST"
  authorization = "AWS_IAM"
}

resource "aws_api_gateway_method" "certificates_get" {
  rest_api_id   = aws_api_gateway_rest_api.kopera-apigw.id
  resource_id   = aws_api_gateway_resource.certificates.id
  http_method   = "GET"
  authorization = "AWS_IAM"
}

# ── /certificates/{certificateId} ─────────────────────────────────────────────

resource "aws_api_gateway_resource" "certificate_item" {
  rest_api_id = aws_api_gateway_rest_api.kopera-apigw.id
  parent_id   = aws_api_gateway_resource.certificates.id
  path_part   = "{certificateId}"
}

resource "aws_api_gateway_method" "certificate_item_get" {
  rest_api_id   = aws_api_gateway_rest_api.kopera-apigw.id
  resource_id   = aws_api_gateway_resource.certificate_item.id
  http_method   = "GET"
  authorization = "AWS_IAM"
}

# ── /companies ────────────────────────────────────────────────────────────────

resource "aws_api_gateway_resource" "companies" {
  rest_api_id = aws_api_gateway_rest_api.kopera-apigw.id
  parent_id   = aws_api_gateway_rest_api.kopera-apigw.root_resource_id
  path_part   = "companies"
}

resource "aws_api_gateway_method" "companies_post" {
  rest_api_id   = aws_api_gateway_rest_api.kopera-apigw.id
  resource_id   = aws_api_gateway_resource.companies.id
  http_method   = "POST"
  authorization = "AWS_IAM"
}

resource "aws_api_gateway_method" "companies_get" {
  rest_api_id   = aws_api_gateway_rest_api.kopera-apigw.id
  resource_id   = aws_api_gateway_resource.companies.id
  http_method   = "GET"
  authorization = "AWS_IAM"
}

# ── /members ──────────────────────────────────────────────────────────────────

resource "aws_api_gateway_resource" "members" {
  rest_api_id = aws_api_gateway_rest_api.kopera-apigw.id
  parent_id   = aws_api_gateway_rest_api.kopera-apigw.root_resource_id
  path_part   = "members"
}

resource "aws_api_gateway_method" "members_post" {
  rest_api_id   = aws_api_gateway_rest_api.kopera-apigw.id
  resource_id   = aws_api_gateway_resource.members.id
  http_method   = "POST"
  authorization = "AWS_IAM"
}

resource "aws_api_gateway_method" "members_get" {
  rest_api_id   = aws_api_gateway_rest_api.kopera-apigw.id
  resource_id   = aws_api_gateway_resource.members.id
  http_method   = "GET"
  authorization = "AWS_IAM"
}

# ── Deployment & Stage ────────────────────────────────────────────────────────

resource "aws_api_gateway_deployment" "kopera-apigw" {
  rest_api_id = aws_api_gateway_rest_api.kopera-apigw.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_integration.certificates_post.id,
      aws_api_gateway_integration.certificates_get.id,
      aws_api_gateway_integration.certificate_item_get.id,
      aws_api_gateway_integration.companies_post.id,
      aws_api_gateway_integration.companies_get.id,
      aws_api_gateway_integration.members_post.id,
      aws_api_gateway_integration.members_get.id,
    ]))
  }

  depends_on = [
    aws_api_gateway_integration.certificates_post,
    aws_api_gateway_integration.certificates_get,
    aws_api_gateway_integration.certificate_item_get,
    aws_api_gateway_integration.companies_post,
    aws_api_gateway_integration.companies_get,
    aws_api_gateway_integration.members_post,
    aws_api_gateway_integration.members_get,
  ]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "kopera-apigw" {
  deployment_id = aws_api_gateway_deployment.kopera-apigw.id
  rest_api_id   = aws_api_gateway_rest_api.kopera-apigw.id
  stage_name    = var.environment

  tags = local.common_tags
}

resource "aws_api_gateway_method_settings" "kopera-apigw" {
  rest_api_id = aws_api_gateway_rest_api.kopera-apigw.id
  stage_name  = aws_api_gateway_stage.kopera-apigw.stage_name
  method_path = "*/*"

  settings {
    metrics_enabled        = true
    throttling_burst_limit = 100
    throttling_rate_limit  = 50
  }
}

# ── Mock Integrations (placeholder until backend is connected) ────────────────

resource "aws_api_gateway_integration" "certificates_post" {
  rest_api_id = aws_api_gateway_rest_api.kopera-apigw.id
  resource_id = aws_api_gateway_resource.certificates.id
  http_method = aws_api_gateway_method.certificates_post.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_integration" "certificates_get" {
  rest_api_id = aws_api_gateway_rest_api.kopera-apigw.id
  resource_id = aws_api_gateway_resource.certificates.id
  http_method = aws_api_gateway_method.certificates_get.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_integration" "certificate_item_get" {
  rest_api_id = aws_api_gateway_rest_api.kopera-apigw.id
  resource_id = aws_api_gateway_resource.certificate_item.id
  http_method = aws_api_gateway_method.certificate_item_get.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_integration" "companies_post" {
  rest_api_id = aws_api_gateway_rest_api.kopera-apigw.id
  resource_id = aws_api_gateway_resource.companies.id
  http_method = aws_api_gateway_method.companies_post.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_integration" "companies_get" {
  rest_api_id = aws_api_gateway_rest_api.kopera-apigw.id
  resource_id = aws_api_gateway_resource.companies.id
  http_method = aws_api_gateway_method.companies_get.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_integration" "members_post" {
  rest_api_id = aws_api_gateway_rest_api.kopera-apigw.id
  resource_id = aws_api_gateway_resource.members.id
  http_method = aws_api_gateway_method.members_post.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_integration" "members_get" {
  rest_api_id = aws_api_gateway_rest_api.kopera-apigw.id
  resource_id = aws_api_gateway_resource.members.id
  http_method = aws_api_gateway_method.members_get.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

################################################################################
# IAM — Lambda Execution Role
################################################################################

data "aws_partition" "current" {}

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    sid     = "LambdaAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_exec" {
  name               = "${local.prefix}-lambda-exec"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "lambda_dynamodb" {
  statement {
    sid    = "DynamoDBTables"
    effect = "Allow"

    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:DeleteItem",
      "dynamodb:Query",
      "dynamodb:Scan",
      "dynamodb:BatchGetItem",
      "dynamodb:BatchWriteItem",
    ]

    resources = [
      aws_dynamodb_table.kopera-company.arn,
      aws_dynamodb_table.kopera-member.arn,
      "${aws_dynamodb_table.kopera-company.arn}/index/*",
      "${aws_dynamodb_table.kopera-member.arn}/index/*",
    ]
  }
}

resource "aws_iam_policy" "lambda_dynamodb" {
  name        = "${local.prefix}-lambda-dynamodb"
  description = "Allow Lambda to read/write DynamoDB tables"
  policy      = data.aws_iam_policy_document.lambda_dynamodb.json
  tags        = local.common_tags
}

resource "aws_iam_role_policy_attachment" "lambda_dynamodb" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.lambda_dynamodb.arn
}

data "aws_iam_policy_document" "lambda_s3" {
  statement {
    sid    = "S3CertificateBucket"
    effect = "Allow"

    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]

    resources = [
      aws_s3_bucket.kopera-certificate.arn,
      "${aws_s3_bucket.kopera-certificate.arn}/*",
    ]
  }

  statement {
    sid    = "S3AssetBucketRead"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:ListBucket",
    ]

    resources = [
      aws_s3_bucket.kopera-asset.arn,
      "${aws_s3_bucket.kopera-asset.arn}/*",
    ]
  }
}

resource "aws_iam_policy" "lambda_s3" {
  name        = "${local.prefix}-lambda-s3"
  description = "Allow Lambda to manage S3 objects"
  policy      = data.aws_iam_policy_document.lambda_s3.json
  tags        = local.common_tags
}

resource "aws_iam_role_policy_attachment" "lambda_s3" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.lambda_s3.arn
}

data "aws_iam_policy_document" "lambda_cloudwatch" {
  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"

    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:TagResource",
    ]

    resources = [
      "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.prefix}-*",
      "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.prefix}-*:*",
    ]
  }
}

resource "aws_iam_policy" "lambda_cloudwatch" {
  name        = "${local.prefix}-lambda-cloudwatch"
  description = "Allow Lambda to write CloudWatch logs"
  policy      = data.aws_iam_policy_document.lambda_cloudwatch.json
  tags        = local.common_tags
}

resource "aws_iam_role_policy_attachment" "lambda_cloudwatch" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.lambda_cloudwatch.arn
}

data "aws_iam_policy_document" "lambda_apigw" {
  statement {
    sid    = "InvokeAPIGateway"
    effect = "Allow"

    actions = ["execute-api:Invoke"]

    resources = [
      "${aws_api_gateway_rest_api.kopera-apigw.execution_arn}/${var.environment}/GET/members",
      "${aws_api_gateway_rest_api.kopera-apigw.execution_arn}/${var.environment}/GET/companies",
    ]
  }
}

resource "aws_iam_policy" "lambda_apigw" {
  name        = "${local.prefix}-lambda-apigw"
  description = "Allow Lambda to invoke its own API Gateway GET endpoints"
  policy      = data.aws_iam_policy_document.lambda_apigw.json
  tags        = local.common_tags
}

resource "aws_iam_role_policy_attachment" "lambda_apigw" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.lambda_apigw.arn
}

################################################################################
# Lambda — Certificate Handler (no code deployed yet)
################################################################################

resource "aws_lambda_function" "certificate_handler" {
  function_name = "${local.prefix}-certificate-handler"
  description   = "Generates PDF/JPEG certificates, uploads to S3, updates DynamoDB"

  s3_bucket = aws_s3_bucket.kopera-asset.id
  s3_key    = "lambda/placeholder.zip"

  runtime     = "python3.12"
  handler     = "handler.lambda_handler"
  role        = aws_iam_role.lambda_exec.arn
  timeout     = 60
  memory_size = 512

environment {
  variables = {
    COMPANIES_TABLE = aws_dynamodb_table.kopera-company.name
    MEMBERS_TABLE   = aws_dynamodb_table.kopera-member.name
    CERTS_BUCKET    = aws_s3_bucket.kopera-certificate.id
    ASSETS_BUCKET   = aws_s3_bucket.kopera-asset.id
    ENVIRONMENT     = var.environment
    API_BASE_URL    = "https://${aws_api_gateway_rest_api.kopera-apigw.id}.execute-api.${var.aws_region}.amazonaws.com/${var.environment}"
  }
}

  depends_on = [
    aws_iam_role_policy_attachment.lambda_dynamodb,
    aws_iam_role_policy_attachment.lambda_s3,
    aws_iam_role_policy_attachment.lambda_cloudwatch,
  ]

  tags = local.common_tags
}

resource "aws_lambda_permission" "apigw_invoke" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.certificate_handler.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.kopera-apigw.execution_arn}/${var.environment}/*/*"
}


################################################################################
# Outputs
################################################################################

output "api_gateway_invoke_url" {
  description = "Base invoke URL for the KAFA certificate API"
  value       = "https://${aws_api_gateway_rest_api.kopera-apigw.id}.execute-api.${var.aws_region}.amazonaws.com/${var.environment}"
}

output "api_gateway_id" {
  description = "ID of the API Gateway REST API"
  value       = aws_api_gateway_rest_api.kopera-apigw.id
}

output "companies_table_name" {
  description = "DynamoDB companies table name"
  value       = aws_dynamodb_table.kopera-company.name
}

output "companies_table_arn" {
  description = "DynamoDB companies table ARN"
  value       = aws_dynamodb_table.kopera-company.arn
}

output "members_table_name" {
  description = "DynamoDB members table name"
  value       = aws_dynamodb_table.kopera-member.name
}

output "members_table_arn" {
  description = "DynamoDB members table ARN"
  value       = aws_dynamodb_table.kopera-member.arn
}

output "kopera_certificate_bucket_name" {
  description = "Kopera certificate S3 bucket name"
  value       = aws_s3_bucket.kopera-certificate.id
}

output "kopera_certificate_bucket_arn" {
  description = "Kopera certificate S3 bucket ARN"
  value       = aws_s3_bucket.kopera-certificate.arn
}

output "kopera_certificate_prefix" {
  description = "S3 path prefix where certificates are stored"
  value       = "s3://${aws_s3_bucket.kopera-certificate.id}/certificates/"
}

output "kopera_asset_bucket_name" {
  description = "Kopera private assets S3 bucket name"
  value       = aws_s3_bucket.kopera-asset.id
}

output "kopera_asset_bucket_arn" {
  description = "Kopera private assets S3 bucket ARN"
  value       = aws_s3_bucket.kopera-asset.arn
}

output "lambda_function_name" {
  description = "Certificate handler Lambda function name"
  value       = aws_lambda_function.certificate_handler.function_name
}

output "lambda_function_arn" {
  description = "Certificate handler Lambda function ARN"
  value       = aws_lambda_function.certificate_handler.arn
}

