"""
backfill_missing_emails.py — Set placeholder email on members with no email in DynamoDB

Usage:
    python backfill_missing_emails.py                    # targets kopera-member (prod)
    python backfill_missing_emails.py --table kopera-member-dev
    python backfill_missing_emails.py --dry-run          # preview without writing
"""

import argparse
import boto3
from boto3.dynamodb.conditions import Attr

TABLE_NAME        = "kopera-member"
AWS_REGION        = "us-east-1"
PLACEHOLDER_EMAIL = "noemail@kafayiti.com"


def scan_missing_emails(table) -> list[dict]:
    """Return all members whose email attribute is absent or empty."""
    items = []
    kwargs = {
        "FilterExpression": Attr("email").not_exists() | Attr("email").eq("")
    }
    while True:
        resp = table.scan(**kwargs)
        items.extend(resp.get("Items", []))
        last = resp.get("LastEvaluatedKey")
        if not last:
            break
        kwargs["ExclusiveStartKey"] = last
    return items


def backfill(table, items: list[dict], dry_run: bool) -> tuple[int, int]:
    success, errors = 0, 0
    for item in items:
        member_id  = item.get("memberId", "?")
        company_id = item.get("companyId", "?")
        full_name  = item.get("full_name", "—")
        if dry_run:
            print(f"  [DRY RUN] Would set email on {member_id} ({full_name})")
            success += 1
            continue
        try:
            table.update_item(
                Key={"memberId": member_id, "companyId": company_id},
                UpdateExpression="SET email = :e",
                ExpressionAttributeValues={":e": PLACEHOLDER_EMAIL},
            )
            print(f"  ✅ {member_id} ({full_name})")
            success += 1
        except Exception as exc:
            print(f"  ❌ {member_id}: {exc}")
            errors += 1
    return success, errors


def main():
    parser = argparse.ArgumentParser(description="Backfill placeholder email for members with no email")
    parser.add_argument("--table",   default=TABLE_NAME, help="DynamoDB table name")
    parser.add_argument("--region",  default=AWS_REGION, help="AWS region")
    parser.add_argument("--dry-run", action="store_true", help="Preview without writing")
    args = parser.parse_args()

    print(f"\n{'='*55}")
    print(f"  KAFA Email Backfill")
    print(f"  Table  : {args.table}")
    print(f"  Mode   : {'DRY RUN' if args.dry_run else 'LIVE'}")
    print(f"{'='*55}\n")

    dynamodb = boto3.resource("dynamodb", region_name=args.region)
    table    = dynamodb.Table(args.table)

    print("🔍 Scanning for members with no email ...")
    items = scan_missing_emails(table)
    print(f"   Found {len(items)} member(s) missing an email\n")

    if not items:
        print("Nothing to update.")
        return

    if not args.dry_run:
        confirm = input(f"⚠️  About to update {len(items)} records in '{args.table}'. Proceed? [y/N]: ")
        if confirm.strip().lower() != "y":
            print("Aborted.")
            return

    success, errors = backfill(table, items, dry_run=args.dry_run)

    print(f"\n{'='*55}")
    print(f"  ✅ Updated : {success}")
    print(f"  ❌ Errors  : {errors}")
    print(f"{'='*55}\n")


if __name__ == "__main__":
    main()
