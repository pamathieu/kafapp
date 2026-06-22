"""
generate_certificates.py — Local KAFA Certificate Batch Generator

For each member in kopera-member:
  1. Fetch member record from DynamoDB
  2. Fetch company record from DynamoDB
  3. Render PDF certificate (reportlab)
  4. Convert to JPEG (pdf2image / Pillow fallback)
  5. Upload PDF + JPEG to kopera-certificate S3 bucket
  6. Update member record in DynamoDB with certificate metadata

Usage:
    python generate_certificates.py                        # all members
    python generate_certificates.py --member MBR-001      # single member
    python generate_certificates.py --dry-run             # preview only
    python generate_certificates.py --company KAFA-001    # all members of a company

Requirements:
    pip install boto3 reportlab Pillow pdf2image
    poppler must be installed for pdf2image:
        macOS:   brew install poppler
        Ubuntu:  apt-get install poppler-utils
"""

import argparse
import io
import json
import os
import sys
import uuid
import logging
from datetime import datetime, timezone

import boto3
from boto3.dynamodb.conditions import Key


################################################################################
# Config
################################################################################

AWS_REGION     = "us-east-1"
MEMBERS_TABLE  = "kopera-member"
COMPANIES_TABLE= "kopera-company"
CERTS_BUCKET   = "kopera-certificate"
COMPANY_ID     = "KAFA-001"         # default company
LOCAL_LOGO     = os.path.join(os.path.dirname(os.path.abspath(__file__)), "kafa_logo.png")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger(__name__)

################################################################################
# AWS clients
################################################################################

dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION)
s3       = boto3.client("s3",        region_name=AWS_REGION)

members_table  = dynamodb.Table(MEMBERS_TABLE)
companies_table= dynamodb.Table(COMPANIES_TABLE)

################################################################################
# DynamoDB helpers
################################################################################

def get_all_members(company_id: str) -> list[dict]:
    """Scan kopera-member for all members belonging to company_id."""
    resp  = members_table.query(
        IndexName="CompanyMembersIndex",
        KeyConditionExpression=Key("companyId").eq(company_id),
    )
    items = resp.get("Items", [])

    # Handle pagination
    while "LastEvaluatedKey" in resp:
        resp  = members_table.query(
            IndexName="CompanyMembersIndex",
            KeyConditionExpression=Key("companyId").eq(company_id),
            ExclusiveStartKey=resp["LastEvaluatedKey"],
        )
        items += resp.get("Items", [])

    log.info("Fetched %d members for company %s", len(items), company_id)
    return items


def get_member(member_id: str, company_id: str) -> dict | None:
    resp = members_table.get_item(Key={"memberId": member_id, "companyId": company_id})
    return resp.get("Item")


def get_company(company_id: str) -> dict | None:
    resp = companies_table.get_item(Key={"companyId": company_id})
    return resp.get("Item")


def save_certificate(member_id: str, company_id: str, cert: dict) -> None:
    members_table.update_item(
        Key={"memberId": member_id, "companyId": company_id},
        UpdateExpression="SET certificate = :c, issued_date = :d",
        ExpressionAttributeValues={
            ":c": cert,
            ":d": cert["issued_date"],
        },
    )

################################################################################
# S3 helpers
################################################################################

def upload(data: bytes, key: str, content_type: str) -> str:
    s3.put_object(
        Bucket      = CERTS_BUCKET,
        Key         = key,
        Body        = data,
        ContentType = content_type,
    )
    return f"s3://{CERTS_BUCKET}/{key}"


def fetch_logo(s3_path: str) -> io.BytesIO | None:
    """Download logo from S3 and return as BytesIO; falls back to local kafa_logo.png."""
    if s3_path and s3_path.startswith("s3://"):
        try:
            without_prefix = s3_path[len("s3://"):]
            bucket, _, key = without_prefix.partition("/")
            resp = s3.get_object(Bucket=bucket, Key=key)
            return io.BytesIO(resp["Body"].read())
        except Exception as exc:
            log.warning("Could not fetch logo from %s: %s — falling back to local", s3_path, exc)
    if os.path.exists(LOCAL_LOGO):
        with open(LOCAL_LOGO, "rb") as f:
            return io.BytesIO(f.read())
    return None

################################################################################
# PDF / JPEG generation — imported from certificate_engine (single source of truth)
################################################################################

# Add project root to path so certificate_engine can be found
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from certificate_engine import generate_pdf, generate_jpeg  # noqa: E402

def delete_old_certificates(member: dict) -> None:
    """Delete existing PDF and JPEG from S3 if they exist."""
    cert = member.get("certificate")
    if not cert:
        return
    for url_key in ("pdf_s3_url", "jpeg_s3_url"):
        s3_url = cert.get(url_key, "")
        if s3_url and s3_url.startswith("s3://"):
            without_prefix = s3_url[len("s3://"):]
            bucket, _, key = without_prefix.partition("/")
            try:
                s3.delete_object(Bucket=bucket, Key=key)
                log.info("  🗑  Deleted old file: %s", key)
            except Exception as exc:
                log.warning("  Could not delete %s: %s", s3_url, exc)


def _is_active(member: dict) -> bool:
    v = member.get("status", True)
    if isinstance(v, bool):
        return v
    return str(v).lower() == "true"


def process_member(member: dict, company: dict, dry_run: bool) -> bool:
    member_id  = member["memberId"]
    company_id = member["companyId"]
    name       = member.get("full_name", member_id)

    # Skip inactive members
    if not _is_active(member):
        log.info("  ⏭  %-30s inactive — skipping", name)
        return True

    # Skip if certificate already exists
    if member.get("certificate"):
        log.info("  ⏭  %-30s already has a certificate — skipping", name)
        return True

    certificate_id = f"CERT-{uuid.uuid4().hex[:8].upper()}"
    issued_date    = datetime.now(timezone.utc).strftime("%d / %m / %Y")
    timestamp      = datetime.now(timezone.utc).isoformat()

    if dry_run:
        log.info("  [DRY RUN] %-30s → %s", name, certificate_id)
        return True

    try:
        # Delete old files from S3 first
        delete_old_certificates(member)

        # Generate files
        pdf_bytes  = generate_pdf(member, company, certificate_id, issued_date)
        jpeg_bytes = generate_jpeg(pdf_bytes)

        # Upload to kopera-certificate
        prefix      = f"certificates/{company_id}/{member_id}/{certificate_id}"
        pdf_url     = upload(pdf_bytes,  f"{prefix}.pdf",  "application/pdf")
        jpeg_url    = upload(jpeg_bytes, f"{prefix}.jpeg", "image/jpeg")

        # Update DynamoDB
        cert_record = {
            "certificate_id": certificate_id,
            "issued_date":    issued_date,
            "pdf_s3_url":     pdf_url,
            "jpeg_s3_url":    jpeg_url,
            "whatsapp_sent":  False,
            "timestamp":      timestamp,
        }
        save_certificate(member_id, company_id, cert_record)

        log.info("  ✅  %-30s → %s", name, certificate_id)
        return True

    except Exception as exc:
        log.error("  ❌  %-30s → %s", name, exc)
        return False

################################################################################
# Main
################################################################################

def main():
    parser = argparse.ArgumentParser(description="Batch generate KAFA certificates")
    parser.add_argument("--member",  help="Generate for a single memberId only")
    parser.add_argument("--company", default=COMPANY_ID, help="companyId (default: KAFA-001)")
    parser.add_argument("--dry-run", action="store_true", help="Preview without writing anything")
    parser.add_argument("--force",   action="store_true", help="Regenerate even if certificate already exists")
    args = parser.parse_args()

    print(f"\n{'='*58}")
    print(f"  KAFA Certificate Batch Generator")
    print(f"  Company : {args.company}")
    print(f"  Mode    : {'DRY RUN' if args.dry_run else 'LIVE'}")
    if args.member:
        print(f"  Member  : {args.member}")
    print(f"{'='*58}\n")

    # Fetch company record
    company = get_company(args.company)
    if not company:
        log.error("Company '%s' not found in %s. Add it first.", args.company, COMPANIES_TABLE)
        sys.exit(1)
    log.info("Company loaded: %s", company.get("name", args.company))

    # Fetch members
    if args.member:
        member = get_member(args.member, args.company)
        if not member:
            log.error("Member '%s' not found.", args.member)
            sys.exit(1)
        members = [member]
    else:
        members = get_all_members(args.company)

    if not members:
        log.warning("No members found. Exiting.")
        sys.exit(0)

    # Only process active members
    all_count = len(members)
    members = [m for m in members if _is_active(m)]
    inactive = all_count - len(members)
    if inactive:
        log.info("Skipping %d inactive member(s).", inactive)

    if not members:
        log.warning("No active members found. Exiting.")
        sys.exit(0)

    # If --force, clear existing certificate so it gets regenerated
    if args.force:
        for m in members:
            m.pop("certificate", None)

    print(f"Processing {len(members)} member(s)...\n")

    success = 0
    skipped = 0
    failed  = 0

    for member in members:
        # Count skips before processing
        already_done = bool(member.get("certificate")) and not args.force
        result = process_member(member, company, dry_run=args.dry_run)
        if already_done:
            skipped += 1
        elif result:
            success += 1
        else:
            failed += 1

    print(f"\n{'='*58}")
    print(f"  Done")
    print(f"  ✅  Generated : {success}")
    print(f"  ⏭   Skipped   : {skipped}  (already had certificates)")
    print(f"  ❌  Failed    : {failed}")
    print(f"{'='*58}\n")

    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()