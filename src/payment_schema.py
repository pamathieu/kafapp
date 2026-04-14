"""
KAFA Payment Schema
-------------------
Defines the DynamoDB record structure for Stripe payments
in the kopera-life-insurance table (single-table design).

Access patterns supported:
  - Get all payments for a member       → Query PK=MEMBER#<id>, SK begins_with PAYMENT#
  - Get all payments for a policy       → Query GSI1: PK=POLICY#<id>, SK begins_with PAYMENT#
  - Get payment by Stripe intent ID     → Query GSI2: stripe_payment_intent_id
  - Get payments by status              → Query GSI3: status (e.g. all FAILED for follow-up)
"""

from datetime import datetime, timezone
import uuid


# ──────────────────────────────────────────────
# Table name (match your Terraform resource)
# ──────────────────────────────────────────────
TABLE_NAME = "kopera-life-insurance"


# ──────────────────────────────────────────────
# Payment status values
# ──────────────────────────────────────────────
class PaymentStatus:
    PENDING   = "PENDING"     # PaymentIntent created, not yet confirmed
    SUCCEEDED = "SUCCEEDED"   # Stripe confirmed payment
    FAILED    = "FAILED"      # Stripe reported failure
    REFUNDED  = "REFUNDED"    # Issued refund


# ──────────────────────────────────────────────
# Payment method types
# ──────────────────────────────────────────────
class PaymentMethod:
    CARD    = "card"
    ACH     = "us_bank_account"
    MONCASH = "moncash"   # future MonCash integration


# ──────────────────────────────────────────────
# Record builder
# ──────────────────────────────────────────────
def build_payment_record(
    member_id: str,
    policy_id: str,
    amount_cents: int,          # Always store in cents (e.g. $25.00 → 2500)
    currency: str,              # "usd" or "htg"
    stripe_payment_intent_id: str,
    period_start: str,          # ISO date "2026-04-01"
    period_end: str,            # ISO date "2026-04-30"
    payment_method: str = PaymentMethod.CARD,
    status: str = PaymentStatus.PENDING,
) -> dict:
    """
    Returns a DynamoDB item dict ready for put_item().

    Key schema:
      PK  = MEMBER#<member_id>
      SK  = PAYMENT#<iso_timestamp>#<short_uuid>

    GSIs:
      GSI1: POLICY#<policy_id>  /  PAYMENT#<iso_timestamp>   (payments per policy)
      GSI2: stripe_payment_intent_id                          (lookup by Stripe ID)
      GSI3: status              /  created_at                 (filter by status)
    """
    now = datetime.now(timezone.utc).isoformat()
    payment_id = f"PAY-{uuid.uuid4().hex[:8].upper()}"
    sk = f"PAYMENT#{now}#{payment_id}"

    return {
        # ── Primary Key ──────────────────────────────
        "PK":           f"MEMBER#{member_id}",
        "SK":           sk,

        # ── GSI Keys ─────────────────────────────────
        "GSI1PK":       f"POLICY#{policy_id}",
        "GSI1SK":       sk,
        "GSI2PK":       stripe_payment_intent_id,   # direct lookup by Stripe ID
        "GSI3PK":       status,
        "GSI3SK":       now,

        # ── Entity type (for single-table filtering) ──
        "entity_type":  "PAYMENT",

        # ── Business data ─────────────────────────────
        "payment_id":                  payment_id,
        "member_id":                   member_id,
        "policy_id":                   policy_id,
        "amount_cents":                amount_cents,
        "currency":                    currency,
        "status":                      status,
        "payment_method":              payment_method,
        "stripe_payment_intent_id":    stripe_payment_intent_id,
        "stripe_charge_id":            None,        # filled on webhook success
        "stripe_receipt_url":          None,        # filled on webhook success
        "failure_message":             None,        # filled on webhook failure

        # ── Coverage period this payment covers ───────
        "period_start":  period_start,
        "period_end":    period_end,

        # ── Timestamps ────────────────────────────────
        "created_at":   now,
        "updated_at":   now,
    }


def payment_status_update(
    status: str,
    stripe_charge_id: str = None,
    stripe_receipt_url: str = None,
    failure_message: str = None,
) -> dict:
    """
    Returns an update expression dict for updating payment status on webhook events.
    Use with update_item() UpdateExpression.
    """
    now = datetime.now(timezone.utc).isoformat()
    expr_parts = [
        "SET #status = :status",
        "updated_at = :updated_at",
        "GSI3PK = :status",         # keep GSI3 in sync with new status
    ]
    values = {
        ":status":     status,
        ":updated_at": now,
    }

    if stripe_charge_id:
        expr_parts.append("stripe_charge_id = :charge_id")
        values[":charge_id"] = stripe_charge_id

    if stripe_receipt_url:
        expr_parts.append("stripe_receipt_url = :receipt")
        values[":receipt"] = stripe_receipt_url

    if failure_message:
        expr_parts.append("failure_message = :fail_msg")
        values[":fail_msg"] = failure_message

    return {
        "UpdateExpression": ", ".join(expr_parts),
        "ExpressionAttributeNames": {"#status": "status"},
        "ExpressionAttributeValues": values,
    }