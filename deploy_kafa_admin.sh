#!/usr/bin/env bash
set -euo pipefail

# ── Stripe & API config ───────────────────────────────────────────────────────
# Pass these as env vars before running, e.g.:
#   STRIPE_KEY=pk_live_... ./deploy_kafa_admin.sh
# Or hardcode the test key here for dev deployments.
STRIPE_KEY="${STRIPE_KEY:-pk_test_REPLACE_ME}"
API_BASE_URL="${API_BASE_URL:-https://8ajfrnzdag.execute-api.us-east-1.amazonaws.com/prod}"

cd ~/Projects/member_management

# ── Admin portal ──────────────────────────────────────────────────────────────
flutter build web --release \
  --dart-define=PORTAL=admin \
  --dart-define=STRIPE_KEY="$STRIPE_KEY" \
  --dart-define=API_BASE_URL="$API_BASE_URL"

aws s3 sync build/web/ s3://kafa-admin-kafayiti/ --delete
aws cloudfront create-invalidation --distribution-id E26L9YGGOBRFGL --paths "/*"

# ── Member portal ─────────────────────────────────────────────────────────────
flutter build web --release \
  --dart-define=PORTAL=member \
  --dart-define=STRIPE_KEY="$STRIPE_KEY" \
  --dart-define=API_BASE_URL="$API_BASE_URL"

aws s3 sync build/web/ s3://kafa-member-kafayiti/ --delete
aws cloudfront create-invalidation \
  --distribution-id $(aws cloudfront list-distributions \
    --query "DistributionList.Items[?Comment=='KAFA Member Portal Flutter Web App'].Id" \
    --output text) \
  --paths "/*"

echo "✓ Deploy complete"

cd ~/Projects/member_management/lambda

# Deploy create-payment-intent Lambda
zip payment.zip create_payment_intent.py payment_schema.py
aws s3 cp payment.zip s3://kopera-asset/lambda/payment.zip
aws lambda update-function-code \
  --function-name certplatform-prod-create-payment-intent \
  --zip-file fileb://payment.zip

# Deploy list-member-payments Lambda (admin: GET /admin/payments?memberId=)
zip list_payments.zip list_member_payments.py
aws lambda update-function-code \
  --function-name certplatform-prod-list-member-payments \
  --zip-file fileb://list_payments.zip 2>/dev/null || \
  echo "⚠  list-member-payments Lambda not yet created — see setup instructions"
