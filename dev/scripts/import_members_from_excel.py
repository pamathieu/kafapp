#!/usr/bin/env python3
"""
Import membership share data from KAFAMemberList.xlsx into DynamoDB.

For every member that has an amount in the "Part Sociale" column:
  1. Find the member in kopera-member by phone number.
  2. Write a share record to kopera-share (idempotent — skips if one with
     source='spreadsheet_import' already exists for this member).
  3. Set member status=True and clear the reason field.

Usage:
    python3 dev/scripts/import_members_from_excel.py [/path/to/KAFAMemberList.xlsx]

Default Excel path: ~/Downloads/KAFAMemberList.xlsx
"""

import sys
import os
from pathlib import Path

# Re-exec with project venv if not already in it
_venv_py = Path(__file__).resolve().parents[2] / "dev" / "venv" / "bin" / "python3"
if _venv_py.exists() and Path(sys.executable).resolve() != _venv_py.resolve():
    os.execv(str(_venv_py), [str(_venv_py)] + sys.argv)

import uuid
import datetime
import boto3
import openpyxl
from decimal import Decimal
from boto3.dynamodb.conditions import Key, Attr

EXCEL_PATH    = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.home() / "Downloads" / "KAFAMemberList.xlsx"
MEMBER_TABLE  = "kopera-member"
SHARE_TABLE   = "kopera-share"
COMPANY_ID    = "KAFA-001"

# Column indices (0-based) in the Excel sheet
COL_NAME      = 1   # B — Nom & Prénom
COL_PAYS      = 2   # C — Pays
COL_SOCIALE   = 3   # D — Part Sociale
COL_PRIV      = 4   # E — Part Privilégiée
COL_DATE      = 5   # F — Date
COL_PHONE     = 6   # G — Téléphone
COL_EMAIL     = 7   # H — Email

dynamodb = boto3.resource("dynamodb", region_name="us-east-1")
member_table = dynamodb.Table(MEMBER_TABLE)
share_table  = dynamodb.Table(SHARE_TABLE)


def _normalize_phone(raw: str) -> str:
    """Return phone stripped of spaces and dashes for comparison."""
    return raw.replace("-", "").replace(" ", "").replace(".", "")


def find_member_by_phone(phone: str):
    """Scan kopera-member for a member whose phone matches (exact or digits-only)."""
    norm = _normalize_phone(phone)
    response = member_table.scan(
        FilterExpression=Attr("companyId").eq(COMPANY_ID),
        ProjectionExpression="memberId,companyId,full_name,phone,#s,reason",
        ExpressionAttributeNames={"#s": "status"},
    )
    for item in response.get("Items", []):
        stored = item.get("phone", "")
        if stored == phone or _normalize_phone(stored) == norm:
            return item
    return None


def has_existing_share(member_id: str) -> bool:
    """Return True if a spreadsheet_import share already exists for this member."""
    response = share_table.query(
        KeyConditionExpression=Key("memberID").eq(member_id),
        FilterExpression=Attr("source").eq("spreadsheet_import"),
        Limit=1,
    )
    return len(response.get("Items", [])) > 0


def write_share(member_id: str, amount_usd: int, date_val) -> str:
    """Write a membership share record. Returns the shareId written."""
    if isinstance(date_val, (datetime.date, datetime.datetime)):
        ts = datetime.datetime.combine(
            date_val if isinstance(date_val, datetime.date) else date_val.date(),
            datetime.time.min,
            tzinfo=datetime.timezone.utc,
        ).isoformat()
    else:
        ts = datetime.datetime.now(tz=datetime.timezone.utc).isoformat()

    suffix   = uuid.uuid4().hex[:8]
    share_id = f"SHARE#{ts}#{suffix}"

    share_table.put_item(Item={
        "memberID":   member_id,
        "shareId":    share_id,
        "companyId":  COMPANY_ID,
        "share_type": "membership",
        "amount":     str(amount_usd),
        "APR":        "0",
        "status":     "SUCCEEDED",
        "datetime":   ts,
        "source":     "spreadsheet_import",
    })
    return share_id


def activate_member(member_id: str) -> None:
    """Set status=True and remove the reason attribute."""
    member_table.update_item(
        Key={"memberId": member_id, "companyId": COMPANY_ID},
        UpdateExpression="SET #s = :t REMOVE reason",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={":t": True},
    )


def main():
    if not EXCEL_PATH.exists():
        print(f"ERROR: Excel file not found: {EXCEL_PATH}")
        sys.exit(1)

    wb = openpyxl.load_workbook(str(EXCEL_PATH), data_only=True)
    ws = wb.active

    rows = list(ws.iter_rows(min_row=2, values_only=True))  # skip header
    candidates = [
        r for r in rows
        if r[COL_SOCIALE] is not None and float(r[COL_SOCIALE]) > 0
    ]

    print(f"\nKAFA Member Import — {EXCEL_PATH.name}")
    print(f"  Total rows: {len(rows)}")
    print(f"  Members with Part Sociale: {len(candidates)}")
    print(f"  Tables: {MEMBER_TABLE} / {SHARE_TABLE}")
    print("=" * 60)

    matched     = 0
    skipped_dup = 0
    shares_new  = 0
    activated   = 0
    not_found   = []

    for row in candidates:
        name   = (row[COL_NAME]   or "").strip()
        phone  = str(row[COL_PHONE] or "").strip()
        amount = int(float(row[COL_SOCIALE]))
        date_v = row[COL_DATE]

        if not phone:
            print(f"  SKIP  {name!r} — no phone number in Excel")
            continue

        member = find_member_by_phone(phone)
        if not member:
            not_found.append((name, phone))
            print(f"  NOT FOUND  {name!r} | {phone}")
            continue

        member_id = member["memberId"]
        matched += 1

        # Write share only if none exists yet
        if has_existing_share(member_id):
            skipped_dup += 1
            share_note = "share already exists"
        else:
            share_id  = write_share(member_id, amount, date_v)
            shares_new += 1
            share_note = f"share written ({share_id[:30]}...)"

        # Always ensure member is active
        already_active = member.get("status") is True
        if not already_active:
            activate_member(member_id)
            activated += 1
            status_note = "activated"
        else:
            status_note = "already active"

        print(f"  OK  {member_id} | {name!r} | ${amount} | {share_note} | {status_note}")

    print()
    print("=" * 60)
    print(f"  Matched:          {matched}")
    print(f"  New shares:       {shares_new}")
    print(f"  Duplicate shares: {skipped_dup}")
    print(f"  Activated:        {activated}")
    if not_found:
        print(f"  Not found ({len(not_found)}):")
        for name, phone in not_found:
            print(f"    {name!r} | {phone}")
    print()


if __name__ == "__main__":
    main()
