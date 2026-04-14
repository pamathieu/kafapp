"""
Lambda: stripe_webhook.py
--------------------------
Handles incoming Stripe webhook events and updates DynamoDB payment records.

Registered events in Stripe Dashboard:
  - payment_intent.succeeded       → mark SUCCEEDED, store receipt
  - payment_intent.payment_failed  → mark FAILED, store failure reason
  - charge.refunded                → mark REFUNDED

Security:
  - All events verified against STRIPE_WEBHOOK_SECRET (whsec_...)
  - Idempotent: re-delivery of the same event is safe (status won't regress)

API Gateway setup:
  - POST /payments/webhook
  - Pass raw body (do NOT transform) — Stripe signature depends on raw bytes
"""

import json
import os
import boto3
import stripe
from boto3.dynamodb.conditions import Attr
from payment_schema import PaymentStatus, payment_status_update, TABLE_NAME

# ── Clients ───────────────────────────────────────────────────────────────────
stripe.api_key = os.environ["STRIPE_SECRET_KEY"]
WEBHOOK_SECRET = os.environ["KAFA_WEBHOOK_SECRET"]

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ.get("DYNAMODB_TABLE", TABLE_NAME))


def handler(event, context):
    """
    Stripe sends POST requests with a Stripe-Signature header.
    We verify, then dispatch to the appropriate handler.
    """
    payload   = event.get("body", "")
    sig_header = event.get("headers", {}).get("Stripe-Signature", "")

    # ── Verify webhook signature ──────────────────────────────────────────────
    try:
        stripe_event = stripe.Webhook.construct_event(
            payload, sig_header, WEBHOOK_SECRET
        )
    except stripe.error.SignatureVerificationError:
        print("[Webhook] Invalid signature — rejecting")
        return _response(400, {"error": "Invalid signature"})
    except Exception as e:
        print(f"[Webhook] Parse error: {e}")
        return _response(400, {"error": "Bad request"})

    event_type = stripe_event["type"]
    data_obj   = stripe_event["data"]["object"]

    print(f"[Webhook] Received: {event_type} | id={stripe_event['id']}")

    # ── Dispatch ──────────────────────────────────────────────────────────────
    if event_type == "payment_intent.succeeded":
        _handle_payment_succeeded(data_obj)

    elif event_type == "payment_intent.payment_failed":
        _handle_payment_failed(data_obj)

    elif event_type == "charge.refunded":
        _handle_charge_refunded(data_obj)

    else:
        print(f"[Webhook] Unhandled event type: {event_type}")

    # Always return 200 so Stripe doesn't retry
    return _response(200, {"received": True})


# ── Event handlers ────────────────────────────────────────────────────────────

def _handle_payment_succeeded(intent: dict):
    """
    Fires when Stripe confirms funds captured.
    Updates payment status to SUCCEEDED and stores receipt URL.
    """
    intent_id   = intent["id"]
    charge_id   = intent.get("latest_charge")
    receipt_url = None

    # Fetch the charge object to get the receipt URL
    if charge_id:
        try:
            charge      = stripe.Charge.retrieve(charge_id)
            receipt_url = charge.get("receipt_url")
        except stripe.error.StripeError as e:
            print(f"[Webhook] Could not fetch charge {charge_id}: {e}")

    record = _find_payment_by_intent_id(intent_id)
    if not record:
        print(f"[Webhook] No DynamoDB record found for intent {intent_id}")
        return

    updates = payment_status_update(
        status=PaymentStatus.SUCCEEDED,
        stripe_charge_id=charge_id,
        stripe_receipt_url=receipt_url,
    )
    _update_payment(record["PK"], record["SK"], updates)

    # ── Trigger downstream actions ────────────────────────────────────────────
    _send_payment_confirmation(record, receipt_url)
    print(f"[Webhook] Payment SUCCEEDED: {record['payment_id']}")


def _handle_payment_failed(intent: dict):
    """
    Fires when a payment attempt fails.
    Stores the Stripe failure message for member-facing display.
    """
    intent_id       = intent["id"]
    failure_message = (
        intent.get("last_payment_error", {}).get("message")
        or "Payment failed. Please check your payment details."
    )

    record = _find_payment_by_intent_id(intent_id)
    if not record:
        print(f"[Webhook] No DynamoDB record found for intent {intent_id}")
        return

    updates = payment_status_update(
        status=PaymentStatus.FAILED,
        failure_message=failure_message,
    )
    _update_payment(record["PK"], record["SK"], updates)
    print(f"[Webhook] Payment FAILED: {record['payment_id']} | {failure_message}")


def _handle_charge_refunded(charge: dict):
    """
    Fires when a refund is issued (from Stripe dashboard or refund API).
    """
    payment_intent_id = charge.get("payment_intent")
    if not payment_intent_id:
        return

    record = _find_payment_by_intent_id(payment_intent_id)
    if not record:
        print(f"[Webhook] No DynamoDB record found for refunded intent {payment_intent_id}")
        return

    updates = payment_status_update(status=PaymentStatus.REFUNDED)
    _update_payment(record["PK"], record["SK"], updates)
    print(f"[Webhook] Payment REFUNDED: {record['payment_id']}")


# ── DynamoDB helpers ──────────────────────────────────────────────────────────

def _find_payment_by_intent_id(intent_id: str) -> dict | None:
    """
    Uses GSI2 (GSI2PK = stripe_payment_intent_id) to find the payment record.
    """
    resp = table.query(
        IndexName="GSI2",
        KeyConditionExpression="GSI2PK = :pk",
        ExpressionAttributeValues={":pk": intent_id},
        Limit=1,
    )
    items = resp.get("Items", [])
    return items[0] if items else None


def _update_payment(pk: str, sk: str, update_params: dict):
    """
    Applies a status update to a payment record.
    Includes idempotency guard: won't downgrade a SUCCEEDED record to FAILED.
    """
    try:
        table.update_item(
            Key={"PK": pk, "SK": sk},
            ConditionExpression=Attr("status").ne(PaymentStatus.SUCCEEDED)
                if update_params["ExpressionAttributeValues"].get(":status") == PaymentStatus.FAILED
                else Attr("PK").exists(),   # always true — just need a valid condition
            **update_params,
        )
    except dynamodb.meta.client.exceptions.ConditionalCheckFailedException:
        print(f"[DynamoDB] Skipped downgrade attempt for {sk}")
    except Exception as e:
        print(f"[DynamoDB] Update error for {sk}: {e}")
        raise


# ── Downstream actions ────────────────────────────────────────────────────────

def _send_payment_confirmation(record: dict, receipt_url: str | None):
    """
    Publishes a payment confirmation event to SNS (or SES).
    Hook this into your existing notification Lambda or SNS topic.

    TODO: Replace topic ARN with your Terraform output variable.
    """
    sns = boto3.client("sns")
    topic_arn = os.environ.get("PAYMENT_NOTIFICATION_TOPIC_ARN")
    if not topic_arn:
        print("[SNS] No PAYMENT_NOTIFICATION_TOPIC_ARN set — skipping notification")
        return

    message = {
        "type":        "PAYMENT_CONFIRMED",
        "member_id":   record["member_id"],
        "policy_id":   record["policy_id"],
        "payment_id":  record["payment_id"],
        "amount_cents": record["amount_cents"],
        "currency":    record["currency"],
        "period_start": record["period_start"],
        "period_end":  record["period_end"],
        "receipt_url": receipt_url,
    }
    sns.publish(TopicArn=topic_arn, Message=json.dumps(message))


# ── HTTP helper ───────────────────────────────────────────────────────────────
def _response(status_code: int, body: dict) -> dict:
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }