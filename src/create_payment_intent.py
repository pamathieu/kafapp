"""
Lambda: create_payment_intent.py
----------------------------------
Called by the Flutter member portal when a member initiates a premium payment.

Flow:
  1. Member taps "Pay Premium" in Flutter
  2. Flutter calls POST /payments/create-intent  (API Gateway → this Lambda)
  3. Lambda creates a Stripe PaymentIntent + stores a PENDING record in DynamoDB
  4. Lambda returns { client_secret } to Flutter
  5. Flutter uses Stripe SDK to confirm payment with the client_secret
  6. Stripe fires a webhook → stripe_webhook.py handles the result

Environment variables required (set in Terraform):
  STRIPE_SECRET_KEY       - sk_live_... or sk_test_...
  DYNAMODB_TABLE          - kopera-life-insurance
  KAFA_WEBHOOK_SECRET     - whsec_... (Stripe webhook signing secret)
"""

import json
import os
import boto3
import stripe
from payment_schema import build_payment_record, PaymentMethod, TABLE_NAME

# ── Clients (initialized outside handler for Lambda reuse) ────────────────────
stripe.api_key = os.environ["STRIPE_SECRET_KEY"]
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ.get("DYNAMODB_TABLE", TABLE_NAME))


def handler(event, context):
    """
    POST /payments/create-intent
    Expected body:
    {
        "member_id":    "M-001",
        "policy_id":    "POL-2024-001",
        "amount_cents": 2500,           // $25.00
        "currency":     "usd",
        "period_start": "2026-04-01",
        "period_end":   "2026-04-30",
        "payment_method_type": "card"   // or "us_bank_account"
    }
    """
    try:
        body = json.loads(event.get("body", "{}"))
        member_id           = body["member_id"]
        policy_id           = body["policy_id"]
        amount_cents        = int(body["amount_cents"])
        currency            = body.get("currency", "usd")
        period_start        = body["period_start"]
        period_end          = body["period_end"]
        payment_method_type = body.get("payment_method_type", "card")
    except (KeyError, ValueError) as e:
        return _response(400, {"error": f"Missing or invalid field: {e}"})

    # ── Validate amount (min $1, max $10,000) ─────────────────────────────────
    if not (100 <= amount_cents <= 1_000_000):
        return _response(400, {"error": "amount_cents must be between 100 and 1000000"})

    try:
        # ── Create Stripe PaymentIntent ───────────────────────────────────────
        intent = stripe.PaymentIntent.create(
            amount=amount_cents,
            currency=currency,
            payment_method_types=[payment_method_type],
            metadata={
                "member_id":   member_id,
                "policy_id":   policy_id,
                "period_start": period_start,
                "period_end":  period_end,
                "platform":    "kafa",
            },
            description=f"KAFA Premium | Policy {policy_id} | {period_start} – {period_end}",
        )

        # ── Store PENDING payment record in DynamoDB ──────────────────────────
        record = build_payment_record(
            member_id=member_id,
            policy_id=policy_id,
            amount_cents=amount_cents,
            currency=currency,
            stripe_payment_intent_id=intent["id"],
            period_start=period_start,
            period_end=period_end,
            payment_method=payment_method_type,
        )
        table.put_item(Item=record)

        # ── Return client_secret to Flutter ───────────────────────────────────
        return _response(200, {
            "client_secret":           intent["client_secret"],
            "payment_intent_id":       intent["id"],
            "payment_id":              record["payment_id"],
            "amount_cents":            amount_cents,
            "currency":                currency,
        })

    except stripe.error.StripeError as e:
        print(f"[Stripe Error] {e}")
        return _response(502, {"error": "Payment service error. Please try again."})

    except Exception as e:
        print(f"[Internal Error] {e}")
        return _response(500, {"error": "Internal server error."})


# ── Helper ────────────────────────────────────────────────────────────────────
def _response(status_code: int, body: dict) -> dict:
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
        },
        "body": json.dumps(body),
    }