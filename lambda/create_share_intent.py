"""
create_share_intent.py
Lambda handler: POST /member/shares/create-intent

Called by the Flutter member portal when a member buys a membership or
preferred share.
1. Validates the amount rules for the chosen share_type.
2. Blocks preferred-share purchases for members still pending their initial
   membership share.
3. Creates a Stripe PaymentIntent.
4. Writes a PENDING record to kopera-share.
5. Returns { client_secret, share_id, apr } to Flutter.

share_webhook.py flips the record to SUCCEEDED/FAILED and, for a successful
membership share, activates a pending member.

Environment variables:
  MEMBERS_TABLE                — DynamoDB table name (kopera-member)
  SHARES_TABLE                 — DynamoDB table name (kopera-share)
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
_SHARES_TABLE  = os.environ.get("SHARES_TABLE", "kopera-share")
_dynamodb = boto3.resource("dynamodb")
_ssm = boto3.client("ssm")

# Local dev sets STRIPE_SECRET_KEY directly (sandbox sk_test_...) to skip SSM
# entirely — deployed Lambdas leave this unset and always fetch from SSM.
_SSM_PARAM = os.environ.get("STRIPE_SECRET_KEY_SSM_PARAM", "/kafa/stripe/secret_key_live")
stripe.api_key = os.environ.get("STRIPE_SECRET_KEY") or \
    _ssm.get_parameter(Name=_SSM_PARAM, WithDecryption=True)["Parameter"]["Value"]

MEMBERSHIP_MIN_CENTS  = 2_500   # $25 — minimum partial payment toward the $50 target
MEMBERSHIP_TARGET_CENTS = 5_000 # $50 — total needed to activate
PREFERRED_MIN_CENTS   = 50_000  # $500

PENDING_REASON = "Did not pay membership share"


def _cors(status: int, body: dict) -> dict:
    return {
        "statusCode": status,
        "headers": {
            "Content-Type":                "application/json",
            "Access-Control-Allow-Origin": "*",
        },
        "body": json.dumps(body),
    }


def _calculate_preferred_apr(amount_cents: int) -> float:
    """
    Preferred share APR bracket table:
      $500    - $1,000   → 4%
      $1,001  - $2,000   → 5%
      $2,001  - $3,000   → 6%
      $3,001  - $5,000   → 7%
      $5,001  - $10,999  → 10%
      $11,000+           → 12%
    """
    amount_dollars = amount_cents / 100
    if amount_dollars >= 11_000:
        return 12.0
    if amount_dollars >= 5_001:
        return 10.0
    if amount_dollars >= 3_001:
        return 7.0
    if amount_dollars >= 2_001:
        return 6.0
    if amount_dollars >= 1_001:
        return 5.0
    return 4.0  # $500 - $1,000 (the $500 floor is enforced by PREFERRED_MIN_CENTS)


def lambda_handler(event, _context):
    try:
        body = json.loads(event.get("body") or "{}")
        member_id    = body["member_id"]
        company_id   = body.get("company_id", "KAFA-001")
        share_type   = body["share_type"].strip().lower()
        amount_cents = int(body["amount_cents"])
    except (KeyError, ValueError, json.JSONDecodeError) as exc:
        logger.warning("Bad request: %s", exc)
        return _cors(400, {"error": f"Missing or invalid field: {exc}"})

    if share_type not in ("membership", "preferred"):
        return _cors(400, {"error": "share_type must be 'membership' or 'preferred'"})

    members_table = _dynamodb.Table(_MEMBERS_TABLE)
    member = members_table.get_item(Key={"memberId": member_id, "companyId": company_id}).get("Item")
    if not member:
        return _cors(404, {"error": "Payment failed"})

    is_pending = member.get("status") == "Pending" and member.get("reason") == PENDING_REASON

    if share_type == "membership":
        if amount_cents < MEMBERSHIP_MIN_CENTS:
            return _cors(400, {"error": "Minimum membership share payment is $25."})
        apr = 0.0
    else:  # preferred
        if is_pending:
            return _cors(403, {"error": "Pay your initial membership share before purchasing a preferred share."})
        if amount_cents < PREFERRED_MIN_CENTS:
            return _cors(400, {"error": "Preferred shares require a $500 minimum."})
        apr = _calculate_preferred_apr(amount_cents)

    # ── 1. Create Stripe PaymentIntent ────────────────────────────────────────
    try:
        intent = stripe.PaymentIntent.create(
            amount=amount_cents,
            currency="usd",
            metadata={
                "member_id":  member_id,
                "share_type": share_type,
            },
            description=f"KAFA {share_type} share · {member_id}",
        )
    except stripe.error.StripeError as exc:
        logger.error("Stripe error: %s", exc)
        return _cors(502, {"error": "Payment provider error. Please try again."})

    # ── 2. Write PENDING record to kopera-share ───────────────────────────────
    now = datetime.now(timezone.utc).isoformat()
    share_id = f"SHARE#{now}#{uuid.uuid4().hex[:8]}"

    shares_table = _dynamodb.Table(_SHARES_TABLE)
    try:
        shares_table.put_item(Item={
            "memberID":              member_id,
            "shareId":               share_id,
            "companyId":             company_id,
            "amount":                Decimal(str(amount_cents / 100)),
            "datetime":              now,
            "share_type":            share_type,
            "APR":                   Decimal(str(apr)),
            "status":                "PENDING",
            "stripePaymentIntentId": intent.id,
        })
    except Exception as exc:
        logger.error("DynamoDB write failed: %s", exc)
        try:
            stripe.PaymentIntent.cancel(intent.id)
        except stripe.error.StripeError:
            pass
        return _cors(500, {"error": "Failed to record share purchase. Please try again."})

    logger.info("PaymentIntent %s created → share %s (%s)", intent.id, share_id, share_type)

    return _cors(200, {
        "client_secret": intent.client_secret,
        "share_id":      share_id,
        "apr":           apr,
    })
