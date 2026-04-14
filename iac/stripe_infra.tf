# ──────────────────────────────────────────────────────────────────────────────
# KAFA Stripe Infrastructure — Terraform snippets
# Add these to your existing main.tf / lambda.tf / dynamodb.tf
# ──────────────────────────────────────────────────────────────────────────────


# ── 1. Secrets Manager — Stripe keys (never hardcode in env vars) ─────────────
resource "aws_secretsmanager_secret" "stripe" {
  name = "kafa/stripe"
}

resource "aws_secretsmanager_secret_version" "stripe" {
  secret_id = aws_secretsmanager_secret.stripe.id
  secret_string = jsonencode({
    secret_key     = var.stripe_secret_key      # sk_live_...
    webhook_secret = var.stripe_webhook_secret  # whsec_...
  })
}

# ── 2. Lambda: create_payment_intent ─────────────────────────────────────────
resource "aws_lambda_function" "create_payment_intent" {
  function_name = "kafa-create-payment-intent"
  handler       = "create_payment_intent.handler"
  runtime       = "python3.12"
  role          = aws_iam_role.lambda_exec.arn
  filename      = data.archive_file.lambda_zip.output_path

  environment {
    variables = {
      DYNAMODB_TABLE                = aws_dynamodb_table.life_insurance.name
      STRIPE_SECRET_KEY             = var.stripe_secret_key        # or fetch from Secrets Manager at runtime
      PAYMENT_NOTIFICATION_TOPIC_ARN = aws_sns_topic.payment_events.arn
    }
  }
}

# ── 3. Lambda: stripe_webhook ─────────────────────────────────────────────────
resource "aws_lambda_function" "stripe_webhook" {
  function_name = "kafa-stripe-webhook"
  handler       = "stripe_webhook.handler"
  runtime       = "python3.12"
  role          = aws_iam_role.lambda_exec.arn
  filename      = data.archive_file.lambda_zip.output_path

  environment {
    variables = {
      DYNAMODB_TABLE                = aws_dynamodb_table.life_insurance.name
      STRIPE_SECRET_KEY             = var.stripe_secret_key
      KAFA_WEBHOOK_SECRET           = var.stripe_webhook_secret
      PAYMENT_NOTIFICATION_TOPIC_ARN = aws_sns_topic.payment_events.arn
    }
  }
}

# ── 4. API Gateway routes ─────────────────────────────────────────────────────
# POST /payments/create-intent  → create_payment_intent Lambda
# POST /payments/webhook        → stripe_webhook Lambda
#
# IMPORTANT: /payments/webhook must use AWS_PROXY integration with
# "Use Lambda Proxy integration" checked, and Content-Type must NOT
# be transformed — Stripe verifies signatures against the raw body.

# ── 5. DynamoDB GSI additions (add to your existing table resource) ───────────
# Add these global_secondary_index blocks inside your
# aws_dynamodb_table "life_insurance" resource:

# GSI2 — lookup payment by Stripe PaymentIntent ID
# global_secondary_index {
#   name            = "GSI2"
#   hash_key        = "GSI2PK"
#   projection_type = "ALL"
#   read_capacity   = 5
#   write_capacity  = 5
# }

# GSI3 — filter payments by status
# global_secondary_index {
#   name            = "GSI3"
#   hash_key        = "GSI3PK"
#   range_key       = "GSI3SK"
#   projection_type = "ALL"
#   read_capacity   = 5
#   write_capacity  = 5
# }

# ── 6. SNS topic for payment events (consumed by notification Lambda) ─────────
resource "aws_sns_topic" "payment_events" {
  name = "kafa-payment-events"
}

# ── 7. Variables ──────────────────────────────────────────────────────────────
variable "stripe_secret_key" {
  description = "Stripe secret key (sk_live_... or sk_test_...)"
  type        = string
  sensitive   = true
}

variable "stripe_webhook_secret" {
  description = "Stripe webhook signing secret (whsec_...)"
  type        = string
  sensitive   = true
}
