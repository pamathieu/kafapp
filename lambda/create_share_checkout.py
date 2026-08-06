"""
create_share_checkout.py
Lambda handler: POST /member/shares/checkout-session

Called by the admin portal to generate a Stripe Checkout Session URL for a
membership or preferred share payment. The admin shares the URL with the member;
the member completes payment on their own device using their own card.

Unlike create_share_intent.py (which embeds card fields in the admin portal),
this flow does NOT require the admin to enter card credentials. The share record
is written by share_webhook.py when checkout.session.completed fires.

Environment variables:
  MEMBERS_TABLE                — DynamoDB table name (kopera-member)
  STRIPE_SECRET_KEY_SSM_PARAM  — SSM parameter name holding the Stripe secret
                                  key (defaults to /kafa/stripe/secret_key_live)
  MEMBER_PORTAL_URL            — Base URL for success/cancel redirects
                                  (defaults to https://member.kafayiti.com)
"""

import json
import logging
import os

import boto3
import stripe

logger = logging.getLogger()
logger.setLevel(logging.INFO)

_MEMBERS_TABLE = os.environ.get("MEMBERS_TABLE", "kopera-member")
_SHARES_TABLE  = os.environ.get("SHARES_TABLE", "kopera-share")
_dynamodb = boto3.resource("dynamodb")
_ssm = boto3.client("ssm")

_SSM_PARAM = os.environ.get("STRIPE_SECRET_KEY_SSM_PARAM", "/kafa/stripe/secret_key_live")
stripe.api_key = os.environ.get("STRIPE_SECRET_KEY") or \
    _ssm.get_parameter(Name=_SSM_PARAM, WithDecryption=True)["Parameter"]["Value"]

MEMBER_PORTAL_URL    = os.environ.get("MEMBER_PORTAL_URL", "https://member.kafayiti.com")
MEMBERSHIP_MIN_CENTS = 5_000
PREFERRED_MIN_CENTS  = 50_000
PENDING_REASON        = "Did not pay membership share"


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
        body         = json.loads(event.get("body") or "{}")
        member_id    = body["member_id"]
        company_id   = body.get("company_id", "KAFA-001")
        share_type   = body["share_type"].strip().lower()
        amount_cents = int(body["amount_cents"])
    except (KeyError, ValueError, json.JSONDecodeError) as exc:
        return _cors(400, {"error": f"Missing or invalid field: {exc}"})

    if share_type not in ("membership", "preferred"):
        return _cors(400, {"error": "share_type must be 'membership' or 'preferred'"})

    members_table = _dynamodb.Table(_MEMBERS_TABLE)
    member = members_table.get_item(
        Key={"memberId": member_id, "companyId": company_id}
    ).get("Item")
    if not member:
        return _cors(404, {"error": "Payment failed"})

    if share_type == "membership":
        if amount_cents < MEMBERSHIP_MIN_CENTS:
            return _cors(400, {"error": "Membership shares require a $50 minimum."})
    else:
        is_pending = member.get("status") == "Pending" and member.get("reason") == PENDING_REASON
        if is_pending:
            return _cors(403, {"error": "Pay your initial membership share before purchasing a preferred share."})
        if amount_cents < PREFERRED_MIN_CENTS:
            return _cors(400, {"error": "Preferred shares require a $500 minimum."})

    success_url = f"{MEMBER_PORTAL_URL}?payment=success"
    cancel_url  = f"{MEMBER_PORTAL_URL}?payment=cancelled"

    try:
        session = stripe.checkout.Session.create(
            mode="payment",
            line_items=[{
                "price_data": {
                    "currency":     "usd",
                    "unit_amount":  amount_cents,
                    "product_data": {"name": f"KAFA {share_type.capitalize()} Share"},
                },
                "quantity": 1,
            }],
            payment_intent_data={
                "metadata": {
                    "member_id":  member_id,
                    "company_id": company_id,
                    "share_type": share_type,
                },
            },
            metadata={
                "member_id":   member_id,
                "company_id":  company_id,
                "share_type":  share_type,
                "amount_cents": str(amount_cents),
            },
            success_url=success_url,
            cancel_url=cancel_url,
        )
    except stripe.error.StripeError as exc:
        logger.error("Stripe checkout session error: %s", exc)
        return _cors(502, {"error": "Payment provider error. Please try again."})

    logger.info("Checkout session %s created for member %s (%s %s cents)",
                session.id, member_id, share_type, amount_cents)

    return _cors(200, {"checkout_url": session.url, "session_id": session.id})
