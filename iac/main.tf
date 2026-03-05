################################################################################
# main.tf — Certificate Platform Infrastructure
# Services: S3 · DynamoDB · API Gateway · Lambda · IAM
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
data "aws_partition" "current" {}

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

  point_in_time_recovery { enabled = true }
  server_side_encryption  { enabled = true }

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

  global_secondary_index {
    name            = "CompanyMembersIndex"
    hash_key        = "companyId"
    projection_type = "ALL"
  }

  global_secondary_index {
    name            = "CertificateIssuedDateIndex"
    hash_key        = "memberId"
    range_key       = "issued_date"
    projection_type = "ALL"
  }

  point_in_time_recovery { enabled = true }
  server_side_encryption  { enabled = true }

  tags = merge(local.common_tags, { Name = "kopera-member" })
}

################################################################################
# S3 — Kopera Certificate Bucket
################################################################################

resource "aws_s3_bucket" "kopera-certificate" {
  bucket        = "kopera-certificate"
  force_destroy = false
  tags          = merge(local.common_tags, { Name = "kopera-certificate" })
}

resource "aws_s3_bucket_versioning" "kopera-certificate" {
  bucket = aws_s3_bucket.kopera-certificate.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "kopera-certificate" {
  bucket = aws_s3_bucket.kopera-certificate.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "aws:kms" }
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
    filter { prefix = "certificates/" }
    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }
    noncurrent_version_expiration { noncurrent_days = 365 }
  }
}

################################################################################
# S3 — Kopera Private Assets Bucket
################################################################################

resource "aws_s3_bucket" "kopera-asset" {
  bucket        = "kopera-asset"
  force_destroy = false
  tags          = merge(local.common_tags, { Name = "kopera-asset" })
}

resource "aws_s3_bucket_versioning" "kopera-asset" {
  bucket = aws_s3_bucket.kopera-asset.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "kopera-asset" {
  bucket = aws_s3_bucket.kopera-asset.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "aws:kms" }
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
# IAM — Lambda Execution Role
################################################################################

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

# ── DynamoDB ──────────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "lambda_dynamodb" {
  statement {
    sid    = "DynamoDBAccess"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:DeleteItem",
      "dynamodb:Query",
      "dynamodb:Scan",
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
  name   = "${local.prefix}-lambda-dynamodb"
  policy = data.aws_iam_policy_document.lambda_dynamodb.json
  tags   = local.common_tags
}

resource "aws_iam_role_policy_attachment" "lambda_dynamodb" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.lambda_dynamodb.arn
}

# ── S3 ────────────────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "lambda_s3" {
  statement {
    sid    = "S3CertificateWrite"
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
    sid    = "S3AssetRead"
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
  name   = "${local.prefix}-lambda-s3"
  policy = data.aws_iam_policy_document.lambda_s3.json
  tags   = local.common_tags
}

resource "aws_iam_role_policy_attachment" "lambda_s3" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.lambda_s3.arn
}

# ── CloudWatch Logs ───────────────────────────────────────────────────────────

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
  name   = "${local.prefix}-lambda-cloudwatch"
  policy = data.aws_iam_policy_document.lambda_cloudwatch.json
  tags   = local.common_tags
}

resource "aws_iam_role_policy_attachment" "lambda_cloudwatch" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.lambda_cloudwatch.arn
}

# ── execute-api:Invoke  (Lambda calls its own GET routes) ─────────────────────

data "aws_iam_policy_document" "lambda_apigw" {
  statement {
    sid     = "InvokeOwnAPIGateway"
    effect  = "Allow"
    actions = ["execute-api:Invoke"]
    # Wildcard covers all methods and routes Lambda calls on itself:
    # GET /members, GET /companies, and any future internal calls
    resources = [
      "${aws_api_gateway_rest_api.main.execution_arn}/${var.environment}/*/*",
    ]
  }
}

resource "aws_iam_policy" "lambda_apigw" {
  name   = "${local.prefix}-lambda-apigw"
  policy = data.aws_iam_policy_document.lambda_apigw.json
  tags   = local.common_tags
}

resource "aws_iam_role_policy_attachment" "lambda_apigw" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.lambda_apigw.arn
}

################################################################################
# CloudWatch — Lambda Log Group
################################################################################

resource "aws_cloudwatch_log_group" "certificate_handler" {
  name              = "/aws/lambda/${local.prefix}-certificate-handler"
  retention_in_days = 30
  tags              = local.common_tags
}

################################################################################
# Lambda — Certificate Handler
################################################################################

resource "aws_lambda_function" "certificate_handler" {
  function_name = "${local.prefix}-certificate-handler"
  description   = "Generates PDF/JPEG certificates, uploads to S3, updates DynamoDB"

  s3_bucket         = aws_s3_bucket.kopera-asset.id
  s3_key            = "lambda/certificate_handler.zip"

  runtime     = "python3.12"
  handler     = "handler.lambda_handler"
  role        = aws_iam_role.lambda_exec.arn
  timeout     = 120
  memory_size = 1024

  environment {
    variables = {
      COMPANIES_TABLE = aws_dynamodb_table.kopera-company.name
      MEMBERS_TABLE   = aws_dynamodb_table.kopera-member.name
      CERTS_BUCKET    = aws_s3_bucket.kopera-certificate.id
      ASSETS_BUCKET   = aws_s3_bucket.kopera-asset.id
      ENVIRONMENT     = var.environment
      API_BASE_URL    = "https://${aws_api_gateway_rest_api.main.id}.execute-api.${var.aws_region}.amazonaws.com/${var.environment}"
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.certificate_handler,
    aws_iam_role_policy_attachment.lambda_dynamodb,
    aws_iam_role_policy_attachment.lambda_s3,
    aws_iam_role_policy_attachment.lambda_cloudwatch,
    aws_iam_role_policy_attachment.lambda_apigw,
  ]

  tags = local.common_tags
}

resource "aws_lambda_permission" "apigw_invoke" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.certificate_handler.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.main.execution_arn}/*/*"
}

################################################################################
# API Gateway — REST API
################################################################################

resource "aws_api_gateway_rest_api" "main" {
  name        = "${local.prefix}-api"
  description = "KAFA certificate platform API"

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = local.common_tags
}

# ── /certificates  POST → generate certificate ────────────────────────────────

resource "aws_api_gateway_resource" "certificates" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "certificates"
}

resource "aws_api_gateway_method" "certificates_post" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.certificates.id
  http_method   = "POST"
  authorization = "AWS_IAM"
}

resource "aws_api_gateway_integration" "certificates_post" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.certificates.id
  http_method             = aws_api_gateway_method.certificates_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.certificate_handler.invoke_arn
}

# ── /certificates/{certificateId}  GET → fetch certificate ───────────────────

resource "aws_api_gateway_resource" "certificate_item" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.certificates.id
  path_part   = "{certificateId}"
}

resource "aws_api_gateway_method" "certificate_item_get" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.certificate_item.id
  http_method   = "GET"
  authorization = "AWS_IAM"
}

resource "aws_api_gateway_integration" "certificate_item_get" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.certificate_item.id
  http_method             = aws_api_gateway_method.certificate_item_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.certificate_handler.invoke_arn
}

# ── /companies  GET → read company → DynamoDB ─────────────────────────────────

resource "aws_api_gateway_resource" "companies" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "companies"
}

resource "aws_api_gateway_method" "companies_get" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.companies.id
  http_method   = "GET"
  authorization = "AWS_IAM"
}

resource "aws_api_gateway_integration" "companies_get" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.companies.id
  http_method             = aws_api_gateway_method.companies_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.certificate_handler.invoke_arn
}

resource "aws_api_gateway_method" "companies_post" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.companies.id
  http_method   = "POST"
  authorization = "AWS_IAM"
}

resource "aws_api_gateway_integration" "companies_post" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.companies.id
  http_method             = aws_api_gateway_method.companies_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.certificate_handler.invoke_arn
}

# ── /members  GET → read member → DynamoDB ────────────────────────────────────

resource "aws_api_gateway_resource" "members" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "members"
}

resource "aws_api_gateway_method" "members_get" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.members.id
  http_method   = "GET"
  authorization = "AWS_IAM"
}

resource "aws_api_gateway_integration" "members_get" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.members.id
  http_method             = aws_api_gateway_method.members_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.certificate_handler.invoke_arn
}

resource "aws_api_gateway_method" "members_post" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.members.id
  http_method   = "POST"
  authorization = "AWS_IAM"
}

resource "aws_api_gateway_integration" "members_post" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.members.id
  http_method             = aws_api_gateway_method.members_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.certificate_handler.invoke_arn
}

# ── Deployment & Stage ────────────────────────────────────────────────────────

resource "aws_api_gateway_deployment" "main" {
  rest_api_id = aws_api_gateway_rest_api.main.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_integration.certificates_post.id,
      aws_api_gateway_integration.certificate_item_get.id,
      aws_api_gateway_integration.companies_get.id,
      aws_api_gateway_integration.companies_post.id,
      aws_api_gateway_integration.members_get.id,
      aws_api_gateway_integration.members_post.id,
    ]))
  }

  depends_on = [
    aws_api_gateway_integration.certificates_post,
    aws_api_gateway_integration.certificate_item_get,
    aws_api_gateway_integration.companies_get,
    aws_api_gateway_integration.companies_post,
    aws_api_gateway_integration.members_get,
    aws_api_gateway_integration.members_post,
  ]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "main" {
  deployment_id = aws_api_gateway_deployment.main.id
  rest_api_id   = aws_api_gateway_rest_api.main.id
  stage_name    = var.environment
  tags          = local.common_tags
}

resource "aws_api_gateway_method_settings" "main" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  stage_name  = aws_api_gateway_stage.main.stage_name
  method_path = "*/*"

  settings {
    metrics_enabled        = true
    throttling_burst_limit = 100
    throttling_rate_limit  = 50
  }
}

################################################################################
# Outputs
################################################################################

output "api_gateway_invoke_url" {
  description = "Base invoke URL for the KAFA API"
  value       = "https://${aws_api_gateway_rest_api.main.id}.execute-api.${var.aws_region}.amazonaws.com/${var.environment}"
}

output "api_gateway_id" {
  value = aws_api_gateway_rest_api.main.id
}

output "lambda_function_name" {
  value = aws_lambda_function.certificate_handler.function_name
}

output "lambda_function_arn" {
  value = aws_lambda_function.certificate_handler.arn
}

output "lambda_exec_role_arn" {
  value = aws_iam_role.lambda_exec.arn
}

output "companies_table_name" {
  value = aws_dynamodb_table.kopera-company.name
}

output "companies_table_arn" {
  value = aws_dynamodb_table.kopera-company.arn
}

output "members_table_name" {
  value = aws_dynamodb_table.kopera-member.name
}

output "members_table_arn" {
  value = aws_dynamodb_table.kopera-member.arn
}

output "kopera_certificate_bucket_name" {
  value = aws_s3_bucket.kopera-certificate.id
}

output "kopera_certificate_bucket_arn" {
  value = aws_s3_bucket.kopera-certificate.arn
}

output "kopera_certificate_prefix" {
  value = "s3://${aws_s3_bucket.kopera-certificate.id}/certificates/"
}

output "kopera_asset_bucket_name" {
  value = aws_s3_bucket.kopera-asset.id
}

output "kopera_asset_bucket_arn" {
  value = aws_s3_bucket.kopera-asset.arn
}

output "lambda_log_group" {
  description = "CloudWatch log group for the certificate handler Lambda"
  value       = aws_cloudwatch_log_group.certificate_handler.name
}
