"""
Shared test utilities for KAFA API test scripts.

Run from the project root after sourcing .env.local:
    source .env.local && dev/venv/bin/python dev/tests/tc001_admin_adds_member.py
"""

import hashlib
import hmac
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

# Load .env.local automatically so the scripts can be run without `source`.
_ROOT = Path(__file__).resolve().parent.parent.parent
_env_file = _ROOT / ".env.local"
if _env_file.exists():
    try:
        from dotenv import load_dotenv
        load_dotenv(_env_file, override=False)
    except ImportError:
        pass

import boto3
import requests
import stripe as _stripe_module

API_BASE  = os.environ.get("API_BASE_URL", "http://localhost:8000")
REGION    = "us-east-1"

MEMBERS_TABLE      = os.environ.get("MEMBERS_TABLE", "kopera-member-dev")
INSURANCE_TABLE    = os.environ.get("LIFE_INSURANCE_TABLE", "kopera-life-insurance-dev")
SHARES_TABLE       = os.environ.get("SHARES_TABLE", "kopera-share")
PROSPECTS_TABLE    = os.environ.get("PROSPECTS_TABLE", "kopera-prospect")
COMPANY_ID         = "KAFA-001"

_dynamodb = boto3.resource("dynamodb", region_name=REGION)


# ── Assertion helpers ─────────────────────────────────────────────────────────

_FAILURES: list[str] = []
_STEP_NAME: str = ""


def step(name: str) -> None:
    global _STEP_NAME
    _STEP_NAME = name
    print(f"\n  ▶ {name}")


def check(condition: bool, message: str) -> None:
    if condition:
        print(f"    ✓ {message}")
    else:
        msg = f"    ✗ {message}"
        print(msg)
        _FAILURES.append(f"[{_STEP_NAME}] {message}")


def require(condition: bool, message: str) -> None:
    """Like check(), but aborts the current test on failure."""
    if condition:
        print(f"    ✓ {message}")
    else:
        print(f"    ✗ FATAL: {message}")
        _FAILURES.append(f"[{_STEP_NAME}] FATAL: {message}")
        raise AssertionError(f"Required check failed: {message}")


def api(method: str, path: str, **kwargs) -> requests.Response:
    url = f"{API_BASE}{path}"
    resp = requests.request(method, url, **kwargs)
    return resp


def db_get_member(member_id: str) -> dict | None:
    table = _dynamodb.Table(MEMBERS_TABLE)
    item = table.get_item(Key={"memberId": member_id, "companyId": COMPANY_ID}).get("Item")
    return dict(item) if item else None


def db_delete_member(member_id: str) -> None:
    _dynamodb.Table(MEMBERS_TABLE).delete_item(
        Key={"memberId": member_id, "companyId": COMPANY_ID}
    )


def db_delete_policy(policy_no: str, member_id: str = "") -> None:
    """Delete METADATA + all SCHED# + MEMBER# ref records for a policy."""
    ins = _dynamodb.Table(INSURANCE_TABLE)
    pol_pk = f"POLICY#{policy_no}"

    # Read METADATA first to resolve member_id if not supplied.
    if not member_id:
        meta = ins.get_item(Key={"PK": pol_pk, "SK": "METADATA"}).get("Item", {})
        member_id = meta.get("memberId", "")

    # Delete all POLICY#-partitioned items (METADATA + SCHED# records).
    resp = ins.query(KeyConditionExpression=boto3.dynamodb.conditions.Key("PK").eq(pol_pk))
    for item in resp.get("Items", []):
        ins.delete_item(Key={"PK": item["PK"], "SK": item["SK"]})

    # Delete the MEMBER#{member_id} → POLICY# ref item.
    if member_id:
        ins.delete_item(Key={"PK": f"MEMBER#{member_id}", "SK": pol_pk})


def db_delete_shares(member_id: str) -> None:
    table = _dynamodb.Table(SHARES_TABLE)
    resp = table.query(
        KeyConditionExpression=boto3.dynamodb.conditions.Key("memberID").eq(member_id)
    )
    for item in resp.get("Items", []):
        table.delete_item(Key={"memberID": item["memberID"], "shareId": item["shareId"]})


def db_delete_payments(policy_no: str) -> None:
    """Delete all PAYMENT# records that belong to a policy (scan by policyId)."""
    ins = _dynamodb.Table(INSURANCE_TABLE)
    resp = ins.scan(
        FilterExpression=boto3.dynamodb.conditions.Attr("policyId").eq(policy_no)
        & boto3.dynamodb.conditions.Attr("entity_type").eq("PAYMENT"),
    )
    for item in resp.get("Items", []):
        ins.delete_item(Key={"PK": item["PK"], "SK": item["SK"]})


def db_delete_prospect(prospect_id: str) -> None:
    _dynamodb.Table(PROSPECTS_TABLE).delete_item(Key={"id": prospect_id})


# ── Stripe webhook simulation ─────────────────────────────────────────────────

def stripe_sign(payload: str, secret: str) -> str:
    """Return a Stripe-Signature header value for the given payload and secret."""
    ts = int(time.time())
    mac = hmac.new(
        secret.encode("utf-8"),
        f"{ts}.{payload}".encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()
    return f"t={ts},v1={mac}"


def send_stripe_webhook(path: str, event: dict, secret: str) -> requests.Response:
    """POST a Stripe webhook event to the local backend with a valid signature."""
    payload = json.dumps(event, separators=(",", ":"))
    sig = stripe_sign(payload, secret)
    return requests.post(
        f"{API_BASE}{path}",
        data=payload,
        headers={"Content-Type": "application/json", "Stripe-Signature": sig},
    )


def make_pi_succeeded_event(intent_id: str, amount_cents: int, currency: str = "usd") -> dict:
    return {
        "id": f"evt_test_{int(time.time())}",
        "object": "event",
        "type": "payment_intent.succeeded",
        "data": {
            "object": {
                "id": intent_id,
                "object": "payment_intent",
                "status": "succeeded",
                "amount": amount_cents,
                "currency": currency,
                "latest_charge": "",
            }
        },
    }


# ── Stripe self-service payment helper ───────────────────────────────────────

def confirm_stripe_pi(client_secret: str, amount_cents: int, webhook_path: str, wh_secret: str) -> str:
    """
    Confirm a Stripe PaymentIntent with the pm_card_visa test payment method,
    then synthesize the payment_intent.succeeded webhook and POST it to the
    local backend — exactly what the Stripe CLI does during live forwarding.
    Returns the PaymentIntent ID.
    """
    pi_id = client_secret.split("_secret_")[0]
    _stripe_module.PaymentIntent.confirm(
        pi_id,
        payment_method="pm_card_visa",
        return_url="http://localhost:5501",
    )
    event = make_pi_succeeded_event(pi_id, amount_cents)
    r = send_stripe_webhook(webhook_path, event, wh_secret)
    check(r.status_code == 200,
          f"Webhook {webhook_path} → 200 (got {r.status_code}: {r.text[:80]})")
    return pi_id


# ── Results summary ───────────────────────────────────────────────────────────

def print_summary(test_name: str) -> int:
    print(f"\n{'='*60}")
    if not _FAILURES:
        print(f"  {test_name}: ALL CHECKS PASSED ✓")
    else:
        print(f"  {test_name}: {len(_FAILURES)} FAILURE(S)")
        for f in _FAILURES:
            print(f"    • {f}")
    print("=" * 60)
    return 1 if _FAILURES else 0
