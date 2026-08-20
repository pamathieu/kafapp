#!/usr/bin/env python3
"""
Check the TTL/expiry status of member password setup links.

With --member, looks up a single member by memberId, email, or phone.
Without it, scans every member in the table and reports each one's
setup-link status, with a summary tally at the end.

Usage:
    python3 dev/scripts/check_setup_link_ttl.py --member MK00100000069
    python3 dev/scripts/check_setup_link_ttl.py --member nithou03@yahoo.com --env prod
    python3 dev/scripts/check_setup_link_ttl.py --env prod
    python3 dev/scripts/check_setup_link_ttl.py --env prod --expired-only
"""

import sys
import os
import re
import argparse
from pathlib import Path
from datetime import datetime, timezone

# Re-exec with project venv if not already in it
_venv_py = Path(__file__).resolve().parents[2] / "dev" / "venv" / "bin" / "python3"
if _venv_py.exists() and Path(sys.executable).resolve() != _venv_py.resolve():
    os.execv(str(_venv_py), [str(_venv_py)] + sys.argv)

import boto3
from boto3.dynamodb.conditions import Attr

TABLE_BY_ENV = {
    "dev":  "kopera-member-dev",
    "prod": "kopera-member",
}

dynamodb = boto3.resource("dynamodb", region_name="us-east-1")


def find_member(table_name: str, identifier: str) -> dict | None:
    table = dynamodb.Table(table_name)

    # Exact memberId match (fast path — it's the partition key)
    resp = table.scan(FilterExpression=Attr("memberId").eq(identifier))
    if resp.get("Items"):
        return resp["Items"][0]

    # Email match
    resp = table.scan(FilterExpression=Attr("email").eq(identifier))
    if resp.get("Items"):
        return resp["Items"][0]

    # Phone match — normalize by stripping non-digits
    digits = re.sub(r"\D", "", identifier)
    if digits:
        scan_kwargs: dict = {}
        while True:
            resp = table.scan(**scan_kwargs)
            for item in resp.get("Items", []):
                stored = re.sub(r"\D", "", item.get("phone", "") or "")
                if stored and stored == digits:
                    return item
            if "LastEvaluatedKey" not in resp:
                break
            scan_kwargs["ExclusiveStartKey"] = resp["LastEvaluatedKey"]

    return None


def scan_all_members(table_name: str) -> list[dict]:
    table   = dynamodb.Table(table_name)
    items   = []
    kwargs: dict = {}
    while True:
        resp = table.scan(**kwargs)
        items.extend(resp.get("Items", []))
        if "LastEvaluatedKey" not in resp:
            break
        kwargs["ExclusiveStartKey"] = resp["LastEvaluatedKey"]
    return items


def format_delta(target: datetime, now: datetime) -> str:
    delta = target - now
    total_seconds = abs(int(delta.total_seconds()))
    hours, remainder = divmod(total_seconds, 3600)
    minutes = remainder // 60
    return f"{hours}h {minutes}m"


def evaluate_member(member: dict, now: datetime) -> dict:
    """Return {status, detail} for one member's setup token.
    status is one of: 'valid', 'expired', 'unrecorded', 'none'."""
    token      = member.get("setupToken")
    expiry_str = member.get("setupTokenExpiry")

    if not token:
        return {"status": "none", "detail": "no setup token on file"}

    if not expiry_str:
        return {"status": "unrecorded", "detail": "token present but no expiry recorded"}

    try:
        expiry = datetime.fromisoformat(expiry_str)
    except ValueError:
        return {"status": "unrecorded", "detail": f"unparseable expiry: {expiry_str!r}"}

    if expiry > now:
        return {"status": "valid", "detail": f"expires in {format_delta(expiry, now)}"}
    return {"status": "expired", "detail": f"expired {format_delta(expiry, now)} ago"}


def print_single(member: dict, now: datetime) -> None:
    member_id = member.get("memberId", "?")
    name      = member.get("full_name", "?")
    email     = member.get("email", "")
    phone     = member.get("phone", "")

    print(f"  Member:  {name}  ({member_id})")
    if email: print(f"  Email:   {email}")
    if phone: print(f"  Phone:   {phone}")
    print()

    token = member.get("setupToken")
    result = evaluate_member(member, now)

    if result["status"] == "none":
        print("  Setup token: none on file")
        return

    masked = token[:4] + "…" + token[-4:] if len(token) > 8 else token
    print(f"  Setup token: {masked}  ({len(token)} chars)")
    print(f"  Expiry:      {member.get('setupTokenExpiry')}")

    icon = {"valid": "✓ VALID", "expired": "✗ EXPIRED", "unrecorded": "? UNKNOWN"}[result["status"]]
    print(f"  Status:      {icon} — {result['detail']}")
    print()


def print_bulk(members: list[dict], now: datetime, expired_only: bool) -> None:
    tally = {"valid": 0, "expired": 0, "unrecorded": 0, "none": 0}
    rows  = []

    for member in members:
        result = evaluate_member(member, now)
        tally[result["status"]] += 1
        if expired_only and result["status"] not in ("expired", "unrecorded"):
            continue
        rows.append((
            member.get("memberId", "?"),
            (member.get("full_name") or "?")[:28],
            result["status"],
            result["detail"],
        ))

    header = f"  {'Member ID':<15} {'Name':<28} {'Status':<10} Detail"
    print(header)
    print("  " + "-" * (len(header) - 2))
    for member_id, name, status, detail in rows:
        marker = {"valid": "✓", "expired": "✗", "unrecorded": "?", "none": "—"}[status]
        print(f"  {member_id:<15} {name:<28} {marker} {status:<8} {detail}")

    print()
    print("=" * 60)
    print(f"  Total members:        {len(members)}")
    print(f"  Valid setup link:     {tally['valid']}")
    print(f"  Expired setup link:   {tally['expired']}")
    print(f"  Unrecorded/malformed: {tally['unrecorded']}")
    print(f"  No setup token:       {tally['none']}")
    print()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--member", default=None,
                        help="memberId, email, or phone number to look up. Omit to check every member.")
    parser.add_argument("--env", choices=["dev", "prod"], default="dev",
                        help="Which member table to check (default: dev)")
    parser.add_argument("--expired-only", action="store_true",
                        help="In bulk mode, only list members with an expired or unrecorded token")
    args = parser.parse_args()

    table_name = TABLE_BY_ENV[args.env]
    now = datetime.now(timezone.utc)

    print(f"\nChecking setup-link TTL — env={args.env}  table={table_name}")
    print("=" * 60)

    if args.member:
        member = find_member(table_name, args.member)
        if not member:
            print(f"No member found matching '{args.member}'")
            sys.exit(1)
        print_single(member, now)
    else:
        members = scan_all_members(table_name)
        print_bulk(members, now, args.expired_only)


if __name__ == "__main__":
    main()
