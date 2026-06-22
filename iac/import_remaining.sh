#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

echo "=== Importing Lambda functions ==="
terraform import aws_lambda_function.certificate_handler certplatform-prod-certificate-handler
terraform import aws_lambda_function.certificate_retrieval certplatform-prod-certificate-retrieval
terraform import aws_lambda_function.create_payment_intent certplatform-prod-create-payment-intent
terraform import aws_lambda_function.stripe_webhook certplatform-prod-stripe-webhook
terraform import aws_lambda_function.get_policy certplatform-prod-get-policy

echo "=== Importing CloudFront OACs ==="
terraform import aws_cloudfront_origin_access_control.member_management E1GU563T3PJ7BX
terraform import aws_cloudfront_origin_access_control.member_portal ECHLAJ9GRDAN

echo "=== Importing Route53 cert validation records ==="
ZONE=Z08783972HMD46AFLX6D4
terraform import 'aws_route53_record.member_management_cert_validation["admin.kafayiti.com"]' \
  "${ZONE}__239538c809f3502e99d0df1ad5f65ff6.admin.kafayiti.com._CNAME"
terraform import 'aws_route53_record.member_portal_cert_validation["member.kafayiti.com"]' \
  "${ZONE}__3c1fc322d281c5514f8aa751ecd63f36.member.kafayiti.com._CNAME"

echo "=== Importing DynamoDB seed items ==="
terraform import aws_dynamodb_table_item.product_life_basic \
  'kopera-life-insurance|{"PK":{"S":"PRODUCT#LIFE-BASIC"},"SK":{"S":"METADATA"}}'
terraform import aws_dynamodb_table_item.product_life_plus \
  'kopera-life-insurance|{"PK":{"S":"PRODUCT#LIFE-PLUS"},"SK":{"S":"METADATA"}}'
terraform import aws_dynamodb_table_item.plan_basic_monthly \
  'kopera-life-insurance|{"PK":{"S":"PRODUCT#LIFE-BASIC"},"SK":{"S":"PLAN#MONTHLY"}}'
terraform import aws_dynamodb_table_item.plan_plus_monthly \
  'kopera-life-insurance|{"PK":{"S":"PRODUCT#LIFE-PLUS"},"SK":{"S":"PLAN#MONTHLY"}}'

echo "=== All imports complete — running apply ==="
terraform apply -auto-approve
