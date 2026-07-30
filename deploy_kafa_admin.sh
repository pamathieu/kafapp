#!/usr/bin/env bash
set -euo pipefail

# ── Stripe & API config ───────────────────────────────────────────────────────
# Pass these as env vars before running, e.g.:
#   STRIPE_KEY=pk_live_... ./deploy_kafa_admin.sh
# Or hardcode the test key here for dev deployments.
STRIPE_KEY="${STRIPE_KEY:-pk_test_REPLACE_ME}"
API_BASE_URL="${API_BASE_URL:-https://8ajfrnzdag.execute-api.us-east-1.amazonaws.com/prod}"
# Set ENV=dev to deploy to devadmin/devmember (uses -dev API routes + dev DynamoDB tables).
# Set ENV=prod (default) to deploy to admin/member production portals.
ENV="${ENV:-prod}"

cd ~/development/Projects/kafapp

if [ "$ENV" = "dev" ]; then
  # ── Dev admin portal (devadmin.kafayiti.com) ────────────────────────────────
  flutter build web --release \
    --dart-define=PORTAL=admin \
    --dart-define=API_ENV_SUFFIX=-dev \
    --dart-define=STRIPE_KEY="$STRIPE_KEY" \
    --dart-define=API_BASE_URL="$API_BASE_URL" \
    --dart-define=MEMBER_PORTAL_URL=https://devmember.kafayiti.com

  aws s3 sync build/web/ s3://kafa-admin-dev-kafayiti/ --delete
  aws cloudfront create-invalidation --distribution-id EI737MOF3BJLT --paths "/*"

  # ── Dev member portal (devmember.kafayiti.com) ──────────────────────────────
  flutter build web --release \
    --dart-define=PORTAL=member \
    --dart-define=API_ENV_SUFFIX=-dev \
    --dart-define=PAYMENT_ENDPOINT_SUFFIX=-dev \
    --dart-define=STRIPE_KEY="pk_test_51TjRYjF9EQQP3sE5lRggX57wMoAGgh1M4sigfkQsejYb8Warl72OCvEuzupkcUoJgsd07JKrsxdmc6YxBojntPgt00fSNJpn9f" \
    --dart-define=API_BASE_URL="$API_BASE_URL"

  aws s3 sync build/web/ s3://kafa-member-dev-kafayiti/ --delete
  aws cloudfront create-invalidation --distribution-id E2PB17EWH850GN --paths "/*"

else
  # ── Prod admin portal (admin.kafayiti.com) ──────────────────────────────────
  flutter build web --release \
    --dart-define=PORTAL=admin \
    --dart-define=STRIPE_KEY="$STRIPE_KEY" \
    --dart-define=API_BASE_URL="$API_BASE_URL"

  aws s3 sync build/web/ s3://kafa-admin-kafayiti/ --delete
  aws cloudfront create-invalidation --distribution-id E26L9YGGOBRFGL --paths "/*"

  # ── Prod member portal (member.kafayiti.com) ────────────────────────────────
  flutter build web --release \
    --dart-define=PORTAL=member \
    --dart-define=STRIPE_KEY="$STRIPE_KEY" \
    --dart-define=API_BASE_URL="$API_BASE_URL"

  aws s3 sync build/web/ s3://kafa-member-kafayiti/ --delete
  aws cloudfront create-invalidation --distribution-id E2T4JNQCAOZFKZ --paths "/*"
fi

echo "✓ Deploy complete"

cd ~/development/Projects/kafapp/lambda

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
