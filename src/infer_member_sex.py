"""
infer_member_sex.py — Infer member sex from name, then update DynamoDB.

Strategy:
  1. Extract the first name from full_name.
  2. Look it up in a Haitian name override dictionary first.
  3. Fall back to gender_guesser (large international/French database).
  4. If still unknown, log and skip.

Usage:
    python infer_member_sex.py               # update all members with sex=""
    python infer_member_sex.py --dry-run     # preview without writing
    python infer_member_sex.py --all         # re-infer even already-set members
    python infer_member_sex.py --member MK08100000014

Requirements:
    pip install boto3 gender-guesser
"""

import argparse
import logging
import sys

import boto3
from boto3.dynamodb.conditions import Attr
import gender_guesser.detector as gender

AWS_REGION    = "us-east-1"
MEMBERS_TABLE = "kopera-member"
COMPANY_ID    = "KAFA-001"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger(__name__)

dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION)
table    = dynamodb.Table(MEMBERS_TABLE)

# ── Haitian name overrides ────────────────────────────────────────────────────
# First names that gender_guesser doesn't know or gets wrong for Haitian usage.
HAITIAN_NAMES: dict[str, str] = {
    # Female
    "Jesimene": "Female", "Ninether": "Female", "Verlene": "Female",
    "Franchette": "Female", "Rosiny": "Female", "Marly": "Female",

    # Male
    "Olange": "Male", "Jambat": "Male", "Botlaire": "Male", "Chadly": "Male",
    "Kesner": "Male", "Rood": "Male", "Winslow": "Male",
    "Winsor": "Male", "Luckner": "Male", "Rudens": "Male",
    "Abed": "Male", "Boyer": "Male", "Reynold": "Male",
    "Nixon": "Male", "Adelson": "Male", "Claudel": "Male",
    "Rony": "Male", "Hilaire": "Male", "Israel": "Male",
    "Rodolphe": "Male", "Wilner": "Male",
}

_detector = gender.Detector(case_sensitive=False)


def infer_sex(full_name: str) -> str:
    """Return 'Male', 'Female', or '' (unknown)."""
    first = full_name.strip().split()[0] if full_name.strip() else ""
    if not first:
        return ""

    # 1. Haitian override
    override = HAITIAN_NAMES.get(first.capitalize())
    if override:
        return override

    # 2. gender_guesser
    result = _detector.get_gender(first)
    if result in ("male", "mostly_male"):
        return "Male"
    if result in ("female", "mostly_female"):
        return "Female"

    return ""   # andy / unknown


# ── DynamoDB helpers ──────────────────────────────────────────────────────────

def fetch_members(member_id: str | None, include_set: bool) -> list[dict]:
    if member_id:
        resp = table.get_item(Key={"memberId": member_id, "companyId": COMPANY_ID})
        item = resp.get("Item")
        return [item] if item else []

    items, kwargs = [], {}
    if not include_set:
        kwargs["FilterExpression"] = (
            Attr("companyId").eq(COMPANY_ID) &
            (Attr("sex").not_exists() | Attr("sex").eq(""))
        )
    else:
        kwargs["FilterExpression"] = Attr("companyId").eq(COMPANY_ID)

    while True:
        resp = table.scan(**kwargs)
        items.extend(resp.get("Items", []))
        if "LastEvaluatedKey" not in resp:
            break
        kwargs["ExclusiveStartKey"] = resp["LastEvaluatedKey"]

    return items


def save_sex(member_id: str, company_id: str, sex: str) -> None:
    table.update_item(
        Key={"memberId": member_id, "companyId": company_id},
        UpdateExpression="SET sex = :s",
        ExpressionAttributeValues={":s": sex},
    )


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Infer member sex from name")
    parser.add_argument("--dry-run", action="store_true", help="Preview without writing")
    parser.add_argument("--all",     action="store_true", help="Re-infer already-set members too")
    parser.add_argument("--member",  help="Single memberId to process")
    args = parser.parse_args()

    members = fetch_members(args.member, include_set=args.all)
    if not members:
        log.info("No members to process.")
        sys.exit(0)

    log.info("Processing %d member(s)  [dry-run=%s]", len(members), args.dry_run)

    updated = skipped = unknown = 0
    for member in members:
        name     = member.get("full_name", member["memberId"])
        inferred = infer_sex(name)
        current  = member.get("sex", "")

        if not inferred:
            log.warning("  ❓  %-35s → unknown", name)
            unknown += 1
            continue

        if inferred == current:
            log.info("  ⏭   %-35s  already %s", name, current)
            skipped += 1
            continue

        log.info("  ✅  %-35s  → %s", name, inferred)
        if not args.dry_run:
            save_sex(member["memberId"], member["companyId"], inferred)
        updated += 1

    print(f"\n{'='*52}")
    print(f"  Updated  : {updated}")
    print(f"  Skipped  : {skipped}  (already correct)")
    print(f"  Unknown  : {unknown}  (not updated — add to HAITIAN_NAMES)")
    if args.dry_run:
        print(f"  [DRY RUN — no changes written]")
    print(f"{'='*52}\n")


if __name__ == "__main__":
    main()
