"""
Seed kopera-life-insurance with one policy per KAFA member.

Scans kopera-member for all members with a memberId and full_name,
then creates:
  - MEMBER#<memberId>  SK=POLICY#<policyNo>   (index item)
  - POLICY#<policyNo>  SK=METADATA            (policy master)
  - POLICY#<policyNo>  SK=SCHED#<date>#000001 (first installment - PAID)
  - POLICY#<policyNo>  SK=SCHED#<date>#000002 (next installment - PENDING)

Run: python3 seed_policies.py
"""

import boto3
from decimal import Decimal
from datetime import date, timedelta

MEMBERS_TABLE       = "kopera-member"
LIFE_INSURANCE_TABLE = "kopera-life-insurance"
COMPANY_ID          = "KAFA-001"
REGION              = "us-east-1"

# All KAFA members get the Basic Life Cover plan
PRODUCT_CODE   = "LIFE-BASIC"
PLAN_ID        = "plan-basic-monthly"
PREMIUM_AMOUNT = Decimal("150")
SUM_ASSURED    = Decimal("50000")
FREQUENCY      = "MONTHLY"


def scan_all_members(table):
    items = []
    resp  = table.scan(
        FilterExpression="companyId = :c",
        ExpressionAttributeValues={":c": COMPANY_ID},
        ProjectionExpression="memberId, full_name",
    )
    items.extend(resp.get("Items", []))
    while "LastEvaluatedKey" in resp:
        resp = table.scan(
            FilterExpression="companyId = :c",
            ExpressionAttributeValues={":c": COMPANY_ID},
            ProjectionExpression="memberId, full_name",
            ExclusiveStartKey=resp["LastEvaluatedKey"],
        )
        items.extend(resp.get("Items", []))
    return items


def policy_no(idx):
    return f"POL-KAFA-{idx:06d}"


def main():
    dynamodb        = boto3.resource("dynamodb", region_name=REGION)
    members_table   = dynamodb.Table(MEMBERS_TABLE)
    insurance_table = dynamodb.Table(LIFE_INSURANCE_TABLE)

    print(f"Scanning {MEMBERS_TABLE}...")
    members = scan_all_members(members_table)
    print(f"  Found {len(members)} members.\n")

    today      = date.today()
    last_month = today.replace(day=15) - timedelta(days=30)
    next_month = today.replace(day=15) + timedelta(days=30)
    last_date  = last_month.strftime("%Y-%m-%d")
    next_date  = next_month.strftime("%Y-%m-%d")

    with insurance_table.batch_writer() as batch:
        for idx, member in enumerate(members, start=1):
            member_id   = member.get("memberId", "")
            member_name = member.get("full_name", "Unknown")
            if not member_id:
                continue

            pol_no    = policy_no(idx)
            pol_pk    = f"POLICY#{pol_no}"
            start_str = "2025-01-01"

            # ── Policy master ──────────────────────────────────────────────
            batch.put_item(Item={
                "PK":            pol_pk,
                "SK":            "METADATA",
                "GSI2PK":        next_date,
                "GSI2SK":        pol_pk,
                "GSI4PK":        "ACTIVE",
                "GSI4SK":        next_date,
                "entity_type":   "POLICY",
                "policyNo":      pol_no,
                "memberId":      member_id,
                "companyId":     COMPANY_ID,
                "memberName":    member_name,
                "productCode":   PRODUCT_CODE,
                "planId":        PLAN_ID,
                "frequency":     FREQUENCY,
                "startDate":     start_str,
                "endDate":       "",
                "policyStatus":  "ACTIVE",
                "sumAssured":    SUM_ASSURED,
                "premiumAmount": PREMIUM_AMOUNT,
                "nextDueDate":   next_date,
                "lastPaidDate":  last_date,
                "lastPaidAmount": PREMIUM_AMOUNT,
                "totalPaid":     PREMIUM_AMOUNT,
                "createdAt":     "2025-01-01T00:00:00Z",
                "updatedAt":     f"{today.isoformat()}T00:00:00Z",
            })

            # ── Member → Policy index ──────────────────────────────────────
            batch.put_item(Item={
                "PK":           f"MEMBER#{member_id}",
                "SK":           pol_pk,
                "entity_type":  "MEMBER_POLICY_REF",
                "memberId":     member_id,
                "companyId":    COMPANY_ID,
                "policyNo":     pol_no,
                "productCode":  PRODUCT_CODE,
                "policyStatus": "ACTIVE",
                "premiumAmount": PREMIUM_AMOUNT,
                "sumAssured":   SUM_ASSURED,
                "startDate":    start_str,
                "nextDueDate":  next_date,
            })

            # ── Last schedule (PAID) ───────────────────────────────────────
            batch.put_item(Item={
                "PK":           pol_pk,
                "SK":           f"SCHED#{last_date}#000001",
                "entity_type":  "SCHEDULE",
                "policyNo":     pol_no,
                "installmentNo": Decimal("1"),
                "dueDate":      last_date,
                "amountDue":    PREMIUM_AMOUNT,
                "status":       "PAID",
                "paidDate":     last_date,
                "paidAmount":   PREMIUM_AMOUNT,
            })

            # ── Next schedule (PENDING) ────────────────────────────────────
            batch.put_item(Item={
                "PK":           pol_pk,
                "SK":           f"SCHED#{next_date}#000002",
                "entity_type":  "SCHEDULE",
                "policyNo":     pol_no,
                "installmentNo": Decimal("2"),
                "dueDate":      next_date,
                "amountDue":    PREMIUM_AMOUNT,
                "status":       "PENDING",
                "paidDate":     "",
                "paidAmount":   Decimal("0"),
            })

            print(f"  ✓ {member_name} ({member_id}) → {pol_no}")

    print(f"\nSeeded {len(members)} policies in {LIFE_INSURANCE_TABLE}.")


if __name__ == "__main__":
    main()