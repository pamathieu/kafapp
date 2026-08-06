#!/usr/bin/env bash
set -euo pipefail

# ── Stripe & API config ───────────────────────────────────────────────────────
# Pass these as env vars before running, e.g.:
#   STRIPE_KEY=pk_live_... ./deploy_kafa_admin.sh
# Or hardcode the test key here for dev deployments.
STRIPE_KEY="${STRIPE_KEY:-pk_test_51TjRYjF9EQQP3sE5lRggX57wMoAGgh1M4sigfkQsejYb8Warl72OCvEuzupkcUoJgsd07JKrsxdmc6YxBojntPgt00fSNJpn9f}"
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
    --dart-define=PAYMENT_ENDPOINT_SUFFIX=-dev \
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

cd ~/development/Projects/kafapp

# Deploy create-payment-intent Lambda (requires stripe)
PAYMENT_PKG=/tmp/payment_intent_package
rm -rf "$PAYMENT_PKG" && mkdir -p "$PAYMENT_PKG"
pip install stripe \
  --platform manylinux2014_x86_64 \
  --python-version 312 \
  --implementation cp \
  --only-binary=:all: \
  -t "$PAYMENT_PKG" \
  --quiet 2>/dev/null
cp lambda/create_payment_intent.py lambda/payment_schema.py "$PAYMENT_PKG/"
cd "$PAYMENT_PKG"
zip -r /tmp/payment_intent.zip . -x "*.pyc" -x "__pycache__/*" -x "*.dist-info/*" > /dev/null
aws lambda update-function-code \
  --function-name certplatform-prod-create-payment-intent \
  --zip-file fileb:///tmp/payment_intent.zip \
  --output text --query 'LastModified'

# Deploy list-member-payments Lambda (admin: GET /admin/payments?memberId=)
zip list_payments.zip list_member_payments.py
aws lambda update-function-code \
  --function-name certplatform-prod-list-member-payments \
  --zip-file fileb://list_payments.zip 2>/dev/null || \
  echo "⚠  list-member-payments Lambda not yet created — see setup instructions"

# Deploy certificate handler Lambda (POST /certificates + /certificates-dev)
# Requires reportlab, pymupdf, requests — bundled as a platform-specific wheel package.
cd ~/development/Projects/kafapp
CERT_PKG=/tmp/cert_lambda_package
rm -rf "$CERT_PKG" && mkdir -p "$CERT_PKG"
pip install reportlab pymupdf requests \
  --platform manylinux2014_x86_64 \
  --python-version 312 \
  --implementation cp \
  --only-binary=:all: \
  -t "$CERT_PKG" \
  --quiet 2>/dev/null
cp handler.py certificate_engine.py "$CERT_PKG/"
cd "$CERT_PKG"
zip -r /tmp/cert_handler.zip . -x "*.pyc" -x "__pycache__/*" -x "*.dist-info/*" > /dev/null
aws lambda update-function-code --function-name certplatform-dev-certificate-handler  --zip-file fileb:///tmp/cert_handler.zip --output text --query 'LastModified'
aws lambda update-function-code --function-name certplatform-prod-certificate-handler --zip-file fileb:///tmp/cert_handler.zip --output text --query 'LastModified'

# Deploy share checkout + webhook Lambdas (require stripe package)
SHARE_PKG=/tmp/share_checkout_package
rm -rf "$SHARE_PKG" && mkdir -p "$SHARE_PKG"
pip install stripe \
  --platform manylinux2014_x86_64 \
  --python-version 312 \
  --implementation cp \
  --only-binary=:all: \
  -t "$SHARE_PKG" \
  --quiet 2>/dev/null
cp ~/development/Projects/kafapp/lambda/create_share_checkout.py "$SHARE_PKG/"
cp ~/development/Projects/kafapp/lambda/share_webhook.py "$SHARE_PKG/"
cd "$SHARE_PKG"
zip -r /tmp/share_checkout.zip . -x "*.pyc" -x "__pycache__/*" -x "*.dist-info/*" > /dev/null
aws lambda update-function-code --function-name certplatform-dev-create-share-checkout  --zip-file fileb:///tmp/share_checkout.zip --output text --query 'LastModified'
aws lambda update-function-code --function-name certplatform-prod-create-share-checkout --zip-file fileb:///tmp/share_checkout.zip --output text --query 'LastModified'
aws lambda update-function-code --function-name certplatform-dev-share-webhook           --zip-file fileb:///tmp/share_checkout.zip --output text --query 'LastModified'
aws lambda update-function-code --function-name certplatform-prod-share-webhook          --zip-file fileb:///tmp/share_checkout.zip --output text --query 'LastModified'

# Deploy create-share-intent Lambda (inline Stripe card flow — requires stripe package)
SHARE_INTENT_PKG=/tmp/share_intent_package
rm -rf "$SHARE_INTENT_PKG" && mkdir -p "$SHARE_INTENT_PKG"
pip install stripe \
  --platform manylinux2014_x86_64 \
  --python-version 312 \
  --implementation cp \
  --only-binary=:all: \
  -t "$SHARE_INTENT_PKG" \
  --quiet 2>/dev/null
cp ~/development/Projects/kafapp/lambda/create_share_intent.py "$SHARE_INTENT_PKG/"
cd "$SHARE_INTENT_PKG"
zip -r /tmp/share_intent.zip . -x "*.pyc" -x "__pycache__/*" -x "*.dist-info/*" > /dev/null
aws lambda update-function-code --function-name certplatform-dev-create-share-intent  --zip-file fileb:///tmp/share_intent.zip --output text --query 'LastModified'
aws lambda update-function-code --function-name certplatform-prod-create-share-intent --zip-file fileb:///tmp/share_intent.zip --output text --query 'LastModified'

# Deploy stripe-webhook Lambda (premium payments — requires stripe + payment_schema)
STRIPE_WH_PKG=/tmp/stripe_webhook_package
rm -rf "$STRIPE_WH_PKG" && mkdir -p "$STRIPE_WH_PKG"
pip install stripe \
  --platform manylinux2014_x86_64 \
  --python-version 312 \
  --implementation cp \
  --only-binary=:all: \
  -t "$STRIPE_WH_PKG" \
  --quiet 2>/dev/null
cp ~/development/Projects/kafapp/lambda/stripe_webhook.py \
   ~/development/Projects/kafapp/lambda/payment_schema.py "$STRIPE_WH_PKG/"
cd "$STRIPE_WH_PKG"
zip -r /tmp/stripe_webhook.zip . -x "*.pyc" -x "__pycache__/*" -x "*.dist-info/*" > /dev/null
aws lambda update-function-code --function-name certplatform-dev-stripe-webhook  --zip-file fileb:///tmp/stripe_webhook.zip --output text --query 'LastModified'
aws lambda update-function-code --function-name certplatform-prod-stripe-webhook --zip-file fileb:///tmp/stripe_webhook.zip --output text --query 'LastModified'

cd ~/development/Projects/kafapp/lambda
