"""
stripe_webhook.py
Lambda handler: POST /payments/webhook

Stripe calls this after a payment settles. The handler:
1. Verifies the Stripe signature (rejects spoofed requests).
2. Looks up the PENDING payment record via GSI5-StripeIntent.
3. Updates the record status to SUCCEEDED, FAILED, or REFUNDED.

Environment variables:
  LIFE_INSURANCE_TABLE       — DynamoDB table name (kopera-life-insurance)
  STRIPE_SECRET_KEY_SSM_PARAM    — SSM param holding the Stripe secret key
                                    (defaults to /kafa/stripe/secret_key_live)
  WEBHOOK_SECRET_SSM_PARAM       — SSM param holding the webhook signing
                                    secret (defaults to /kafa/stripe/webhook_secret_live)
"""

import json
import logging
import os
from datetime import datetime, timedelta, timezone

import boto3
import stripe

_ses = boto3.client("ses", region_name="us-east-1")
_RECEIPT_EMAILS = ["kontak@kafayiti.com", "kafayiti509@gmail.com"]
_FROM_EMAIL     = "KAFA <noreply@kafayiti.com>"

logger = logging.getLogger()
logger.setLevel(logging.INFO)

_TABLE   = os.environ["LIFE_INSURANCE_TABLE"]
_GSI     = "GSI5-StripeIntent"
_MEMBERS_TABLE = os.environ.get("MEMBERS_TABLE", "kopera-member")
_dynamodb = boto3.client("dynamodb")
_ssm = boto3.client("ssm")

_MONTH_NAMES = [
    "", "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
]

_SECRET_KEY_PARAM = os.environ.get("STRIPE_SECRET_KEY_SSM_PARAM", "/kafa/stripe/secret_key_live")
_WEBHOOK_PARAM    = os.environ.get("WEBHOOK_SECRET_SSM_PARAM", "/kafa/stripe/webhook_secret_live")

# Local dev sets STRIPE_SECRET_KEY / STRIPE_WEBHOOK_SECRET directly to skip
# SSM entirely — deployed Lambdas leave these unset and always fetch from SSM.
stripe.api_key  = os.environ.get("STRIPE_SECRET_KEY") or \
    _ssm.get_parameter(Name=_SECRET_KEY_PARAM, WithDecryption=True)["Parameter"]["Value"]

def _get_webhook_secret() -> str:
    """Read the webhook secret at request time so .env.local updates take effect
    without restarting the server (important for local dev where stripe listen
    generates a new secret each session)."""
    val = os.environ.get("STRIPE_WEBHOOK_SECRET", "")
    if val and val != "whsec_local_placeholder":
        return val
    try:
        return _ssm.get_parameter(Name=_WEBHOOK_PARAM, WithDecryption=True)["Parameter"]["Value"]
    except Exception:
        return val

from payment_schema import payment_update_expression  # noqa: E402


def _advance_policy_after_payment(item: dict) -> None:
    """
    After a successful Stripe premium payment, advance nextDueDate on the
    policy METADATA and mark the matching SCHED record as PAID — mirroring
    what the manual-payment handler does in handler.py.
    """
    try:
        policy_id    = item.get("policyId",    {}).get("S", "")
        period_end   = item.get("periodEnd",   {}).get("S", "")
        amount_cents = int(item.get("amountCents", {}).get("N", "0"))
        payment_id   = item.get("paymentId",   {}).get("S", "")

        if not policy_id or not period_end:
            logger.warning("Missing policyId or periodEnd — skipping nextDueDate advance")
            return

        paid_date  = datetime.fromisoformat(period_end).date()
        next_due   = (paid_date.replace(day=1) + timedelta(days=32)).replace(day=1).isoformat()
        today      = datetime.now(timezone.utc).date().isoformat()
        now        = datetime.now(timezone.utc).isoformat()
        pol_pk     = f"POLICY#{policy_id}"

        # Advance nextDueDate, lastPaidDate, lastPaidAmount on METADATA.
        _dynamodb.update_item(
            TableName=_TABLE,
            Key={"PK": {"S": pol_pk}, "SK": {"S": "METADATA"}},
            UpdateExpression=(
                "SET nextDueDate = :nd, lastPaidDate = :ld, "
                "lastPaidAmount = :la, updatedAt = :u"
            ),
            ExpressionAttributeValues={
                ":nd": {"S": next_due},
                ":ld": {"S": today},
                ":la": {"N": str(amount_cents / 100)},
                ":u":  {"S": now},
            },
        )

        # Mark the matching SCHED record as PAID (best-effort).
        sched_resp = _dynamodb.query(
            TableName=_TABLE,
            KeyConditionExpression="PK = :pk AND begins_with(SK, :prefix)",
            ExpressionAttributeValues={
                ":pk":     {"S": pol_pk},
                ":prefix": {"S": "SCHED#"},
            },
        )
        pending = sorted(
            [s for s in sched_resp.get("Items", [])
             if s.get("status", {}).get("S", "") == "PENDING"],
            key=lambda s: s.get("dueDate", {}).get("S", ""),
        )
        amount_str = str(amount_cents / 100)
        if pending:
            sched = pending[0]
            _dynamodb.update_item(
                TableName=_TABLE,
                Key={"PK": {"S": pol_pk}, "SK": sched["SK"]},
                UpdateExpression=(
                    "SET #s = :paid, paidDate = :ld, paidAmount = :la, "
                    "paymentMethod = :method, referenceNo = :ref"
                ),
                ExpressionAttributeNames={"#s": "status"},
                ExpressionAttributeValues={
                    ":paid":   {"S": "PAID"},
                    ":ld":     {"S": today},
                    ":la":     {"N": amount_str},
                    ":method": {"S": "STRIPE"},
                    ":ref":    {"S": payment_id},
                },
            )
        else:
            # No pending SCHED# slot (e.g. subsequent Stripe payments) — create one
            # so this payment appears in the member's premium payment history.
            all_scheds = sched_resp.get("Items", [])
            next_no = len(all_scheds) + 1
            _dynamodb.put_item(
                TableName=_TABLE,
                Item={
                    "PK":            {"S": pol_pk},
                    "SK":            {"S": f"SCHED#{period_end}#{next_no:06d}"},
                    "entity_type":   {"S": "SCHEDULE"},
                    "policyNo":      {"S": policy_id},
                    "installmentNo": {"N": str(next_no)},
                    "dueDate":       {"S": period_end},
                    "amountDue":     {"N": amount_str},
                    "status":        {"S": "PAID"},
                    "paidDate":      {"S": today},
                    "paidAmount":    {"N": amount_str},
                    "paymentMethod": {"S": "STRIPE"},
                    "referenceNo":   {"S": payment_id},
                },
            )

        logger.info("Policy %s nextDueDate advanced to %s", policy_id, next_due)
    except Exception as exc:
        logger.warning("Could not advance policy nextDueDate for %s: %s", policy_id, exc)


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


def _notify_member_payment(item: dict) -> None:
    """
    Surfaces a "payment received" notification on the member's dashboard.
    Best-effort — never let a notification failure affect the webhook's
    200 response, since Stripe will otherwise retry indefinitely.
    """
    try:
        member_id  = item.get("memberId", {}).get("S", "")
        policy_id  = item.get("policyId", {}).get("S", "")
        payment_id = item.get("paymentId", {}).get("S", "")
        amount_cents = int(item.get("amountCents", {}).get("N", "0"))
        period_start = item.get("periodStart", {}).get("S", "")
        if not member_id:
            return

        period_label = ""
        try:
            year, month, _ = period_start.split("-")
            period_label = f"{_MONTH_NAMES[int(month)]} {year}"
        except (ValueError, IndexError):
            pass

        _dynamodb.update_item(
            TableName=_MEMBERS_TABLE,
            Key={"memberId": {"S": member_id}, "companyId": {"S": "KAFA-001"}},
            UpdateExpression="SET payment_notification = :n",
            ExpressionAttributeValues={
                ":n": {"M": {
                    "amountPaid":    {"N": str(amount_cents / 100)},
                    "paymentDate":   {"S": datetime.now(timezone.utc).date().isoformat()},
                    "referenceNo":   {"S": payment_id},
                    "policyNo":      {"S": policy_id},
                    "paymentMethod": {"S": "STRIPE"},
                    "paymentPeriod": {"S": period_label},
                    "currency":      {"S": "usd"},
                    "seen":          {"BOOL": False},
                }}
            },
        )
    except Exception as exc:
        logger.warning("Could not set payment_notification: %s", exc)


def _send_receipt_email(item: dict, receipt_url: str = "") -> None:
    """Send a payment receipt email to KAFA admin addresses."""
    try:
        member_id    = item.get("memberId",    {}).get("S", "")
        policy_id    = item.get("policyId",    {}).get("S", "")
        payment_id   = item.get("paymentId",   {}).get("S", "")
        amount_cents = int(item.get("amountCents", {}).get("N", "0"))
        period_start = item.get("periodStart", {}).get("S", "")
        amount_str   = f"US${amount_cents / 100:.2f}"

        # Try to get member name/phone/email from DynamoDB
        full_name, phone, member_email = "", "", ""
        try:
            resp = _dynamodb.get_item(
                TableName=_MEMBERS_TABLE,
                Key={"memberId": {"S": member_id}, "companyId": {"S": "KAFA-001"}},
                ProjectionExpression="full_name, phone, email",
            )
            m = resp.get("Item", {})
            full_name    = m.get("full_name", {}).get("S", member_id)
            phone        = m.get("phone",     {}).get("S", "")
            member_email = m.get("email",     {}).get("S", "")
        except Exception:
            full_name = member_id

        period_label = period_start[:10] if period_start else ""
        receipt_row  = f'<tr><td style="padding:6px 12px;color:#555;font-weight:bold">Stripe Receipt</td><td style="padding:6px 12px"><a href="{receipt_url}" style="color:#1a5c2a">{receipt_url}</a></td></tr>' if receipt_url else ""

        html = f"""
        <div style="font-family:sans-serif;max-width:600px;margin:0 auto">
          <div style="background:#1a5c2e;padding:20px 32px">
            <h2 style="color:#fff;margin:0;font-size:18px">KAFA — Payment Receipt</h2>
          </div>
          <div style="padding:28px;background:#fff">
            <p style="color:#333">A premium payment has been received.</p>
            <table style="border-collapse:collapse;width:100%;font-size:14px;background:#f9f9f9;border-radius:8px">
              <tr><td style="padding:6px 12px;color:#555;font-weight:bold">Member</td><td style="padding:6px 12px">{full_name} ({member_id})</td></tr>
              <tr><td style="padding:6px 12px;color:#555;font-weight:bold">Phone</td><td style="padding:6px 12px">{phone}</td></tr>
              <tr><td style="padding:6px 12px;color:#555;font-weight:bold">Amount</td><td style="padding:6px 12px;font-weight:bold;color:#1a5c2e">{amount_str}</td></tr>
              <tr><td style="padding:6px 12px;color:#555;font-weight:bold">Policy</td><td style="padding:6px 12px">{policy_id}</td></tr>
              <tr><td style="padding:6px 12px;color:#555;font-weight:bold">Period</td><td style="padding:6px 12px">{period_label}</td></tr>
              <tr><td style="padding:6px 12px;color:#555;font-weight:bold">Method</td><td style="padding:6px 12px">Stripe</td></tr>
              <tr><td style="padding:6px 12px;color:#555;font-weight:bold">Reference</td><td style="padding:6px 12px">{payment_id}</td></tr>
              {receipt_row}
            </table>
          </div>
          <div style="background:#f0f0f0;padding:14px 32px;text-align:center;font-size:12px;color:#888">
            KAFA — 874 Rue Ste Catherine, Léogâne, Haïti
          </div>
        </div>"""

        recipients = _RECEIPT_EMAILS + ([member_email] if member_email else [])
        for email in recipients:
            _ses.send_email(
                Source=_FROM_EMAIL,
                Destination={"ToAddresses": [email]},
                Message={
                    "Subject": {"Data": f"KAFA Payment Received — {full_name} — {amount_str}"},
                    "Body":    {"Html": {"Data": html}},
                },
            )
        logger.info("Receipt emails sent for payment %s", payment_id)
    except Exception as exc:
        logger.warning("Could not send receipt email: %s", exc)


def lambda_handler(event, _context):
    # ── 1. Verify Stripe signature ────────────────────────────────────────────
    payload   = event.get("body", "")
    sig_header = (event.get("headers") or {}).get("Stripe-Signature", "")

    try:
        stripe_event = stripe.Webhook.construct_event(
            payload, sig_header, _get_webhook_secret()
        )
    except stripe.error.SignatureVerificationError:
        logger.warning("Invalid Stripe signature — request rejected")
        return _cors(400, {"error": "Invalid signature"})
    except Exception as exc:
        logger.error("Webhook parse error: %s", exc)
        return _cors(400, {"error": "Bad request"})

    # Parse raw payload as plain dict — newer Stripe SDK returns StripeObject
    # which doesn't support .get(), so we use the already-verified JSON instead.
    event_dict = json.loads(payload)
    event_type = event_dict["type"]
    data_obj   = event_dict["data"]["object"]
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
                receipt_url = charge.receipt_url or ""
            except Exception:
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

    if status == "SUCCEEDED":
        _notify_member_payment(item)
        _advance_policy_after_payment(item)
        _send_receipt_email(item, receipt_url=receipt_url)

    logger.info("Payment %s → %s", pk, status)
    return _cors(200, {"received": True})
