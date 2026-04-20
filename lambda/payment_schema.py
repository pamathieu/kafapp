"""
payment_schema.py
DynamoDB record helpers for KAFA Stripe payment records.

Table:  kopera-life-insurance  (env: LIFE_INSURANCE_TABLE)
PK:     PAYMENT#<payment_id>
SK:     METADATA

GSI5-StripeIntent:  GSI5PK = stripe_payment_intent_id
                    Used by stripe_webhook.py to find the record on callback.
"""

import uuid
from datetime import datetime, timezone


def build_payment_record(
    *,
    member_id: str,
    policy_id: str,
    amount_cents: int,
    currency: str,
    period_start: str,
    period_end: str,
    stripe_payment_intent_id: str,
) -> dict:
    """
    Returns a DynamoDB item dict ready for put_item().
    Status starts as PENDING — stripe_webhook.py updates it to SUCCEEDED or FAILED.
    """
    payment_id = f"PAY-{uuid.uuid4().hex[:12].upper()}"
    now = datetime.now(timezone.utc).isoformat()

    return {
        # ── Keys ─────────────────────────────────────────────────────────────
        "PK":     {"S": f"PAYMENT#{payment_id}"},
        "SK":     {"S": "METADATA"},

        # ── GSI1 — payments by policy (used by get_policy Lambda) ─────────
        "GSI1PK": {"S": f"POLICY#{policy_id}"},
        "GSI1SK": {"S": f"PAYMENT#{now}"},

        # ── GSI5 — Stripe intent lookup (used by webhook) ─────────────────
        "GSI5PK": {"S": stripe_payment_intent_id},

        # ── Payment data ──────────────────────────────────────────────────
        # camelCase keys used internally; snake_case aliases for get_policy.py
        "paymentId":               {"S": payment_id},
        "payment_id":              {"S": payment_id},
        "memberId":                {"S": member_id},
        "policyId":                {"S": policy_id},
        "amountCents":             {"N": str(amount_cents)},
        "amount_cents":            {"N": str(amount_cents)},
        "currency":                {"S": currency},
        "periodStart":             {"S": period_start},
        "period_start":            {"S": period_start},
        "periodEnd":               {"S": period_end},
        "period_end":              {"S": period_end},
        "stripePaymentIntentId":   {"S": stripe_payment_intent_id},
        "status":                  {"S": "PENDING"},
        "createdAt":               {"S": now},
        "created_at":              {"S": now},
        "updatedAt":               {"S": now},
    }


def payment_update_expression(status: str, *, charge_id: str = "", receipt_url: str = "") -> dict:
    """
    Returns kwargs for update_item() to flip status after webhook fires.
    status: "SUCCEEDED" | "FAILED" | "REFUNDED"
    """
    now = datetime.now(timezone.utc).isoformat()

    expr = "SET #s = :status, updatedAt = :now"
    names = {"#s": "status"}
    values = {
        ":status": {"S": status},
        ":now":    {"S": now},
    }

    if charge_id:
        expr += ", stripeChargeId = :charge"
        values[":charge"] = {"S": charge_id}
    if receipt_url:
        expr += ", receiptUrl = :receipt"
        values[":receipt"] = {"S": receipt_url}

    return {
        "UpdateExpression":          expr,
        "ExpressionAttributeNames":  names,
        "ExpressionAttributeValues": values,
    }
