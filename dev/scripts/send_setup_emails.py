#!/usr/bin/env python3
"""
Send password setup emails to all members that have an email address.

For each member with a valid email:
  1. Generate a secure 200-char URL-safe setup token.
  2. Store the token + 24-hour expiry on the member record.
  3. Send a branded SES email with a "Set Up Password" button.

Usage:
    # Dry run against dev table (safe — prints links, touches nothing):
    python3 dev/scripts/send_setup_emails.py --dry-run

    # Test for real against the DEV table (kopera-member-dev):
    python3 dev/scripts/send_setup_emails.py --env dev

    # Send to all members in the PROD table (kopera-member):
    python3 dev/scripts/send_setup_emails.py --env prod
"""

import sys
import os
import argparse
import secrets
from pathlib import Path
from datetime import datetime, timezone, timedelta

# Re-exec with project venv if not already in it
_venv_py = Path(__file__).resolve().parents[2] / "dev" / "venv" / "bin" / "python3"
if _venv_py.exists() and Path(sys.executable).resolve() != _venv_py.resolve():
    os.execv(str(_venv_py), [str(_venv_py)] + sys.argv)

import boto3
from boto3.dynamodb.conditions import Attr

# ── Config ────────────────────────────────────────────────────────────────────

TABLE_BY_ENV = {
    "dev":  "kopera-member-dev",
    "prod": "kopera-member",
}
PORTAL_URL   = "https://member.kafayiti.com"
COMPANY_ID   = "KAFA-001"
SES_SOURCE   = "KAFA <noreply@kafayiti.com>"
SES_REGION   = "us-east-1"

# ── AWS clients ───────────────────────────────────────────────────────────────

dynamodb = boto3.resource("dynamodb", region_name="us-east-1")
ses      = boto3.client("ses",        region_name=SES_REGION)

# ── Helpers ───────────────────────────────────────────────────────────────────

def scan_members(table_name: str) -> list[dict]:
    table    = dynamodb.Table(table_name)
    response = table.scan(
        FilterExpression=Attr("companyId").eq(COMPANY_ID),
        ProjectionExpression=(
            "memberId,companyId,full_name,email,#s,setupToken"
        ),
        ExpressionAttributeNames={"#s": "status"},
    )
    return response.get("Items", [])


def has_valid_email(member: dict) -> bool:
    email = (member.get("email") or "").strip()
    return bool(email) and "@" in email


def store_token(table_name: str, member: dict, token: str, expiry: str, dry_run: bool) -> None:
    if dry_run:
        return
    table = dynamodb.Table(table_name)
    table.update_item(
        Key={"memberId": member["memberId"], "companyId": member.get("companyId", COMPANY_ID)},
        UpdateExpression="SET setupToken = :t, setupTokenExpiry = :e",
        ExpressionAttributeValues={":t": token, ":e": expiry},
    )


def build_email_html(name: str, link: str) -> str:
    return f"""
    <div style="font-family:sans-serif;max-width:600px;margin:0 auto">
      <div style="background:#1a5c2e;padding:24px 32px;text-align:center">
        <h1 style="color:#fff;margin:0;font-size:22px">KAFA — Kooperativ Asirans Fòs Ayiti</h1>
      </div>
      <div style="padding:32px;background:#fff">
        <h2 style="color:#1a5c2e;margin-top:0">Création de votre mot de passe</h2>
        <p>Bonjour {name},</p>
        <p>Un administrateur KAFA a configuré l'accès au portail pour votre compte membre.
           Cliquez sur le bouton ci-dessous pour créer votre mot de passe.
           <strong>Ce lien expire dans 24 heures.</strong></p>
        <div style="text-align:center;margin:32px 0">
          <a href="{link}"
             style="background:#1a5c2e;color:#fff;padding:14px 32px;border-radius:6px;
                    text-decoration:none;font-weight:bold;font-size:16px;display:inline-block">
            Créer mon mot de passe
          </a>
        </div>
        <p style="color:#888;font-size:13px">
          Si vous n'attendiez pas cet e-mail, vous pouvez l'ignorer. Votre compte reste sécurisé.
        </p>
        <p>Des questions ? Contactez-nous à
          <a href="mailto:info@kafayiti.com" style="color:#1a5c2e">info@kafayiti.com</a>
          ou appelez le (509) 3500-0326.
        </p>
      </div>
      <div style="background:#f0f0f0;padding:16px 32px;text-align:center;font-size:12px;color:#888">
        KAFA — 874 Rue Ste Catherine, Léogâne, Haïti
      </div>
    </div>"""


def send_email(member: dict, link: str, dry_run: bool) -> bool:
    """Send setup email. Returns True on success."""
    email = member["email"].strip()
    name  = (member.get("full_name") or "Member").strip()
    html  = build_email_html(name, link)

    if dry_run:
        return True

    try:
        ses.send_email(
            Source=SES_SOURCE,
            Destination={
                "ToAddresses": [email],
                "CcAddresses": ["winsor.netsurance@gmail.com"],
            },
            Message={
                "Subject": {"Data": "KAFA — Création de votre mot de passe"},
                "Body":    {"Html": {"Data": html}},
            },
        )
        return True
    except Exception as exc:
        print(f"    ERROR sending email: {exc}")
        return False


def process_member(table_name: str, member: dict, dry_run: bool) -> dict:
    token  = secrets.token_urlsafe(7)   # 10 URL-safe chars
    expiry = (datetime.now(timezone.utc) + timedelta(hours=24)).isoformat()
    link   = f"{PORTAL_URL}?setup={token}"

    store_token(table_name, member, token, expiry, dry_run)
    sent = send_email(member, link, dry_run)

    return {"link": link, "sent": sent}


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--env",     choices=["dev", "prod"], default="dev",
                        help="Which member table to use (default: dev)")
    parser.add_argument("--dry-run", action="store_true",
                        help="Print what would happen without storing tokens or sending emails")
    args = parser.parse_args()

    table_name = TABLE_BY_ENV[args.env]
    dry_tag    = "  [DRY RUN]" if args.dry_run else ""

    print(f"\nKAFA — Send Password Setup Emails{dry_tag}")
    print(f"  Environment:  {args.env}")
    print(f"  Table:        {table_name}")
    print(f"  Portal URL:   {PORTAL_URL}")
    print("=" * 60)

    members    = scan_members(table_name)
    eligible   = [m for m in members if has_valid_email(m)]
    skipped    = len(members) - len(eligible)

    print(f"  Total members:     {len(members)}")
    print(f"  With email:        {len(eligible)}")
    print(f"  Without email:     {skipped}")
    print()

    sent_ok  = 0
    sent_err = 0

    for member in eligible:
        mid   = member["memberId"]
        email = member["email"].strip()
        name  = (member.get("full_name") or "?").strip()

        result = process_member(table_name, member, args.dry_run)

        status = "SENT" if result["sent"] else "ERROR"
        if args.dry_run:
            status = "DRY"

        if result["sent"] or args.dry_run:
            sent_ok += 1
        else:
            sent_err += 1

        print(f"  [{status}]  {mid} | {name} | {email}")
        if args.dry_run or not result["sent"]:
            print(f"          Setup link: {result['link']}")

    print()
    print("=" * 60)
    if args.dry_run:
        print(f"  Would send: {sent_ok}  |  Skipped (no email): {skipped}")
    else:
        print(f"  Sent OK:  {sent_ok}  |  Errors: {sent_err}  |  Skipped (no email): {skipped}")
    print()


if __name__ == "__main__":
    main()
