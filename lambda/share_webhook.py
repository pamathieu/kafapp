"""
share_webhook.py
Lambda handler: POST /member/shares/webhook

Stripe calls this after a share purchase settles. The handler:
1. Verifies the Stripe signature (rejects spoofed requests).
2. Looks up the PENDING kopera-share record via GSI-StripeIntent.
3. Updates the record status to SUCCEEDED or FAILED.
4. On a successful MEMBERSHIP share, activates a pending member
   (status=True, clears reason) — preferred shares never affect status.

Environment variables:
  MEMBERS_TABLE                — DynamoDB table name (kopera-member)
  SHARES_TABLE                 — DynamoDB table name (kopera-share)
  STRIPE_SECRET_KEY_SSM_PARAM  — SSM param holding the Stripe secret key
                                  (defaults to /kafa/stripe/secret_key_live)
  WEBHOOK_SECRET_SSM_PARAM     — SSM param holding the webhook signing secret
                                  (defaults to /kafa/stripe/webhook_secret_live)
"""

import json
import logging
import os
import uuid
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
_SHARES_TABLE  = os.environ.get("SHARES_TABLE", "kopera-share")
_dynamodb = boto3.resource("dynamodb")
_ssm = boto3.client("ssm")

_SECRET_KEY_PARAM = os.environ.get("STRIPE_SECRET_KEY_SSM_PARAM", "/kafa/stripe/secret_key_live")
_WEBHOOK_PARAM    = os.environ.get("SHARE_WEBHOOK_SECRET_SSM_PARAM", "/kafa/stripe/share_webhook_secret_live")

# This is a separate API Gateway route/Stripe webhook endpoint from
# stripe_webhook.py, so it has its own signing secret — SHARE_WEBHOOK_SECRET,
# not STRIPE_WEBHOOK_SECRET (which belongs to the premium-payment webhook).
# Local dev sets STRIPE_SECRET_KEY / SHARE_WEBHOOK_SECRET directly to skip SSM
# entirely — deployed Lambdas leave these unset and always fetch from SSM.
stripe.api_key  = os.environ.get("STRIPE_SECRET_KEY") or \
    _ssm.get_parameter(Name=_SECRET_KEY_PARAM, WithDecryption=True)["Parameter"]["Value"]

def _get_webhook_secret() -> str:
    val = os.environ.get("SHARE_WEBHOOK_SECRET", "")
    if val and val != "whsec_local_placeholder":
        return val
    try:
        return _ssm.get_parameter(Name=_WEBHOOK_PARAM, WithDecryption=True)["Parameter"]["Value"]
    except Exception:
        return val

PENDING_REASON = "Did not pay membership share"


def _calculate_preferred_apr(amount_cents: int) -> float:
    amount_dollars = amount_cents / 100
    if amount_dollars >= 11_000: return 12.0
    if amount_dollars >= 5_001:  return 10.0
    if amount_dollars >= 3_001:  return 7.0
    if amount_dollars >= 2_001:  return 6.0
    if amount_dollars >= 1_001:  return 5.0
    return 4.0


def _cors(status: int, body: dict) -> dict:
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def _find_share_by_intent(intent_id: str):
    table = _dynamodb.Table(_SHARES_TABLE)
    resp = table.query(
        IndexName="GSI-StripeIntent",
        KeyConditionExpression=Key("stripePaymentIntentId").eq(intent_id),
        Limit=1,
    )
    items = resp.get("Items", [])
    return items[0] if items else None


def _handle_checkout_completed(session: dict) -> None:
    """Create a SUCCEEDED share record when a Checkout Session payment settles."""
    if session.get("payment_status") != "paid":
        logger.info("Checkout session %s not paid yet (%s) — skipping",
                    session.get("id"), session.get("payment_status"))
        return

    meta         = session.get("metadata") or {}
    member_id    = meta.get("member_id", "")
    company_id   = meta.get("company_id", "KAFA-001")
    share_type   = meta.get("share_type", "")
    amount_cents = int(meta.get("amount_cents", "0"))
    session_id   = session.get("id", "")

    if not (member_id and share_type and amount_cents):
        logger.warning("checkout.session.completed missing metadata on %s", session_id)
        return

    now      = datetime.now(timezone.utc).isoformat()
    share_id = f"SHARE#{session_id}"
    apr      = _calculate_preferred_apr(amount_cents) if share_type == "preferred" else 0.0

    shares_table  = _dynamodb.Table(_SHARES_TABLE)
    members_table = _dynamodb.Table(_MEMBERS_TABLE)

    shares_table.put_item(Item={
        "memberID":                member_id,
        "shareId":                 share_id,
        "companyId":               company_id,
        "amount":                  Decimal(str(amount_cents / 100)),
        "datetime":                now,
        "share_type":              share_type,
        "APR":                     Decimal(str(apr)),
        "status":                  "SUCCEEDED",
        "stripeCheckoutSessionId": session_id,
        "stripePaymentIntentId":   session.get("payment_intent", ""),
    })
    logger.info("Share %s created (SUCCEEDED) via checkout session %s", share_id, session_id)

    if share_type == "membership":
        member = members_table.get_item(
            Key={"memberId": member_id, "companyId": company_id}
        ).get("Item")
        if member and member.get("status") == "Pending":
            MEMBERSHIP_TARGET_CENTS = 5_000  # $50
            prev_paid = Decimal(str(member.get("membershipSharesPaid") or 0))
            new_total = prev_paid + Decimal(str(amount_cents / 100))
            total_paid_cents = int(new_total * 100)
            if total_paid_cents >= MEMBERSHIP_TARGET_CENTS:
                members_table.update_item(
                    Key={"memberId": member_id, "companyId": company_id},
                    UpdateExpression="SET #s = :active REMOVE #r, membershipSharesPaid",
                    ExpressionAttributeNames={"#s": "status", "#r": "reason"},
                    ExpressionAttributeValues={":active": "Active"},
                )
                logger.info("Member %s activated after checkout membership share", member_id)
            else:
                members_table.update_item(
                    Key={"memberId": member_id, "companyId": company_id},
                    UpdateExpression="SET membershipSharesPaid = :paid",
                    ExpressionAttributeValues={":paid": new_total},
                )
                logger.info("Member %s partial checkout membership: %d/%d cents",
                            member_id, total_paid_cents, MEMBERSHIP_TARGET_CENTS)

    try:
        members_table.update_item(
            Key={"memberId": member_id, "companyId": company_id},
            UpdateExpression="SET payment_notification = :n",
            ExpressionAttributeValues={
                ":n": {
                    "amountPaid":    Decimal(str(amount_cents / 100)),
                    "paymentDate":   datetime.now(timezone.utc).isoformat(),
                    "referenceNo":   share_id,
                    "policyNo":      f"{share_type.capitalize()} Share",
                    "paymentMethod": "STRIPE",
                    "paymentPeriod": "",
                    "currency":      "usd",
                    "seen":          False,
                }
            },
        )
    except Exception as exc:
        logger.warning("Could not set payment_notification for %s: %s", member_id, exc)

    _send_share_receipt_email(
        member_id=member_id,
        company_id=company_id,
        share_type=share_type,
        amount_cents=amount_cents,
        reference=share_id,
    )


def _send_share_receipt_email(member_id: str, company_id: str, share_type: str,
                               amount_cents: int, reference: str) -> None:
    """Send a share payment receipt email to KAFA admin addresses."""
    try:
        amount_str  = f"US${amount_cents / 100:.2f}"
        type_label  = f"{share_type.capitalize()} Share"

        full_name, phone, member_email = "", "", ""
        try:
            members_table = _dynamodb.Table(_MEMBERS_TABLE)
            m = members_table.get_item(
                Key={"memberId": member_id, "companyId": company_id},
            ).get("Item", {})
            full_name    = m.get("full_name", member_id)
            phone        = m.get("phone", "")
            member_email = m.get("email", "")
        except Exception:
            full_name = member_id

        now_str = datetime.now(timezone.utc).strftime("%B %d, %Y %H:%M UTC")

        html = f"""
        <div style="font-family:sans-serif;max-width:600px;margin:0 auto">
          <div style="background:#1a5c2e;padding:20px 32px">
            <h2 style="color:#fff;margin:0;font-size:18px">KAFA — Share Payment Receipt</h2>
          </div>
          <div style="padding:28px;background:#fff">
            <p style="color:#333">A share payment has been received.</p>
            <table style="border-collapse:collapse;width:100%;font-size:14px;background:#f9f9f9;border-radius:8px">
              <tr><td style="padding:6px 12px;color:#555;font-weight:bold">Member</td><td style="padding:6px 12px">{full_name} ({member_id})</td></tr>
              <tr><td style="padding:6px 12px;color:#555;font-weight:bold">Phone</td><td style="padding:6px 12px">{phone}</td></tr>
              <tr><td style="padding:6px 12px;color:#555;font-weight:bold">Amount</td><td style="padding:6px 12px;font-weight:bold;color:#1a5c2e">{amount_str}</td></tr>
              <tr><td style="padding:6px 12px;color:#555;font-weight:bold">Payment Type</td><td style="padding:6px 12px">{type_label}</td></tr>
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
                    "Subject": {"Data": f"KAFA Share Payment — {full_name} — {amount_str} ({type_label})"},
                    "Body":    {"Html": {"Data": html}},
                },
            )
        logger.info("Receipt emails sent for share %s", reference)
    except Exception as exc:
        logger.warning("Could not send share receipt email: %s", exc)


def lambda_handler(event, _context):
    payload    = event.get("body") or ""
    sig_header = (event.get("headers") or {}).get("Stripe-Signature", "")

    try:
        stripe_event = stripe.Webhook.construct_event(payload, sig_header, _get_webhook_secret())
    except stripe.error.SignatureVerificationError:
        logger.warning("Invalid Stripe signature — request rejected")
        return _cors(400, {"error": "Invalid signature"})
    except Exception as exc:
        logger.error("Webhook parse error: %s", exc)
        return _cors(400, {"error": "Bad request"})

    event_type = stripe_event["type"]
    data_obj   = stripe_event["data"]["object"]
    intent_id  = data_obj.get("id")

    if event_type == "checkout.session.completed":
        _handle_checkout_completed(data_obj)
        return _cors(200, {"received": True})

    if event_type == "payment_intent.succeeded":
        status = "SUCCEEDED"
    elif event_type == "payment_intent.payment_failed":
        status = "FAILED"
    else:
        logger.info("Unhandled event type %s — skipping", event_type)
        return _cors(200, {"received": True})

    if not intent_id:
        return _cors(200, {"received": True})

    share = _find_share_by_intent(intent_id)
    if not share:
        logger.warning("No share record found for intent %s", intent_id)
        return _cors(200, {"received": True})

    shares_table = _dynamodb.Table(_SHARES_TABLE)
    shares_table.update_item(
        Key={"memberID": share["memberID"], "shareId": share["shareId"]},
        UpdateExpression="SET #s = :status",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={":status": status},
    )

    # Activate a pending member once their total membership shares reach $50.
    if status == "SUCCEEDED" and share.get("share_type") == "membership":
        MEMBERSHIP_TARGET_CENTS = 5_000  # $50
        members_table = _dynamodb.Table(_MEMBERS_TABLE)
        company_id = share.get("companyId", "KAFA-001")
        member = members_table.get_item(
            Key={"memberId": share["memberID"], "companyId": company_id}
        ).get("Item")
        if member and member.get("status") == "Pending":
            prev_paid = Decimal(str(member.get("membershipSharesPaid") or 0))
            new_total = prev_paid + Decimal(str(share.get("amount", 0)))
            total_paid_cents = int(new_total * 100)
            if total_paid_cents >= MEMBERSHIP_TARGET_CENTS:
                members_table.update_item(
                    Key={"memberId": share["memberID"], "companyId": company_id},
                    UpdateExpression="SET #s = :active REMOVE #r, membershipSharesPaid",
                    ExpressionAttributeNames={"#s": "status", "#r": "reason"},
                    ExpressionAttributeValues={":active": "Active"},
                )
                logger.info("Member %s activated after membership share payment", share["memberID"])
            else:
                members_table.update_item(
                    Key={"memberId": share["memberID"], "companyId": company_id},
                    UpdateExpression="SET membershipSharesPaid = :paid",
                    ExpressionAttributeValues={":paid": new_total},
                )
                logger.info("Member %s partial membership: %d/%d cents",
                            share["memberID"], total_paid_cents, MEMBERSHIP_TARGET_CENTS)

    if status == "SUCCEEDED":
        try:
            members_table = _dynamodb.Table(_MEMBERS_TABLE)
            company_id = share.get("companyId", "KAFA-001")
            members_table.update_item(
                Key={"memberId": share["memberID"], "companyId": company_id},
                UpdateExpression="SET payment_notification = :n",
                ExpressionAttributeValues={
                    ":n": {
                        "amountPaid":    Decimal(str(share.get("amount", 0))),
                        "paymentDate":   datetime.now(timezone.utc).isoformat(),
                        "referenceNo":   share["shareId"],
                        "policyNo":      f"{share.get('share_type', '').capitalize()} Share",
                        "paymentMethod": "STRIPE",
                        "paymentPeriod": "",
                        "currency":      "usd",
                        "seen":          False,
                    }
                },
            )
        except Exception as exc:
            logger.warning("Could not set payment_notification: %s", exc)

        _send_share_receipt_email(
            member_id=share["memberID"],
            company_id=share.get("companyId", "KAFA-001"),
            share_type=share.get("share_type", ""),
            amount_cents=int(Decimal(str(share.get("amount", 0))) * 100),
            reference=share["shareId"],
        )

    logger.info("Share %s → %s", share["shareId"], status)
    return _cors(200, {"received": True})
