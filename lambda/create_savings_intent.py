"""
create_savings_intent.py
Lambda handler: POST /member/savings/create-intent

Called by the Flutter member portal when a member deposits into their Kafa
Savings account.
1. Validates the minimum deposit amount.
2. Creates a Stripe PaymentIntent.
3. Writes a PENDING record to kopera-savings.
4. Returns { client_secret, deposit_id } to Flutter.

savings_webhook.py flips the record to SUCCEEDED/FAILED.

Environment variables:
  MEMBERS_TABLE                — DynamoDB table name (kopera-member)
  SAVINGS_TABLE                — DynamoDB table name (kopera-savings)
  STRIPE_SECRET_KEY_SSM_PARAM  — SSM parameter name holding the Stripe secret
                                  key (defaults to /kafa/stripe/secret_key_live)
"""

import json
import logging
import os
import uuid
from datetime import datetime, timezone
from decimal import Decimal

import boto3
import stripe

logger = logging.getLogger()
logger.setLevel(logging.INFO)

_MEMBERS_TABLE = os.environ.get("MEMBERS_TABLE", "kopera-member")
_SAVINGS_TABLE = os.environ.get("SAVINGS_TABLE", "kopera-savings")
_dynamodb = boto3.resource("dynamodb")
_ssm = boto3.client("ssm")

# Local dev sets STRIPE_SECRET_KEY directly (sandbox sk_test_...) to skip SSM
# entirely — deployed Lambdas leave this unset and always fetch from SSM.
_SSM_PARAM = os.environ.get("STRIPE_SECRET_KEY_SSM_PARAM", "/kafa/stripe/secret_key_live")
stripe.api_key = os.environ.get("STRIPE_SECRET_KEY") or \
    _ssm.get_parameter(Name=_SSM_PARAM, WithDecryption=True)["Parameter"]["Value"]

SAVINGS_MIN_CENTS = 100  # $1 minimum per deposit


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
        member_id    = body["member_id"]
        company_id   = body.get("company_id", "KAFA-001")
        amount_cents = int(body["amount_cents"])
    except (KeyError, ValueError, json.JSONDecodeError) as exc:
        logger.warning("Bad request: %s", exc)
        return _cors(400, {"error": f"Missing or invalid field: {exc}"})

    if amount_cents < SAVINGS_MIN_CENTS:
        return _cors(400, {"error": "Minimum deposit is $1."})

    members_table = _dynamodb.Table(_MEMBERS_TABLE)
    member = members_table.get_item(Key={"memberId": member_id, "companyId": company_id}).get("Item")
    if not member:
        return _cors(404, {"error": "Deposit failed"})

    # ── 1. Create Stripe PaymentIntent ────────────────────────────────────────
    try:
        intent = stripe.PaymentIntent.create(
            amount=amount_cents,
            currency="usd",
            metadata={
                "member_id": member_id,
                "purpose":   "savings",
            },
            description=f"KAFA savings deposit · {member_id}",
        )
    except stripe.error.StripeError as exc:
        logger.error("Stripe error: %s", exc)
        return _cors(502, {"error": "Payment provider error. Please try again."})

    # ── 2. Write PENDING record to kopera-savings ─────────────────────────────
    now = datetime.now(timezone.utc).isoformat()
    deposit_id = f"DEPOSIT#{now}#{uuid.uuid4().hex[:8]}"

    savings_table = _dynamodb.Table(_SAVINGS_TABLE)
    try:
        savings_table.put_item(Item={
            "memberID":              member_id,
            "depositId":             deposit_id,
            "companyId":             company_id,
            "amount":                Decimal(str(amount_cents / 100)),
            "datetime":              now,
            "status":                "PENDING",
            "paymentMethod":         "STRIPE",
            "stripePaymentIntentId": intent.id,
            "recordedBy":            "member",
        })
    except Exception as exc:
        logger.error("DynamoDB write failed: %s", exc)
        try:
            stripe.PaymentIntent.cancel(intent.id)
        except stripe.error.StripeError:
            pass
        return _cors(500, {"error": "Failed to record deposit. Please try again."})

    logger.info("PaymentIntent %s created → deposit %s", intent.id, deposit_id)

    return _cors(200, {
        "client_secret": intent.client_secret,
        "deposit_id":    deposit_id,
    })
