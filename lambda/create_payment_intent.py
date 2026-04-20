"""
create_payment_intent.py
Lambda handler: POST /payments/create-intent

Called by Flutter PaymentService when a member taps "Pay Premium".
1. Creates a Stripe PaymentIntent.
2. Writes a PENDING payment record to kopera-life-insurance.
3. Returns { client_secret, payment_id } to Flutter.

Flutter uses the client_secret with the Stripe SDK to collect and confirm
card details client-side — raw card data never touches this function.

Environment variables:
  LIFE_INSURANCE_TABLE  — DynamoDB table name (kopera-life-insurance)
  STRIPE_SECRET_KEY     — Stripe secret key (sk_test_... / sk_live_...)
"""

import json
import logging
import os

import boto3
import stripe

logger = logging.getLogger()
logger.setLevel(logging.INFO)

_TABLE = os.environ["LIFE_INSURANCE_TABLE"]
_dynamodb = boto3.client("dynamodb")

stripe.api_key = os.environ["STRIPE_SECRET_KEY"]

# Import after stripe.api_key is set so the module initialises cleanly.
from payment_schema import build_payment_record  # noqa: E402


def _cors(status: int, body: dict) -> dict:
    return {
        "statusCode": status,
        "headers": {
            "Content-Type":                "application/json",
            "Access-Control-Allow-Origin": "*",
        },
        "body": json.dumps(body),
    }


def lambda_handler(event, _context):
    try:
        body = json.loads(event.get("body") or "{}")

        member_id   = body["member_id"]
        policy_id   = body["policy_id"]
        amount_cents = int(body["amount_cents"])
        currency    = body.get("currency", "usd")
        period_start = body["period_start"]
        period_end   = body["period_end"]

    except (KeyError, ValueError, json.JSONDecodeError) as exc:
        logger.warning("Bad request: %s", exc)
        return _cors(400, {"error": f"Missing or invalid field: {exc}"})

    # ── 1. Create Stripe PaymentIntent ────────────────────────────────────────
    try:
        intent = stripe.PaymentIntent.create(
            amount=amount_cents,
            currency=currency,
            metadata={
                "member_id":   member_id,
                "policy_id":   policy_id,
                "period_start": period_start,
                "period_end":   period_end,
            },
            description=f"KAFA premium · {policy_id} · {period_start}/{period_end}",
        )
    except stripe.error.StripeError as exc:
        logger.error("Stripe error: %s", exc)
        return _cors(502, {"error": "Payment provider error. Please try again."})

    # ── 2. Write PENDING record to DynamoDB ───────────────────────────────────
    record = build_payment_record(
        member_id=member_id,
        policy_id=policy_id,
        amount_cents=amount_cents,
        currency=currency,
        period_start=period_start,
        period_end=period_end,
        stripe_payment_intent_id=intent.id,
    )

    try:
        _dynamodb.put_item(TableName=_TABLE, Item=record)
    except Exception as exc:
        logger.error("DynamoDB write failed: %s", exc)
        # Payment intent was created — cancel it so Stripe doesn't hold funds.
        try:
            stripe.PaymentIntent.cancel(intent.id)
        except stripe.error.StripeError:
            pass
        return _cors(500, {"error": "Failed to record payment. Please try again."})

    payment_id = record["paymentId"]["S"]
    logger.info("PaymentIntent %s created → payment_id %s", intent.id, payment_id)

    return _cors(200, {
        "client_secret": intent.client_secret,
        "payment_id":    payment_id,
    })
