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
import json
import logging
import boto3
import requests
from boto3.dynamodb.conditions import Attr
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest

################################################################################
# Bootstrap
################################################################################

logger = logging.getLogger()
logger.setLevel(logging.INFO)

_session  = boto3.session.Session()
dynamodb  = boto3.resource("dynamodb")
s3_client = boto3.client("s3")

MEMBERS_TABLE   = os.environ["MEMBERS_TABLE"]    # kopera-member
COMPANIES_TABLE = os.environ["COMPANIES_TABLE"]  # kopera-company
CERTS_BUCKET    = os.environ["CERTS_BUCKET"]     # kopera-certificate
ASSETS_BUCKET   = os.environ["ASSETS_BUCKET"]    # kopera-asset
ENVIRONMENT     = os.environ.get("ENVIRONMENT", "prod")
AWS_REGION      = os.environ.get("AWS_REGION", "us-east-1")
API_BASE_URL    = os.environ["API_BASE_URL"]     # https://<id>.execute-api.<region>.amazonaws.com/prod

################################################################################
# Router
################################################################################

def lambda_handler(event, context):
    logger.info("Event: %s", json.dumps(event))

    method   = event.get("httpMethod", "")
    resource = event.get("resource", "")

    # ── GET /lookup?phone= ────────────────────────────────────────────────────
    if method == "GET" and resource == "/lookup":
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

    return _resp(404, {"error": f"Route not found: {method} {resource}"})


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

    # ── Step 2: Confirm via certplatform-prod-api GET /members ────────────────
    confirmed = _apigw_get(f"/members?memberId={member_id}&companyId={company_id}")
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

    # ── Step 5: Return the two S3 links ───────────────────────────────────────
    return _resp(200, {
        "member_id":      member_id,
        "company_id":     company_id,
        "full_name":      confirmed.get("full_name", ""),
        "phone":          phone,
        "certificate_id": cert.get("certificate_id"),
        "issued_date":    cert.get("issued_date"),
        "documents": {
            "pdf":  pdf_url,
            "jpeg": jpeg_url,
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
        member_id  = body["member_id"]
        company_id = body["company_id"]
    except (KeyError, json.JSONDecodeError) as exc:
        return _resp(400, {"error": f"Missing field: {exc}"})

    try:
        import io, uuid
        from datetime import datetime, timezone

        member  = _apigw_get(f"/members?memberId={member_id}&companyId={company_id}")
        company = _apigw_get(f"/companies?companyId={company_id}")

        if not member:  return _resp(404, {"error": f"Member not found: {member_id}"})
        if not company: return _resp(404, {"error": f"Company not found: {company_id}"})

        # Import PDF/JPEG generation from the shared module
        from certificate_engine import generate_pdf, generate_jpeg

        certificate_id = f"CERT-{uuid.uuid4().hex[:8].upper()}"
        issued_date    = datetime.now(timezone.utc).strftime("%d / %m / %Y")
        timestamp      = datetime.now(timezone.utc).isoformat()

        pdf_bytes  = generate_pdf(member, company, certificate_id, issued_date)
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
        logger.exception("Certificate generation failed")
        return _resp(500, {"error": str(exc)})


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
# HTTP response helper
################################################################################

def _resp(status_code: int, body: dict) -> dict:
    return {
        "statusCode": status_code,
        "headers":    {"Content-Type": "application/json"},
        "body":       json.dumps(body, default=str),
    }
