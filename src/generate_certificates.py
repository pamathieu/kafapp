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
import sys
import uuid
import logging
from datetime import datetime, timezone

import boto3
from boto3.dynamodb.conditions import Key

from reportlab.lib.pagesizes import A4
from reportlab.lib.units import cm
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.enums import TA_CENTER, TA_LEFT, TA_JUSTIFY
from reportlab.lib import colors
from reportlab.platypus import (
    SimpleDocTemplate, Paragraph, Spacer,
    HRFlowable, Table, TableStyle,
)
from PIL import Image

################################################################################
# Config
################################################################################

AWS_REGION     = "us-east-1"
MEMBERS_TABLE  = "kopera-member"
COMPANIES_TABLE= "kopera-company"
CERTS_BUCKET   = "kopera-certificate"
COMPANY_ID     = "KAFA-001"         # default company

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

################################################################################
# PDF generation — exact KAFA certificate template
################################################################################

def generate_pdf(member: dict, company: dict, certificate_id: str, issued_date: str) -> bytes:
    buf = io.BytesIO()
    doc = SimpleDocTemplate(
        buf, pagesize=A4,
        leftMargin=2.8*cm, rightMargin=2.8*cm,
        topMargin=2.2*cm,  bottomMargin=2.2*cm,
    )

    DARK   = colors.HexColor("#0d1b2a")
    MID    = colors.HexColor("#1b3a5c")
    ACCENT = colors.HexColor("#c8a96e")
    GREY   = colors.HexColor("#5a6a7a")
    RULE   = colors.HexColor("#d0d8e0")

    def S(name, **kw):
        base = dict(fontName="Helvetica", textColor=DARK, leading=14)
        base.update(kw)
        return ParagraphStyle(name, **base)

    s = {
        "org":     S("org",     fontSize=7,  textColor=GREY, alignment=TA_CENTER),
        "title":   S("title",   fontSize=20, fontName="Helvetica-Bold", alignment=TA_CENTER, spaceBefore=4, spaceAfter=2),
        "sub":     S("sub",     fontSize=10, textColor=MID,  alignment=TA_CENTER, spaceAfter=6),
        "intro":   S("intro",   fontSize=10, alignment=TA_JUSTIFY, spaceAfter=10),
        "label":   S("label",   fontSize=9,  fontName="Helvetica-Bold", textColor=MID, alignment=TA_LEFT),
        "value":   S("value",   fontSize=11, alignment=TA_LEFT, spaceAfter=4),
        "sec":     S("sec",     fontSize=11, fontName="Helvetica-Bold", alignment=TA_CENTER, spaceBefore=8, spaceAfter=4),
        "bbold":   S("bbold",   fontSize=10, fontName="Helvetica-Bold", alignment=TA_JUSTIFY, spaceAfter=6),
        "bnorm":   S("bnorm",   fontSize=10, alignment=TA_JUSTIFY, spaceAfter=6),
        "signame": S("signame", fontSize=10, fontName="Helvetica-Bold", alignment=TA_CENTER),
        "sigtit":  S("sigtit",  fontSize=9,  textColor=GREY, alignment=TA_CENTER),
        "footer":  S("footer",  fontSize=8,  textColor=GREY, alignment=TA_CENTER),
        "seal":    S("seal",    fontSize=8,  textColor=colors.HexColor("#aabbcc"), alignment=TA_CENTER),
    }

    def rule(thick=1, color=ACCENT, **kw):
        return HRFlowable(width="100%", thickness=thick, color=color, **kw)

    def field(label, value):
        story.extend([
            Paragraph(label, s["label"]),
            Paragraph(value,  s["value"]),
            rule(thick=0.5, color=RULE, spaceAfter=6),
        ])

    def fmt_date(raw: str) -> str:
        if not raw:
            return "____ / ____ / ______"
        try:
            return datetime.strptime(str(raw)[:10], "%Y-%m-%d").strftime("%d / %m / %Y")
        except ValueError:
            return str(raw)

    # Company fields
    co_name   = company.get("name",                "Koperativ Asirans Fòs Ayiti (KAFA)")
    co_reg    = company.get("registration_number", "___________________")
    co_siege  = company.get("siege_social",        "Léogâne, Haiti")
    co_phone  = company.get("phone",               "")
    co_email  = company.get("email",               "")
    co_web    = company.get("website",             "")
    co_city   = company.get("city",                "Leogane")
    co_ctry   = company.get("country",             "Haiti")
    sec_name  = company.get("secretary_name",      "Verlène REBECCA")
    sec_title = company.get("secretary_title",     "Secretaire du Conseil d'Administration")
    dir_name  = company.get("director_name",       "Jean René AMY")
    dir_title = company.get("director_title",      "Directeur Exécutif")

    # Member fields
    m_name  = member.get("full_name",    "___________________________")
    m_dob   = fmt_date(member.get("date_of_birth", ""))
    m_id    = member.get("id_number",   "___________________________")
    m_type  = member.get("id_type",     "_______________")
    m_addr  = member.get("address",     "___________________________")
    m_num   = member.get("memberId",    "___________________________")
    m_dom   = fmt_date(member.get("issued_date", issued_date))

    story = []

    # Header
    org_parts = [x for x in [
        f"Siège Social : {co_siege}" if co_siege else "",
        f"Tél : {co_phone}"          if co_phone else "",
        f"Email : {co_email}"        if co_email else "",
        f"Web : {co_web}"            if co_web   else "",
    ] if x]

    if org_parts:
        story += [Paragraph("  |  ".join(org_parts), s["org"]), Spacer(1, 0.3*cm)]

    story += [
        rule(thick=3, spaceAfter=6),
        Paragraph(co_name.upper(), s["title"]),
        Paragraph("CERTIFICAT OFFICIEL D'ADHÉSION", s["sub"]),
        rule(thick=3, spaceBefore=4, spaceAfter=12),
        Paragraph(
            f"La <b>{co_name}</b>, constituée conformément aux lois de la République d'Ayiti "
            f"et régulièrement enregistrée sous le numéro <b>{co_reg}</b>, certifie que :",
            s["intro"],
        ),
    ]

    field("Nom et Prénom :",         m_name)
    field("Date de naissance :",     m_dob)
    field("No Identification :",     f"{m_id}    Type : {m_type}")
    field("Adresse :",               m_addr)
    field("Numéro d'adhérent :",     m_num)
    field("Date d'adhésion :",       m_dom)

    story.append(Spacer(1, 0.4*cm))

    story += [
        rule(spaceAfter=6),
        Paragraph("STATUT DU MEMBRE", s["sec"]),
        rule(spaceAfter=8),
        Paragraph(
            "Le titulaire du présent certificat est reconnu comme "
            "<b>Membre Fondateur (Actif)</b> de KAFA, et a ce titre, il/elle bénéficie des droits, "
            "privilèges et garanties prévues par les statuts de la coopérative ainsi que par les "
            "programmes offerts aux membres, conformément aux règlements internes en vigueur.",
            s["bbold"],
        ),
        Paragraph(
            "Le présent certificat constitue une preuve officielle d'adhésion et peut être présenté "
            "à toute autorité, institution ou organisme pour confirmation de statut du membre "
            "au sein de la coopérative.",
            s["bnorm"],
        ),
        Spacer(1, 0.5*cm),
        rule(spaceAfter=8),
        Paragraph("SIGNATURES AUTORISÉES", s["sec"]),
        Spacer(1, 0.2*cm),
        Paragraph(f"Fait à {co_city}, {co_ctry}, le {issued_date}", s["intro"]),
        Spacer(1, 0.8*cm),
    ]

    sig_table = Table(
        [
            [Paragraph("_"*38, s["signame"]),              Paragraph("_"*38, s["signame"])],
            [Paragraph(f"<b>{sec_name}</b>", s["signame"]),Paragraph(f"<b>{dir_name}</b>", s["signame"])],
            [Paragraph(sec_title, s["sigtit"]),            Paragraph(dir_title, s["sigtit"])],
        ],
        colWidths=["50%", "50%"],
    )
    sig_table.setStyle(TableStyle([
        ("ALIGN",         (0,0), (-1,-1), "CENTER"),
        ("VALIGN",        (0,0), (-1,-1), "TOP"),
        ("TOPPADDING",    (0,0), (-1,-1), 3),
        ("BOTTOMPADDING", (0,0), (-1,-1), 3),
    ]))

    story += [
        sig_table,
        Spacer(1, 0.5*cm),
        Paragraph("[SCEAU OFFICIEL]", s["seal"]),
        Spacer(1, 0.3*cm),
        rule(thick=2, spaceAfter=4),
        Paragraph(f"Certificat ID : {certificate_id}", s["footer"]),
    ]

    doc.build(story)
    return buf.getvalue()

################################################################################
# JPEG generation
################################################################################

def generate_jpeg(pdf_bytes: bytes) -> bytes:
    try:
        from pdf2image import convert_from_bytes
        imgs = convert_from_bytes(pdf_bytes, dpi=150, first_page=1, last_page=1)
        buf  = io.BytesIO()
        imgs[0].convert("RGB").save(buf, format="JPEG", quality=90)
        return buf.getvalue()
    except Exception as exc:
        log.warning("pdf2image failed (%s) — using Pillow placeholder. "
                    "Install poppler to generate real JPEGs.", exc)
        buf = io.BytesIO()
        Image.new("RGB", (794, 1123), color=(245, 240, 232)).save(buf, format="JPEG", quality=90)
        return buf.getvalue()

################################################################################
# Certificate pipeline for a single member
################################################################################

def process_member(member: dict, company: dict, dry_run: bool) -> bool:
    member_id  = member["memberId"]
    company_id = member["companyId"]
    name       = member.get("full_name", member_id)

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
