"""
Lambda: get_policy.py
----------------------
Returns full policy detail for the member portal's PolicyDetailScreen.

Route:  GET /policies/{policyId}?memberId=M-001
Auth:   Expects a Cognito-issued JWT in the Authorization header.
        API Gateway validates the token; Lambda trusts the claims it injects
        into event['requestContext']['authorizer']['claims'].

DynamoDB reads:
  1. Policy record         PK=POLICY#<id>       SK=METADATA
  2. Beneficiaries         PK=POLICY#<id>       SK begins_with BENEFICIARY#
  3. Payment schedule      PK=POLICY#<id>       SK=SCHEDULE
  4. Recent payments       GSI1: PK=POLICY#<id> SK begins_with PAYMENT#  (last 12)
  5. Member name           PK=MEMBER#<id>       SK=PROFILE  (kopera-member table)

Returns a single JSON object consumed by the Flutter PolicyDetail model.
"""

import json
import os
from datetime import datetime, timezone, timedelta
from calendar import monthrange
import boto3
from boto3.dynamodb.conditions import Key

# ── Clients ───────────────────────────────────────────────────────────────────
dynamodb  = boto3.resource("dynamodb")
ins_table = dynamodb.Table(os.environ.get("INSURANCE_TABLE", "kopera-life-insurance"))
mem_table = dynamodb.Table(os.environ.get("MEMBER_TABLE",   "kopera-member"))


def handler(event, context):
    # ── Parse path + query params ─────────────────────────────────────────────
    path_params  = event.get("pathParameters") or {}
    query_params = event.get("queryStringParameters") or {}
    policy_id    = path_params.get("policyId", "").strip()
    member_id    = query_params.get("memberId", "").strip()

    if not policy_id or not member_id:
        return _resp(400, {"error": "policyId (path) and memberId (query) are required."})

    # ── Authorization guard ───────────────────────────────────────────────────
    # Ensure the requesting Cognito user owns this member account.
    claims      = (event.get("requestContext", {})
                       .get("authorizer", {})
                       .get("claims", {}))
    cognito_sub = claims.get("sub", "")
    if not _is_authorized(cognito_sub, member_id):
        return _resp(403, {"error": "Access denied."})

    try:
        # ── 1. Policy metadata ────────────────────────────────────────────────
        policy = _get_item(ins_table, f"POLICY#{policy_id}", "METADATA")
        if not policy:
            return _resp(404, {"error": "Policy not found."})

        # Verify this policy belongs to the requesting member
        if policy.get("member_id") != member_id:
            return _resp(403, {"error": "Access denied."})

        # ── 2. Beneficiaries ──────────────────────────────────────────────────
        beneficiaries = _query_begins_with(
            ins_table,
            pk=f"POLICY#{policy_id}",
            sk_prefix="BENEFICIARY#",
        )

        # ── 3. Payment schedule ───────────────────────────────────────────────
        schedule = _get_item(ins_table, f"POLICY#{policy_id}", "SCHEDULE")

        # ── 4. Recent payments (last 12, newest first) ────────────────────────
        payments = _query_gsi1_payments(policy_id, limit=12)

        # ── 5. Member name ─────────────────────────────────────────────────────
        member   = _get_item(mem_table, f"MEMBER#{member_id}", "PROFILE")
        member_name = _full_name(member) if member else "Member"

        # ── Compute next due date + period ────────────────────────────────────
        next_due, period_start, period_end = _compute_next_period(
            payments, policy.get("start_date", "")
        )

        # ── Build response ────────────────────────────────────────────────────
        return _resp(200, {
            "policy_id":              policy_id,
            "member_id":              member_id,
            "member_name":            member_name,
            "plan_name":              policy.get("plan_name", "KAFA Plan"),
            "status":                 policy.get("status", "ACTIVE").upper(),
            "start_date":             policy.get("start_date", ""),
            "monthly_premium_cents":  int(policy.get("monthly_premium_cents", 0)),
            "coverage_amount_cents":  int(policy.get("coverage_amount_cents", 0)),
            "next_due_date":          next_due,
            "next_period_start":      period_start,
            "next_period_end":        period_end,
            "beneficiaries":          _format_beneficiaries(beneficiaries),
            "payment_history":        _format_payments(payments),
        })

    except Exception as e:
        print(f"[get_policy] Error: {e}")
        return _resp(500, {"error": "Internal server error."})


# ── Business logic ────────────────────────────────────────────────────────────

def _compute_next_period(payments: list, start_date: str) -> tuple[str, str, str]:
    """
    Determines the next unpaid coverage month.

    Logic:
      - Find the most recent SUCCEEDED payment's period_end.
      - Next period starts the day after that.
      - If no payments, next period starts on the policy start_date.
    """
    succeeded = [
        p for p in payments if p.get("status") == "SUCCEEDED"
    ]
    succeeded.sort(key=lambda p: p.get("period_end", ""), reverse=True)

    if succeeded:
        last_end = succeeded[0]["period_end"]          # e.g. "2026-04-30"
        last_end_dt = datetime.strptime(last_end, "%Y-%m-%d")
        period_start_dt = last_end_dt + timedelta(days=1)
    else:
        if start_date:
            period_start_dt = datetime.strptime(start_date, "%Y-%m-%d")
        else:
            today = datetime.now(timezone.utc)
            period_start_dt = today.replace(day=1)

    # Period end = last day of that month
    _, last_day = monthrange(period_start_dt.year, period_start_dt.month)
    period_end_dt = period_start_dt.replace(day=last_day)

    fmt = "%Y-%m-%d"
    return (
        period_start_dt.strftime(fmt),   # next_due_date (1st of month)
        period_start_dt.strftime(fmt),   # period_start
        period_end_dt.strftime(fmt),     # period_end
    )


def _is_authorized(cognito_sub: str, member_id: str) -> bool:
    """
    Checks the kopera-member table to verify the Cognito sub matches
    the requested member_id. Prevents member A from viewing member B's policy.

    TODO: Cache this check in ElastiCache / DAX if it becomes a hot path.
    """
    if not cognito_sub:
        return False
    try:
        resp = mem_table.get_item(Key={"PK": f"MEMBER#{member_id}", "SK": "PROFILE"})
        item = resp.get("Item")
        return item is not None and item.get("cognito_sub") == cognito_sub
    except Exception as e:
        print(f"[auth check] Error: {e}")
        return False


# ── DynamoDB helpers ──────────────────────────────────────────────────────────

def _get_item(table, pk: str, sk: str) -> dict | None:
    resp = table.get_item(Key={"PK": pk, "SK": sk})
    return resp.get("Item")


def _query_begins_with(table, pk: str, sk_prefix: str) -> list:
    resp = table.query(
        KeyConditionExpression=(
            Key("PK").eq(pk) & Key("SK").begins_with(sk_prefix)
        )
    )
    return resp.get("Items", [])


def _query_gsi1_payments(policy_id: str, limit: int = 12) -> list:
    """
    Uses GSI1 (GSI1PK = POLICY#<id>, GSI1SK begins_with PAYMENT#)
    to fetch recent payments sorted newest-first.
    """
    resp = ins_table.query(
        IndexName="GSI1",
        KeyConditionExpression=(
            Key("GSI1PK").eq(f"POLICY#{policy_id}")
            & Key("GSI1SK").begins_with("PAYMENT#")
        ),
        ScanIndexForward=False,   # newest first
        Limit=limit,
    )
    return resp.get("Items", [])


# ── Formatters ────────────────────────────────────────────────────────────────

def _format_beneficiaries(items: list) -> list:
    result = []
    for b in items:
        result.append({
            "name":         b.get("name", ""),
            "relationship": b.get("relationship", ""),
            "percentage":   int(b.get("percentage", 0)),
        })
    return sorted(result, key=lambda x: x["percentage"], reverse=True)


def _format_payments(items: list) -> list:
    result = []
    for p in items:
        amount_cents = int(p.get("amount_cents", 0))
        result.append({
            "payment_id":   p.get("payment_id", ""),
            "date":         _friendly_date(p.get("created_at", "")),
            "amount_cents": amount_cents,
            "status":       p.get("status", "PENDING"),
            "period":       _period_label(
                                p.get("period_start", ""),
                                p.get("period_end", ""),
                            ),
        })
    return result


def _full_name(member: dict) -> str:
    first = member.get("first_name", "")
    last  = member.get("last_name", "")
    return f"{first} {last}".strip() or member.get("email", "Member")


def _friendly_date(iso_ts: str) -> str:
    """Converts ISO timestamp → 'Apr 1, 2026'."""
    try:
        dt = datetime.fromisoformat(iso_ts.replace("Z", "+00:00"))
        return dt.strftime("%b %-d, %Y")
    except Exception:
        return iso_ts[:10] if len(iso_ts) >= 10 else iso_ts


def _period_label(start: str, end: str) -> str:
    """'2026-04-01' + '2026-04-30' → 'Apr 2026'"""
    try:
        dt = datetime.strptime(start, "%Y-%m-%d")
        return dt.strftime("%b %Y")
    except Exception:
        return f"{start} – {end}"


# ── HTTP helper ───────────────────────────────────────────────────────────────
def _resp(status: int, body: dict) -> dict:
    return {
        "statusCode": status,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
        },
        "body": json.dumps(body, default=str),
    }
