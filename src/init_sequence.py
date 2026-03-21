"""
Initialize kopera-company.sequence by scanning all existing members
and setting the counter to the highest MK sequence number found.

Run once after deploying the new handler. Safe to re-run — it only
ever raises the counter, never lowers it.

Usage:
    python3 init_sequence.py
"""

import boto3
from decimal import Decimal

MEMBERS_TABLE  = "kopera-member"
COMPANIES_TABLE = "kopera-company"
COMPANY_ID     = "KAFA-001"
REGION         = "us-east-1"


def scan_all_members(table):
    items = []
    resp  = table.scan(ProjectionExpression="memberId")
    items.extend(resp.get("Items", []))
    while "LastEvaluatedKey" in resp:
        resp = table.scan(
            ProjectionExpression="memberId",
            ExclusiveStartKey=resp["LastEvaluatedKey"],
        )
        items.extend(resp.get("Items", []))
    return items


def main():
    dynamodb = boto3.resource("dynamodb", region_name=REGION)
    members_table   = dynamodb.Table(MEMBERS_TABLE)
    companies_table = dynamodb.Table(COMPANIES_TABLE)

    print(f"Scanning {MEMBERS_TABLE}...")
    members = scan_all_members(members_table)
    print(f"  Found {len(members)} members total.")

    max_seq = 0
    mk_count = 0
    for m in members:
        mid = m.get("memberId", "")
        if mid.startswith("MK") and len(mid) == 13:
            try:
                seq = int(mid[5:])   # after MK + 3-digit code
                if seq > max_seq:
                    max_seq = seq
                mk_count += 1
            except ValueError:
                pass

    print(f"  MK-format members: {mk_count}")
    print(f"  Highest sequence found: {max_seq}")

    # Read current sequence
    resp = companies_table.get_item(Key={"companyId": COMPANY_ID})
    current = int(resp.get("Item", {}).get("sequence", 0))
    print(f"  Current sequence in kopera-company: {current}")

    if max_seq > current:
        companies_table.update_item(
            Key={"companyId": COMPANY_ID},
            UpdateExpression="SET #seq = :val",
            ExpressionAttributeNames={"#seq": "sequence"},
            ExpressionAttributeValues={":val": Decimal(str(max_seq))},
        )
        print(f"  ✓ Sequence updated: {current} → {max_seq}")
    else:
        print(f"  ✓ Sequence already up to date ({current}). No change needed.")

    print(f"\nNext new member will receive sequence {max(max_seq, current) + 1:08d}.")


if __name__ == "__main__":
    main()
