"""
savings_webhook.py
Lambda handler: POST /member/savings/webhook

Stripe calls this after a savings deposit settles. The handler:
1. Verifies the Stripe signature (rejects spoofed requests).
2. Looks up the PENDING kopera-savings record via GSI-StripeIntent.
3. Updates the record status to SUCCEEDED or FAILED.
4. On success, sets a payment notification on the member and emails a
   receipt to KAFA admins.

Unlike share_webhook.py, there is no membership-activation side effect —
savings is a flat deposit ledger.

Environment variables:
  MEMBERS_TABLE                    — DynamoDB table name (kopera-member)
  SAVINGS_TABLE                    — DynamoDB table name (kopera-savings)
  STRIPE_SECRET_KEY_SSM_PARAM      — SSM param holding the Stripe secret key
                                      (defaults to /kafa/stripe/secret_key_live)
  SAVINGS_WEBHOOK_SECRET_SSM_PARAM — SSM param holding the webhook signing
                                      secret. In dev this points at the shared
                                      /kafa/stripe/webhook_secret_test param
                                      (same shortcut share_webhook.py's dev
                                      deployment uses) since a dedicated
                                      savings test endpoint hasn't been set up
                                      in the Stripe dashboard yet. Defaults to
                                      /kafa/stripe/savings_webhook_secret_live
                                      in prod.
"""

import json
import logging
import os
from datetime import datetime, timezone
from decimal import Decimal

import boto3
import stripe
from boto3.dynamodb.conditions import Key

_ses = boto3.client("ses", region_name="us-east-1")
_RECEIPT_EMAILS = ["kontak@kafayiti.com", "kafayiti509@gmail.com"]
_FROM_EMAIL     = "KAFA <noreply@kafayiti.com>"

logger = logging.getLogger()
logger.setLevel(logging.INFO)

_MEMBERS_TABLE = os.environ.get("MEMBERS_TABLE", "kopera-member")
_SAVINGS_TABLE = os.environ.get("SAVINGS_TABLE", "kopera-savings")
_dynamodb = boto3.resource("dynamodb")
_ssm = boto3.client("ssm")

_SECRET_KEY_PARAM = os.environ.get("STRIPE_SECRET_KEY_SSM_PARAM", "/kafa/stripe/secret_key_live")
_WEBHOOK_PARAM     = os.environ.get("SAVINGS_WEBHOOK_SECRET_SSM_PARAM", "/kafa/stripe/savings_webhook_secret_live")

# This is a separate API Gateway route/Stripe webhook endpoint from
# stripe_webhook.py and share_webhook.py, so it has its own signing secret.
# Local dev sets STRIPE_SECRET_KEY / SAVINGS_WEBHOOK_SECRET directly to skip
# SSM entirely — deployed Lambdas leave these unset and always fetch from SSM.
stripe.api_key = os.environ.get("STRIPE_SECRET_KEY") or \
    _ssm.get_parameter(Name=_SECRET_KEY_PARAM, WithDecryption=True)["Parameter"]["Value"]


def _get_webhook_secret() -> str:
    val = os.environ.get("SAVINGS_WEBHOOK_SECRET", "")
    if val and val != "whsec_local_placeholder":
        return val
    try:
        return _ssm.get_parameter(Name=_WEBHOOK_PARAM, WithDecryption=True)["Parameter"]["Value"]
    except Exception:
        return val


def _cors(status: int, body: dict) -> dict:
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def _find_deposit_by_intent(intent_id: str):
    table = _dynamodb.Table(_SAVINGS_TABLE)
    resp = table.query(
        IndexName="GSI-StripeIntent",
        KeyConditionExpression=Key("stripePaymentIntentId").eq(intent_id),
        Limit=1,
    )
    items = resp.get("Items", [])
    return items[0] if items else None


def _send_savings_receipt_email(member_id: str, company_id: str,
                                 amount_cents: int, reference: str) -> None:
    """Send a savings deposit receipt email to KAFA admin addresses."""
    try:
        amount_str = f"US${amount_cents / 100:.2f}"

        full_name, phone, member_email = member_id, "", ""
        try:
            members_table = _dynamodb.Table(_MEMBERS_TABLE)
            m = members_table.get_item(
                Key={"memberId": member_id, "companyId": company_id},
            ).get("Item", {})
            full_name    = m.get("full_name", member_id)
            phone        = m.get("phone", "")
            member_email = m.get("email", "")
        except Exception:
            pass

        now_str = datetime.now(timezone.utc).strftime("%B %d, %Y %H:%M UTC")

        html = f"""
        <div style="font-family:sans-serif;max-width:600px;margin:0 auto">
          <div style="background:#1a5c2e;padding:20px 32px">
            <h2 style="color:#fff;margin:0;font-size:18px">KAFA — Savings Deposit Receipt</h2>
          </div>
          <div style="padding:28px;background:#fff">
            <p style="color:#333">A savings deposit has been received.</p>
            <table style="border-collapse:collapse;width:100%;font-size:14px;background:#f9f9f9;border-radius:8px">
              <tr><td style="padding:6px 12px;color:#555;font-weight:bold">Member</td><td style="padding:6px 12px">{full_name} ({member_id})</td></tr>
              <tr><td style="padding:6px 12px;color:#555;font-weight:bold">Phone</td><td style="padding:6px 12px">{phone}</td></tr>
              <tr><td style="padding:6px 12px;color:#555;font-weight:bold">Amount</td><td style="padding:6px 12px;font-weight:bold;color:#1a5c2e">{amount_str}</td></tr>
              <tr><td style="padding:6px 12px;color:#555;font-weight:bold">Date</td><td style="padding:6px 12px">{now_str}</td></tr>
              <tr><td style="padding:6px 12px;color:#555;font-weight:bold">Method</td><td style="padding:6px 12px">Stripe</td></tr>
              <tr><td style="padding:6px 12px;color:#555;font-weight:bold">Reference</td><td style="padding:6px 12px">{reference}</td></tr>
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
                    "Subject": {"Data": f"KAFA Savings Deposit — {full_name} — {amount_str}"},
                    "Body":    {"Html": {"Data": html}},
                },
            )
        logger.info("Receipt emails sent for deposit %s", reference)
    except Exception as exc:
        logger.warning("Could not send savings receipt email: %s", exc)


def lambda_handler(event, _context):
    payload    = event.get("body") or ""
    sig_header = (event.get("headers") or {}).get("Stripe-Signature", "")

    try:
        stripe.Webhook.construct_event(payload, sig_header, _get_webhook_secret())
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
    intent_id  = data_obj.get("id")

    if event_type == "payment_intent.succeeded":
        status = "SUCCEEDED"
    elif event_type == "payment_intent.payment_failed":
        status = "FAILED"
    else:
        logger.info("Unhandled event type %s — skipping", event_type)
        return _cors(200, {"received": True})

    if not intent_id:
        return _cors(200, {"received": True})

    deposit = _find_deposit_by_intent(intent_id)
    if not deposit:
        logger.warning("No savings deposit found for intent %s", intent_id)
        return _cors(200, {"received": True})

    savings_table = _dynamodb.Table(_SAVINGS_TABLE)
    savings_table.update_item(
        Key={"memberID": deposit["memberID"], "depositId": deposit["depositId"]},
        UpdateExpression="SET #s = :status, paymentMethod = if_not_exists(paymentMethod, :method)",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={":status": status, ":method": "STRIPE"},
    )

    if status == "SUCCEEDED":
        company_id = deposit.get("companyId", "KAFA-001")
        try:
            members_table = _dynamodb.Table(_MEMBERS_TABLE)
            members_table.update_item(
                Key={"memberId": deposit["memberID"], "companyId": company_id},
                UpdateExpression="SET payment_notification = :n",
                ExpressionAttributeValues={
                    ":n": {
                        "amountPaid":    Decimal(str(deposit.get("amount", 0))),
                        "paymentDate":   datetime.now(timezone.utc).isoformat(),
                        "referenceNo":   deposit["depositId"],
                        "policyNo":      "Savings Deposit",
                        "paymentMethod": "STRIPE",
                        "paymentPeriod": "",
                        "currency":      "usd",
                        "seen":          False,
                    }
                },
            )
        except Exception as exc:
            logger.warning("Could not set payment_notification: %s", exc)

        _send_savings_receipt_email(
            member_id=deposit["memberID"],
            company_id=company_id,
            amount_cents=int(Decimal(str(deposit.get("amount", 0))) * 100),
            reference=deposit["depositId"],
        )

    logger.info("Deposit %s → %s", deposit["depositId"], status)
    return _cors(200, {"received": True})
