#!/bin/bash
# update_company_and_regenerate.sh
# 1. Upload kafa_logo.png to kopera-asset
# 2. Update kopera-company with registration_number and path_to_logo
# 3. Regenerate all 52 certificates with --force

set -e

REGION="us-east-1"
ASSET_BUCKET="kopera-asset"
LOGO_KEY="assets/kafa_logo.png"
LOGO_S3_PATH="s3://${ASSET_BUCKET}/${LOGO_KEY}"
COMPANY_TABLE="kopera-company"
COMPANY_ID="KAFA-001"
REGISTRATION_NUMBER="Z-00-CSAN/02-2026-005-9"

echo "============================================================"
echo "  KAFA — Company Update & Certificate Regeneration"
echo "============================================================"

# ── Step 1: Upload logo to kopera-asset ──────────────────────────────────────
echo ""
echo "[1/3] Uploading logo to ${LOGO_S3_PATH}..."
aws s3 cp kafa_logo.png "s3://${ASSET_BUCKET}/${LOGO_KEY}" \
  --content-type "image/png" \
  --region "${REGION}"
echo "      ✅ Logo uploaded"

# ── Step 2: Update kopera-company record ─────────────────────────────────────
echo ""
echo "[2/3] Updating kopera-company record for ${COMPANY_ID}..."
aws dynamodb update-item \
  --table-name "${COMPANY_TABLE}" \
  --region "${REGION}" \
  --key '{"companyId": {"S": "KAFA-001"}}' \
  --update-expression "SET registration_number = :r, path_to_logo = :l" \
  --expression-attribute-values "{
    \":r\": {\"S\": \"${REGISTRATION_NUMBER}\"},
    \":l\": {\"S\": \"${LOGO_S3_PATH}\"}
  }"
echo "      ✅ Company updated"
echo "         registration_number : ${REGISTRATION_NUMBER}"
echo "         path_to_logo        : ${LOGO_S3_PATH}"

# ── Step 3: Verify the update ─────────────────────────────────────────────────
echo ""
echo "      Verifying company record..."
aws dynamodb get-item \
  --table-name "${COMPANY_TABLE}" \
  --region "${REGION}" \
  --key '{"companyId": {"S": "KAFA-001"}}' \
  --query 'Item.{reg: registration_number.S, logo: path_to_logo.S}' \
  --output table

# ── Step 4: Regenerate all certificates ──────────────────────────────────────
echo ""
echo "[3/3] Regenerating all certificates with updated logo and registration number..."
echo "      (This will overwrite all existing certificates)"
echo ""
python generate_certificates.py --force

echo ""
echo "============================================================"
echo "  All done! Certificates regenerated with:"
echo "  • KAFA logo in top-left corner"
echo "  • Registration number: ${REGISTRATION_NUMBER}"
echo "============================================================"
