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

variable "anthropic_api_key" {
  description = "Anthropic API key for the member portal chatbot"
  type        = string
  sensitive   = true
  default     = ""
}

variable "stripe_secret_key" {
  description = "Stripe secret key (sk_test_... for dev, sk_live_... for prod)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "stripe_webhook_secret" {
  description = "Stripe webhook signing secret (whsec_...) from the Stripe dashboard"
  type        = string
  sensitive   = true
  default     = ""
}

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
        aws_dynamodb_table.kopera-life-insurance.arn,
        "${aws_dynamodb_table.kopera-company.arn}/index/*",
        "${aws_dynamodb_table.kopera-member.arn}/index/*",
        "${aws_dynamodb_table.kopera-life-insurance.arn}/index/*",
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
      ANTHROPIC_API_KEY = var.anthropic_api_key
      LIFE_INSURANCE_TABLE = "kopera-life-insurance"
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

# ── /member  parent resource (member self-service) ───────────────────────────

resource "aws_api_gateway_resource" "member" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "member"
}

# ── /member/login  POST → member self-service login ──────────────────────────

resource "aws_api_gateway_resource" "member_login" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.member.id
  path_part   = "login"
}

resource "aws_api_gateway_method" "member_login_post" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.member_login.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "member_login_post" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.member_login.id
  http_method             = aws_api_gateway_method.member_login_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.certificate_handler.invoke_arn
}

resource "aws_api_gateway_method" "member_login_options" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.member_login.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "member_login_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.member_login.id
  http_method = aws_api_gateway_method.member_login_options.http_method
  type        = "MOCK"
  request_templates = { "application/json" = "{\"statusCode\": 200}" }
}

resource "aws_api_gateway_method_response" "member_login_options_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.member_login.id
  http_method = aws_api_gateway_method.member_login_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "member_login_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.member_login.id
  http_method = aws_api_gateway_method.member_login_options.http_method
  status_code = aws_api_gateway_method_response.member_login_options_200.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token,X-Amz-Content-Sha256'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
  depends_on = [aws_api_gateway_integration.member_login_options]
}

# ── /member/chat  POST → AI chatbot for member portal ────────────────────────

resource "aws_api_gateway_resource" "member_chat" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.member.id
  path_part   = "chat"
}

resource "aws_api_gateway_method" "member_chat_post" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.member_chat.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "member_chat_post" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.member_chat.id
  http_method             = aws_api_gateway_method.member_chat_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.certificate_handler.invoke_arn
}

resource "aws_api_gateway_method" "member_chat_options" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.member_chat.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "member_chat_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.member_chat.id
  http_method = aws_api_gateway_method.member_chat_options.http_method
  type        = "MOCK"
  request_templates = { "application/json" = "{\"statusCode\": 200}" }
}

resource "aws_api_gateway_method_response" "member_chat_options_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.member_chat.id
  http_method = aws_api_gateway_method.member_chat_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "member_chat_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.member_chat.id
  http_method = aws_api_gateway_method.member_chat_options.http_method
  status_code = aws_api_gateway_method_response.member_chat_options_200.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token,X-Amz-Content-Sha256'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
  depends_on = [aws_api_gateway_integration.member_chat_options]
}

# ── /member/policy  GET → member's policies ───────────────────────────────────

resource "aws_api_gateway_resource" "member_policy" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.member.id
  path_part   = "policy"
}

resource "aws_api_gateway_method" "member_policy_get" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.member_policy.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "member_policy_get" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.member_policy.id
  http_method             = aws_api_gateway_method.member_policy_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.certificate_handler.invoke_arn
}

resource "aws_api_gateway_method" "member_policy_options" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.member_policy.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "member_policy_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.member_policy.id
  http_method = aws_api_gateway_method.member_policy_options.http_method
  type        = "MOCK"
  request_templates = { "application/json" = "{\"statusCode\": 200}" }
}

resource "aws_api_gateway_method_response" "member_policy_options_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.member_policy.id
  http_method = aws_api_gateway_method.member_policy_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "member_policy_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.member_policy.id
  http_method = aws_api_gateway_method.member_policy_options.http_method
  status_code = aws_api_gateway_method_response.member_policy_options_200.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token,X-Amz-Content-Sha256'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
  depends_on = [aws_api_gateway_integration.member_policy_options]
}

# ── /member/payment  POST → record a premium payment ─────────────────────────

resource "aws_api_gateway_resource" "member_payment" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.member.id
  path_part   = "payment"
}

resource "aws_api_gateway_method" "member_payment_post" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.member_payment.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "member_payment_post" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.member_payment.id
  http_method             = aws_api_gateway_method.member_payment_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.certificate_handler.invoke_arn
}

resource "aws_api_gateway_method" "member_payment_options" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.member_payment.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "member_payment_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.member_payment.id
  http_method = aws_api_gateway_method.member_payment_options.http_method
  type        = "MOCK"
  request_templates = { "application/json" = "{\"statusCode\": 200}" }
}

resource "aws_api_gateway_method_response" "member_payment_options_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.member_payment.id
  http_method = aws_api_gateway_method.member_payment_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "member_payment_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.member_payment.id
  http_method = aws_api_gateway_method.member_payment_options.http_method
  status_code = aws_api_gateway_method_response.member_payment_options_200.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token,X-Amz-Content-Sha256'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
  depends_on = [aws_api_gateway_integration.member_payment_options]
}

# ── /member/claim  POST → submit a new claim ─────────────────────────────────

resource "aws_api_gateway_resource" "member_claim" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.member.id
  path_part   = "claim"
}

resource "aws_api_gateway_method" "member_claim_post" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.member_claim.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "member_claim_post" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.member_claim.id
  http_method             = aws_api_gateway_method.member_claim_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.certificate_handler.invoke_arn
}

resource "aws_api_gateway_method" "member_claim_options" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.member_claim.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "member_claim_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.member_claim.id
  http_method = aws_api_gateway_method.member_claim_options.http_method
  type        = "MOCK"
  request_templates = { "application/json" = "{\"statusCode\": 200}" }
}

resource "aws_api_gateway_method_response" "member_claim_options_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.member_claim.id
  http_method = aws_api_gateway_method.member_claim_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "member_claim_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.member_claim.id
  http_method = aws_api_gateway_method.member_claim_options.http_method
  status_code = aws_api_gateway_method_response.member_claim_options_200.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token,X-Amz-Content-Sha256'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
  depends_on = [aws_api_gateway_integration.member_claim_options]
}

# ── /members/set-payment-access  POST → admin grants/revokes payment access ───

resource "aws_api_gateway_resource" "members_set_payment_access" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.members.id
  path_part   = "set-payment-access"
}

resource "aws_api_gateway_method" "members_set_payment_access_post" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.members_set_payment_access.id
  http_method   = "POST"
  authorization = "AWS_IAM"
}

resource "aws_api_gateway_integration" "members_set_payment_access_post" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.members_set_payment_access.id
  http_method             = aws_api_gateway_method.members_set_payment_access_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.certificate_handler.invoke_arn
}

resource "aws_api_gateway_method" "members_set_payment_access_options" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.members_set_payment_access.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "members_set_payment_access_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.members_set_payment_access.id
  http_method = aws_api_gateway_method.members_set_payment_access_options.http_method
  type        = "MOCK"
  request_templates = { "application/json" = "{\"statusCode\": 200}" }
}

resource "aws_api_gateway_method_response" "members_set_payment_access_options_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.members_set_payment_access.id
  http_method = aws_api_gateway_method.members_set_payment_access_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "members_set_payment_access_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.members_set_payment_access.id
  http_method = aws_api_gateway_method.members_set_payment_access_options.http_method
  status_code = aws_api_gateway_method_response.members_set_payment_access_options_200.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token,X-Amz-Content-Sha256'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
  depends_on = [aws_api_gateway_integration.members_set_payment_access_options]
}

# ── /member/beneficiaries  GET+POST → fetch / save beneficiaries ─────────────

resource "aws_api_gateway_resource" "member_beneficiaries" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.member.id
  path_part   = "beneficiaries"
}

resource "aws_api_gateway_method" "member_beneficiaries_get" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.member_beneficiaries.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "member_beneficiaries_get" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.member_beneficiaries.id
  http_method             = aws_api_gateway_method.member_beneficiaries_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.certificate_handler.invoke_arn
}

resource "aws_api_gateway_method" "member_beneficiaries_post" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.member_beneficiaries.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "member_beneficiaries_post" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.member_beneficiaries.id
  http_method             = aws_api_gateway_method.member_beneficiaries_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.certificate_handler.invoke_arn
}

resource "aws_api_gateway_method" "member_beneficiaries_options" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.member_beneficiaries.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "member_beneficiaries_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.member_beneficiaries.id
  http_method = aws_api_gateway_method.member_beneficiaries_options.http_method
  type        = "MOCK"
  request_templates = { "application/json" = "{\"statusCode\": 200}" }
}

resource "aws_api_gateway_method_response" "member_beneficiaries_options_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.member_beneficiaries.id
  http_method = aws_api_gateway_method.member_beneficiaries_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "member_beneficiaries_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.member_beneficiaries.id
  http_method = aws_api_gateway_method.member_beneficiaries_options.http_method
  status_code = aws_api_gateway_method_response.member_beneficiaries_options_200.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token,X-Amz-Content-Sha256'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
  depends_on = [aws_api_gateway_integration.member_beneficiaries_options]
}

# ── /member/acknowledge-payment  POST → member dismisses payment notification ─

resource "aws_api_gateway_resource" "member_acknowledge_payment" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.member.id
  path_part   = "acknowledge-payment"
}

resource "aws_api_gateway_method" "member_acknowledge_payment_post" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.member_acknowledge_payment.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "member_acknowledge_payment_post" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.member_acknowledge_payment.id
  http_method             = aws_api_gateway_method.member_acknowledge_payment_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.certificate_handler.invoke_arn
}

resource "aws_api_gateway_method" "member_acknowledge_payment_options" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.member_acknowledge_payment.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "member_acknowledge_payment_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.member_acknowledge_payment.id
  http_method = aws_api_gateway_method.member_acknowledge_payment_options.http_method
  type        = "MOCK"
  request_templates = { "application/json" = "{\"statusCode\": 200}" }
}

resource "aws_api_gateway_method_response" "member_acknowledge_payment_options_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.member_acknowledge_payment.id
  http_method = aws_api_gateway_method.member_acknowledge_payment_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "member_acknowledge_payment_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.member_acknowledge_payment.id
  http_method = aws_api_gateway_method.member_acknowledge_payment_options.http_method
  status_code = aws_api_gateway_method_response.member_acknowledge_payment_options_200.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token,X-Amz-Content-Sha256'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
  depends_on = [aws_api_gateway_integration.member_acknowledge_payment_options]
}

# ── /member/profile  GET → fresh member profile for dashboard refresh ─────────

resource "aws_api_gateway_resource" "member_profile" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.member.id
  path_part   = "profile"
}

resource "aws_api_gateway_method" "member_profile_get" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.member_profile.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "member_profile_get" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.member_profile.id
  http_method             = aws_api_gateway_method.member_profile_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.certificate_handler.invoke_arn
}

resource "aws_api_gateway_method" "member_profile_options" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.member_profile.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "member_profile_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.member_profile.id
  http_method = aws_api_gateway_method.member_profile_options.http_method
  type        = "MOCK"
  request_templates = { "application/json" = "{\"statusCode\": 200}" }
}

resource "aws_api_gateway_method_response" "member_profile_options_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.member_profile.id
  http_method = aws_api_gateway_method.member_profile_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "member_profile_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.member_profile.id
  http_method = aws_api_gateway_method.member_profile_options.http_method
  status_code = aws_api_gateway_method_response.member_profile_options_200.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token,X-Amz-Content-Sha256'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
  depends_on = [aws_api_gateway_integration.member_profile_options]
}

# ── /members/set-credentials  POST → admin sets member password ──────────────

resource "aws_api_gateway_resource" "members_set_credentials" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.members.id
  path_part   = "set-credentials"
}

resource "aws_api_gateway_method" "members_set_credentials_post" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.members_set_credentials.id
  http_method   = "POST"
  authorization = "AWS_IAM"
}

resource "aws_api_gateway_integration" "members_set_credentials_post" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.members_set_credentials.id
  http_method             = aws_api_gateway_method.members_set_credentials_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.certificate_handler.invoke_arn
}

resource "aws_api_gateway_method" "members_set_credentials_options" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.members_set_credentials.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "members_set_credentials_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.members_set_credentials.id
  http_method = aws_api_gateway_method.members_set_credentials_options.http_method
  type        = "MOCK"
  request_templates = { "application/json" = "{\"statusCode\": 200}" }
}

resource "aws_api_gateway_method_response" "members_set_credentials_options_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.members_set_credentials.id
  http_method = aws_api_gateway_method.members_set_credentials_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "members_set_credentials_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.members_set_credentials.id
  http_method = aws_api_gateway_method.members_set_credentials_options.http_method
  status_code = aws_api_gateway_method_response.members_set_credentials_options_200.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token,X-Amz-Content-Sha256'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
  depends_on = [aws_api_gateway_integration.members_set_credentials_options]
}

# ── /member/partners  GET → funeral service partner directory ─────────────────

resource "aws_api_gateway_resource" "member_partners" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.member.id
  path_part   = "partners"
}

resource "aws_api_gateway_method" "member_partners_get" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.member_partners.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "member_partners_get" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.member_partners.id
  http_method             = aws_api_gateway_method.member_partners_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.certificate_handler.invoke_arn
}

resource "aws_api_gateway_method" "member_partners_options" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.member_partners.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "member_partners_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.member_partners.id
  http_method = aws_api_gateway_method.member_partners_options.http_method
  type        = "MOCK"
  request_templates = { "application/json" = "{\"statusCode\": 200}" }
}

resource "aws_api_gateway_method_response" "member_partners_options_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.member_partners.id
  http_method = aws_api_gateway_method.member_partners_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "member_partners_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.member_partners.id
  http_method = aws_api_gateway_method.member_partners_options.http_method
  status_code = aws_api_gateway_method_response.member_partners_options_200.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token,X-Amz-Content-Sha256'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
  depends_on = [aws_api_gateway_integration.member_partners_options]
}

# ── /member/documents  GET → list member documents ────────────────────────────

resource "aws_api_gateway_resource" "member_documents" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.member.id
  path_part   = "documents"
}

resource "aws_api_gateway_method" "member_documents_get" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.member_documents.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "member_documents_get" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.member_documents.id
  http_method             = aws_api_gateway_method.member_documents_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.certificate_handler.invoke_arn
}

resource "aws_api_gateway_method" "member_documents_options" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.member_documents.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "member_documents_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.member_documents.id
  http_method = aws_api_gateway_method.member_documents_options.http_method
  type        = "MOCK"
  request_templates = { "application/json" = "{\"statusCode\": 200}" }
}

resource "aws_api_gateway_method_response" "member_documents_options_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.member_documents.id
  http_method = aws_api_gateway_method.member_documents_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "member_documents_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.member_documents.id
  http_method = aws_api_gateway_method.member_documents_options.http_method
  status_code = aws_api_gateway_method_response.member_documents_options_200.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token,X-Amz-Content-Sha256'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
  depends_on = [aws_api_gateway_integration.member_documents_options]
}

# ── /member/documents/upload  POST → request presigned PUT URL ───────────────

resource "aws_api_gateway_resource" "member_documents_upload" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.member_documents.id
  path_part   = "upload"
}

resource "aws_api_gateway_method" "member_documents_upload_post" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.member_documents_upload.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "member_documents_upload_post" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.member_documents_upload.id
  http_method             = aws_api_gateway_method.member_documents_upload_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.certificate_handler.invoke_arn
}

resource "aws_api_gateway_method" "member_documents_upload_options" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.member_documents_upload.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "member_documents_upload_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.member_documents_upload.id
  http_method = aws_api_gateway_method.member_documents_upload_options.http_method
  type        = "MOCK"
  request_templates = { "application/json" = "{\"statusCode\": 200}" }
}

resource "aws_api_gateway_method_response" "member_documents_upload_options_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.member_documents_upload.id
  http_method = aws_api_gateway_method.member_documents_upload_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "member_documents_upload_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.member_documents_upload.id
  http_method = aws_api_gateway_method.member_documents_upload_options.http_method
  status_code = aws_api_gateway_method_response.member_documents_upload_options_200.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token,X-Amz-Content-Sha256'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
  depends_on = [aws_api_gateway_integration.member_documents_upload_options]
}

# ── /member/death-report  POST → SES death notification ──────────────────────

resource "aws_api_gateway_resource" "member_death_report" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.member.id
  path_part   = "death-report"
}

resource "aws_api_gateway_method" "member_death_report_post" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.member_death_report.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "member_death_report_post" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.member_death_report.id
  http_method             = aws_api_gateway_method.member_death_report_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.certificate_handler.invoke_arn
}

resource "aws_api_gateway_method" "member_death_report_options" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.member_death_report.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "member_death_report_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.member_death_report.id
  http_method = aws_api_gateway_method.member_death_report_options.http_method
  type        = "MOCK"
  request_templates = { "application/json" = "{\"statusCode\": 200}" }
}

resource "aws_api_gateway_method_response" "member_death_report_options_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.member_death_report.id
  http_method = aws_api_gateway_method.member_death_report_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "member_death_report_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.member_death_report.id
  http_method = aws_api_gateway_method.member_death_report_options.http_method
  status_code = aws_api_gateway_method_response.member_death_report_options_200.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token,X-Amz-Content-Sha256'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
  depends_on = [aws_api_gateway_integration.member_death_report_options]
}

# ── /member/enrollment  POST → express enrollment request ────────────────────

resource "aws_api_gateway_resource" "member_enrollment" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.member.id
  path_part   = "enrollment"
}

resource "aws_api_gateway_method" "member_enrollment_post" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.member_enrollment.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "member_enrollment_post" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.member_enrollment.id
  http_method             = aws_api_gateway_method.member_enrollment_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.certificate_handler.invoke_arn
}

resource "aws_api_gateway_method" "member_enrollment_options" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.member_enrollment.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "member_enrollment_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.member_enrollment.id
  http_method = aws_api_gateway_method.member_enrollment_options.http_method
  type        = "MOCK"
  request_templates = { "application/json" = "{\"statusCode\": 200}" }
}

resource "aws_api_gateway_method_response" "member_enrollment_options_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.member_enrollment.id
  http_method = aws_api_gateway_method.member_enrollment_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "member_enrollment_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.member_enrollment.id
  http_method = aws_api_gateway_method.member_enrollment_options.http_method
  status_code = aws_api_gateway_method_response.member_enrollment_options_200.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token,X-Amz-Content-Sha256'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
  depends_on = [aws_api_gateway_integration.member_enrollment_options]
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
      aws_api_gateway_integration.member_login_post.id,
      aws_api_gateway_integration.members_set_credentials_post.id,
      aws_api_gateway_integration.member_chat_post.id,
      aws_api_gateway_integration.member_policy_get.id,
      aws_api_gateway_integration.member_payment_post.id,
      aws_api_gateway_integration.member_claim_post.id,
      aws_api_gateway_integration.members_set_payment_access_post.id,
      aws_api_gateway_integration.member_acknowledge_payment_post.id,
      aws_api_gateway_integration.member_profile_get.id,
      aws_api_gateway_integration.member_beneficiaries_get.id,
      aws_api_gateway_integration.member_beneficiaries_post.id,
      aws_api_gateway_integration.member_partners_get.id,
      aws_api_gateway_integration.member_documents_get.id,
      aws_api_gateway_integration.member_documents_upload_post.id,
      aws_api_gateway_integration.member_death_report_post.id,
      aws_api_gateway_integration.member_enrollment_post.id,
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
    aws_api_gateway_integration.member_login_post,
    aws_api_gateway_integration.members_set_credentials_post,
    aws_api_gateway_integration.member_chat_post,
    aws_api_gateway_integration.member_policy_get,
    aws_api_gateway_integration.member_payment_post,
    aws_api_gateway_integration.member_claim_post,
    aws_api_gateway_integration.members_set_payment_access_post,
    aws_api_gateway_integration.member_acknowledge_payment_post,
    aws_api_gateway_integration.member_profile_get,
    aws_api_gateway_integration.member_beneficiaries_get,
    aws_api_gateway_integration.member_beneficiaries_post,
    aws_api_gateway_integration.member_partners_get,
    aws_api_gateway_integration.member_documents_get,
    aws_api_gateway_integration.member_documents_upload_post,
    aws_api_gateway_integration.member_death_report_post,
    aws_api_gateway_integration.member_enrollment_post,
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

################################################################################
# ACM Certificate — member.kafayiti.com
# Must be in us-east-1 for CloudFront
################################################################################

resource "aws_acm_certificate" "member_portal" {
  provider          = aws.us_east_1
  domain_name       = "member.kafayiti.com"
  validation_method = "DNS"
  tags              = local.common_tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "member_portal_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.member_portal.domain_validation_options : dvo.domain_name => {
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

resource "aws_acm_certificate_validation" "member_portal" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.member_portal.arn
  validation_record_fqdns = [for record in aws_route53_record.member_portal_cert_validation : record.fqdn]
}

################################################################################
# S3 — Member Portal Flutter Web App
################################################################################

resource "aws_s3_bucket" "member_portal" {
  bucket        = "kafa-member-kafayiti"
  force_destroy = true
  tags          = local.common_tags
}

resource "aws_s3_bucket_versioning" "member_portal" {
  bucket = aws_s3_bucket.member_portal.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "member_portal" {
  bucket                  = aws_s3_bucket.member_portal.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_website_configuration" "member_portal" {
  bucket = aws_s3_bucket.member_portal.id

  index_document { suffix = "index.html" }
  error_document { key    = "index.html" }
}

################################################################################
# CloudFront — HTTPS distribution for Member Portal
################################################################################

resource "aws_cloudfront_origin_access_control" "member_portal" {
  name                              = "kafa-member-kafayiti-oac"
  description                       = "OAC for KAFA Member Portal S3 bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "member_portal" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  comment             = "KAFA Member Portal Flutter Web App"
  tags                = local.common_tags

  origin {
    domain_name              = aws_s3_bucket.member_portal.bucket_regional_domain_name
    origin_id                = "S3-kafa-member-kafayiti"
    origin_access_control_id = aws_cloudfront_origin_access_control.member_portal.id
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "S3-kafa-member-kafayiti"
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

  aliases = ["member.kafayiti.com"]

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.member_portal.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

# Bucket policy — allow CloudFront OAC to read from S3
resource "aws_s3_bucket_policy" "member_portal" {
  bucket = aws_s3_bucket.member_portal.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowCloudFrontOAC"
      Effect = "Allow"
      Principal = {
        Service = "cloudfront.amazonaws.com"
      }
      Action   = "s3:GetObject"
      Resource = "${aws_s3_bucket.member_portal.arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.member_portal.arn
        }
      }
    }]
  })
}

################################################################################
# Route 53 — member.kafayiti.com → CloudFront
################################################################################

resource "aws_route53_record" "member_portal" {
  zone_id = data.aws_route53_zone.kafayiti.zone_id
  name    = "member.kafayiti.com"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.member_portal.domain_name
    zone_id                = aws_cloudfront_distribution.member_portal.hosted_zone_id
    evaluate_target_health = false
  }
}

################################################################################
# Outputs — Member Portal hosting
################################################################################

output "member_portal_bucket" {
  description = "S3 bucket for Member Portal Flutter web build"
  value       = aws_s3_bucket.member_portal.id
}

output "member_portal_cloudfront_url" {
  description = "HTTPS URL for the KAFA Member Portal"
  value       = "https://member.kafayiti.com"
}

output "member_portal_cloudfront_id" {
  description = "CloudFront distribution ID for Member Portal"
  value       = aws_cloudfront_distribution.member_portal.id
}

################################################################################
# DynamoDB — kopera-life-insurance  (Cooperative Life Insurance)
#
# Single-table design  ·  PK + SK  ·  3 GSIs
#
# ── FOREIGN KEY ───────────────────────────────────────────────────────────────
#   Members are stored in the separate "kopera-member" table.
#   Every policy item carries BOTH:
#     memberId  — kopera-member hash key
#     companyId — kopera-member range key
#   Together they form the composite key needed for a direct GetItem on
#   kopera-member. No member data is duplicated in this table.
#
# ── KEY SCHEMA ────────────────────────────────────────────────────────────────
#   PK  (HASH)   entity-type prefix    e.g. POLICY#POL-2024-000001
#   SK  (RANGE)  sub-entity / date     e.g. METADATA | PAY#2024-03-15#TXN-XXX
#
# ── ENTITY → KEY MAPPING ──────────────────────────────────────────────────────
#   Policy master           PK=POLICY#<policyNo>    SK=METADATA
#   Policy-by-member index  PK=MEMBER#<memberId>    SK=POLICY#<policyNo>
#   Premium schedule        PK=POLICY#<policyNo>    SK=SCHED#<YYYY-MM-DD>#<000001>
#   Premium payment         PK=POLICY#<policyNo>    SK=PAY#<YYYY-MM-DD>#<refNo>
#   Beneficiary             PK=POLICY#<policyNo>    SK=BENEF#<id>
#   Claim                   PK=POLICY#<policyNo>    SK=CLAIM#<claimNo>
#   Insurance product       PK=PRODUCT#<code>       SK=METADATA
#   Premium plan            PK=PRODUCT#<code>       SK=PLAN#<planId>
#
# ── GSI USAGE ─────────────────────────────────────────────────────────────────
#   GSI2-DueDate      all policies due on a given date (reminder / collection jobs)
#   GSI3-PaymentRef   retrieve a payment by its unique reference number
#   GSI4-StatusDue    overdue sweep: status=ACTIVE AND nextDueDate < today
################################################################################

resource "aws_dynamodb_table" "kopera-life-insurance" {
  name         = "kopera-life-insurance"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "PK"
  range_key    = "SK"

  # ── Base table keys ──────────────────────────────────────────────────────────
  attribute {
    name = "PK"
    type = "S"
  }

  attribute {
    name = "SK"
    type = "S"
  }

  # ── GSI1 attributes (payments by policy, newest-first) ───────────────────────
  attribute {
    name = "GSI1PK"   # "POLICY#<policy_id>"
    type = "S"
  }

  attribute {
    name = "GSI1SK"   # "PAYMENT#<created_at ISO>"  — sorts chronologically
    type = "S"
  }

  # ── GSI2 attributes (policies by next due date) ──────────────────────────────
  attribute {
    name = "GSI2PK"   # next_due_date  e.g. "2024-03-15"
    type = "S"
  }

  attribute {
    name = "GSI2SK"   # PK of the policy  e.g. "POLICY#POL-2024-000001"
    type = "S"
  }

  # ── GSI3 attribute (payment lookup by reference number) ──────────────────────
  attribute {
    name = "GSI3PK"   # reference_no  e.g. "TXN-20240315-A1B2C3D4"
    type = "S"
  }

  # ── GSI4 attributes (overdue/lapsed policy sweep) ────────────────────────────
  attribute {
    name = "GSI4PK"   # policy_status  e.g. "ACTIVE" | "LAPSED"
    type = "S"
  }

  attribute {
    name = "GSI4SK"   # next_due_date  e.g. "2024-03-15"  (same shape as GSI2PK)
    type = "S"
  }

  # ── GSI5 attribute (Stripe payment intent lookup) ─────────────────────────────
  attribute {
    name = "GSI5PK"   # stripe_payment_intent_id  e.g. "pi_3Pxxxxx"
    type = "S"
  }

  # ── GSI1 — payments by policy ────────────────────────────────────────────────
  # Access pattern: getRecentPayments(policyId, limit=12)
  # Used by get_policy Lambda to populate payment history tab.
  global_secondary_index {
    name            = "GSI1"
    hash_key        = "GSI1PK"
    range_key       = "GSI1SK"
    projection_type = "ALL"
  }

  # ── GSI2 — policies due on a date ────────────────────────────────────────────
  # Access pattern: getPoliciesDueOnDate("2024-03-15")
  # Sparse projection keeps this index lean — only premium collection fields.
  global_secondary_index {
    name            = "GSI2-DueDate"
    hash_key        = "GSI2PK"
    range_key       = "GSI2SK"
    projection_type = "INCLUDE"
    non_key_attributes = [
      "policyNo",
      "memberId",
      "memberName",
      "premiumAmount",
      "policyStatus",
    ]
  }

  # ── GSI3 — payment by reference number ───────────────────────────────────────
  # Access pattern: getPaymentByRef("TXN-20240315-A1B2C3D4")
  # No range key — reference numbers are globally unique (UUID segment + date).
  global_secondary_index {
    name            = "GSI3-PaymentRef"
    hash_key        = "GSI3PK"
    projection_type = "ALL"
  }

  # ── GSI4 — overdue policy sweep ──────────────────────────────────────────────
  # Access pattern: getOverduePolicies()
  #   Query: GSI4PK = "ACTIVE" AND GSI4SK < "2024-03-15"
  global_secondary_index {
    name            = "GSI4-StatusDue"
    hash_key        = "GSI4PK"
    range_key       = "GSI4SK"
    projection_type = "INCLUDE"
    non_key_attributes = [
      "policyNo",
      "memberId",
      "memberName",
      "premiumAmount",
      "nextDueDate",
    ]
  }

  # ── GSI5 — Stripe payment intent lookup ───────────────────────────────────────
  # Access pattern: getPaymentByStripeIntentId("pi_3Pxxxxx")
  # Used by stripe_webhook Lambda to find the PENDING record and update its status.
  global_secondary_index {
    name            = "GSI5-StripeIntent"
    hash_key        = "GSI5PK"
    projection_type = "ALL"
  }

  # ── Operational safety ───────────────────────────────────────────────────────
  point_in_time_recovery {
    enabled = true   # 35-day rolling backup window
  }

  server_side_encryption {
    enabled = true   # AES-256 managed by AWS
  }

  tags = merge(local.common_tags, {
    Name    = "kopera-life-insurance"
    Purpose = "cooperative-life-insurance"
  })
}

################################################################################
# IAM — extend Lambda execution role to cover the life-insurance table
#
# Added actions beyond the base lambda_dynamodb policy:
#   TransactWriteItems  — atomic pay-premium (write PAY# + update SCHED# + update METADATA)
#   ConditionCheck      — idempotency guard inside TransactWrite
################################################################################

resource "aws_iam_role_policy" "lambda_life_insurance_dynamodb" {
  name = "life-insurance-dynamodb"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "LifeInsuranceCRUD"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem",
          "dynamodb:Query",
          "dynamodb:Scan",
          "dynamodb:BatchWriteItem",
          # Required for atomic pay-premium TransactWrite
          "dynamodb:TransactWriteItems",
          "dynamodb:TransactGetItems",
          # Required as a participant inside TransactWrite
          "dynamodb:ConditionCheckItem",
        ]
        Resource = [
          aws_dynamodb_table.kopera-life-insurance.arn,
          "${aws_dynamodb_table.kopera-life-insurance.arn}/index/*",
        ]
      },
    ]
  })
}

################################################################################
# Stripe Payment Lambdas
#
#  create_payment_intent  — POST /payments/create-intent
#  stripe_webhook         — POST /payments/webhook
#
# Secrets stored in AWS Secrets Manager; retrieved at deploy time via
# aws_secretsmanager_secret_version data sources (see below).
# Add two secrets manually before running terraform apply:
#   kopera/stripe/secret_key      → sk_test_... (or sk_live_...)
#   kopera/stripe/webhook_secret  → whsec_...
################################################################################

# ── IAM role shared by both payment Lambdas ───────────────────────────────────

resource "aws_iam_role" "lambda_payment_exec" {
  name = "${local.prefix}-lambda-payment-exec"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambda_payment_policy" {
  name = "${local.prefix}-lambda-payment-policy"
  role = aws_iam_role.lambda_payment_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Logs"
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Sid    = "DynamoDB"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:GetItem",
          "dynamodb:Query",
        ]
        Resource = [
          aws_dynamodb_table.kopera-life-insurance.arn,
          "${aws_dynamodb_table.kopera-life-insurance.arn}/index/*",
        ]
      },
      {
        Sid    = "Secrets"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = [
          "arn:aws:secretsmanager:${var.aws_region}:*:secret:kopera/stripe/*",
        ]
      },
    ]
  })
}

# ── create_payment_intent Lambda ──────────────────────────────────────────────

resource "aws_lambda_function" "create_payment_intent" {
  function_name = "${local.prefix}-create-payment-intent"
  description   = "Creates a Stripe PaymentIntent and writes a PENDING record to DynamoDB"

  s3_bucket = aws_s3_bucket.kopera-asset.id
  s3_key    = "lambda/payment.zip"

  runtime     = "python3.12"
  handler     = "create_payment_intent.lambda_handler"
  role        = aws_iam_role.lambda_payment_exec.arn
  timeout     = 30
  memory_size = 256

  environment {
    variables = {
      LIFE_INSURANCE_TABLE = aws_dynamodb_table.kopera-life-insurance.name
      STRIPE_SECRET_KEY    = var.stripe_secret_key
    }
  }
}

resource "aws_lambda_permission" "create_payment_intent_apigw" {
  statement_id  = "AllowAPIGatewayInvokePaymentIntent"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.create_payment_intent.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.main.execution_arn}/*/*"
}

# ── stripe_webhook Lambda ─────────────────────────────────────────────────────

resource "aws_lambda_function" "stripe_webhook" {
  function_name = "${local.prefix}-stripe-webhook"
  description   = "Receives Stripe webhook events and updates DynamoDB payment status"

  s3_bucket = aws_s3_bucket.kopera-asset.id
  s3_key    = "lambda/payment.zip"

  runtime     = "python3.12"
  handler     = "stripe_webhook.lambda_handler"
  role        = aws_iam_role.lambda_payment_exec.arn
  timeout     = 30
  memory_size = 256

  environment {
    variables = {
      LIFE_INSURANCE_TABLE = aws_dynamodb_table.kopera-life-insurance.name
      STRIPE_SECRET_KEY    = var.stripe_secret_key
      KAFA_WEBHOOK_SECRET  = var.stripe_webhook_secret
    }
  }
}

resource "aws_lambda_permission" "stripe_webhook_apigw" {
  statement_id  = "AllowAPIGatewayInvokeStripeWebhook"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.stripe_webhook.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.main.execution_arn}/*/*"
}

# ── API Gateway routes ────────────────────────────────────────────────────────

resource "aws_api_gateway_resource" "payments" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "payments"
}

resource "aws_api_gateway_resource" "payments_create_intent" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.payments.id
  path_part   = "create-intent"
}

resource "aws_api_gateway_resource" "payments_webhook" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.payments.id
  path_part   = "webhook"
}

resource "aws_api_gateway_method" "post_create_intent" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.payments_create_intent.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_method" "post_webhook" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.payments_webhook.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "create_intent_lambda" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.payments_create_intent.id
  http_method             = aws_api_gateway_method.post_create_intent.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.create_payment_intent.invoke_arn
}

resource "aws_api_gateway_integration" "webhook_lambda" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.payments_webhook.id
  http_method             = aws_api_gateway_method.post_webhook.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.stripe_webhook.invoke_arn
}

# ── CORS OPTIONS for /payments/create-intent ──────────────────────────────────

resource "aws_api_gateway_method" "create_intent_options" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.payments_create_intent.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "create_intent_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.payments_create_intent.id
  http_method = aws_api_gateway_method.create_intent_options.http_method
  type        = "MOCK"
  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "create_intent_options_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.payments_create_intent.id
  http_method = aws_api_gateway_method.create_intent_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "create_intent_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.payments_create_intent.id
  http_method = aws_api_gateway_method.create_intent_options.http_method
  status_code = aws_api_gateway_method_response.create_intent_options_200.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'https://member.kafayiti.com'"
  }
  depends_on = [aws_api_gateway_integration.create_intent_options]
}

################################################################################
# Outputs — kopera-life-insurance table
################################################################################

output "life_insurance_table_name" {
  description = "DynamoDB table name for the cooperative life insurance model"
  value       = aws_dynamodb_table.kopera-life-insurance.name
}

output "life_insurance_table_arn" {
  description = "ARN of the kopera-life-insurance DynamoDB table"
  value       = aws_dynamodb_table.kopera-life-insurance.arn
}

output "life_insurance_stream_arn" {
  description = "DynamoDB Streams ARN (empty when streams are disabled)"
  value       = aws_dynamodb_table.kopera-life-insurance.stream_arn
}

output "api_gateway_base_url" {
  description = "Base URL for the KAFA API Gateway — pass as --dart-define=API_BASE_URL=<value>"
  value       = "https://${aws_api_gateway_rest_api.main.id}.execute-api.${var.aws_region}.amazonaws.com/${var.environment}"
}

################################################################################
# get_policy Lambda  — GET /policies/{policyId}?memberId=...
################################################################################

resource "aws_lambda_function" "get_policy" {
  function_name = "${local.prefix}-get-policy"
  description   = "Returns full policy detail for the member portal PolicyDetailScreen"

  s3_bucket = aws_s3_bucket.kopera-asset.id
  s3_key    = "lambda/payment.zip"

  runtime     = "python3.12"
  handler     = "get_policy.handler"
  role        = aws_iam_role.lambda_exec.arn
  timeout     = 10
  memory_size = 256

  environment {
    variables = {
      INSURANCE_TABLE = aws_dynamodb_table.kopera-life-insurance.name
      MEMBER_TABLE    = aws_dynamodb_table.kopera-member.name
    }
  }
}

resource "aws_api_gateway_resource" "policies" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "policies"
}

resource "aws_api_gateway_resource" "policy_item" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.policies.id
  path_part   = "{policyId}"
}

resource "aws_api_gateway_method" "get_policy" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.policy_item.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "get_policy" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.policy_item.id
  http_method             = aws_api_gateway_method.get_policy.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.get_policy.invoke_arn
}

resource "aws_lambda_permission" "get_policy_apigw" {
  statement_id  = "AllowAPIGWGetPolicy"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.get_policy.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.main.execution_arn}/*/*"
}

################################################################################
# DynamoDB Seed Data — kopera-life-insurance
#
# Entities seeded (single-table):
#   2 Insurance products  (LIFE-BASIC, LIFE-PLUS)
#   2 Premium plans       (monthly for each product)
#   2 Members             (Alice Kamau, Bruno Nakamura)
#   2 Policies            (one per member)
#   2 Policy→Member refs  (allows listing a member's policies)
#   6 Premium schedule    (3 installments per policy)
#   2 Payments            (first installment paid for each policy)
#   2 Beneficiaries       (one primary per policy)
################################################################################

# ── Insurance Products ────────────────────────────────────────────────────────

resource "aws_dynamodb_table_item" "product_life_basic" {
  table_name = aws_dynamodb_table.kopera-life-insurance.name
  hash_key   = "PK"
  range_key  = "SK"

  item = jsonencode({
    PK            = { S = "PRODUCT#LIFE-BASIC" }
    SK            = { S = "METADATA" }
    entity_type   = { S = "PRODUCT" }
    productCode   = { S = "LIFE-BASIC" }
    name          = { S = "Kopera Basic Life Cover" }
    description   = { S = "Essential whole-life cover for cooperative members" }
    coverageType  = { S = "WHOLE_LIFE" }
    isActive      = { BOOL = true }
    createdAt     = { S = "2024-01-01T00:00:00Z" }
  })
}

resource "aws_dynamodb_table_item" "product_life_plus" {
  table_name = aws_dynamodb_table.kopera-life-insurance.name
  hash_key   = "PK"
  range_key  = "SK"

  item = jsonencode({
    PK            = { S = "PRODUCT#LIFE-PLUS" }
    SK            = { S = "METADATA" }
    entity_type   = { S = "PRODUCT" }
    productCode   = { S = "LIFE-PLUS" }
    name          = { S = "Kopera Plus Life Cover" }
    description   = { S = "Enhanced term cover with critical illness rider" }
    coverageType  = { S = "TERM" }
    isActive      = { BOOL = true }
    createdAt     = { S = "2024-01-01T00:00:00Z" }
  })
}

# ── Premium Plans ─────────────────────────────────────────────────────────────

resource "aws_dynamodb_table_item" "plan_basic_monthly" {
  table_name = aws_dynamodb_table.kopera-life-insurance.name
  hash_key   = "PK"
  range_key  = "SK"

  item = jsonencode({
    PK               = { S = "PRODUCT#LIFE-BASIC" }
    SK               = { S = "PLAN#plan-basic-monthly" }
    entity_type      = { S = "PLAN" }
    planId           = { S = "plan-basic-monthly" }
    productCode      = { S = "LIFE-BASIC" }
    name             = { S = "Basic Monthly" }
    frequency        = { S = "MONTHLY" }
    premiumAmount    = { N = "150" }
    sumAssured       = { N = "50000" }
    gracePeriodDays  = { N = "30" }
    lateFeeAmount    = { N = "10" }
    lateFeePct       = { N = "2" }
    isActive         = { BOOL = true }
  })
}

resource "aws_dynamodb_table_item" "plan_plus_monthly" {
  table_name = aws_dynamodb_table.kopera-life-insurance.name
  hash_key   = "PK"
  range_key  = "SK"

  item = jsonencode({
    PK               = { S = "PRODUCT#LIFE-PLUS" }
    SK               = { S = "PLAN#plan-plus-monthly" }
    entity_type      = { S = "PLAN" }
    planId           = { S = "plan-plus-monthly" }
    productCode      = { S = "LIFE-PLUS" }
    name             = { S = "Plus Monthly" }
    frequency        = { S = "MONTHLY" }
    premiumAmount    = { N = "280" }
    sumAssured       = { N = "120000" }
    gracePeriodDays  = { N = "30" }
    lateFeeAmount    = { N = "20" }
    lateFeePct       = { N = "2" }
    isActive         = { BOOL = true }
  })
}

# ── Members ───────────────────────────────────────────────────────────────────

# ── Policy Masters ────────────────────────────────────────────────────────────

resource "aws_dynamodb_table_item" "policy_alice_metadata" {
  table_name = aws_dynamodb_table.kopera-life-insurance.name
  hash_key   = "PK"
  range_key  = "SK"

  item = jsonencode({
    PK             = { S = "POLICY#POL-2024-000001" }
    SK             = { S = "METADATA" }
    GSI2PK         = { S = "2024-04-15" }
    GSI2SK         = { S = "POLICY#POL-2024-000001" }
    GSI4PK         = { S = "ACTIVE" }
    GSI4SK         = { S = "2024-04-15" }
    entity_type    = { S = "POLICY" }
    policyNo       = { S = "POL-2024-000001" }
    # FK → kopera-member (hash=memberId, range=companyId)
    memberId       = { S = "mbr-001" }
    companyId      = { S = "coop-001" }
    memberName     = { S = "Alice Kamau" }
    productCode    = { S = "LIFE-BASIC" }
    planId         = { S = "plan-basic-monthly" }
    frequency      = { S = "MONTHLY" }
    startDate      = { S = "2024-01-15" }
    endDate        = { S = "" }
    policyStatus   = { S = "ACTIVE" }
    sumAssured     = { N = "50000" }
    premiumAmount  = { N = "150" }
    nextDueDate    = { S = "2024-04-15" }
    lastPaidDate   = { S = "2024-03-15" }
    lastPaidAmount = { N = "150" }
    totalPaid      = { N = "300" }
    createdAt      = { S = "2024-01-15T10:00:00Z" }
    updatedAt      = { S = "2024-03-15T11:00:00Z" }
  })
}

resource "aws_dynamodb_table_item" "policy_bruno_metadata" {
  table_name = aws_dynamodb_table.kopera-life-insurance.name
  hash_key   = "PK"
  range_key  = "SK"

  item = jsonencode({
    PK             = { S = "POLICY#POL-2024-000002" }
    SK             = { S = "METADATA" }
    GSI2PK         = { S = "2024-04-15" }
    GSI2SK         = { S = "POLICY#POL-2024-000002" }
    GSI4PK         = { S = "ACTIVE" }
    GSI4SK         = { S = "2024-04-15" }
    entity_type    = { S = "POLICY" }
    policyNo       = { S = "POL-2024-000002" }
    # FK → kopera-member (hash=memberId, range=companyId)
    memberId       = { S = "mbr-002" }
    companyId      = { S = "coop-001" }
    memberName     = { S = "Bruno Nakamura" }
    productCode    = { S = "LIFE-PLUS" }
    planId         = { S = "plan-plus-monthly" }
    frequency      = { S = "MONTHLY" }
    startDate      = { S = "2024-01-20" }
    endDate        = { S = "" }
    policyStatus   = { S = "ACTIVE" }
    sumAssured     = { N = "120000" }
    premiumAmount  = { N = "280" }
    nextDueDate    = { S = "2024-04-15" }
    lastPaidDate   = { S = "2024-03-15" }
    lastPaidAmount = { N = "280" }
    totalPaid      = { N = "560" }
    createdAt      = { S = "2024-01-20T10:00:00Z" }
    updatedAt      = { S = "2024-03-15T11:30:00Z" }
  })
}

# ── Policy → Member index items (allows listing policies per member) ──────────

resource "aws_dynamodb_table_item" "member_alice_policy_ref" {
  table_name = aws_dynamodb_table.kopera-life-insurance.name
  hash_key   = "PK"
  range_key  = "SK"

  item = jsonencode({
    PK            = { S = "MEMBER#mbr-001" }
    SK            = { S = "POLICY#POL-2024-000001" }
    entity_type   = { S = "MEMBER_POLICY_REF" }
    # FK → kopera-member (hash=memberId, range=companyId)
    memberId      = { S = "mbr-001" }
    companyId     = { S = "coop-001" }
    policyNo      = { S = "POL-2024-000001" }
    productCode   = { S = "LIFE-BASIC" }
    policyStatus  = { S = "ACTIVE" }
    premiumAmount = { N = "150" }
    sumAssured    = { N = "50000" }
    startDate     = { S = "2024-01-15" }
    nextDueDate   = { S = "2024-04-15" }
  })
}

resource "aws_dynamodb_table_item" "member_bruno_policy_ref" {
  table_name = aws_dynamodb_table.kopera-life-insurance.name
  hash_key   = "PK"
  range_key  = "SK"

  item = jsonencode({
    PK            = { S = "MEMBER#mbr-002" }
    SK            = { S = "POLICY#POL-2024-000002" }
    entity_type   = { S = "MEMBER_POLICY_REF" }
    # FK → kopera-member (hash=memberId, range=companyId)
    memberId      = { S = "mbr-002" }
    companyId     = { S = "coop-001" }
    policyNo      = { S = "POL-2024-000002" }
    productCode   = { S = "LIFE-PLUS" }
    policyStatus  = { S = "ACTIVE" }
    premiumAmount = { N = "280" }
    sumAssured    = { N = "120000" }
    startDate     = { S = "2024-01-20" }
    nextDueDate   = { S = "2024-04-15" }
  })
}

# ── Premium Schedules — Alice (POL-2024-000001) ───────────────────────────────

resource "aws_dynamodb_table_item" "sched_alice_1" {
  table_name = aws_dynamodb_table.kopera-life-insurance.name
  hash_key   = "PK"
  range_key  = "SK"

  item = jsonencode({
    PK             = { S = "POLICY#POL-2024-000001" }
    SK             = { S = "SCHED#2024-02-15#000001" }
    entity_type    = { S = "SCHEDULE" }
    policyNo       = { S = "POL-2024-000001" }
    installmentNo  = { N = "1" }
    dueDate        = { S = "2024-02-15" }
    amountDue      = { N = "150" }
    status         = { S = "PAID" }
    paidDate       = { S = "2024-02-15" }
    paidAmount     = { N = "150" }
  })
}

resource "aws_dynamodb_table_item" "sched_alice_2" {
  table_name = aws_dynamodb_table.kopera-life-insurance.name
  hash_key   = "PK"
  range_key  = "SK"

  item = jsonencode({
    PK             = { S = "POLICY#POL-2024-000001" }
    SK             = { S = "SCHED#2024-03-15#000002" }
    entity_type    = { S = "SCHEDULE" }
    policyNo       = { S = "POL-2024-000001" }
    installmentNo  = { N = "2" }
    dueDate        = { S = "2024-03-15" }
    amountDue      = { N = "150" }
    status         = { S = "PAID" }
    paidDate       = { S = "2024-03-15" }
    paidAmount     = { N = "150" }
  })
}

resource "aws_dynamodb_table_item" "sched_alice_3" {
  table_name = aws_dynamodb_table.kopera-life-insurance.name
  hash_key   = "PK"
  range_key  = "SK"

  item = jsonencode({
    PK             = { S = "POLICY#POL-2024-000001" }
    SK             = { S = "SCHED#2024-04-15#000003" }
    entity_type    = { S = "SCHEDULE" }
    policyNo       = { S = "POL-2024-000001" }
    installmentNo  = { N = "3" }
    dueDate        = { S = "2024-04-15" }
    amountDue      = { N = "150" }
    status         = { S = "PENDING" }
    paidDate       = { S = "" }
    paidAmount     = { N = "0" }
  })
}

# ── Premium Schedules — Bruno (POL-2024-000002) ───────────────────────────────

resource "aws_dynamodb_table_item" "sched_bruno_1" {
  table_name = aws_dynamodb_table.kopera-life-insurance.name
  hash_key   = "PK"
  range_key  = "SK"

  item = jsonencode({
    PK             = { S = "POLICY#POL-2024-000002" }
    SK             = { S = "SCHED#2024-02-15#000001" }
    entity_type    = { S = "SCHEDULE" }
    policyNo       = { S = "POL-2024-000002" }
    installmentNo  = { N = "1" }
    dueDate        = { S = "2024-02-15" }
    amountDue      = { N = "280" }
    status         = { S = "PAID" }
    paidDate       = { S = "2024-02-14" }
    paidAmount     = { N = "280" }
  })
}

resource "aws_dynamodb_table_item" "sched_bruno_2" {
  table_name = aws_dynamodb_table.kopera-life-insurance.name
  hash_key   = "PK"
  range_key  = "SK"

  item = jsonencode({
    PK             = { S = "POLICY#POL-2024-000002" }
    SK             = { S = "SCHED#2024-03-15#000002" }
    entity_type    = { S = "SCHEDULE" }
    policyNo       = { S = "POL-2024-000002" }
    installmentNo  = { N = "2" }
    dueDate        = { S = "2024-03-15" }
    amountDue      = { N = "280" }
    status         = { S = "PAID" }
    paidDate       = { S = "2024-03-15" }
    paidAmount     = { N = "280" }
  })
}

resource "aws_dynamodb_table_item" "sched_bruno_3" {
  table_name = aws_dynamodb_table.kopera-life-insurance.name
  hash_key   = "PK"
  range_key  = "SK"

  item = jsonencode({
    PK             = { S = "POLICY#POL-2024-000002" }
    SK             = { S = "SCHED#2024-04-15#000003" }
    entity_type    = { S = "SCHEDULE" }
    policyNo       = { S = "POL-2024-000002" }
    installmentNo  = { N = "3" }
    dueDate        = { S = "2024-04-15" }
    amountDue      = { N = "280" }
    status         = { S = "PENDING" }
    paidDate       = { S = "" }
    paidAmount     = { N = "0" }
  })
}

# ── Premium Payments — Alice ──────────────────────────────────────────────────

resource "aws_dynamodb_table_item" "pay_alice_1" {
  table_name = aws_dynamodb_table.kopera-life-insurance.name
  hash_key   = "PK"
  range_key  = "SK"

  item = jsonencode({
    PK             = { S = "POLICY#POL-2024-000001" }
    SK             = { S = "PAY#2024-02-15#TXN-20240215-A1B2C3D4" }
    GSI3PK         = { S = "TXN-20240215-A1B2C3D4" }
    entity_type    = { S = "PAYMENT" }
    referenceNo    = { S = "TXN-20240215-A1B2C3D4" }
    policyNo       = { S = "POL-2024-000001" }
    schedSK        = { S = "SCHED#2024-02-15#000001" }
    paymentDate    = { S = "2024-02-15" }
    amountPaid     = { N = "150" }
    lateFee        = { N = "0" }
    totalCollected = { N = "150" }
    paymentMethod  = { S = "MOBILE_MONEY" }
    channel        = { S = "MOBILE_APP" }
    externalRef    = { S = "MM-20240215-XYZXYZ" }
    collectedBy    = { S = "mbr-001" }
    voided         = { BOOL = false }
    createdAt      = { S = "2024-02-15T10:22:00Z" }
  })
}

resource "aws_dynamodb_table_item" "pay_alice_2" {
  table_name = aws_dynamodb_table.kopera-life-insurance.name
  hash_key   = "PK"
  range_key  = "SK"

  item = jsonencode({
    PK             = { S = "POLICY#POL-2024-000001" }
    SK             = { S = "PAY#2024-03-15#TXN-20240315-E5F6G7H8" }
    GSI3PK         = { S = "TXN-20240315-E5F6G7H8" }
    entity_type    = { S = "PAYMENT" }
    referenceNo    = { S = "TXN-20240315-E5F6G7H8" }
    policyNo       = { S = "POL-2024-000001" }
    schedSK        = { S = "SCHED#2024-03-15#000002" }
    paymentDate    = { S = "2024-03-15" }
    amountPaid     = { N = "150" }
    lateFee        = { N = "0" }
    totalCollected = { N = "150" }
    paymentMethod  = { S = "BANK_TRANSFER" }
    channel        = { S = "WEB" }
    externalRef    = { S = "BNK-20240315-ABCABC" }
    collectedBy    = { S = "mbr-001" }
    voided         = { BOOL = false }
    createdAt      = { S = "2024-03-15T09:10:00Z" }
  })
}

# ── Premium Payments — Bruno ──────────────────────────────────────────────────

resource "aws_dynamodb_table_item" "pay_bruno_1" {
  table_name = aws_dynamodb_table.kopera-life-insurance.name
  hash_key   = "PK"
  range_key  = "SK"

  item = jsonencode({
    PK             = { S = "POLICY#POL-2024-000002" }
    SK             = { S = "PAY#2024-02-14#TXN-20240214-I9J0K1L2" }
    GSI3PK         = { S = "TXN-20240214-I9J0K1L2" }
    entity_type    = { S = "PAYMENT" }
    referenceNo    = { S = "TXN-20240214-I9J0K1L2" }
    policyNo       = { S = "POL-2024-000002" }
    schedSK        = { S = "SCHED#2024-02-15#000001" }
    paymentDate    = { S = "2024-02-14" }
    amountPaid     = { N = "280" }
    lateFee        = { N = "0" }
    totalCollected = { N = "280" }
    paymentMethod  = { S = "CASH" }
    channel        = { S = "BRANCH" }
    externalRef    = { S = "" }
    collectedBy    = { S = "mbr-002" }
    voided         = { BOOL = false }
    createdAt      = { S = "2024-02-14T14:05:00Z" }
  })
}

resource "aws_dynamodb_table_item" "pay_bruno_2" {
  table_name = aws_dynamodb_table.kopera-life-insurance.name
  hash_key   = "PK"
  range_key  = "SK"

  item = jsonencode({
    PK             = { S = "POLICY#POL-2024-000002" }
    SK             = { S = "PAY#2024-03-15#TXN-20240315-M3N4O5P6" }
    GSI3PK         = { S = "TXN-20240315-M3N4O5P6" }
    entity_type    = { S = "PAYMENT" }
    referenceNo    = { S = "TXN-20240315-M3N4O5P6" }
    policyNo       = { S = "POL-2024-000002" }
    schedSK        = { S = "SCHED#2024-03-15#000002" }
    paymentDate    = { S = "2024-03-15" }
    amountPaid     = { N = "280" }
    lateFee        = { N = "0" }
    totalCollected = { N = "280" }
    paymentMethod  = { S = "MOBILE_MONEY" }
    channel        = { S = "USSD" }
    externalRef    = { S = "MM-20240315-MNOPQR" }
    collectedBy    = { S = "mbr-002" }
    voided         = { BOOL = false }
    createdAt      = { S = "2024-03-15T08:45:00Z" }
  })
}

# ── Beneficiaries ─────────────────────────────────────────────────────────────

resource "aws_dynamodb_table_item" "benef_alice" {
  table_name = aws_dynamodb_table.kopera-life-insurance.name
  hash_key   = "PK"
  range_key  = "SK"

  item = jsonencode({
    PK           = { S = "POLICY#POL-2024-000001" }
    SK           = { S = "BENEF#bnf-001" }
    entity_type  = { S = "BENEFICIARY" }
    benefId      = { S = "bnf-001" }
    policyNo     = { S = "POL-2024-000001" }
    fullName     = { S = "James Kamau" }
    relationship = { S = "SPOUSE" }
    dateOfBirth  = { S = "1983-07-22" }
    nationalId   = { S = "ID-5544332" }
    phone        = { S = "+254700000010" }
    sharePct     = { N = "100" }
    isPrimary    = { BOOL = true }
    createdAt    = { S = "2024-01-15T10:05:00Z" }
  })
}

resource "aws_dynamodb_table_item" "benef_bruno" {
  table_name = aws_dynamodb_table.kopera-life-insurance.name
  hash_key   = "PK"
  range_key  = "SK"

  item = jsonencode({
    PK           = { S = "POLICY#POL-2024-000002" }
    SK           = { S = "BENEF#bnf-002" }
    entity_type  = { S = "BENEFICIARY" }
    benefId      = { S = "bnf-002" }
    policyNo     = { S = "POL-2024-000002" }
    fullName     = { S = "Yuki Nakamura" }
    relationship = { S = "SPOUSE" }
    dateOfBirth  = { S = "1981-03-14" }
    nationalId   = { S = "ID-3322110" }
    phone        = { S = "+254700000020" }
    sharePct     = { N = "100" }
    isPrimary    = { BOOL = true }
    createdAt    = { S = "2024-01-20T10:10:00Z" }
  })
}
