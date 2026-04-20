"""
stripe_webhook.py
Lambda handler: POST /payments/webhook

Stripe calls this after a payment settles. The handler:
1. Verifies the Stripe signature (rejects spoofed requests).
2. Looks up the PENDING payment record via GSI5-StripeIntent.
3. Updates the record status to SUCCEEDED, FAILED, or REFUNDED.

Environment variables:
  LIFE_INSURANCE_TABLE  — DynamoDB table name (kopera-life-insurance)
  STRIPE_SECRET_KEY     — Stripe secret key  (sk_test_... / sk_live_...)
  KAFA_WEBHOOK_SECRET   — Stripe webhook signing secret (whsec_...)
"""

import json
import logging
import os

import boto3
import stripe

logger = logging.getLogger()
logger.setLevel(logging.INFO)

_TABLE   = os.environ["LIFE_INSURANCE_TABLE"]
_GSI     = "GSI5-StripeIntent"
_dynamodb = boto3.client("dynamodb")

stripe.api_key          = os.environ["STRIPE_SECRET_KEY"]
_WEBHOOK_SECRET         = os.environ["KAFA_WEBHOOK_SECRET"]

from payment_schema import payment_update_expression  # noqa: E402


def _cors(status: int, body: dict) -> dict:
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def _find_payment_by_intent_id(intent_id: str) -> dict | None:
    """Query GSI5-StripeIntent to find the payment record."""
    resp = _dynamodb.query(
        TableName=_TABLE,
        IndexName=_GSI,
        KeyConditionExpression="GSI5PK = :id",
        ExpressionAttributeValues={":id": {"S": intent_id}},
        Limit=1,
    )
    items = resp.get("Items", [])
    return items[0] if items else None


def _update_payment(pk: str, status: str, charge_id: str = "", receipt_url: str = "") -> None:
    """Update the payment record's status in the base table."""
    kwargs = payment_update_expression(status, charge_id=charge_id, receipt_url=receipt_url)
    _dynamodb.update_item(
        TableName=_TABLE,
        Key={
            "PK": {"S": pk},
            "SK": {"S": "METADATA"},
        },
        **kwargs,
    )


def lambda_handler(event, _context):
    # ── 1. Verify Stripe signature ────────────────────────────────────────────
    payload   = event.get("body", "")
    sig_header = (event.get("headers") or {}).get("Stripe-Signature", "")

    try:
        stripe_event = stripe.Webhook.construct_event(
            payload, sig_header, _WEBHOOK_SECRET
        )
    except stripe.error.SignatureVerificationError:
        logger.warning("Invalid Stripe signature — request rejected")
        return _cors(400, {"error": "Invalid signature"})
    except Exception as exc:
        logger.error("Webhook parse error: %s", exc)
        return _cors(400, {"error": "Bad request"})

    event_type = stripe_event["type"]
    data_obj   = stripe_event["data"]["object"]
    intent_id  = data_obj.get("id") or data_obj.get("payment_intent")

    logger.info("Received %s for intent %s", event_type, intent_id)

    # ── 2. Map event type → status ────────────────────────────────────────────
    if event_type == "payment_intent.succeeded":
        status      = "SUCCEEDED"
        charge_id   = data_obj.get("latest_charge", "")
        receipt_url = ""
        # Fetch charge receipt URL if available
        if charge_id:
            try:
                charge = stripe.Charge.retrieve(charge_id)
                receipt_url = charge.get("receipt_url", "")
            except stripe.error.StripeError:
                pass

    elif event_type == "payment_intent.payment_failed":
        status      = "FAILED"
        charge_id   = ""
        receipt_url = ""
        intent_id   = data_obj.get("id")

    elif event_type == "charge.refunded":
        status      = "REFUNDED"
        charge_id   = data_obj.get("id", "")
        receipt_url = data_obj.get("receipt_url", "")
        intent_id   = data_obj.get("payment_intent", "")

    else:
        # Unhandled event type — acknowledge and ignore
        logger.info("Unhandled event type %s — skipping", event_type)
        return _cors(200, {"received": True})

    if not intent_id:
        logger.warning("No intent_id found in event — skipping")
        return _cors(200, {"received": True})

    # ── 3. Find and update the payment record ─────────────────────────────────
    item = _find_payment_by_intent_id(intent_id)
    if not item:
        logger.warning("No payment record found for intent %s", intent_id)
        # Return 200 so Stripe doesn't retry — record may have been cleaned up.
        return _cors(200, {"received": True})

    pk = item["PK"]["S"]
    _update_payment(pk, status, charge_id=charge_id, receipt_url=receipt_url)

    logger.info("Payment %s → %s", pk, status)
    return _cors(200, {"received": True})
