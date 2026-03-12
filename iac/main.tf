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

# ACM certificates for CloudFront must always be in us-east-1
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
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
# DynamoDB — Admin Table
################################################################################

resource "aws_dynamodb_table" "kopera-admin" {
  name         = "kopera-admin"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "username"

  attribute {
    name = "username"
    type = "S"
  }

  tags = local.common_tags
}

################################################################################
# DynamoDB — Localities Table
################################################################################

resource "aws_dynamodb_table" "kopera-localities" {
  name         = "kopera-localities"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "code"

  attribute {
    name = "code"
    type = "S"
  }

  tags = local.common_tags
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
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
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

# ── DynamoDB inline policy ────────────────────────────────────────────────────

resource "aws_iam_role_policy" "lambda_dynamodb" {
  name = "dynamodb"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "DynamoDBAccess"
      Effect = "Allow"
      Action = [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:UpdateItem",
        "dynamodb:DeleteItem",
        "dynamodb:Query",
        "dynamodb:Scan",
      ]
      Resource = [
        aws_dynamodb_table.kopera-company.arn,
        aws_dynamodb_table.kopera-member.arn,
        aws_dynamodb_table.kopera-admin.arn,
        aws_dynamodb_table.kopera-localities.arn,
        "${aws_dynamodb_table.kopera-company.arn}/index/*",
        "${aws_dynamodb_table.kopera-member.arn}/index/*",
      ]
    }]
  })
}

# ── S3 inline policy ──────────────────────────────────────────────────────────

resource "aws_iam_role_policy" "lambda_s3" {
  name = "s3"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3CertificateWrite"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:HeadObject",
          "s3:DeleteObject",
          "s3:ListBucket",
        ]
        Resource = [
          aws_s3_bucket.kopera-certificate.arn,
          "${aws_s3_bucket.kopera-certificate.arn}/*",
        ]
      },
      {
        Sid    = "S3AssetRead"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket",
        ]
        Resource = [
          aws_s3_bucket.kopera-asset.arn,
          "${aws_s3_bucket.kopera-asset.arn}/*",
        ]
      },
    ]
  })
}

# ── CloudWatch Logs inline policy ─────────────────────────────────────────────

resource "aws_iam_role_policy" "lambda_cloudwatch" {
  name = "cloudwatch"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "CloudWatchLogs"
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
      ]
      Resource = [
        "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.prefix}-*",
        "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.prefix}-*:*",
      ]
    }]
  })
}

# ── execute-api:Invoke inline policy ──────────────────────────────────────────

resource "aws_iam_role_policy" "lambda_apigw" {
  name = "apigw"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "InvokeOwnAPIGateway"
      Effect   = "Allow"
      Action   = ["execute-api:Invoke"]
      Resource = ["${aws_api_gateway_rest_api.main.execution_arn}/${var.environment}/*/*"]
    }]
  })
}

################################################################################
# Lambda — Certificate Handler
################################################################################

resource "aws_lambda_function" "certificate_handler" {
  function_name = "${local.prefix}-certificate-handler"
  description   = "Generates PDF/JPEG certificates, uploads to S3, updates DynamoDB"

  s3_bucket = aws_s3_bucket.kopera-asset.id
  s3_key    = "lambda/certificate_handler.zip"

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
      ADMIN_TABLE     = aws_dynamodb_table.kopera-admin.name
      LOCALITIES_TABLE = aws_dynamodb_table.kopera-localities.name
    }
  }

  depends_on = [
    aws_iam_role_policy.lambda_dynamodb,
    aws_iam_role_policy.lambda_s3,
    aws_iam_role_policy.lambda_cloudwatch,
    aws_iam_role_policy.lambda_apigw,
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
# IAM — extra policies for retrieval Lambda
################################################################################

# DynamoDB Scan (needed to search by phone number across all members)
resource "aws_iam_role_policy" "retrieval_dynamodb_scan" {
  name = "dynamodb-scan"
  role = aws_iam_role.lambda_retrieval_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "DynamoDBScanAndGet"
      Effect = "Allow"
      Action = [
        "dynamodb:Scan",
        "dynamodb:GetItem",
        "dynamodb:Query",
      ]
      Resource = [
        aws_dynamodb_table.kopera-member.arn,
        "${aws_dynamodb_table.kopera-member.arn}/index/*",
      ]
    }]
  })
}

# S3 — read objects + generate pre-signed URLs from kopera-certificate
resource "aws_iam_role_policy" "retrieval_s3" {
  name = "s3-presign"
  role = aws_iam_role.lambda_retrieval_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "S3CertificateRead"
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:ListBucket",
      ]
      Resource = [
        aws_s3_bucket.kopera-certificate.arn,
        "${aws_s3_bucket.kopera-certificate.arn}/*",
      ]
    }]
  })
}

# CloudWatch Logs for retrieval Lambda
resource "aws_iam_role_policy" "retrieval_cloudwatch" {
  name = "cloudwatch"
  role = aws_iam_role.lambda_retrieval_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "CloudWatchLogs"
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
      ]
      Resource = [
        "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.prefix}-*",
        "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.prefix}-*:*",
      ]
    }]
  })
}

# execute-api:Invoke so retrieval Lambda can call GET /members on kopera-apigw
resource "aws_iam_role_policy" "retrieval_apigw" {
  name = "apigw"
  role = aws_iam_role.lambda_retrieval_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "InvokeAPIGateway"
      Effect   = "Allow"
      Action   = ["execute-api:Invoke"]
      Resource = ["${aws_api_gateway_rest_api.main.execution_arn}/${var.environment}/*/*"]
    }]
  })
}

################################################################################
# IAM — Retrieval Lambda execution role
################################################################################

resource "aws_iam_role" "lambda_retrieval_exec" {
  name = "${local.prefix}-lambda-retrieval-exec"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "LambdaAssumeRole"
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = local.common_tags
}

################################################################################
################################################################################
# Lambda — Certificate Retrieval Handler
################################################################################

resource "aws_lambda_function" "certificate_retrieval" {
  function_name = "${local.prefix}-certificate-retrieval"
  description   = "Looks up a member by phone number and returns pre-signed certificate download URLs"

  s3_bucket = aws_s3_bucket.kopera-asset.id
  s3_key    = "lambda/certificate_retrieval.zip"

  runtime     = "python3.12"
  handler     = "certificate_retrieval_handler.lambda_handler"
  role        = aws_iam_role.lambda_retrieval_exec.arn
  timeout     = 30
  memory_size = 256

  environment {
    variables = {
      MEMBERS_TABLE        = aws_dynamodb_table.kopera-member.name
      CERTS_BUCKET         = aws_s3_bucket.kopera-certificate.id
      ENVIRONMENT          = var.environment
      API_BASE_URL         = "https://${aws_api_gateway_rest_api.main.id}.execute-api.${var.aws_region}.amazonaws.com/${var.environment}"
      TWILIO_ACCOUNT_SID   = "AC251485462ba1efded83ef97d638a2279"
      TWILIO_AUTH_TOKEN    = "2c7fa3467194847e5ef2395a9bc5369c"
      TWILIO_WHATSAPP_FROM = "whatsapp:+18665287758"
    }
  }

  depends_on = [
    aws_iam_role_policy.retrieval_dynamodb_scan,
    aws_iam_role_policy.retrieval_s3,
    aws_iam_role_policy.retrieval_cloudwatch,
    aws_iam_role_policy.retrieval_apigw,
  ]

  tags = local.common_tags
}

resource "aws_lambda_permission" "apigw_invoke_retrieval" {
  statement_id  = "AllowAPIGatewayInvokeRetrieval"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.certificate_retrieval.function_name
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


# ── /retrieve  GET → look up member by phone, return pre-signed cert URLs ────

resource "aws_api_gateway_resource" "retrieve" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "retrieve"
}

resource "aws_api_gateway_method" "retrieve_get" {
  rest_api_id        = aws_api_gateway_rest_api.main.id
  resource_id        = aws_api_gateway_resource.retrieve.id
  http_method        = "GET"
  authorization      = "NONE"

  request_parameters = {
    "method.request.querystring.phone" = true
  }
}

resource "aws_api_gateway_method_response" "retrieve_get_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.retrieve.id
  http_method = aws_api_gateway_method.retrieve_get.http_method
  status_code = "200"

  response_models = {
    "application/json" = "Empty"
  }
}

resource "aws_api_gateway_integration" "retrieve_get" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.retrieve.id
  http_method             = aws_api_gateway_method.retrieve_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.certificate_retrieval.invoke_arn
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

# ── /members/list  GET → list all members for a company ──────────────────────

resource "aws_api_gateway_resource" "members_list" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.members.id
  path_part   = "list"
}

resource "aws_api_gateway_method" "members_list_get" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.members_list.id
  http_method   = "GET"
  authorization = "AWS_IAM"
}

resource "aws_api_gateway_integration" "members_list_get" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.members_list.id
  http_method             = aws_api_gateway_method.members_list_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.certificate_handler.invoke_arn
}

# ── /members/edit  POST → fetch member ready for editing ─────────────────────

resource "aws_api_gateway_resource" "members_edit" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.members.id
  path_part   = "edit"
}

resource "aws_api_gateway_method" "members_edit_post" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.members_edit.id
  http_method   = "POST"
  authorization = "AWS_IAM"
}

resource "aws_api_gateway_integration" "members_edit_post" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.members_edit.id
  http_method             = aws_api_gateway_method.members_edit_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.certificate_handler.invoke_arn
}

# ── /members/update  POST → persist updated member fields ────────────────────

resource "aws_api_gateway_resource" "members_update" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.members.id
  path_part   = "update"
}

resource "aws_api_gateway_method" "members_update_post" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.members_update.id
  http_method   = "POST"
  authorization = "AWS_IAM"
}

resource "aws_api_gateway_integration" "members_update_post" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.members_update.id
  http_method             = aws_api_gateway_method.members_update_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.certificate_handler.invoke_arn
}


# ── CORS OPTIONS for /retrieve ───────────────────────────────────────────────

resource "aws_api_gateway_method" "retrieve_options" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.retrieve.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "retrieve_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.retrieve.id
  http_method = aws_api_gateway_method.retrieve_options.http_method
  type        = "MOCK"
  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "retrieve_options_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.retrieve.id
  http_method = aws_api_gateway_method.retrieve_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "retrieve_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.retrieve.id
  http_method = aws_api_gateway_method.retrieve_options.http_method
  status_code = aws_api_gateway_method_response.retrieve_options_200.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token,X-Amz-Content-Sha256'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
  depends_on = [aws_api_gateway_integration.retrieve_options]
}

# ── /auth  parent resource ───────────────────────────────────────────────────

resource "aws_api_gateway_resource" "auth" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "auth"
}

# ── /auth/login  POST → validate admin credentials ───────────────────────────

resource "aws_api_gateway_resource" "auth_login" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.auth.id
  path_part   = "login"
}

resource "aws_api_gateway_method" "auth_login_post" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.auth_login.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "auth_login_post" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.auth_login.id
  http_method             = aws_api_gateway_method.auth_login_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.certificate_handler.invoke_arn
}

# ── CORS OPTIONS for /auth/login ─────────────────────────────────────────────

resource "aws_api_gateway_method" "auth_login_options" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.auth_login.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "auth_login_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.auth_login.id
  http_method = aws_api_gateway_method.auth_login_options.http_method
  type        = "MOCK"
  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "auth_login_options_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.auth_login.id
  http_method = aws_api_gateway_method.auth_login_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "auth_login_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.auth_login.id
  http_method = aws_api_gateway_method.auth_login_options.http_method
  status_code = aws_api_gateway_method_response.auth_login_options_200.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token,X-Amz-Content-Sha256'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
  depends_on = [aws_api_gateway_integration.auth_login_options]
}

# ── CORS OPTIONS for /members/list ───────────────────────────────────────────

resource "aws_api_gateway_method" "members_list_options" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.members_list.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "members_list_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.members_list.id
  http_method = aws_api_gateway_method.members_list_options.http_method
  type        = "MOCK"
  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "members_list_options_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.members_list.id
  http_method = aws_api_gateway_method.members_list_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "members_list_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.members_list.id
  http_method = aws_api_gateway_method.members_list_options.http_method
  status_code = aws_api_gateway_method_response.members_list_options_200.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token,X-Amz-Content-Sha256'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
  depends_on = [aws_api_gateway_integration.members_list_options]
}

# ── CORS OPTIONS for /members/edit ────────────────────────────────────────────

resource "aws_api_gateway_method" "members_edit_options" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.members_edit.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "members_edit_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.members_edit.id
  http_method = aws_api_gateway_method.members_edit_options.http_method
  type        = "MOCK"
  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "members_edit_options_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.members_edit.id
  http_method = aws_api_gateway_method.members_edit_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "members_edit_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.members_edit.id
  http_method = aws_api_gateway_method.members_edit_options.http_method
  status_code = aws_api_gateway_method_response.members_edit_options_200.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token,X-Amz-Content-Sha256'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
  depends_on = [aws_api_gateway_integration.members_edit_options]
}

# ── CORS OPTIONS for /members/update ─────────────────────────────────────────

resource "aws_api_gateway_method" "members_update_options" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.members_update.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "members_update_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.members_update.id
  http_method = aws_api_gateway_method.members_update_options.http_method
  type        = "MOCK"
  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "members_update_options_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.members_update.id
  http_method = aws_api_gateway_method.members_update_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "members_update_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.members_update.id
  http_method = aws_api_gateway_method.members_update_options.http_method
  status_code = aws_api_gateway_method_response.members_update_options_200.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token,X-Amz-Content-Sha256'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
  depends_on = [aws_api_gateway_integration.members_update_options]
}

# ── /localities ───────────────────────────────────────────────────────────────

resource "aws_api_gateway_resource" "localities" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "localities"
}

resource "aws_api_gateway_method" "localities_get" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.localities.id
  http_method   = "GET"
  authorization = "AWS_IAM"
}

resource "aws_api_gateway_integration" "localities_get" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.localities.id
  http_method             = aws_api_gateway_method.localities_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.certificate_handler.invoke_arn
}

resource "aws_api_gateway_method" "localities_options" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.localities.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "localities_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.localities.id
  http_method = aws_api_gateway_method.localities_options.http_method
  type        = "MOCK"
  request_templates = { "application/json" = "{\"statusCode\": 200}" }
}

resource "aws_api_gateway_method_response" "localities_options_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.localities.id
  http_method = aws_api_gateway_method.localities_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "localities_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.localities.id
  http_method = aws_api_gateway_method.localities_options.http_method
  status_code = aws_api_gateway_method_response.localities_options_200.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token,X-Amz-Content-Sha256'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
  depends_on = [aws_api_gateway_integration.localities_options]
}

# ── /members/create ────────────────────────────────────────────────────────────

resource "aws_api_gateway_resource" "members_create" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.members.id
  path_part   = "create"
}

resource "aws_api_gateway_method" "members_create_post" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.members_create.id
  http_method   = "POST"
  authorization = "AWS_IAM"
}

resource "aws_api_gateway_integration" "members_create_post" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.members_create.id
  http_method             = aws_api_gateway_method.members_create_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.certificate_handler.invoke_arn
}

resource "aws_api_gateway_method" "members_create_options" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.members_create.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "members_create_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.members_create.id
  http_method = aws_api_gateway_method.members_create_options.http_method
  type        = "MOCK"
  request_templates = { "application/json" = "{\"statusCode\": 200}" }
}

resource "aws_api_gateway_method_response" "members_create_options_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.members_create.id
  http_method = aws_api_gateway_method.members_create_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "members_create_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.members_create.id
  http_method = aws_api_gateway_method.members_create_options.http_method
  status_code = aws_api_gateway_method_response.members_create_options_200.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token,X-Amz-Content-Sha256'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
  depends_on = [aws_api_gateway_integration.members_create_options]
}

# ── Deployment & Stage ────────────────────────────────────────────────────────

resource "aws_api_gateway_deployment" "main" {
  rest_api_id = aws_api_gateway_rest_api.main.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_integration.retrieve_get.id,
      aws_api_gateway_method_response.retrieve_get_200.id,
      aws_api_gateway_integration.certificates_post.id,
      aws_api_gateway_integration.certificate_item_get.id,
      aws_api_gateway_integration.companies_get.id,
      aws_api_gateway_integration.companies_post.id,
      aws_api_gateway_integration.members_get.id,
      aws_api_gateway_integration.members_post.id,
      aws_api_gateway_integration.members_list_get.id,
      aws_api_gateway_integration.members_edit_post.id,
      aws_api_gateway_integration.members_update_post.id,
      aws_api_gateway_integration.members_list_options.id,
      aws_api_gateway_integration.members_edit_options.id,
      aws_api_gateway_integration.members_update_options.id,
      aws_api_gateway_integration.localities_get.id,
      aws_api_gateway_integration.members_create_post.id,
    ]))
  }

  depends_on = [
    aws_api_gateway_integration.retrieve_get,
    aws_api_gateway_integration.certificates_post,
    aws_api_gateway_integration.certificate_item_get,
    aws_api_gateway_integration.companies_get,
    aws_api_gateway_integration.companies_post,
    aws_api_gateway_integration.members_get,
    aws_api_gateway_integration.members_post,
    aws_api_gateway_integration.members_list_get,
    aws_api_gateway_integration.members_edit_post,
    aws_api_gateway_integration.members_update_post,
    aws_api_gateway_integration_response.members_list_options,
    aws_api_gateway_integration_response.members_edit_options,
    aws_api_gateway_integration_response.members_update_options,
    aws_api_gateway_integration.localities_get,
    aws_api_gateway_integration.members_create_post,
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

output "retrieval_lambda_function_name" {
  description = "Certificate retrieval Lambda function name"
  value       = aws_lambda_function.certificate_retrieval.function_name
}

output "retrieval_lambda_function_arn" {
  description = "Certificate retrieval Lambda function ARN"
  value       = aws_lambda_function.certificate_retrieval.arn
}

output "retrieve_endpoint" {
  description = "GET endpoint — retrieve certificate by phone number"
  value       = "https://${aws_api_gateway_rest_api.main.id}.execute-api.${var.aws_region}.amazonaws.com/${var.environment}/retrieve?phone=<phone_number>"
}

################################################################################
# Route 53 — kafayiti.com hosted zone
################################################################################

data "aws_route53_zone" "kafayiti" {
  name         = "kafayiti.com"
  private_zone = false
}

################################################################################
# ACM Certificate — admin.kafayiti.com
# Must be in us-east-1 for CloudFront
################################################################################

resource "aws_acm_certificate" "member_management" {
  provider          = aws.us_east_1
  domain_name       = "admin.kafayiti.com"
  validation_method = "DNS"
  tags              = local.common_tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "member_management_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.member_management.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id = data.aws_route53_zone.kafayiti.zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 60
  records = [each.value.record]
}

resource "aws_acm_certificate_validation" "member_management" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.member_management.arn
  validation_record_fqdns = [for record in aws_route53_record.member_management_cert_validation : record.fqdn]
}

################################################################################
# S3 — Member Management Flutter Web App
################################################################################

resource "aws_s3_bucket" "member_management" {
  bucket        = "kafa-admin-kafayiti"
  force_destroy = true
  tags          = local.common_tags
}

resource "aws_s3_bucket_versioning" "member_management" {
  bucket = aws_s3_bucket.member_management.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "member_management" {
  bucket                  = aws_s3_bucket.member_management.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_website_configuration" "member_management" {
  bucket = aws_s3_bucket.member_management.id

  index_document { suffix = "index.html" }
  error_document { key    = "index.html" }
}

################################################################################
# CloudFront — HTTPS distribution for Member Management app
################################################################################

resource "aws_cloudfront_origin_access_control" "member_management" {
  name                              = "kafa-admin-kafayiti-oac"
  description                       = "OAC for KAFA Member Management S3 bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "member_management" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  comment             = "KAFA Admin Flutter Web App"
  tags                = local.common_tags

  origin {
    domain_name              = aws_s3_bucket.member_management.bucket_regional_domain_name
    origin_id                = "S3-kafa-admin-kafayiti"
    origin_access_control_id = aws_cloudfront_origin_access_control.member_management.id
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "S3-kafa-admin-kafayiti"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }

    min_ttl     = 0
    default_ttl = 3600
    max_ttl     = 86400
  }

  # Return index.html for all routes — required for Flutter web SPA routing
  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }

  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  aliases = ["admin.kafayiti.com"]

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.member_management.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

# Bucket policy — allow CloudFront OAC to read from S3
resource "aws_s3_bucket_policy" "member_management" {
  bucket = aws_s3_bucket.member_management.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowCloudFrontOAC"
      Effect = "Allow"
      Principal = {
        Service = "cloudfront.amazonaws.com"
      }
      Action   = "s3:GetObject"
      Resource = "${aws_s3_bucket.member_management.arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.member_management.arn
        }
      }
    }]
  })
}

################################################################################
# Route 53 — admin.kafayiti.com → CloudFront
################################################################################

resource "aws_route53_record" "member_management" {
  zone_id = data.aws_route53_zone.kafayiti.zone_id
  name    = "admin.kafayiti.com"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.member_management.domain_name
    zone_id                = aws_cloudfront_distribution.member_management.hosted_zone_id
    evaluate_target_health = false
  }
}

################################################################################
# Outputs — Member Management hosting
################################################################################

output "member_management_bucket" {
  description = "S3 bucket for Flutter web build artifacts"
  value       = aws_s3_bucket.member_management.id
}

output "member_management_cloudfront_url" {
  description = "HTTPS URL for the KAFA Member Management app"
  value       = "https://admin.kafayiti.com"
}

output "member_management_cloudfront_id" {
  description = "CloudFront distribution ID (needed to invalidate cache after deploy)"
  value       = aws_cloudfront_distribution.member_management.id
}
