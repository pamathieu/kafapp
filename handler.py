"""
handler.py — KAFA Certificate Lookup Lambda

Triggered by API Gateway  GET /lookup?phone=561-303-4161

Flow:
  1. Receive phone number from query string
  2. Scan kopera-member table for a member matching that phone number
  3. Call GET /members via certplatform-prod-api (SigV4-signed) to confirm
     the record and pull full member data
  4. Read certificate metadata from the member record
  5. Verify both S3 objects (PDF + JPEG) exist in kopera-certificate
  6. Return the two S3 URLs

Route map (this Lambda handles all routes):
  GET  /lookup?phone=          → find member by phone, return certificate S3 links
  GET  /members?memberId=&companyId=   → read member from DynamoDB
  GET  /companies?companyId=           → read company from DynamoDB
  POST /members                        → upsert member
  POST /companies                      → upsert company
  POST /certificates                   → generate certificate (existing flow)
  GET  /certificates/{certificateId}   → return certificate metadata
"""

import os
import re
import json
import logging
import hashlib
import secrets
import boto3
import requests
from boto3.dynamodb.conditions import Attr
from decimal import Decimal
from datetime import datetime, timezone, timedelta
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest

################################################################################
# Bootstrap
################################################################################

logger = logging.getLogger()
logger.setLevel(logging.ERROR)

_session  = boto3.session.Session()
dynamodb  = boto3.resource("dynamodb")
s3_client = boto3.client("s3")
ses       = boto3.client("ses", region_name="us-east-1")

def _log_error(context_label: str, error: Exception, extra: dict = None):
    """Write error as a JSON file to kopera-asset/logs/errors/YYYY-MM-DD/."""
    try:
        now = datetime.now(timezone.utc)
        payload = {
            "timestamp": now.isoformat(),
            "function":  os.environ.get("AWS_LAMBDA_FUNCTION_NAME", "handler"),
            "context":   context_label,
            "error":     str(error),
            "type":      type(error).__name__,
            **(extra or {}),
        }
        key = f"logs/errors/{now.strftime('%Y-%m-%d')}/{now.strftime('%H-%M-%S-%f')}_{context_label[:40]}.json"
        s3_client.put_object(
            Bucket=ASSETS_BUCKET,
            Key=key,
            Body=json.dumps(payload, indent=2),
            ContentType="application/json",
        )
    except Exception:
        pass  # never let logging crash the handler

MEMBERS_TABLE   = os.environ["MEMBERS_TABLE"]    # kopera-member
COMPANIES_TABLE = os.environ["COMPANIES_TABLE"]  # kopera-company
CERTS_BUCKET    = os.environ["CERTS_BUCKET"]     # kopera-certificate
ASSETS_BUCKET   = os.environ["ASSETS_BUCKET"]    # kopera-asset
ENVIRONMENT     = os.environ.get("ENVIRONMENT", "prod")
AWS_REGION      = os.environ.get("AWS_REGION", "us-east-1")
API_BASE_URL    = os.environ["API_BASE_URL"]     # https://<id>.execute-api.<region>.amazonaws.com/prod
ADMIN_TABLE      = os.environ.get("ADMIN_TABLE", "kopera-admin")
LIFE_INSURANCE_TABLE_NAME = os.environ.get("LIFE_INSURANCE_TABLE", "kopera-life-insurance")
LOCALITIES_TABLE = os.environ.get("LOCALITIES_TABLE", "kopera-localities")
SHARES_TABLE      = os.environ.get("SHARES_TABLE", "kopera-share")
PROSPECTS_TABLE   = os.environ.get("PROSPECTS_TABLE", "kopera-prospect")
SHORTLINKS_TABLE  = os.environ.get("SHORTLINKS_TABLE", "kopera-shortlink")
MEMBER_PORTAL_URL = os.environ.get("MEMBER_PORTAL_URL", "https://member.kafayiti.com")

################################################################################
# Router
################################################################################

def lambda_handler(event, context):
    try:
        return _route(event, context)
    except Exception as exc:
        _log_error("unhandled", exc, {
            "method":   event.get("httpMethod", ""),
            "resource": event.get("resource", ""),
        })
        return _resp(500, {"error": "Something went wrong."})


def _route(event, context):
    method   = event.get("httpMethod", "")
    resource = event.get("resource", "")

    # The dev certificate-handler Lambda is wired to "-dev" suffixed paths
    # (e.g. /members-dev/list) so it can share this exact codebase while
    # pointing at the dev DynamoDB tables. Normalize back to the canonical
    # path before routing so the if/elif chain below needs no duplication.
    resource = resource.replace("-dev", "")

    # ── CORS preflight ────────────────────────────────────────────────────────
    if method == "OPTIONS":
        return _resp(200, {})

    # ── GET /lookup?phone= (also /retrieve after -dev normalisation) ──────────
    if method == "GET" and resource in ("/lookup", "/retrieve"):
        return _handle_lookup(event)

    # ── GET /members ──────────────────────────────────────────────────────────
    if method == "GET" and resource == "/members":
        params     = event.get("queryStringParameters") or {}
        member_id  = params.get("memberId")
        company_id = params.get("companyId")
        if not member_id or not company_id:
            return _resp(400, {"error": "memberId and companyId required"})
        item = _db_get_member(member_id, company_id)
        return _resp(200, item) if item else _resp(404, {"error": "Member not found"})

    # ── GET /companies ────────────────────────────────────────────────────────
    if method == "GET" and resource == "/companies":
        company_id = (event.get("queryStringParameters") or {}).get("companyId")
        if not company_id:
            return _resp(400, {"error": "companyId required"})
        item = _db_get_company(company_id)
        return _resp(200, item) if item else _resp(404, {"error": "Company not found"})

    # ── POST /members ─────────────────────────────────────────────────────────
    if method == "POST" and resource == "/members":
        try:
            body = json.loads(event.get("body") or "{}")
        except json.JSONDecodeError:
            return _resp(400, {"error": "Invalid JSON"})
        if not body.get("memberId") or not body.get("companyId"):
            return _resp(400, {"error": "memberId and companyId required"})
        dynamodb.Table(MEMBERS_TABLE).put_item(Item=body)
        return _resp(200, {"message": "Member saved", "memberId": body["memberId"]})

    # ── POST /companies ───────────────────────────────────────────────────────
    if method == "POST" and resource == "/companies":
        try:
            body = json.loads(event.get("body") or "{}")
        except json.JSONDecodeError:
            return _resp(400, {"error": "Invalid JSON"})
        if not body.get("companyId"):
            return _resp(400, {"error": "companyId required"})
        dynamodb.Table(COMPANIES_TABLE).put_item(Item=body)
        return _resp(200, {"message": "Company saved", "companyId": body["companyId"]})

    # ── POST /certificates ────────────────────────────────────────────────────
    if method == "POST" and resource == "/certificates":
        return _handle_generate_certificate(event)

    # ── GET /certificates/{certificateId} ─────────────────────────────────────
    if method == "GET" and resource == "/certificates/{certificateId}":
        return _handle_get_certificate(event)

    # ── GET /members/list — list all members for a company ────────────────────
    if method == "GET" and resource == "/members/list":
        company_id = (event.get("queryStringParameters") or {}).get("companyId", "KAFA-001")
        return _handle_list_members(company_id)

    # ── POST /members/edit — mark member as being edited (lock/flag) ──────────
    if method == "POST" and resource == "/members/edit":
        try:
            body = json.loads(event.get("body") or "{}")
        except json.JSONDecodeError:
            return _resp(400, {"error": "Invalid JSON"})
        member_id  = body.get("memberId")
        company_id = body.get("companyId")
        if not member_id or not company_id:
            return _resp(400, {"error": "memberId and companyId required"})
        item = _db_get_member(member_id, company_id)
        if not item:
            return _resp(404, {"error": "Member not found"})
        return _resp(200, {"message": "Member ready for edit", "member": item})

    # ── POST /members/update — update member fields ───────────────────────────
    if method == "POST" and resource == "/members/update":
        return _handle_update_member_v2(event)

    # ── GET /localities — list all communes ──────────────────────────────────
    if method == "GET" and resource == "/localities":
        return _handle_list_localities()

    # ── POST /member/login — member self-service login ────────────────────────
    if method == "POST" and resource == "/member/login":
        return _handle_member_login(event)

    # ── GET /member/profile — fetch member profile ────────────────────────────
    if method == "GET" and resource == "/member/profile":
        params     = event.get("queryStringParameters") or {}
        member_id  = params.get("memberId")
        company_id = params.get("companyId", "KAFA-001")
        if not member_id:
            return _resp(400, {"error": "memberId required"})
        item = _db_get_member(member_id, company_id)
        if not item:
            return _resp(404, {"error": "Member not found"})
        safe = {k: v for k, v in item.items() if k not in ("credentials", "setupToken", "setupTokenExpiry")}
        return _resp(200, {"member": safe})

    # ── POST /member/profile/update — member edits their own profile ──────────
    if method == "POST" and resource == "/member/profile/update":
        return _handle_member_profile_update(event)

    # ── POST /members/set-credentials — admin sets member password ────────────
    if method == "POST" and resource == "/members/set-credentials":
        return _handle_set_member_credentials(event)

    # ── POST /members/send-password-setup — admin emails member a setup link ──
    if method == "POST" and resource == "/members/send-password-setup":
        return _handle_send_password_setup(event)

    # ── POST /member/request-password-reset — send setup link by email ────────
    if method == "POST" and resource == "/member/request-password-reset":
        return _handle_request_password_reset(event)


    # ── POST /members/create — create new member with uniqueness check ─────────
    if method == "POST" and resource == "/members/create":
        return _handle_create_member(event)

    # ── POST /auth/login — validate admin credentials ────────────────────────
    if method == "POST" and resource == "/auth/login":
        return _handle_admin_login(event)

    # ── GET /member/policy — list policies for a member ───────────────────────
    if method == "GET" and resource == "/member/policy":
        return _handle_get_member_policies(event)

    # ── GET /member/documents — list member documents ─────────────────────────
    if method == "GET" and resource == "/member/documents":
        return _handle_get_member_documents(event)

    # ── POST /member/documents/upload — request presigned S3 upload URL ───────
    if method == "POST" and resource == "/member/documents/upload":
        return _handle_request_document_upload(event)

    # ── POST /members/policies/create — admin creates a policy for a member ───
    if method == "POST" and resource == "/members/policies/create":
        return _handle_create_member_policy(event)

    # ── GET /member/shares — list a member's share purchases ──────────────────
    if method == "GET" and resource == "/member/shares":
        return _handle_get_member_shares(event)

    # ── POST /member/payment — admin records a manual premium payment ─────────
    if method == "POST" and resource == "/member/payment":
        return _handle_record_member_payment(event)

    # ── POST /member/shares/manual — admin records a manual share purchase ────
    if method == "POST" and resource == "/member/shares/manual":
        return _handle_record_member_share(event)

    # ── POST /member/acknowledge-payment — member dismisses the notification ──
    if method == "POST" and resource == "/member/acknowledge-payment":
        return _handle_acknowledge_payment(event)

    # ── GET /member/beneficiaries — list beneficiaries for a member ───────────
    if method == "GET" and resource == "/member/beneficiaries":
        return _handle_get_member_beneficiaries(event)

    # ── POST /member/beneficiaries — add or update a beneficiary ─────────────
    if method == "POST" and resource == "/member/beneficiaries":
        return _handle_save_member_beneficiary(event)

    # ── POST /member/enrollment — member applies for a plan or requests switch ─
    if method == "POST" and resource in ("/member/enrollment", "/member-dev/enrollment"):
        return _handle_member_enrollment(event)

    # ── POST /member/death-report — member reports a death to KAFA ───────────
    if method == "POST" and resource in ("/member/death-report", "/member-dev/death-report"):
        return _handle_death_report(event)

    # ── GET /prospects — list all prospects ───────────────────────────────────
    if method == "GET" and resource == "/prospects":
        return _list_prospects()

    # ── PATCH /prospects/{id} — update prospect status / note ─────────────────
    if method == "PATCH" and resource == "/prospects/{id}":
        return _update_prospect(event)

    # ── POST /admin/shorten — create a custom short URL ──────────────────────
    if method == "POST" and resource == "/admin/shorten":
        return _handle_shorten_url(event)

    # ── GET /r/{code} — redirect short URL to original ───────────────────────
    if method == "GET" and resource == "/r/{code}":
        return _handle_redirect(event)

    return _resp(404, {"error": f"Route not found: {method} {resource}"})


################################################################################
# POST /admin/shorten  — create a custom short link
# GET  /r/{code}       — redirect to original URL
################################################################################

_SHORTLINK_CHARS = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789"
_SHORTLINK_TTL_DAYS = 365


def _make_short_link(url: str, base_url: str | None = None) -> str:
    """Store `url` in the shortlink table and return the short URL."""
    code = "".join(secrets.choice(_SHORTLINK_CHARS) for _ in range(8))
    expires_at = int((datetime.now(timezone.utc) + timedelta(days=_SHORTLINK_TTL_DAYS)).timestamp())
    dynamodb.Table(SHORTLINKS_TABLE).put_item(Item={
        "code":       code,
        "url":        url,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "expires_at": expires_at,
    })
    root = (base_url or MEMBER_PORTAL_URL).rstrip("/")
    return f"{root}/r/{code}"


def _make_setup_link(member: dict, reset: bool = False) -> str:
    """Generate a 24-hour setup token for *member*, persist it, and return the full URL.
    Uses ?reset= for member-initiated resets and ?setup= for admin-initiated first-time setup.
    Also records the token in setupTokenHistory (never removed) so that an
    old link — even after its token has been rotated away by a later
    request — can still be traced back to the right member forever, instead
    of becoming permanently unrecoverable once it's no longer the *current*
    token on file."""
    token  = secrets.token_urlsafe(7)   # 10 URL-safe chars
    expiry = (datetime.now(timezone.utc) + timedelta(hours=24)).isoformat()
    dynamodb.Table(MEMBERS_TABLE).update_item(
        Key={"memberId": member["memberId"], "companyId": member.get("companyId", "KAFA-001")},
        UpdateExpression="SET setupToken = :t, setupTokenExpiry = :e ADD setupTokenHistory :h",
        ExpressionAttributeValues={":t": token, ":e": expiry, ":h": {token}},
    )
    param = "reset" if reset else "setup"
    return f"{MEMBER_PORTAL_URL}?{param}={token}"


def _handle_shorten_url(event: dict) -> dict:
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _resp(400, {"error": "Invalid JSON"})
    url = (body.get("url") or "").strip()
    if not url:
        return _resp(400, {"error": "url required"})
    base_url = (body.get("base_url") or "").strip() or None
    return _resp(200, {"short": _make_short_link(url, base_url)})


def _handle_redirect(event: dict) -> dict:
    code = (event.get("pathParameters") or {}).get("code", "").strip()
    if not code:
        return _resp(400, {"error": "code required"})

    item = dynamodb.Table(SHORTLINKS_TABLE).get_item(Key={"code": code}).get("Item")
    if not item:
        return _resp(404, {"error": "Link not found or expired"})

    return {
        "statusCode": 302,
        "headers": {
            "Location":                    item["url"],
            "Access-Control-Allow-Origin": "*",
        },
        "body": "",
    }


################################################################################
# GET /lookup?phone=  — core new feature
################################################################################

def _handle_lookup(event: dict) -> dict:
    """
    1. Extract phone from query string
    2. Scan kopera-member for matching phone number
    3. Call GET /members via certplatform-prod-api to confirm record
    4. Verify S3 objects exist
    5. Return PDF + JPEG S3 URLs
    """
    params = event.get("queryStringParameters") or {}
    phone  = params.get("phone", "").strip()

    if not phone:
        return _resp(400, {"error": "phone query parameter is required"})

    logger.info("Looking up member by phone: %s", phone)

    # ── Step 1: Scan kopera-member for this phone number ──────────────────────
    member = _scan_member_by_phone(phone)

    if not member:
        return _resp(404, {
            "error":   "No member found with that phone number",
            "phone":   phone,
        })

    member_id  = member["memberId"]
    company_id = member["companyId"]
    logger.info("Found member %s in company %s", member_id, company_id)

    # ── Step 2: Confirm record exists in DynamoDB ────────────────────────────
    confirmed = _db_get_member(member_id, company_id)
    if not confirmed:
        return _resp(404, {
            "error":     "Member found in DynamoDB but could not be confirmed via API",
            "member_id": member_id,
        })

    # ── Step 3: Read certificate metadata ─────────────────────────────────────
    cert = confirmed.get("certificate")
    if not cert:
        return _resp(404, {
            "error":     "Member has no certificate yet. Generate one first.",
            "member_id": member_id,
            "full_name": confirmed.get("full_name", ""),
        })

    pdf_url  = cert.get("pdf_s3_url",  "")
    jpeg_url = cert.get("jpeg_s3_url", "")

    if not pdf_url or not jpeg_url:
        return _resp(404, {
            "error":          "Certificate metadata incomplete — S3 URLs missing",
            "certificate_id": cert.get("certificate_id"),
        })

    # ── Step 4: Verify both S3 objects actually exist ─────────────────────────
    pdf_exists  = _s3_object_exists(pdf_url)
    jpeg_exists = _s3_object_exists(jpeg_url)

    if not pdf_exists or not jpeg_exists:
        missing = []
        if not pdf_exists:  missing.append("PDF")
        if not jpeg_exists: missing.append("JPEG")
        return _resp(404, {
            "error":          f"Certificate files missing in S3: {', '.join(missing)}",
            "certificate_id": cert.get("certificate_id"),
        })

    # ── Step 5: Return presigned HTTPS links (7-day expiry) ──────────────────
    member_name = confirmed.get("full_name", member_id).replace(" ", "_")
    return _resp(200, {
        "member_id":      member_id,
        "company_id":     company_id,
        "full_name":      confirmed.get("full_name", ""),
        "phone":          phone,
        "certificate_id": cert.get("certificate_id"),
        "issued_date":    cert.get("issued_date"),
        "documents": {
            "pdf":  {"download_url": _s3_presign(pdf_url,  expiry=604800, filename=f"KAFA_Certificate_{member_name}.pdf")},
            "jpeg": {"download_url": _s3_presign(jpeg_url, expiry=604800, filename=f"KAFA_Certificate_{member_name}.jpeg")},
        },
    })


################################################################################
# GET /certificates/{certificateId}
################################################################################

def _handle_get_certificate(event: dict) -> dict:
    params     = event.get("queryStringParameters") or {}
    member_id  = params.get("memberId")
    company_id = params.get("companyId")
    if not member_id or not company_id:
        return _resp(400, {"error": "memberId and companyId required"})
    member = _db_get_member(member_id, company_id)
    if not member:
        return _resp(404, {"error": "Member not found"})
    cert = member.get("certificate")
    return _resp(200, cert) if cert else _resp(404, {"error": "No certificate on record"})


################################################################################
# POST /certificates — certificate generation (delegates to existing flow)
################################################################################

def _handle_generate_certificate(event: dict) -> dict:
    """
    Imports the full generation logic inline so this Lambda is self-contained.
    Generation flow: fetch member + company via API → render PDF/JPEG → upload S3 → update DynamoDB.
    """
    try:
        body       = json.loads(event.get("body") or "{}")
        member_id  = body.get("memberId") or body.get("member_id")
        company_id = body.get("companyId") or body.get("company_id")
        if not member_id or not company_id:
            raise KeyError("memberId / companyId")
    except (KeyError, json.JSONDecodeError) as exc:
        return _resp(400, {"error": f"Missing field: {exc}"})

    try:
        import io, uuid
        from datetime import datetime, timezone

        member  = _db_get_member(member_id, company_id)
        company = _db_get_company(company_id)

        if not member:  return _resp(404, {"error": f"Member not found: {member_id}"})
        if not company: return _resp(404, {"error": f"Company not found: {company_id}"})

        is_active = member.get("status") == "Active"
        if not is_active:
            return _resp(400, {"error": "Member must be active to generate certificate"})

        # Import PDF/JPEG generation from the shared module
        from certificate_engine import generate_pdf, generate_jpeg

        certificate_id = f"CERT-{uuid.uuid4().hex[:8].upper()}"
        issued_date    = datetime.now(timezone.utc).strftime("%d / %m / %Y")
        timestamp      = datetime.now(timezone.utc).isoformat()

        pdf_bytes  = generate_pdf(member, company, certificate_id, issued_date, s3_client=s3_client)
        jpeg_bytes = generate_jpeg(pdf_bytes)

        prefix      = f"certificates/{company_id}/{member_id}/{certificate_id}"
        pdf_url     = _s3_upload(pdf_bytes,  f"{prefix}.pdf",  "application/pdf")
        jpeg_url    = _s3_upload(jpeg_bytes, f"{prefix}.jpeg", "image/jpeg")

        dynamodb.Table(MEMBERS_TABLE).update_item(
            Key={"memberId": member_id, "companyId": company_id},
            UpdateExpression="SET certificate = :c, issued_date = :d",
            ExpressionAttributeValues={
                ":c": {
                    "certificate_id": certificate_id,
                    "issued_date":    issued_date,
                    "pdf_s3_url":     pdf_url,
                    "jpeg_s3_url":    jpeg_url,
                    "whatsapp_sent":  False,
                    "timestamp":      timestamp,
                },
                ":d": issued_date,
            },
        )

        return _resp(200, {
            "certificate_id": certificate_id,
            "member_id":      member_id,
            "documents": {"pdf": pdf_url, "jpeg": jpeg_url},
            "issued_date":    issued_date,
        })

    except Exception as exc:
        _log_error("certificate_generation", exc)
        return _resp(500, {"error": "Something went wrong."})


################################################################################
# Member list + update handlers
################################################################################

def _handle_list_members(company_id: str) -> dict:
    """Scan all members for a given companyId."""
    table = dynamodb.Table(MEMBERS_TABLE)
    items = []
    scan_kwargs = {"FilterExpression": Attr("companyId").eq(company_id)}
    while True:
        resp = table.scan(**scan_kwargs)
        items.extend(resp.get("Items", []))
        last_key = resp.get("LastEvaluatedKey")
        if not last_key:
            break
        scan_kwargs["ExclusiveStartKey"] = last_key
    items.sort(key=lambda x: x.get("memberId", ""))
    return _resp(200, {"members": items, "count": len(items)})


def _handle_update_member(event: dict) -> dict:
    """Update allowed member fields including status (active/inactive)."""
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _resp(400, {"error": "Invalid JSON"})

    member_id  = body.get("memberId")
    company_id = body.get("companyId")
    if not member_id or not company_id:
        return _resp(400, {"error": "memberId and companyId required"})

    allowed = [
        "full_name", "date_of_birth", "address", "phone", "email",
        "identification_number", "identification_type", "status", "notes",
    ]

    update_parts = []
    attr_names   = {}
    attr_values  = {}

    for field in allowed:
        if field in body:
            nk = f"#f_{field}"
            vk = f":v_{field}"
            update_parts.append(f"{nk} = {vk}")
            attr_names[nk] = field
            attr_values[vk] = body[field]

    if not update_parts:
        return _resp(400, {"error": "No updatable fields provided"})

    dynamodb.Table(MEMBERS_TABLE).update_item(
        Key={"memberId": member_id, "companyId": company_id},
        UpdateExpression="SET " + ", ".join(update_parts),
        ExpressionAttributeNames=attr_names,
        ExpressionAttributeValues=attr_values,
    )

    updated = _db_get_member(member_id, company_id)
    logger.info("Member %s updated", member_id)
    return _resp(200, {"message": "Member updated", "member": updated})


################################################################################
# DynamoDB helpers
################################################################################

def _scan_member_by_phone(phone: str) -> dict | None:
    """
    Scan kopera-member for a member whose phone attribute matches.
    Uses a FilterExpression — efficient enough for 52 members.
    For larger datasets, add a GSI on phone.
    """
    table = dynamodb.Table(MEMBERS_TABLE)
    resp  = table.scan(FilterExpression=Attr("phone").eq(phone))
    items = resp.get("Items", [])

    # Handle pagination (unlikely at this scale but correct)
    while "LastEvaluatedKey" in resp:
        resp  = table.scan(
            FilterExpression=Attr("phone").eq(phone),
            ExclusiveStartKey=resp["LastEvaluatedKey"],
        )
        items += resp.get("Items", [])

    if not items:
        return None

    if len(items) > 1:
        logger.warning("Multiple members share phone %s — returning first match", phone)

    return items[0]


def _db_get_member(member_id: str, company_id: str) -> dict:
    resp = dynamodb.Table(MEMBERS_TABLE).get_item(
        Key={"memberId": member_id, "companyId": company_id}
    )
    return dict(resp["Item"]) if resp.get("Item") else {}


def _db_get_company(company_id: str) -> dict:
    resp = dynamodb.Table(COMPANIES_TABLE).get_item(Key={"companyId": company_id})
    return dict(resp["Item"]) if resp.get("Item") else {}


################################################################################
# API Gateway helper (SigV4-signed → certplatform-prod-api)
################################################################################

def _apigw_get(path: str) -> dict:
    url   = f"{API_BASE_URL.rstrip('/')}{path}"
    creds = _session.get_credentials().get_frozen_credentials()
    req   = AWSRequest(method="GET", url=url)
    SigV4Auth(creds, "execute-api", AWS_REGION).add_auth(req)

    resp = requests.get(url, headers=dict(req.headers), timeout=10)
    if resp.status_code == 404:
        return {}
    resp.raise_for_status()

    payload = resp.json()
    if isinstance(payload, dict) and "Item" in payload:
        return payload["Item"]
    return payload or {}


################################################################################
# S3 helpers
################################################################################

def _s3_public_url(s3_url: str) -> str:
    """Convert s3://bucket/key to a permanent public HTTPS URL (bucket must allow public GetObject)."""
    if not s3_url.startswith("s3://"):
        return s3_url
    parts  = s3_url[5:].split("/", 1)
    bucket = parts[0]
    key    = parts[1] if len(parts) > 1 else ""
    return f"https://{bucket}.s3.amazonaws.com/{key}"


def _s3_presign(s3_url: str, expiry: int = 3600, filename: str = None) -> str:
    """Convert s3://bucket/key to a presigned HTTPS download URL."""
    if not s3_url.startswith("s3://"):
        return s3_url
    parts  = s3_url[5:].split("/", 1)
    bucket = parts[0]
    key    = parts[1] if len(parts) > 1 else ""
    params = {"Bucket": bucket, "Key": key}
    if filename:
        params["ResponseContentDisposition"] = f'attachment; filename="{filename}"'
    return s3_client.generate_presigned_url(
        "get_object",
        Params=params,
        ExpiresIn=expiry,
    )


def _s3_object_exists(s3_url: str) -> bool:
    """Check s3://bucket/key exists without downloading."""
    if not s3_url.startswith("s3://"):
        return False
    parts  = s3_url[5:].split("/", 1)
    bucket = parts[0]
    key    = parts[1] if len(parts) > 1 else ""
    try:
        s3_client.head_object(Bucket=bucket, Key=key)
        return True
    except s3_client.exceptions.ClientError:
        return False
    except Exception:
        return False


def _s3_upload(data: bytes, key: str, content_type: str) -> str:
    s3_client.put_object(
        Bucket=CERTS_BUCKET, Key=key, Body=data, ContentType=content_type
    )
    return f"s3://{CERTS_BUCKET}/{key}"


################################################################################
# POST /auth/login — admin authentication
################################################################################

def _handle_admin_login(event: dict) -> dict:
    """
    Validates admin credentials against kopera-admin DynamoDB table.
    Password is stored as a SHA-256 hash — never in plaintext.
    Returns 200 + username on success, 401 on failure.
    """
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _resp(400, {"error": "Invalid JSON"})

    username = body.get("username", "").strip()
    password = body.get("password", "").strip()

    if not username or not password:
        return _resp(400, {"error": "username and password required"})

    # Hash the incoming password with SHA-256 for comparison
    password_hash = hashlib.sha256(password.encode("utf-8")).hexdigest()

    table = dynamodb.Table(ADMIN_TABLE)
    response = table.get_item(Key={"username": username})
    item = response.get("Item")

    if not item:
        logger.warning("Login failed — username not found: %s", username)
        return _resp(401, {"error": "Invalid username or password"})

    stored_hash = item.get("password_hash", "")
    if stored_hash != password_hash:
        logger.warning("Login failed — wrong password for: %s", username)
        return _resp(401, {"error": "Invalid username or password"})

    logger.info("Login successful: %s", username)

    # Return temporary AWS credentials scoped to this session.
    # The Flutter app uses these for SigV4-signed API Gateway calls.
    # Credentials are sourced from the Lambda execution role via the
    # instance metadata — never hardcoded.
    credentials = _session.get_credentials().get_frozen_credentials()

    return _resp(200, {
        "message":          "Login successful",
        "username":         username,
        "accessKeyId":      credentials.access_key,
        "secretAccessKey":  credentials.secret_key,
        "sessionToken":     credentials.token,
    })



################################################################################
################################################################################
# Sequence helpers — kopera-company.sequence is the global MK counter
################################################################################

def _next_sequence(company_id: str) -> int:
    """Atomically increment kopera-company.sequence and return the new value."""
    result = dynamodb.Table(COMPANIES_TABLE).update_item(
        Key={"companyId": company_id},
        UpdateExpression="ADD #seq :inc",
        ExpressionAttributeNames={"#seq": "sequence"},
        ExpressionAttributeValues={":inc": Decimal("1")},
        ReturnValues="UPDATED_NEW",
    )
    return int(result["Attributes"]["sequence"])


def _mk_member_id(code: str, seq: int) -> str:
    """Build a canonical MK member ID: MK + 3-digit commune code + 8-digit seq."""
    return f"MK{str(code).zfill(3)}{str(seq).zfill(8)}"


# GET /localities — list all communes
################################################################################

def _handle_list_localities() -> dict:
    table = dynamodb.Table(LOCALITIES_TABLE)
    items = []
    resp = table.scan()
    items.extend(resp.get("Items", []))
    while "LastEvaluatedKey" in resp:
        resp = table.scan(ExclusiveStartKey=resp["LastEvaluatedKey"])
        items.extend(resp.get("Items", []))
    items.sort(key=lambda x: x.get("commune", ""))
    return _resp(200, {"localities": items, "count": len(items)})


################################################################################
# POST /members/create — create new member with uniqueness validation
################################################################################

def _handle_create_member(event: dict) -> dict:
    """
    Creates a new member.
    - If locality is provided: atomically increments kopera-company.sequence
      and auto-generates memberId = MK{code}{seq:08d}.
    - If no locality: memberId must be supplied by the client.
    """
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _resp(400, {"error": "Invalid JSON"})

    company_id = body.get("companyId", "KAFA-001").strip()
    phone      = body.get("phone", "").strip()
    email      = body.get("email", "").strip()
    locality   = body.get("locality")

    # ── Determine member ID ───────────────────────────────────────────────────
    if locality and locality.get("code"):
        seq       = _next_sequence(company_id)
        member_id = _mk_member_id(locality["code"], seq)
        logger.info("Auto-generated member ID: %s (seq=%s)", member_id, seq)
    else:
        member_id = body.get("memberId", "").strip()
        if not member_id:
            return _resp(400, {"error": "memberId required when no locality provided"})

    table = dynamodb.Table(MEMBERS_TABLE)

    # ── Uniqueness checks ─────────────────────────────────────────────────────
    existing = table.get_item(Key={"memberId": member_id, "companyId": company_id})
    if existing.get("Item"):
        return _resp(409, {"error": f"Member ID '{member_id}' already exists"})

    if phone and ENVIRONMENT != "dev":
        phone_check = table.scan(FilterExpression=Attr("phone").eq(phone))
        if phone_check.get("Items"):
            return _resp(409, {"error": f"Phone number '{phone}' is already registered to another member"})

    if email and ENVIRONMENT != "dev":
        email_check = table.scan(FilterExpression=Attr("email").eq(email))
        if email_check.get("Items"):
            return _resp(409, {"error": f"Email '{email}' is already registered to another member"})

    # ── Build item ────────────────────────────────────────────────────────────
    item = {
        "memberId":              member_id,
        "companyId":             company_id,
        "full_name":             body.get("full_name", ""),
        "date_of_birth":         body.get("date_of_birth", ""),
        "address":               body.get("address", ""),
        "phone":                 phone,
        "email":                 email,
        "identification_number": body.get("identification_number", ""),
        "identification_type":   body.get("identification_type", ""),
        "status":                "Pending",
        "reason":                _SHARE_PENDING_REASON,
        "notes":                 body.get("notes", ""),
    }

    if locality:
        item["locality"] = {
            "commune": locality.get("commune", ""),
            "code":    locality.get("code", ""),
        }

    table.put_item(Item=item)
    logger.info("Member created: %s", member_id)
    return _resp(201, {"message": "Member created successfully", "member": item})


################################################################################
# Updated POST /members/update — add memberId rename + uniqueness validation
################################################################################

def _handle_update_member_v2(event: dict) -> dict:
    """
    Extended update supporting:
    - MBR → MK conversion: when locality is set on a non-MK member,
      atomically increments kopera-company.sequence and generates new MK ID.
    - MK commune change: preserves existing sequence, updates commune prefix.
    - Renaming memberId (old_member_id → new memberId) for manual cases.
    - Uniqueness checks for memberId, phone, email.
    """
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _resp(400, {"error": "Invalid JSON"})

    old_member_id = body.get("oldMemberId") or body.get("memberId")
    company_id    = body.get("companyId")
    locality      = body.get("locality")

    if not old_member_id or not company_id:
        return _resp(400, {"error": "memberId and companyId required"})

    # ── Server-side MK ID generation ─────────────────────────────────────────
    if locality and locality.get("code"):
        code = str(locality["code"]).zfill(3)
        if not old_member_id.startswith("MK"):
            # MBR → MK: assign new global sequence
            seq           = _next_sequence(company_id)
            new_member_id = _mk_member_id(code, seq)
            logger.info("Converting %s → %s (seq=%s)", old_member_id, new_member_id, seq)
        elif len(old_member_id) == 13:
            # MK → MK with new commune: preserve existing sequence
            existing_seq  = int(old_member_id[5:])
            new_member_id = _mk_member_id(code, existing_seq)
        else:
            new_member_id = body.get("memberId", old_member_id).strip()
    else:
        new_member_id = body.get("memberId", old_member_id).strip()

    table = dynamodb.Table(MEMBERS_TABLE)

    # ── Uniqueness checks ─────────────────────────────────────────────────────
    if new_member_id != old_member_id:
        existing = table.get_item(Key={"memberId": new_member_id, "companyId": company_id})
        if existing.get("Item"):
            return _resp(409, {"error": f"Member ID '{new_member_id}' already exists"})

    # Fetch current record so we only check uniqueness when values actually change
    current = _db_get_member(old_member_id, company_id) or {}

    phone = body.get("phone", "").strip()
    if phone and phone != (current.get("phone") or "").strip():
        phone_check = table.scan(FilterExpression=Attr("phone").eq(phone))
        for item in phone_check.get("Items", []):
            if item["memberId"] != old_member_id:
                return _resp(409, {"error": f"Phone '{phone}' is already registered to another member"})

    email = body.get("email", "").strip()
    if email and email != (current.get("email") or "").strip():
        email_check = table.scan(FilterExpression=Attr("email").eq(email))
        for item in email_check.get("Items", []):
            if item["memberId"] != old_member_id:
                return _resp(409, {"error": f"Email '{email}' is already registered to another member"})

    allowed = [
        "full_name", "date_of_birth", "address", "phone", "email",
        "identification_number", "identification_type", "status", "notes",
    ]

    if new_member_id != old_member_id:
        # Rename: delete old record, insert with new memberId
        old_item = _db_get_member(old_member_id, company_id)
        if not old_item:
            return _resp(404, {"error": "Member not found"})
        for field in allowed:
            if field in body:
                old_item[field] = body[field]
        if locality:
            old_item["locality"] = locality
        old_item["memberId"] = new_member_id
        table.delete_item(Key={"memberId": old_member_id, "companyId": company_id})
        table.put_item(Item=old_item)
        updated = old_item
    else:
        # Standard in-place update
        update_parts = []
        attr_names   = {}
        attr_values  = {}

        for field in allowed:
            if field in body:
                nk = f"#f_{field}"
                vk = f":v_{field}"
                update_parts.append(f"{nk} = {vk}")
                attr_names[nk] = field
                attr_values[vk] = body[field]

        if locality:
            update_parts.append("#f_locality = :v_locality")
            attr_names["#f_locality"] = "locality"
            attr_values[":v_locality"] = locality

        if not update_parts:
            return _resp(400, {"error": "No updatable fields provided"})

        table.update_item(
            Key={"memberId": old_member_id, "companyId": company_id},
            UpdateExpression="SET " + ", ".join(update_parts),
            ExpressionAttributeNames=attr_names,
            ExpressionAttributeValues=attr_values,
        )
        updated = _db_get_member(new_member_id, company_id)

    logger.info("Member %s updated (new ID: %s)", old_member_id, new_member_id)
    return _resp(200, {"message": "Member updated", "member": updated})

################################################################################
# POST /member/login — member self-service login
################################################################################

def _find_member_by_setup_token(setup_token: str) -> dict | None:
    """Find the member this token belongs to — either as their current
    setupToken, or anywhere in their setupTokenHistory (older, rotated-away
    tokens), so an old link can still be traced back to its rightful owner."""
    table = dynamodb.Table(MEMBERS_TABLE)
    scan_kwargs = {
        "FilterExpression": Attr("setupToken").eq(setup_token)
        | Attr("setupTokenHistory").contains(setup_token)
    }
    items = []
    while True:
        resp = table.scan(**scan_kwargs)
        items.extend(resp.get("Items", []))
        if items or not resp.get("LastEvaluatedKey"):
            break
        scan_kwargs["ExclusiveStartKey"] = resp["LastEvaluatedKey"]
    return items[0] if items else None


def _handle_member_login(event: dict) -> dict:
    """
    Allows a cooperative member to log in using their email or phone number
    plus a password. Also handles first-time password setup when the body
    contains {memberId, setupPassword} instead of {identifier, password}.
    """
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _resp(400, {"error": "Invalid JSON"})

    setup_password = body.get("setupPassword", "").strip()
    setup_token    = body.get("setupToken", "").strip()

    # ── Setup-link precheck ───────────────────────────────────────────────────
    # Called with just {setupToken} before the member has typed anything, so
    # the frontend can block the password form outright on an expired/invalid
    # link instead of only finding out after submit.
    if setup_token and not setup_password:
        member = _find_member_by_setup_token(setup_token)
        if not member:
            return _resp(401, {"error": "Invalid setup link."})
        expiry_str = member.get("setupTokenExpiry", "")
        if not expiry_str or datetime.fromisoformat(expiry_str) < datetime.now(timezone.utc):
            # Resolve who this link was for *now*, while the token still
            # traces back to them, so the frontend can scope any later
            # "request new password" call to this exact member even after
            # this token itself gets rotated away by that request.
            return _resp(410, {
                "error": "This setup link has expired. Request a new one from the login screen.",
                "memberId": member["memberId"],
            })
        return _resp(200, {"valid": True})

    # ── Password setup / reset flow ───────────────────────────────────────────
    # Used both for first-time setup and for resetting an existing password —
    # a valid, unexpired setup token always overwrites whatever credentials
    # (if any) are already on file, and can be reused as many times as needed
    # until it naturally expires (e.g. the member mistypes and wants to redo
    # it). The expiry itself is what bounds how long the link stays usable.
    if setup_password and setup_token:
        if len(setup_password) < 6:
            return _resp(400, {"error": "Password must be at least 6 characters"})
        member = _find_member_by_setup_token(setup_token)
        if not member:
            return _resp(401, {"error": "Invalid setup link."})
        expiry_str = member.get("setupTokenExpiry", "")
        if not expiry_str or datetime.fromisoformat(expiry_str) < datetime.now(timezone.utc):
            return _resp(410, {"error": "This setup link has expired. Request a new one from the login screen."})
        pw_hash = hashlib.sha256(setup_password.encode()).hexdigest()
        dynamodb.Table(MEMBERS_TABLE).update_item(
            Key={"memberId": member["memberId"], "companyId": member.get("companyId", "KAFA-001")},
            UpdateExpression="SET credentials = :h",
            ExpressionAttributeValues={":h": pw_hash},
        )
        logger.info("Password set/reset for member: %s", member["memberId"])
        safe = {k: v for k, v in member.items() if k not in ("credentials", "setupToken", "setupTokenExpiry")}
        return _resp(200, {"message": "Password set successfully", "member": safe})

    # ── Normal login flow ─────────────────────────────────────────────────────
    identifier = body.get("identifier", "").strip()   # email OR phone
    password   = body.get("password", "").strip()

    if not identifier or not password:
        return _resp(400, {"error": "identifier (email or phone) and password are required"})

    password_hash = hashlib.sha256(password.encode()).hexdigest()
    table         = dynamodb.Table(MEMBERS_TABLE)

    # Scan for email match
    resp  = table.scan(FilterExpression=Attr("email").eq(identifier))
    items = resp.get("Items", [])

    # Fall back to phone match — normalize by stripping non-digits so that
    # "5613034161" matches a stored value of "561-303-4161".
    if not items:
        digits_only = re.sub(r"\D", "", identifier)
        resp  = table.scan(FilterExpression=Attr("phone").eq(identifier))
        items = resp.get("Items", [])
        if not items and digits_only:
            all_resp = table.scan()
            all_members = all_resp.get("Items", [])
            while all_resp.get("LastEvaluatedKey"):
                all_resp = table.scan(ExclusiveStartKey=all_resp["LastEvaluatedKey"])
                all_members.extend(all_resp.get("Items", []))
            items = [m for m in all_members if re.sub(r"\D", "", m.get("phone") or "") == digits_only]

    if not items:
        return _resp(401, {"error": "No member found with that email or phone number."})

    # When multiple records share the same phone/email (common in test data),
    # prefer the one that has credentials set.
    member = next((m for m in items if m.get("credentials")), items[0])

    stored_hash = member.get("credentials")
    if not stored_hash:
        return _resp(401, {"error": "This account does not have a password set. Please contact your administrator."})

    if stored_hash != password_hash:
        return _resp(401, {"error": "Incorrect password."})

    # Return member profile — never include credentials in the response
    safe_member = {k: v for k, v in member.items() if k != "credentials"}
    logger.info("Member login: %s", member.get("memberId"))
    return _resp(200, {"message": "Login successful", "member": safe_member})


################################################################################
# POST /member/profile/update — member edits their own profile
################################################################################

def _handle_member_profile_update(event: dict) -> dict:
    """
    Member self-service profile edit. Limited to contact/personal fields a
    member may safely change themselves — never status, memberId, or notes,
    which remain admin-only via /members/update.
    """
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _resp(400, {"error": "Invalid JSON"})

    member_id  = body.get("memberId", "").strip()
    company_id = body.get("companyId", "KAFA-001").strip()

    if not member_id:
        return _resp(400, {"error": "memberId required"})

    current = _db_get_member(member_id, company_id)
    if not current:
        return _resp(404, {"error": "Member not found"})

    table = dynamodb.Table(MEMBERS_TABLE)

    phone = body.get("phone", "").strip()
    if phone and phone != (current.get("phone") or "").strip():
        phone_check = table.scan(FilterExpression=Attr("phone").eq(phone))
        for item in phone_check.get("Items", []):
            if item["memberId"] != member_id:
                return _resp(409, {"error": f"Phone '{phone}' is already registered to another member"})

    email = body.get("email", "").strip()
    if email and email != (current.get("email") or "").strip():
        email_check = table.scan(FilterExpression=Attr("email").eq(email))
        for item in email_check.get("Items", []):
            if item["memberId"] != member_id:
                return _resp(409, {"error": f"Email '{email}' is already registered to another member"})

    allowed = ["phone", "email", "address", "date_of_birth",
               "identification_number", "identification_type"]

    update_parts = []
    attr_names   = {}
    attr_values  = {}

    for field in allowed:
        if field in body:
            nk = f"#f_{field}"
            vk = f":v_{field}"
            update_parts.append(f"{nk} = {vk}")
            attr_names[nk] = field
            attr_values[vk] = body[field]

    if not update_parts:
        return _resp(400, {"error": "No updatable fields provided"})

    table.update_item(
        Key={"memberId": member_id, "companyId": company_id},
        UpdateExpression="SET " + ", ".join(update_parts),
        ExpressionAttributeNames=attr_names,
        ExpressionAttributeValues=attr_values,
    )

    updated = _db_get_member(member_id, company_id)
    safe_member = {k: v for k, v in updated.items() if k != "credentials"}
    logger.info("Member %s updated their own profile", member_id)
    return _resp(200, {"message": "Profile updated", "member": safe_member})


################################################################################
# POST /member/request-password-reset — send a new setup link by email
################################################################################

def _find_member_by_identifier(identifier: str) -> dict | None:
    """Return the first member matching by email (exact) or phone (digit-normalized)."""
    table  = dynamodb.Table(MEMBERS_TABLE)
    digits = re.sub(r"\D", "", identifier)

    # Fast path: exact email match
    resp = table.scan(FilterExpression=Attr("email").eq(identifier))
    if resp.get("Items"):
        return resp["Items"][0]

    # Phone lookup: scan full table with pagination and compare stripped digits.
    # Stored formats vary ("5091234567", "509-123-4567") so we normalize both sides.
    if not digits:
        return None
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


def _identifier_matches_member(identifier: str, member: dict) -> bool:
    """True if identifier is exactly the email or phone already on file for this member."""
    identifier = identifier.strip()
    email = (member.get("email") or "").strip()
    if email and identifier.lower() == email.lower():
        return True
    digits = re.sub(r"\D", "", identifier)
    phone  = re.sub(r"\D", "", member.get("phone") or "")
    return bool(digits) and bool(phone) and digits == phone


def _handle_request_password_reset(event: dict) -> dict:
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _resp(400, {"error": "Invalid JSON"})

    identifier      = body.get("identifier", "").strip()
    delivery        = body.get("delivery", "email")   # "email" | "whatsapp"
    from_link       = bool(body.get("fromExpiredLink"))
    scoped_member_id = body.get("memberId", "").strip()
    if not identifier:
        return _resp(400, {"error": "identifier (member ID, email, or phone) required"})

    if from_link:
        # Scoped recovery from an expired setup/reset link. scoped_member_id
        # was resolved by the frontend at page-load time (while the link's
        # token still traced back to its owner) and is stable even after
        # that token gets rotated away by a later successful request here —
        # unlike matching on the token itself, which would otherwise let a
        # dead/rotated token silently fall through to an unscoped lookup.
        # Only the exact email or phone on file for that specific member is
        # accepted; if no member could ever be resolved for this link,
        # there's nothing to scope to and the request is rejected outright
        # rather than falling back to an open lookup.
        member = _db_get_member(scoped_member_id, "KAFA-001") if scoped_member_id else None
        if not member:
            return _resp(410, {"error": "This link is no longer valid. Please contact an administrator for a new setup link."})
        if not _identifier_matches_member(identifier, member):
            return _resp(404, {"error": "That email or phone doesn't match our records for this link."})
    else:
        member = _find_member_by_identifier(identifier)

    if delivery == "whatsapp":
        # For WhatsApp we return the shortened link directly — the member
        # proved identity by knowing their email / phone.
        if not member:
            return _resp(404, {"error": "No account found with that email or phone."})
        link  = _make_setup_link(member)
        short = _make_short_link(link)
        phone = re.sub(r"\D", "", member.get("phone", "") or "")
        return _resp(200, {"setupLink": short, "phone": phone})

    # Email delivery — always return the same vague message to avoid
    # leaking whether an account exists.
    if not member:
        return _resp(200, {"message": "If an account exists, a reset link has been sent to the email on file."})

    if not (member.get("email") or "").strip():
        return _resp(400, {"error": "No email on file for this account. Use the WhatsApp option instead."})

    _send_password_setup_email(member, requested_by_member=True)
    return _resp(200, {"message": "If an account exists, a reset link has been sent to the email on file."})


def _send_password_setup_email(member: dict, requested_by_member: bool, reset: bool = False) -> str:
    """Generate a setup token for `member`, store it, email a setup link, and return the link."""
    member_id = member.get("memberId", "")
    email     = (member.get("email") or "").strip()

    link = _make_setup_link(member, reset=reset)

    html = f"""
    <div style="font-family:sans-serif;max-width:600px;margin:0 auto">
      <div style="background:#1a5c2e;padding:24px 32px;text-align:center">
        <h1 style="color:#fff;margin:0;font-size:22px">KAFA — Kooperativ Asirans Fòs Ayiti</h1>
      </div>
      <div style="padding:32px;background:#fff">
        <p style="font-size:15px">Here's the link to reset your password to the KAFA member portal:</p>
        <div style="text-align:center;margin:32px 0">
          <a href="{link}"
             style="background:#1a5c2e;color:#fff;padding:14px 32px;border-radius:6px;text-decoration:none;font-weight:bold;font-size:16px;display:inline-block">
            Reset my password
          </a>
        </div>
        <p style="color:#888;font-size:13px">This link expires in 24 hours.</p>
        <p style="color:#888;font-size:13px">If you did not request this, you can ignore this email. Your account remains secure.</p>
      </div>
      <div style="background:#f0f0f0;padding:16px 32px;text-align:center;font-size:12px;color:#888">
        KAFA — 874 Rue Ste Catherine, Léogâne, Haïti
      </div>
    </div>"""

    ses.send_email(
        Source="KAFA <noreply@kafayiti.com>",
        Destination={"ToAddresses": [email]},
        Message={
            "Subject": {"Data": "KAFA — Reset your password"},
            "Body":    {"Html": {"Data": html}},
        },
    )
    logger.info("Password setup link sent for member: %s", member_id)
    return link


################################################################################
# POST /members/send-password-setup — admin sends member a password setup email
################################################################################

def _handle_send_password_setup(event: dict) -> dict:
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _resp(400, {"error": "Invalid JSON"})

    member_id  = body.get("memberId", "").strip()
    company_id = body.get("companyId", "KAFA-001").strip()
    if not member_id:
        return _resp(400, {"error": "memberId required"})

    member = _db_get_member(member_id, company_id)
    if not member:
        return _resp(404, {"error": "Member not found"})

    if not (member.get("email") or "").strip():
        return _resp(400, {"error": "No email address on file for this member. Add an email first."})

    link = _send_password_setup_email(member, requested_by_member=False)
    result = {"message": f"Password setup email sent to {member['email']}", "setupLink": link}
    return _resp(200, result)


################################################################################
# POST /members/set-credentials — admin sets a member's password
################################################################################

def _handle_set_member_credentials(event: dict) -> dict:
    """
    Admin-only. Sets or updates the 'credentials' attribute on a member record
    by storing the SHA-256 hash of the supplied password.
    """
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _resp(400, {"error": "Invalid JSON"})

    member_id  = body.get("memberId", "").strip()
    company_id = body.get("companyId", "KAFA-001").strip()
    password   = body.get("password", "").strip()

    if not member_id or not password:
        return _resp(400, {"error": "memberId and password are required"})

    if len(password) < 6:
        return _resp(400, {"error": "Password must be at least 6 characters"})

    password_hash = hashlib.sha256(password.encode()).hexdigest()

    dynamodb.Table(MEMBERS_TABLE).update_item(
        Key={"memberId": member_id, "companyId": company_id},
        UpdateExpression="SET credentials = :h",
        ExpressionAttributeValues={":h": password_hash},
    )

    logger.info("Credentials set for member: %s", member_id)
    return _resp(200, {"message": f"Password set successfully for member {member_id}"})


################################################################################
# GET /member/policy — list policies for a member
################################################################################

def _handle_get_member_policies(event: dict) -> dict:
    member_id = (event.get("queryStringParameters") or {}).get("memberId", "").strip()
    if not member_id:
        return _resp(400, {"error": "memberId required"})

    ins_table = dynamodb.Table(LIFE_INSURANCE_TABLE_NAME)

    from boto3.dynamodb.conditions import Key as _Key

    # Query the MEMBER# partition to get all POLICY# SK refs
    refs_resp = ins_table.query(
        KeyConditionExpression=_Key("PK").eq(f"MEMBER#{member_id}")
    )
    refs = [r for r in refs_resp.get("Items", []) if r.get("entity_type") == "MEMBER_POLICY_REF"]

    policies = []
    for ref in refs:
        pol_no = ref.get("policyNo", "")
        if not pol_no:
            continue
        pol_resp = ins_table.get_item(Key={"PK": f"POLICY#{pol_no}", "SK": "METADATA"})
        pol = pol_resp.get("Item")
        if not pol:
            continue

        # Fetch payment history (SCHED# items)
        sched_resp = ins_table.query(
            KeyConditionExpression=(
                _Key("PK").eq(f"POLICY#{pol_no}") &
                _Key("SK").begins_with("SCHED#")
            )
        )
        schedules = sched_resp.get("Items", [])
        payment_history = [
            {
                "paymentDate":   s.get("paidDate", ""),
                "referenceNo":   s.get("referenceNo") or s.get("externalRef") or s.get("SK", ""),
                "amountPaid":    float(s.get("paidAmount", 0)),
                "paymentPeriod": _due_date_to_period(s.get("dueDate", "")),
                "paymentMethod": s.get("paymentMethod", ""),
                "status":        s.get("status", "PENDING"),
            }
            for s in schedules if s.get("status") == "PAID"
        ]

        policies.append({
            "policy":         {k: str(v) if not isinstance(v, (str, bool, type(None))) else v
                               for k, v in pol.items()},
            "paymentHistory": payment_history,
        })

    return _resp(200, {"policies": policies})


################################################################################
# POST /member/enrollment — member applies for a plan or requests a plan switch
################################################################################

_PLAN_LABELS = {
    "BASIC":           "KAFA Basic (US$10/mo)",
    "STANDARD":        "KAFA Standard (US$20/mo)",
    "FUNERAL_SAVINGS": "KAFA Funeral Savings",
}

def _handle_member_enrollment(event: dict) -> dict:
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _resp(400, {"error": "Invalid JSON body"})

    member_id    = body.get("memberId",    "").strip()
    name         = body.get("name",        "").strip()
    phone        = body.get("phone",       "").strip()
    email_addr   = body.get("email",       "").strip()
    address      = body.get("address",     "").strip()
    plan         = body.get("plan",        "").strip().upper()
    request_type = body.get("requestType", "ENROLLMENT").strip().upper()
    current_plan = body.get("currentPlan", "").strip()
    notes        = body.get("notes",       "").strip()

    if not member_id or not name or not plan:
        return _resp(400, {"error": "memberId, name and plan are required"})

    is_switch   = request_type == "SWITCH"
    plan_label  = _PLAN_LABELS.get(plan, plan)

    # Resolve current plan label for switch requests (may be "LIFE-BASIC" etc.)
    current_label = ""
    if is_switch and current_plan:
        key = current_plan.split("-")[-1].upper()
        current_label = _PLAN_LABELS.get(key, _PLAN_LABELS.get(current_plan.upper(), current_plan))

    subject = (
        f"[KAFA] Changement de plan — {name}"
        if is_switch else
        f"[KAFA] Nouvelle demande d'adhésion — {name}"
    )

    switch_row = (
        f"<tr><td style='padding:8px;font-weight:bold;color:#555'>Plan actuel</td>"
        f"<td style='padding:8px'>{current_label}</td></tr>"
        if is_switch and current_label else ""
    )

    html = f"""
    <div style="font-family:Arial,sans-serif;max-width:600px;margin:auto">
      <h2 style="color:#1A5C2A">
        {"Changement de Plan" if is_switch else "Nouvelle Demande d'Adhésion"}
      </h2>
      <table style="width:100%;border-collapse:collapse">
        <tr><td style="padding:8px;font-weight:bold;color:#555">Membre</td>
            <td style="padding:8px">{name}</td></tr>
        <tr style="background:#f9f9f9">
            <td style="padding:8px;font-weight:bold;color:#555">ID Membre</td>
            <td style="padding:8px">{member_id}</td></tr>
        {switch_row}
        <tr><td style="padding:8px;font-weight:bold;color:#555">
              {"Nouveau plan demandé" if is_switch else "Plan demandé"}
            </td>
            <td style="padding:8px;color:#1A5C2A;font-weight:bold">{plan_label}</td></tr>
        <tr style="background:#f9f9f9">
            <td style="padding:8px;font-weight:bold;color:#555">Téléphone</td>
            <td style="padding:8px">{phone or "—"}</td></tr>
        <tr><td style="padding:8px;font-weight:bold;color:#555">Email</td>
            <td style="padding:8px">{email_addr or "—"}</td></tr>
        <tr style="background:#f9f9f9">
            <td style="padding:8px;font-weight:bold;color:#555">Adresse</td>
            <td style="padding:8px">{address or "—"}</td></tr>
        <tr><td style="padding:8px;font-weight:bold;color:#555">Notes</td>
            <td style="padding:8px">{notes or "—"}</td></tr>
      </table>
      <p style="margin-top:24px;color:#888;font-size:12px">
        Soumis via le portail membre KAFA
      </p>
    </div>"""

    try:
        ses.send_email(
            Source="KAFA <noreply@kafayiti.com>",
            Destination={"ToAddresses": ["kontak@kafayiti.com"]},
            Message={
                "Subject": {"Data": subject},
                "Body":    {"Html": {"Data": html}},
            },
        )
        logger.info("%s request sent: member %s → plan %s", request_type, member_id, plan)
    except Exception as exc:
        logger.error("SES error sending enrollment: %s", exc)
        return _resp(500, {"error": "Failed to send enrollment request"})

    return _resp(200, {"message": "Request received"})


################################################################################
# POST /member/death-report — member (or family) submits a death notification
################################################################################

_DEATH_REPORT_EMAILS = ["kontak@kafayiti.com", "kafayiti509@gmail.com"]

def _handle_death_report(event: dict) -> dict:
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _resp(400, {"error": "Invalid JSON body"})

    member_id      = body.get("memberId",      "").strip()
    member_name    = body.get("memberName",    "").strip()
    policy_no      = body.get("policyNo",      "").strip()
    date_of_death  = body.get("dateOfDeath",   "").strip()
    declarant_name = body.get("declarantName", "").strip()
    declarant_phone= body.get("declarantPhone","").strip()
    relationship   = body.get("relationship",  "").strip()
    notes          = body.get("notes",         "").strip()

    if not member_id or not date_of_death or not declarant_name:
        return _resp(400, {"error": "memberId, dateOfDeath and declarantName are required"})

    subject = f"[KAFA] Déclaration de décès — {member_name or member_id}"
    html = f"""
    <div style="font-family:Arial,sans-serif;max-width:600px;margin:auto">
      <h2 style="color:#B71C1C">Déclaration de Décès</h2>
      <table style="width:100%;border-collapse:collapse">
        <tr><td style="padding:8px;font-weight:bold;color:#555">Assuré</td>
            <td style="padding:8px">{member_name}</td></tr>
        <tr style="background:#f9f9f9">
            <td style="padding:8px;font-weight:bold;color:#555">Numéro de police</td>
            <td style="padding:8px">{policy_no or '—'}</td></tr>
        <tr><td style="padding:8px;font-weight:bold;color:#555">Date du décès</td>
            <td style="padding:8px">{date_of_death}</td></tr>
        <tr style="background:#f9f9f9">
            <td style="padding:8px;font-weight:bold;color:#555">Déclarant</td>
            <td style="padding:8px">{declarant_name}</td></tr>
        <tr><td style="padding:8px;font-weight:bold;color:#555">Téléphone déclarant</td>
            <td style="padding:8px">{declarant_phone or '—'}</td></tr>
        <tr style="background:#f9f9f9">
            <td style="padding:8px;font-weight:bold;color:#555">Relation</td>
            <td style="padding:8px">{relationship or '—'}</td></tr>
        <tr><td style="padding:8px;font-weight:bold;color:#555">Notes</td>
            <td style="padding:8px">{notes or '—'}</td></tr>
      </table>
      <p style="margin-top:24px;color:#888;font-size:12px">
        Soumis via le portail membre KAFA · ID membre: {member_id}
      </p>
    </div>"""

    try:
        if ENVIRONMENT == "dev":
            logger.info("DEV: death report not emailed — %s on %s by %s",
                        member_name, date_of_death, declarant_name)
        else:
            ses.send_email(
                Source="KAFA <noreply@kafayiti.com>",
                Destination={"ToAddresses": _DEATH_REPORT_EMAILS},
                Message={
                    "Subject": {"Data": subject},
                    "Body":    {"Html": {"Data": html}},
                },
            )
            logger.info("Death report sent for member %s (policy %s)", member_id, policy_no)
    except Exception as exc:
        logger.error("SES error sending death report: %s", exc)
        return _resp(500, {"error": "Failed to send death report notification"})

    return _resp(200, {"message": "Death report received"})


################################################################################
# GET /member/shares — list a member's share purchases (membership + preferred)
################################################################################

def _handle_get_member_shares(event: dict) -> dict:
    member_id = (event.get("queryStringParameters") or {}).get("memberId", "").strip()
    if not member_id:
        return _resp(400, {"error": "memberId required"})

    from boto3.dynamodb.conditions import Key as _Key

    shares_table = dynamodb.Table(SHARES_TABLE)
    resp = shares_table.query(
        KeyConditionExpression=_Key("memberID").eq(member_id),
        ScanIndexForward=False,  # newest first (shareId is time-ordered)
    )
    shares = [
        {
            "shareId":       s.get("shareId", ""),
            "amount":        float(s.get("amount", 0)),
            "datetime":      s.get("datetime", ""),
            "shareType":     s.get("share_type", ""),
            "apr":           float(s.get("APR", 0)),
            "status":        s.get("status", "PENDING"),
            "paymentMethod": s.get("paymentMethod", ""),
            "externalRef":   s.get("externalRef", ""),
        }
        for s in resp.get("Items", [])
    ]
    return _resp(200, {"shares": shares})


################################################################################
# POST /member/payment — admin records a manual premium payment (cash, MonCash,
# bank transfer). Stripe card payments go through /payments/create-intent
# instead — this route is only for the non-Stripe methods.
################################################################################

_MONTH_NAMES = {
    'January': 1, 'February': 2, 'March': 3, 'April': 4, 'May': 5, 'June': 6,
    'July': 7, 'August': 8, 'September': 9, 'October': 10, 'November': 11, 'December': 12,
}


def _parse_period_due_date(period: str, fallback: str) -> str:
    """'August 2026' -> '2026-08-01'. Falls back if unparseable."""
    parts = period.strip().split()
    if len(parts) == 2 and parts[0] in _MONTH_NAMES:
        try:
            year = int(parts[1])
            return f"{year:04d}-{_MONTH_NAMES[parts[0]]:02d}-01"
        except ValueError:
            pass
    return fallback


_MONTH_NUM_TO_NAME = {v: k for k, v in _MONTH_NAMES.items()}


def _due_date_to_period(due_date: str) -> str:
    """'2026-10-01' or '2026-10-31' -> 'October 2026'. Returns raw string on error."""
    try:
        y, m, _ = due_date.split("-")
        return f"{_MONTH_NUM_TO_NAME[int(m)]} {y}"
    except Exception:
        return due_date


def _set_payment_notification(
    member_id: str, company_id: str, *,
    amount, ref_no: str, method: str, item_label: str = "", period: str = "",
    currency: str = "usd",
) -> None:
    """
    Surfaces a "payment received" notification on the member's next login/
    refresh (bell icon on the member dashboard). Best-effort — failures here
    must never block the payment/share collection that triggered it.
    """
    try:
        dynamodb.Table(MEMBERS_TABLE).update_item(
            Key={"memberId": member_id, "companyId": company_id},
            UpdateExpression="SET payment_notification = :n",
            ExpressionAttributeValues={
                ":n": {
                    "amountPaid":     Decimal(str(amount)),
                    "paymentDate":    datetime.now(timezone.utc).isoformat(),
                    "referenceNo":    ref_no,
                    "policyNo":       item_label,
                    "paymentMethod":  method,
                    "paymentPeriod":  period,
                    "currency":       currency.lower(),
                    "seen":           False,
                }
            },
        )
    except Exception as exc:
        logger.warning("Could not set payment_notification for %s: %s", member_id, exc)


################################################################################
# POST /member/acknowledge-payment — member dismisses the payment notification
################################################################################

def _handle_acknowledge_payment(event: dict) -> dict:
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _resp(400, {"error": "Invalid JSON"})

    member_id  = body.get("memberId", "").strip()
    company_id = body.get("companyId", "KAFA-001").strip()
    if not member_id:
        return _resp(400, {"error": "memberId required"})

    try:
        dynamodb.Table(MEMBERS_TABLE).update_item(
            Key={"memberId": member_id, "companyId": company_id},
            UpdateExpression="SET payment_notification.#seen = :true",
            ExpressionAttributeNames={"#seen": "seen"},
            ExpressionAttributeValues={":true": True},
        )
    except Exception as exc:
        logger.warning("Could not acknowledge payment for %s: %s", member_id, exc)

    return _resp(200, {"message": "Acknowledged"})


def _handle_record_member_payment(event: dict) -> dict:
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _resp(400, {"error": "Invalid JSON"})

    policy_no    = body.get("policyNo", "").strip()
    member_id    = body.get("memberId", "").strip()
    company_id   = body.get("companyId", "KAFA-001").strip()
    method       = (body.get("paymentMethod") or "CASH").strip().upper()
    external_ref = body.get("externalRef", "").strip()
    period       = (body.get("paymentPeriod") or "").strip()

    if not policy_no or not member_id:
        return _resp(400, {"error": "policyNo and memberId are required"})
    try:
        amount_dec = Decimal(str(body.get("amount")))
    except Exception:
        return _resp(400, {"error": "amount is required"})
    if amount_dec <= 0:
        return _resp(400, {"error": "amount must be positive"})

    ins_table = dynamodb.Table(LIFE_INSURANCE_TABLE_NAME)
    pol_pk = f"POLICY#{policy_no}"
    policy = ins_table.get_item(Key={"PK": pol_pk, "SK": "METADATA"}).get("Item")
    if not policy:
        return _resp(404, {"error": "Policy not found"})

    from boto3.dynamodb.conditions import Key as _Key

    today = datetime.now(timezone.utc).date()
    ref_no = f"PAY-{secrets.token_hex(6).upper()}"

    sched_resp = ins_table.query(
        KeyConditionExpression=_Key("PK").eq(pol_pk) & _Key("SK").begins_with("SCHED#")
    )
    sched_items = sched_resp.get("Items", [])
    pending = sorted(
        (s for s in sched_items if s.get("status") == "PENDING"),
        key=lambda s: s.get("dueDate", ""),
    )

    if pending:
        sched_item = pending[0]
        paid_due_date_str = sched_item.get("dueDate") or today.isoformat()
        ins_table.update_item(
            Key={"PK": pol_pk, "SK": sched_item["SK"]},
            UpdateExpression=(
                "SET #s = :paid, paidAmount = :amt, paidDate = :today, "
                "paymentMethod = :method, externalRef = :ref, referenceNo = :refno"
            ),
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={
                ":paid": "PAID",
                ":amt": amount_dec,
                ":today": today.isoformat(),
                ":method": method,
                ":ref": external_ref,
                ":refno": ref_no,
            },
        )
    else:
        paid_due_date_str = _parse_period_due_date(period, today.isoformat())
        next_no = len(sched_items) + 1
        ins_table.put_item(Item={
            "PK": pol_pk,
            "SK": f"SCHED#{paid_due_date_str}#{next_no:06d}",
            "entity_type": "SCHEDULE",
            "policyNo": policy_no,
            "installmentNo": Decimal(str(next_no)),
            "dueDate": paid_due_date_str,
            "amountDue": amount_dec,
            "status": "PAID",
            "paidDate": today.isoformat(),
            "paidAmount": amount_dec,
            "paymentMethod": method,
            "externalRef": external_ref,
            "referenceNo": ref_no,
        })

    total_paid = Decimal(str(policy.get("totalPaid", 0))) + amount_dec
    # Advance from the period that was just paid, not from today — otherwise
    # paying a future-dated installment could regress nextDueDate backward.
    paid_due = datetime.fromisoformat(paid_due_date_str).date()
    next_due_dt = paid_due.replace(day=1) + timedelta(days=32)
    next_due = next_due_dt.replace(day=1).isoformat()
    ins_table.update_item(
        Key={"PK": pol_pk, "SK": "METADATA"},
        UpdateExpression=(
            "SET totalPaid = :tp, lastPaidDate = :ld, lastPaidAmount = :la, "
            "nextDueDate = :nd, updatedAt = :u"
        ),
        ExpressionAttributeValues={
            ":tp": total_paid,
            ":ld": today.isoformat(),
            ":la": amount_dec,
            ":nd": next_due,
            ":u": datetime.now(timezone.utc).isoformat(),
        },
    )

    _set_payment_notification(
        member_id, company_id,
        amount=amount_dec, ref_no=ref_no, method=method,
        item_label=policy_no, period=period,
    )

    logger.info("Manual payment %s recorded for policy %s (%s %s)",
                ref_no, policy_no, amount_dec, method)
    return _resp(201, {"message": "Payment recorded", "referenceNo": ref_no})


################################################################################
# POST /member/shares/manual — admin records a manual share purchase (cash,
# MonCash, bank transfer). Stripe card purchases go through
# /member/shares/create-intent instead — this route is only for non-Stripe.
################################################################################

_MEMBERSHIP_MIN_CENTS    = 100     # $1 minimum per payment
_MEMBERSHIP_TARGET_CENTS = 5_000   # $50 total to activate
_PREFERRED_MIN_CENTS     = 50_000
_SHARE_PENDING_REASON    = "Did not pay membership share"


def _sum_membership_shares_cents(member_id: str) -> int:
    """Returns total SUCCEEDED membership shares paid for member_id, in cents."""
    from boto3.dynamodb.conditions import Key as _Key
    table = dynamodb.Table(SHARES_TABLE)
    resp = table.query(KeyConditionExpression=_Key("memberID").eq(member_id))
    items = resp.get("Items", [])
    while resp.get("LastEvaluatedKey"):
        resp = table.query(
            KeyConditionExpression=_Key("memberID").eq(member_id),
            ExclusiveStartKey=resp["LastEvaluatedKey"],
        )
        items.extend(resp.get("Items", []))
    return int(sum(
        Decimal(str(s.get("amount", 0))) * 100
        for s in items
        if s.get("share_type") == "membership" and s.get("status") == "SUCCEEDED"
    ))


def _calculate_preferred_apr(amount_cents: int) -> float:
    """Mirrors lambda/create_share_intent.py's bracket table exactly."""
    amount_dollars = amount_cents / 100
    if amount_dollars >= 11_000:
        return 12.0
    if amount_dollars >= 5_001:
        return 10.0
    if amount_dollars >= 3_001:
        return 7.0
    if amount_dollars >= 2_001:
        return 6.0
    if amount_dollars >= 1_001:
        return 5.0
    return 4.0


def _handle_record_member_share(event: dict) -> dict:
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _resp(400, {"error": "Invalid JSON"})

    member_id    = body.get("member_id", "").strip()
    company_id   = body.get("company_id", "KAFA-001").strip()
    share_type   = (body.get("share_type") or "").strip().lower()
    method       = (body.get("payment_method") or "CASH").strip().upper()
    external_ref = body.get("external_ref", "").strip()

    try:
        amount_cents = int(round(float(body.get("amount_cents"))))
    except (TypeError, ValueError):
        return _resp(400, {"error": "amount_cents is required"})

    if not member_id:
        return _resp(400, {"error": "member_id required"})
    if share_type not in ("membership", "preferred"):
        return _resp(400, {"error": "share_type must be 'membership' or 'preferred'"})

    member = _db_get_member(member_id, company_id)
    if not member:
        return _resp(404, {"error": "Member not found"})

    is_pending = member.get("status") == "Pending"

    if share_type == "membership":
        if amount_cents < _MEMBERSHIP_MIN_CENTS:
            return _resp(400, {"error": "Minimum membership share payment is $1."})
        apr = Decimal("0")
    else:
        if is_pending:
            return _resp(403, {"error": "Pay the member's initial membership share before purchasing a preferred share."})
        if amount_cents < _PREFERRED_MIN_CENTS:
            return _resp(400, {"error": "Preferred shares require a $500 minimum."})
        apr = Decimal(str(_calculate_preferred_apr(amount_cents)))

    now = datetime.now(timezone.utc).isoformat()
    share_id = f"SHARE#{now}#{secrets.token_hex(4)}"

    shares_table = dynamodb.Table(SHARES_TABLE)
    shares_table.put_item(Item={
        "memberID":      member_id,
        "shareId":       share_id,
        "companyId":     company_id,
        "amount":        Decimal(str(amount_cents / 100)),
        "datetime":      now,
        "share_type":    share_type,
        "APR":           apr,
        "status":        "SUCCEEDED",
        "paymentMethod": method,
        "externalRef":   external_ref,
    })

    if share_type == "membership" and is_pending:
        total_paid = _sum_membership_shares_cents(member_id)
        members_table = dynamodb.Table(MEMBERS_TABLE)
        if total_paid >= _MEMBERSHIP_TARGET_CENTS:
            members_table.update_item(
                Key={"memberId": member_id, "companyId": company_id},
                UpdateExpression="SET #s = :active REMOVE #r, membershipSharesPaid",
                ExpressionAttributeNames={"#s": "status", "#r": "reason"},
                ExpressionAttributeValues={":active": "Active"},
            )
            logger.info("Member %s activated after admin-recorded membership share", member_id)
        else:
            members_table.update_item(
                Key={"memberId": member_id, "companyId": company_id},
                UpdateExpression="SET membershipSharesPaid = :paid",
                ExpressionAttributeValues={":paid": Decimal(str(total_paid / 100))},
            )
            logger.info("Member %s partial membership: %d/%d cents",
                        member_id, total_paid, _MEMBERSHIP_TARGET_CENTS)

    _set_payment_notification(
        member_id, company_id,
        amount=amount_cents / 100, ref_no=share_id, method=method,
        item_label=f"{share_type.capitalize()} Share",
    )

    logger.info("Admin recorded %s share %s for member %s (%s)",
                share_type, share_id, member_id, method)
    return _resp(201, {"message": "Share recorded", "shareId": share_id, "apr": float(apr)})


################################################################################
# POST /members/policies/create — admin creates a policy for a member
################################################################################

# KAFA plan catalog — mirrors the pricing shown on the Plans & Coverage screen.
_PLAN_CATALOG = {
    "BASIC": {
        "productCode":   "LIFE-BASIC",
        "planId":        "plan-basic-monthly",
        "premiumAmount": Decimal("10"),
        "sumAssured":    Decimal("270000"),
    },
    "STANDARD": {
        "productCode":   "LIFE-STANDARD",
        "planId":        "plan-standard-monthly",
        "premiumAmount": Decimal("20"),
        "sumAssured":    Decimal("400000"),
    },
}


def _next_policy_number(ins_table) -> str:
    """Scans for the highest existing POL-KAFA-###### number and increments it."""
    resp = ins_table.scan(
        FilterExpression="entity_type = :t",
        ExpressionAttributeValues={":t": "POLICY"},
        ProjectionExpression="policyNo",
    )
    items = resp.get("Items", [])
    while "LastEvaluatedKey" in resp:
        resp = ins_table.scan(
            FilterExpression="entity_type = :t",
            ExpressionAttributeValues={":t": "POLICY"},
            ProjectionExpression="policyNo",
            ExclusiveStartKey=resp["LastEvaluatedKey"],
        )
        items.extend(resp.get("Items", []))

    max_seq = 0
    for item in items:
        pol_no = item.get("policyNo", "")
        if pol_no.startswith("POL-KAFA-"):
            try:
                max_seq = max(max_seq, int(pol_no.rsplit("-", 1)[-1]))
            except ValueError:
                continue
    return f"POL-KAFA-{max_seq + 1:06d}"


def _handle_create_member_policy(event: dict) -> dict:
    """
    Admin-only. Creates a new policy for a member from the fixed KAFA plan
    catalog (BASIC or STANDARD). A member may hold more than one policy.
    """
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _resp(400, {"error": "Invalid JSON"})

    member_id  = body.get("memberId", "").strip()
    company_id = body.get("companyId", "KAFA-001").strip()
    plan_code  = body.get("planCode", "").strip().upper()

    if not member_id:
        return _resp(400, {"error": "memberId required"})
    plan = _PLAN_CATALOG.get(plan_code)
    if not plan:
        return _resp(400, {"error": f"Unknown planCode '{plan_code}'. Expected BASIC or STANDARD."})

    member = _db_get_member(member_id, company_id)
    if not member:
        return _resp(404, {"error": "Member not found"})
    member_name = member.get("full_name", "Unknown")

    ins_table = dynamodb.Table(LIFE_INSURANCE_TABLE_NAME)
    pol_no = _next_policy_number(ins_table)
    pol_pk = f"POLICY#{pol_no}"

    today      = datetime.now(timezone.utc).date()
    next_month = today.replace(day=1) + timedelta(days=32)
    next_due   = next_month.replace(day=1).isoformat()
    start_str  = today.isoformat()

    with ins_table.batch_writer() as batch:
        batch.put_item(Item={
            "PK":            pol_pk,
            "SK":            "METADATA",
            "GSI2PK":        next_due,
            "GSI2SK":        pol_pk,
            "GSI4PK":        "ACTIVE",
            "GSI4SK":        next_due,
            "entity_type":   "POLICY",
            "policyNo":      pol_no,
            "memberId":      member_id,
            "companyId":     company_id,
            "memberName":    member_name,
            "productCode":   plan["productCode"],
            "planId":        plan["planId"],
            "frequency":     "MONTHLY",
            "startDate":     start_str,
            "endDate":       "",
            "policyStatus":  "ACTIVE",
            "sumAssured":    plan["sumAssured"],
            "premiumAmount": plan["premiumAmount"],
            "nextDueDate":   next_due,
            "lastPaidDate":  "",
            "lastPaidAmount": Decimal("0"),
            "totalPaid":     Decimal("0"),
            "createdAt":     f"{today.isoformat()}T00:00:00Z",
            "updatedAt":     f"{today.isoformat()}T00:00:00Z",
        })

        batch.put_item(Item={
            "PK":           f"MEMBER#{member_id}",
            "SK":           pol_pk,
            "entity_type":  "MEMBER_POLICY_REF",
            "memberId":     member_id,
            "companyId":    company_id,
            "policyNo":     pol_no,
            "productCode":  plan["productCode"],
            "policyStatus": "ACTIVE",
            "premiumAmount": plan["premiumAmount"],
            "sumAssured":   plan["sumAssured"],
            "startDate":    start_str,
            "nextDueDate":  next_due,
        })

        # First installment due immediately (PENDING)
        batch.put_item(Item={
            "PK":           pol_pk,
            "SK":           f"SCHED#{next_due}#000001",
            "entity_type":  "SCHEDULE",
            "policyNo":     pol_no,
            "installmentNo": Decimal("1"),
            "dueDate":      next_due,
            "amountDue":    plan["premiumAmount"],
            "status":       "PENDING",
            "paidDate":     "",
            "paidAmount":   Decimal("0"),
        })

    logger.info("Policy %s created for member %s (plan %s)", pol_no, member_id, plan_code)
    return _resp(201, {
        "message":  "Policy created successfully",
        "policyNo": pol_no,
        "policy": {
            "policyNo":      pol_no,
            "memberId":      member_id,
            "productCode":   plan["productCode"],
            "premiumAmount": str(plan["premiumAmount"]),
            "sumAssured":    str(plan["sumAssured"]),
            "policyStatus":  "ACTIVE",
            "nextDueDate":   next_due,
        },
    })


################################################################################
# GET /member/documents — list documents for a member
################################################################################

def _handle_get_member_documents(event: dict) -> dict:
    member_id = (event.get("queryStringParameters") or {}).get("memberId", "").strip()
    if not member_id:
        return _resp(400, {"error": "memberId required"})

    from boto3.dynamodb.conditions import Key as _Key

    docs_table = dynamodb.Table("kopera-member-documents")
    try:
        resp = docs_table.query(
            KeyConditionExpression=_Key("memberId").eq(member_id)
        )
        items = resp.get("Items", [])
        documents = []
        for item in items:
            doc_key = item.get("s3Key", "")
            url = ""
            if doc_key:
                try:
                    url = s3_client.generate_presigned_url(
                        "get_object",
                        Params={"Bucket": ASSETS_BUCKET, "Key": doc_key},
                        ExpiresIn=3600,
                    )
                except Exception:
                    pass
            documents.append({
                "documentId": item.get("documentId", ""),
                "name":       item.get("name", ""),
                "type":       item.get("docType", ""),
                "uploadedAt": item.get("uploadedAt", ""),
                "url":        url,
            })
        documents.sort(key=lambda d: d["uploadedAt"], reverse=True)
        return _resp(200, {"documents": documents})
    except Exception as exc:
        _log_error("list_documents", exc, {"memberId": member_id})
        return _resp(500, {"error": "Something went wrong."})


################################################################################
# POST /member/documents/upload — create doc record + presigned S3 PUT URL
################################################################################

def _handle_request_document_upload(event: dict) -> dict:
    import uuid as _uuid

    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _resp(400, {"error": "Invalid JSON"})

    member_id = body.get("memberId", "").strip()
    name      = body.get("name", "").strip()
    doc_type  = body.get("docType", "Autre").strip()

    if not member_id or not name:
        return _resp(400, {"error": "memberId and name required"})

    doc_id    = f"DOC-{_uuid.uuid4().hex[:10].upper()}"
    s3_key    = f"documents/{member_id}/{doc_id}/{name}"
    timestamp = datetime.now(timezone.utc).isoformat()

    # Save record to DynamoDB
    docs_table = dynamodb.Table("kopera-member-documents")
    docs_table.put_item(Item={
        "memberId":   member_id,
        "documentId": doc_id,
        "name":       name,
        "docType":    doc_type,
        "s3Key":      s3_key,
        "uploadedAt": timestamp,
    })

    # Generate presigned PUT URL (valid 15 min)
    upload_url = s3_client.generate_presigned_url(
        "put_object",
        Params={"Bucket": ASSETS_BUCKET, "Key": s3_key},
        ExpiresIn=900,
    )

    return _resp(201, {"documentId": doc_id, "uploadUrl": upload_url})


################################################################################
# GET /member/beneficiaries?memberId=  — list all beneficiaries for a member
# POST /member/beneficiaries           — create / update a beneficiary
################################################################################

def _handle_get_member_beneficiaries(event: dict) -> dict:
    from boto3.dynamodb.conditions import Key as _Key

    member_id = (event.get("queryStringParameters") or {}).get("memberId", "").strip()
    if not member_id:
        return _resp(400, {"error": "memberId required"})

    ins_table = dynamodb.Table(LIFE_INSURANCE_TABLE_NAME)

    refs_resp = ins_table.query(
        KeyConditionExpression=_Key("PK").eq(f"MEMBER#{member_id}")
    )
    refs = [r for r in refs_resp.get("Items", []) if r.get("entity_type") == "MEMBER_POLICY_REF"]

    beneficiaries = []
    for ref in refs:
        pol_no = ref.get("policyNo", "")
        if not pol_no:
            continue
        bene_resp = ins_table.query(
            KeyConditionExpression=(
                _Key("PK").eq(f"POLICY#{pol_no}") &
                _Key("SK").begins_with("BENEFICIARY#")
            )
        )
        for b in bene_resp.get("Items", []):
            beneficiaries.append({
                "beneficiaryId": b.get("SK", ""),
                "policyNo":      pol_no,
                "name":          b.get("name", ""),
                "relationship":  b.get("relationship", ""),
                "sharePercent":  int(b.get("sharePercent", b.get("percentage", 0))),
            })

    return _resp(200, {"beneficiaries": beneficiaries})


def _handle_save_member_beneficiary(event: dict) -> dict:
    from boto3.dynamodb.conditions import Key as _Key
    import uuid

    try:
        body = json.loads(event.get("body") or "{}")
    except (json.JSONDecodeError, TypeError):
        return _resp(400, {"error": "Invalid JSON body"})

    member_id    = body.get("memberId", "").strip()
    policy_no    = body.get("policyNo", "").strip()
    name         = body.get("name", "").strip()
    relationship = body.get("relationship", "").strip()
    share        = body.get("sharePercent")
    bene_id      = (body.get("beneficiaryId") or "").strip()

    if not all([member_id, policy_no, name, relationship]) or share is None:
        return _resp(400, {"error": "memberId, policyNo, name, relationship and sharePercent are required"})
    try:
        share = int(share)
    except (TypeError, ValueError):
        return _resp(400, {"error": "sharePercent must be an integer"})
    if not (1 <= share <= 100):
        return _resp(400, {"error": "sharePercent must be between 1 and 100"})

    ins_table = dynamodb.Table(LIFE_INSURANCE_TABLE_NAME)

    refs_resp = ins_table.query(
        KeyConditionExpression=_Key("PK").eq(f"MEMBER#{member_id}")
    )
    refs = [r for r in refs_resp.get("Items", []) if r.get("entity_type") == "MEMBER_POLICY_REF"]
    policy_nos = {r.get("policyNo") for r in refs}
    if policy_no not in policy_nos:
        return _resp(403, {"error": "Policy does not belong to this member"})

    sk = bene_id if (bene_id and bene_id.startswith("BENEFICIARY#")) else f"BENEFICIARY#{uuid.uuid4().hex[:8].upper()}"

    ins_table.put_item(Item={
        "PK":           f"POLICY#{policy_no}",
        "SK":           sk,
        "entity_type":  "BENEFICIARY",
        "name":         name,
        "relationship": relationship,
        "sharePercent": share,
        "updatedAt":    datetime.now(timezone.utc).isoformat(),
    })

    return _resp(200, {"beneficiaryId": sk})


################################################################################
# GET /prospects
################################################################################

def _list_prospects() -> dict:
    table = dynamodb.Table(PROSPECTS_TABLE)
    items = []
    kwargs: dict = {}
    while True:
        resp = table.scan(**kwargs)
        items.extend(resp.get("Items", []))
        last = resp.get("LastEvaluatedKey")
        if not last:
            break
        kwargs["ExclusiveStartKey"] = last

    prospects = []
    for item in items:
        data = item.get("data") or {}
        prospects.append({
            "id":               item.get("id", ""),
            "firstName":        item.get("firstName", ""),
            "lastName":         item.get("lastName", ""),
            "phone":            item.get("phone", ""),
            "email":            item.get("email", ""),
            "memberNumber":     item.get("memberNumber", ""),
            "plan":             item.get("plan") or data.get("plan", ""),
            "message":          item.get("message", ""),
            "createdAt":        item.get("createdAt", ""),
            "address":          item.get("address") or data.get("address", ""),
            "commune":          item.get("commune") or data.get("commune", ""),
            "gender":           item.get("gender") or data.get("gender", ""),
            "profession":       item.get("profession") or data.get("profession", ""),
            "birthDatePlace":   item.get("birthDatePlace") or data.get("birthDatePlace", ""),
            "idType":           item.get("idType") or data.get("idType", ""),
            "idNumber":         item.get("idNumber") or data.get("idNumber", ""),
            "idIssueDetails":   item.get("idIssueDetails") or data.get("idIssueDetails", ""),
            "idExpirationDate": item.get("idExpirationDate") or data.get("idExpirationDate", ""),
            "accepterNote":     item.get("accepterNote", ""),
            "status":           item.get("status", ""),
        })
    prospects.sort(key=lambda p: p.get("createdAt", ""), reverse=True)
    return _resp(200, {"prospects": prospects, "count": len(prospects)})


################################################################################
# PATCH /prospects/{id}
################################################################################

_VALID_STATUSES = {"accepted", "pending", "rejected"}

def _update_prospect(event: dict) -> dict:
    prospect_id = (event.get("pathParameters") or {}).get("id")
    if not prospect_id:
        return _resp(400, {"error": "Missing prospect id in path"})

    try:
        body = json.loads(event.get("body") or "{}")
    except Exception:
        return _resp(400, {"error": "Invalid JSON body"})

    new_status = body.get("status", "").lower()
    note       = body.get("note")

    if not new_status and note is None:
        return _resp(400, {"error": "Provide at least one of: status, note"})
    if new_status and new_status not in _VALID_STATUSES:
        return _resp(400, {"error": f"status must be one of: {', '.join(_VALID_STATUSES)}"})

    prospects = dynamodb.Table(PROSPECTS_TABLE)
    resp      = prospects.get_item(Key={"id": prospect_id})
    prospect  = resp.get("Item")
    if not prospect:
        return _resp(404, {"error": "Prospect not found"})

    result = {}

    if not new_status:
        prospects.update_item(
            Key={"id": prospect_id},
            UpdateExpression="SET accepterNote = :n, updatedAt = :u",
            ExpressionAttributeValues={":n": note, ":u": datetime.now(timezone.utc).isoformat()},
        )
        return _resp(200, {"prospectId": prospect_id, "noteSaved": True})

    if new_status == "accepted" and prospect.get("status") != "accepted":
        try:
            member_id   = _prospect_generate_member_id(prospect)
            setup_token = _prospect_create_member(prospect, member_id)
            result["memberId"]      = member_id
            result["memberCreated"] = True
            result["setupLink"]     = f"{MEMBER_PORTAL_URL}?setup={setup_token}"
        except Exception as e:
            return _resp(500, {"error": f"Failed to create member: {e}"})
        try:
            _prospect_send_approval_email(prospect, member_id, setup_token)
        except Exception as e:
            print(f"Approval email failed (non-blocking): {e}")

    update_expr  = "SET #s = :s, updatedAt = :u"
    expr_names   = {"#s": "status"}
    expr_values  = {":s": new_status, ":u": datetime.now(timezone.utc).isoformat()}
    if note is not None:
        update_expr += ", accepterNote = :n"
        expr_values[":n"] = note

    prospects.update_item(
        Key={"id": prospect_id},
        UpdateExpression=update_expr,
        ExpressionAttributeNames=expr_names,
        ExpressionAttributeValues=expr_values,
    )

    if result.get("memberId"):
        prospects.update_item(
            Key={"id": prospect_id},
            UpdateExpression="SET memberId = :m",
            ExpressionAttributeValues={":m": result["memberId"]},
        )

    result["prospectId"] = prospect_id
    result["status"]     = new_status
    return _resp(200, result)


def _prospect_generate_member_id(prospect: dict) -> str:
    existing = (prospect.get("memberNumber") or "").strip()
    if existing and len(existing) == 13 and existing.startswith("MK"):
        return existing
    resp = dynamodb.Table(COMPANIES_TABLE).update_item(
        Key={"companyId": "KAFA-001"},
        UpdateExpression="ADD #seq :one",
        ExpressionAttributeNames={"#seq": "sequence"},
        ExpressionAttributeValues={":one": Decimal("1")},
        ReturnValues="UPDATED_NEW",
    )
    seq = int(resp["Attributes"]["sequence"])
    return f"MK001{seq:08d}"


def _prospect_create_member(prospect: dict, member_id: str) -> str:
    first     = prospect.get("firstName", "")
    last      = prospect.get("lastName", "")
    full_name = f"{first} {last}".strip() or "Unknown"
    data      = prospect.get("data") or {}

    setup_token  = secrets.token_urlsafe(7)   # 10 URL-safe chars
    token_expiry = (datetime.now(timezone.utc) + timedelta(days=7)).isoformat()

    dynamodb.Table(MEMBERS_TABLE).put_item(Item={
        "memberId":          member_id,
        "companyId":         "KAFA-001",
        "full_name":         full_name,
        "phone":             prospect.get("phone") or "",
        "email":             prospect.get("email") or "",
        "address":           prospect.get("address") or data.get("address") or "",
        "date_of_birth":     prospect.get("birthDatePlace") or data.get("birthDatePlace") or "",
        "id_number":         prospect.get("idNumber") or data.get("idNumber") or "",
        "id_type":           prospect.get("idType") or data.get("idType") or "",
        "nationality":       "HTI",
        "status":            "Pending",
        "reason":            "Did not pay membership share",
        "notes":             prospect.get("message") or "",
        "issued_date":       datetime.now(timezone.utc).strftime("%d / %m / %Y"),
        "createdAt":         datetime.now(timezone.utc).isoformat(),
        "sourceProspectId":  prospect.get("id", ""),
        "setupToken":        setup_token,
        "setupTokenExpiry":  token_expiry,
    })
    return setup_token


def _prospect_send_approval_email(prospect: dict, member_id: str, setup_token: str) -> None:
    email = (prospect.get("email") or "").strip()
    if not email:
        return
    first = prospect.get("firstName", "")
    last  = prospect.get("lastName", "")
    name  = f"{first} {last}".strip() or "Member"
    html  = f"""
    <div style="font-family:sans-serif;max-width:600px;margin:0 auto">
      <div style="background:#1a5c2e;padding:24px 32px;text-align:center">
        <h1 style="color:#fff;margin:0;font-size:22px">KAFA — Kooperativ Asirans Fòs Ayiti</h1>
      </div>
      <div style="padding:32px;background:#fff">
        <h2 style="color:#1a5c2e;margin-top:0">Congratulations, {name}! \U0001f389</h2>
        <p>We are pleased to inform you that your KAFA membership application has been <strong>approved</strong>.</p>
        <div style="text-align:center;margin:32px 0">
          <a href="{MEMBER_PORTAL_URL}?setup={setup_token}"
             style="background:#1a5c2e;color:#fff;padding:14px 32px;border-radius:6px;
                    text-decoration:none;font-weight:bold;font-size:16px;display:inline-block">
            Access Member Portal
          </a>
        </div>
      </div>
    </div>"""
    ses.send_email(
        Source="KAFA <noreply@kafayiti.com>",
        Destination={"ToAddresses": [email]},
        Message={
            "Subject": {"Data": "KAFA — Membership Approved! Welcome to the Family"},
            "Body":    {"Html": {"Data": html}},
        },
    )


################################################################################
# HTTP response helper
################################################################################

def _resp(status_code: int, body: dict) -> dict:
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type":                "application/json",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Headers": "Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token,X-Amz-Content-Sha256",
            "Access-Control-Allow-Methods": "GET,POST,PATCH,OPTIONS",
        },
        "body": json.dumps(body, default=str),
    }