"""
seed_policy.py
--------------
Writes sample DynamoDB records so you can test get_policy locally
with `sam local start-api` or against a real dev table.

Run:
    pip install boto3
    AWS_PROFILE=kafa-dev python seed_policy.py

Uses the table names from your .env or defaults below.
Set DYNAMODB_ENDPOINT=http://localhost:8000 for DynamoDB Local.
"""

import os
import boto3
from datetime import datetime, timezone

INSURANCE_TABLE = os.environ.get("INSURANCE_TABLE", "kopera-life-insurance")
MEMBER_TABLE    = os.environ.get("MEMBER_TABLE",    "kopera-member")
ENDPOINT        = os.environ.get("DYNAMODB_ENDPOINT")   # None = real AWS

kwargs = {"region_name": "us-east-1"}
if ENDPOINT:
    kwargs["endpoint_url"] = ENDPOINT

dynamodb  = boto3.resource("dynamodb", **kwargs)
ins_table = dynamodb.Table(INSURANCE_TABLE)
mem_table = dynamodb.Table(MEMBER_TABLE)

NOW = datetime.now(timezone.utc).isoformat()

# ──────────────────────────────────────────────────────────────────────────────
# 1. Member profile (kopera-member table)
# ──────────────────────────────────────────────────────────────────────────────
member_profile = {
    "PK":          "MEMBER#M-001",
    "SK":          "PROFILE",
    "entity_type": "MEMBER",
    "member_id":   "M-001",
    "cognito_sub": "REPLACE-WITH-REAL-COGNITO-SUB",  # from Cognito user pool
    "first_name":  "Jean-Pierre",
    "last_name":   "Mathieu",
    "email":       "jp.mathieu@example.com",
    "phone":       "+1-305-555-0100",
    "status":      "ACTIVE",
    "created_at":  NOW,
    "updated_at":  NOW,
}

# ──────────────────────────────────────────────────────────────────────────────
# 2. Policy metadata (kopera-life-insurance table)
# ──────────────────────────────────────────────────────────────────────────────
policy_metadata = {
    "PK":                   "POLICY#POL-2024-001",
    "SK":                   "METADATA",
    "entity_type":          "POLICY",
    "policy_id":            "POL-2024-001",
    "member_id":            "M-001",
    "plan_name":            "Plan Familyal",
    "status":               "ACTIVE",
    "start_date":           "2024-01-01",
    "monthly_premium_cents": 2500,          # $25.00
    "coverage_amount_cents": 500000,        # $5,000
    "created_at":           NOW,
    "updated_at":           NOW,
}

# ──────────────────────────────────────────────────────────────────────────────
# 3. Payment schedule
# ──────────────────────────────────────────────────────────────────────────────
payment_schedule = {
    "PK":              "POLICY#POL-2024-001",
    "SK":              "SCHEDULE",
    "entity_type":     "SCHEDULE",
    "policy_id":       "POL-2024-001",
    "frequency":       "monthly",
    "due_day_of_month": 1,
    "created_at":      NOW,
    "updated_at":      NOW,
}

# ──────────────────────────────────────────────────────────────────────────────
# 4. Beneficiaries
# ──────────────────────────────────────────────────────────────────────────────
beneficiaries = [
    {
        "PK":          "POLICY#POL-2024-001",
        "SK":          "BENEFICIARY#BEN-001",
        "entity_type": "BENEFICIARY",
        "policy_id":   "POL-2024-001",
        "name":        "Marie Mathieu",
        "relationship": "Spouse",
        "percentage":  60,
        "created_at":  NOW,
    },
    {
        "PK":          "POLICY#POL-2024-001",
        "SK":          "BENEFICIARY#BEN-002",
        "entity_type": "BENEFICIARY",
        "policy_id":   "POL-2024-001",
        "name":        "Claudette Mathieu",
        "relationship": "Child",
        "percentage":  40,
        "created_at":  NOW,
    },
]

# ──────────────────────────────────────────────────────────────────────────────
# 5. Sample payment history
# ──────────────────────────────────────────────────────────────────────────────
payments = [
    {
        "PK":                       "MEMBER#M-001",
        "SK":                       "PAYMENT#2026-04-01T00:00:00+00:00#PAY-3F9A1B2C",
        "GSI1PK":                   "POLICY#POL-2024-001",
        "GSI1SK":                   "PAYMENT#2026-04-01T00:00:00+00:00#PAY-3F9A1B2C",
        "GSI2PK":                   "pi_test_april",
        "GSI3PK":                   "SUCCEEDED",
        "GSI3SK":                   "2026-04-01T00:00:00+00:00",
        "entity_type":              "PAYMENT",
        "payment_id":               "PAY-3F9A1B2C",
        "member_id":                "M-001",
        "policy_id":                "POL-2024-001",
        "amount_cents":             2500,
        "currency":                 "usd",
        "status":                   "SUCCEEDED",
        "payment_method":           "card",
        "stripe_payment_intent_id": "pi_test_april",
        "period_start":             "2026-04-01",
        "period_end":               "2026-04-30",
        "created_at":               "2026-04-01T10:22:00+00:00",
        "updated_at":               "2026-04-01T10:22:05+00:00",
    },
    {
        "PK":                       "MEMBER#M-001",
        "SK":                       "PAYMENT#2026-03-01T00:00:00+00:00#PAY-2D8E4A1F",
        "GSI1PK":                   "POLICY#POL-2024-001",
        "GSI1SK":                   "PAYMENT#2026-03-01T00:00:00+00:00#PAY-2D8E4A1F",
        "GSI2PK":                   "pi_test_march",
        "GSI3PK":                   "SUCCEEDED",
        "GSI3SK":                   "2026-03-01T00:00:00+00:00",
        "entity_type":              "PAYMENT",
        "payment_id":               "PAY-2D8E4A1F",
        "member_id":                "M-001",
        "policy_id":                "POL-2024-001",
        "amount_cents":             2500,
        "currency":                 "usd",
        "status":                   "SUCCEEDED",
        "payment_method":           "card",
        "stripe_payment_intent_id": "pi_test_march",
        "period_start":             "2026-03-01",
        "period_end":               "2026-03-31",
        "created_at":               "2026-03-01T09:15:00+00:00",
        "updated_at":               "2026-03-01T09:15:04+00:00",
    },
]

# ──────────────────────────────────────────────────────────────────────────────
# Write everything
# ──────────────────────────────────────────────────────────────────────────────
def seed():
    print(f"Seeding {MEMBER_TABLE}...")
    mem_table.put_item(Item=member_profile)
    print(f"  ✓ Member profile: M-001")

    print(f"\nSeeding {INSURANCE_TABLE}...")
    for item in [policy_metadata, payment_schedule, *beneficiaries, *payments]:
        ins_table.put_item(Item=item)
        print(f"  ✓ {item['SK']}")

    print("\nDone. You can now call:")
    print("  GET /policies/POL-2024-001?memberId=M-001")

if __name__ == "__main__":
    seed()
