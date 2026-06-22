"""
list_member_payments.py
Lambda handler: GET /admin/payments?memberId=<id>

Returns all Stripe payment records for a given member, sorted newest-first.
Protected by SigV4 / IAM — admin only.

Environment variables:
  LIFE_INSURANCE_TABLE  — DynamoDB table name (kopera-life-insurance)
"""

import json
import logging
import os

import boto3
from boto3.dynamodb.conditions import Attr

logger = logging.getLogger()
logger.setLevel(logging.INFO)

_TABLE = os.environ["LIFE_INSURANCE_TABLE"]
_dynamodb = boto3.resource("dynamodb")
_table = _dynamodb.Table(_TABLE)


def _cors(status: int, body: dict) -> dict:
    return {
        "statusCode": status,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
        },
        "body": json.dumps(body, default=str),
    }


def _period_label(start: str, end: str) -> str:
    """'2026-04-01' → 'Apr 2026'"""
    try:
        from datetime import datetime
        dt = datetime.strptime(start, "%Y-%m-%d")
        return dt.strftime("%b %Y")
    except Exception:
        return f"{start} – {end}" if start else ""


def lambda_handler(event, _context):
    query_params = event.get("queryStringParameters") or {}
    member_id = query_params.get("memberId", "").strip()

    if not member_id:
        return _cors(400, {"error": "memberId query parameter is required"})

    logger.info("Fetching Stripe payments for member %s", member_id)

    try:
        # Scan for PAYMENT# records belonging to this member.
        # We filter on memberId attribute; SK="METADATA" is present on all
        # payment records. A begins_with on PK isn't possible in a scan
        # FilterExpression, so we post-filter in Python.
        resp = _table.scan(
            FilterExpression=(
                Attr("memberId").eq(member_id)
                & Attr("SK").eq("METADATA")
            ),
        )
        items = resp.get("Items", [])

        # DynamoDB scan may be paginated — fetch all pages
        while "LastEvaluatedKey" in resp:
            resp = _table.scan(
                FilterExpression=(
                    Attr("memberId").eq(member_id)
                    & Attr("SK").eq("METADATA")
                ),
                ExclusiveStartKey=resp["LastEvaluatedKey"],
            )
            items.extend(resp.get("Items", []))

        # Keep only PAYMENT# records (not POLICY# or MEMBER# METADATA items)
        payments = [
            item for item in items
            if str(item.get("PK", "")).startswith("PAYMENT#")
        ]

        # Sort newest first
        payments.sort(key=lambda p: p.get("createdAt", ""), reverse=True)

        result = []
        for p in payments:
            amount_cents = int(p.get("amountCents", p.get("amount_cents", 0)))
            period_start = p.get("periodStart", p.get("period_start", ""))
            period_end   = p.get("periodEnd",   p.get("period_end",   ""))
            result.append({
                "paymentId":   p.get("paymentId",  p.get("payment_id", "")),
                "policyId":    p.get("policyId",   p.get("policy_id",  "")),
                "amountCents": amount_cents,
                "currency":    p.get("currency", "htg"),
                "periodStart": period_start,
                "periodEnd":   period_end,
                "period":      _period_label(period_start, period_end),
                "status":      p.get("status", "PENDING"),
                "createdAt":   p.get("createdAt", p.get("created_at", "")),
                "receiptUrl":  p.get("receiptUrl", ""),
                "method":      "STRIPE",
            })

        logger.info("Found %d payment(s) for member %s", len(result), member_id)
        return _cors(200, {"payments": result})

    except Exception as exc:
        logger.error("Error fetching payments for %s: %s", member_id, exc)
        return _cors(500, {"error": "Internal server error"})
