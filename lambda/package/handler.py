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
import hashlib
import boto3
import requests
from boto3.dynamodb.conditions import Attr
from decimal import Decimal
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
ADMIN_TABLE      = os.environ.get("ADMIN_TABLE", "kopera-admin")
LOCALITIES_TABLE = os.environ.get("LOCALITIES_TABLE", "kopera-localities")
ANTHROPIC_API_KEY = os.environ.get("ANTHROPIC_API_KEY", "")
LIFE_INSURANCE_TABLE = os.environ.get("LIFE_INSURANCE_TABLE", "kopera-life-insurance")

################################################################################
# Router
################################################################################

def lambda_handler(event, context):
    logger.info("Event: %s", json.dumps(event))

    method   = event.get("httpMethod", "")
    resource = event.get("resource", "")

    # ── CORS preflight ────────────────────────────────────────────────────────
    if method == "OPTIONS":
        return _resp(200, {})

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

    # ── POST /members/set-payment-access — admin grants/revokes payment access ─
    if method == "POST" and resource == "/members/set-payment-access":
        return _handle_set_payment_access(event)

    # ── GET /member/profile — fetch fresh member profile ─────────────────────
    if method == "GET" and resource == "/member/profile":
        return _handle_get_member_profile(event)

    # ── POST /member/acknowledge-payment — member dismisses payment notification
    if method == "POST" and resource == "/member/acknowledge-payment":
        return _handle_acknowledge_payment(event)

    # ── GET /member/policy — fetch member's policies ──────────────────────────
    if method == "GET" and resource == "/member/policy":
        return _handle_get_member_policy(event)

    # ── POST /member/payment — record a premium payment ───────────────────────
    if method == "POST" and resource == "/member/payment":
        return _handle_make_payment(event)

    # ── POST /member/claim — submit a new claim ───────────────────────────────
    if method == "POST" and resource == "/member/claim":
        return _handle_create_claim(event)

    # ── POST /member/chat — AI chatbot for member portal ──────────────────────
    if method == "POST" and resource == "/member/chat":
        return _handle_member_chat(event)

    # ── GET /member/beneficiaries — fetch beneficiaries for a member ──────────
    if method == "GET" and resource == "/member/beneficiaries":
        return _handle_get_member_beneficiaries(event)

    # ── POST /member/beneficiaries — add or update a beneficiary ─────────────
    if method == "POST" and resource == "/member/beneficiaries":
        return _handle_save_member_beneficiary(event)

    # ── POST /member/login — member self-service login ────────────────────────
    if method == "POST" and resource == "/member/login":
        return _handle_member_login(event)

    # ── POST /members/set-credentials — admin sets member password ────────────
    if method == "POST" and resource == "/members/set-credentials":
        return _handle_set_member_credentials(event)

    # ── POST /members/create — create new member with uniqueness check ─────────
    if method == "POST" and resource == "/members/create":
        return _handle_create_member(event)

    # ── POST /auth/login — validate admin credentials ────────────────────────
    if method == "POST" and resource == "/auth/login":
        return _handle_admin_login(event)

    # ── GET /member/partners — funeral service partners directory ─────────────
    if method == "GET" and resource == "/member/partners":
        return _handle_get_partners(event)

    # ── GET /member/documents — list documents for a member ──────────────────
    if method == "GET" and resource == "/member/documents":
        return _handle_get_documents(event)

    # ── POST /member/documents/upload — request presigned PUT URL ────────────
    if method == "POST" and resource == "/member/documents/upload":
        return _handle_request_upload_url(event)

    # ── POST /member/death-report — report death, send SES email ─────────────
    if method == "POST" and resource == "/member/death-report":
        return _handle_death_report(event)

    # ── POST /member/enrollment — express enrollment request ──────────────────
    if method == "POST" and resource == "/member/enrollment":
        return _handle_enrollment(event)

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
        now_utc = datetime.now(timezone.utc)
        fr_months = [
            "", "Janvier", "Février", "Mars", "Avril", "Mai", "Juin",
            "Juillet", "Août", "Septembre", "Octobre", "Novembre", "Décembre"
        ]
        issued_date = f"{now_utc.day} {fr_months[now_utc.month]} {now_utc.year}"
        timestamp   = now_utc.isoformat()

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

    if phone:
        phone_check = table.scan(FilterExpression=Attr("phone").eq(phone))
        if phone_check.get("Items"):
            return _resp(409, {"error": f"Phone number '{phone}' is already registered to another member"})

    if email:
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
        "status":                body.get("status", True),
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

    phone = body.get("phone", "").strip()
    if phone:
        phone_check = table.scan(FilterExpression=Attr("phone").eq(phone))
        for item in phone_check.get("Items", []):
            if item["memberId"] != old_member_id:
                return _resp(409, {"error": f"Phone '{phone}' is already registered to another member"})

    email = body.get("email", "").strip()
    if email:
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
# GET /member/policy — fetch all policies for a member
################################################################################

def _handle_get_member_policy(event: dict) -> dict:
    params    = (event.get("queryStringParameters") or {})
    member_id = params.get("memberId", "").strip()
    if not member_id:
        return _resp(400, {"error": "memberId is required"})

    table = dynamodb.Table(LIFE_INSURANCE_TABLE)

    # 1. Get policy references for this member
    refs = table.query(
        KeyConditionExpression="PK = :pk AND begins_with(SK, :sk)",
        ExpressionAttributeValues={
            ":pk": f"MEMBER#{member_id}",
            ":sk": "POLICY#",
        },
    ).get("Items", [])

    if not refs:
        return _resp(200, {"policies": []})

    policies = []
    for ref in refs:
        policy_no = ref.get("policyNo") or ref["SK"].replace("POLICY#", "")
        pk = f"POLICY#{policy_no}"

        # 2. Get policy METADATA
        meta = table.get_item(Key={"PK": pk, "SK": "METADATA"}).get("Item", {})

        # 3. Get last payment (most recent PAY# item)
        pays = table.query(
            KeyConditionExpression="PK = :pk AND begins_with(SK, :sk)",
            ExpressionAttributeValues={":pk": pk, ":sk": "PAY#"},
            ScanIndexForward=False,
            Limit=1,
        ).get("Items", [])
        last_pay = pays[0] if pays else {}

        # 4. Get next pending schedule
        scheds = table.query(
            KeyConditionExpression="PK = :pk AND begins_with(SK, :sk)",
            FilterExpression="attribute_not_exists(paidDate) OR paidDate = :empty",
            ExpressionAttributeValues={":pk": pk, ":sk": "SCHED#", ":empty": ""},
            ScanIndexForward=True,
            Limit=1,
        ).get("Items", [])
        next_sched = scheds[0] if scheds else {}

        # 5. Get existing claims
        claims = table.query(
            KeyConditionExpression="PK = :pk AND begins_with(SK, :sk)",
            ExpressionAttributeValues={":pk": pk, ":sk": "CLAIM#"},
            ScanIndexForward=False,
        ).get("Items", [])

        policies.append({
            "policy":    {k: str(v) if isinstance(v, Decimal) else v for k, v in meta.items()},
            "lastPay":   {k: str(v) if isinstance(v, Decimal) else v for k, v in last_pay.items()},
            "nextSched": {k: str(v) if isinstance(v, Decimal) else v for k, v in next_sched.items()},
            "claims":    [{k: str(v) if isinstance(v, Decimal) else v for k, v in c.items()} for c in claims],
        })

    return _resp(200, {"policies": policies})


################################################################################
# POST /member/payment — record a premium payment
################################################################################

def _handle_make_payment(event: dict) -> dict:
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _resp(400, {"error": "Invalid JSON"})

    policy_no      = body.get("policyNo", "").strip()
    amount         = body.get("amount")
    payment_method = body.get("paymentMethod", "CASH").strip()
    sched_sk       = body.get("schedSK", "").strip()
    member_id      = body.get("memberId", "").strip()
    company_id     = body.get("companyId", "KAFA-001").strip()
    external_ref   = body.get("externalRef", "").strip()
    external_details = body.get("externalDetails", {})
    payment_period = body.get("paymentPeriod", "").strip()  # e.g. "May 2026"

    if not policy_no or not amount or not member_id:
        return _resp(400, {"error": "policyNo, amount, and memberId are required"})

    import uuid, datetime
    now       = datetime.datetime.utcnow()
    date_str  = now.strftime("%Y-%m-%d")
    ref_no    = f"TXN-{now.strftime('%Y%m%d')}-{uuid.uuid4().hex[:8].upper()}"
    pay_sk    = f"PAY#{date_str}#{ref_no}"

    ins_table = dynamodb.Table(LIFE_INSURANCE_TABLE)
    mem_table = dynamodb.Table(MEMBERS_TABLE)

    # Write payment record
    ins_table.put_item(Item={
        "PK":             f"POLICY#{policy_no}",
        "SK":             pay_sk,
        "GSI3PK":         ref_no,
        "entity_type":    "PAYMENT",
        "referenceNo":    ref_no,
        "policyNo":       policy_no,
        "schedSK":        sched_sk,
        "paymentDate":    date_str,
        "paymentPeriod":  payment_period,
        "amountPaid":     Decimal(str(amount)),
        "lateFee":        Decimal("0"),
        "totalCollected": Decimal(str(amount)),
        "paymentMethod":  payment_method,
        "channel":        "ADMIN_WEB",
        "externalRef":    external_ref,
        "externalDetails": external_details,
        "collectedBy":    "ADMIN",
        "voided":         False,
        "createdAt":      now.isoformat() + "Z",
    })

    # Mark schedule as paid if schedSK provided
    if sched_sk:
        ins_table.update_item(
            Key={"PK": f"POLICY#{policy_no}", "SK": sched_sk},
            UpdateExpression="SET #s = :paid, paidDate = :d, paidAmount = :a",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={
                ":paid": "PAID",
                ":d":    date_str,
                ":a":    Decimal(str(amount)),
            },
        )

    # Update policy last paid info
    ins_table.update_item(
        Key={"PK": f"POLICY#{policy_no}", "SK": "METADATA"},
        UpdateExpression="SET lastPaidDate = :d, lastPaidAmount = :a, totalPaid = if_not_exists(totalPaid, :zero) + :a, updatedAt = :now",
        ExpressionAttributeValues={
            ":d":    date_str,
            ":a":    Decimal(str(amount)),
            ":zero": Decimal("0"),
            ":now":  now.isoformat() + "Z",
        },
    )

    # Write payment notification to kopera-member so member sees confirmation
    try:
        mem_table.update_item(
            Key={"memberId": member_id, "companyId": company_id},
            UpdateExpression="SET payment_notification = :n",
            ExpressionAttributeValues={":n": {
                "referenceNo":   ref_no,
                "policyNo":      policy_no,
                "amountPaid":    str(amount),
                "paymentDate":   date_str,
                "paymentPeriod": payment_period,
                "paymentMethod": payment_method,
                "seen":          False,
            }},
        )
    except Exception as e:
        logger.warning("Could not write payment notification to member: %s", str(e))

    logger.info("Payment recorded: %s for policy %s", ref_no, policy_no)
    return _resp(201, {"message": "Payment recorded successfully", "referenceNo": ref_no})


################################################################################
# POST /member/claim — submit a new claim
################################################################################

def _handle_create_claim(event: dict) -> dict:
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _resp(400, {"error": "Invalid JSON"})

    policy_no   = body.get("policyNo", "").strip()
    claim_type  = body.get("claimType", "").strip()
    description = body.get("description", "").strip()
    member_id   = body.get("memberId", "").strip()

    if not policy_no or not claim_type or not member_id:
        return _resp(400, {"error": "policyNo, claimType, and memberId are required"})

    import uuid, datetime
    now      = datetime.datetime.utcnow()
    claim_no = f"CLM-{now.strftime('%Y%m%d')}-{uuid.uuid4().hex[:6].upper()}"
    claim_sk = f"CLAIM#{claim_no}"

    table = dynamodb.Table(LIFE_INSURANCE_TABLE)

    table.put_item(Item={
        "PK":          f"POLICY#{policy_no}",
        "SK":          claim_sk,
        "entity_type": "CLAIM",
        "claimNo":     claim_no,
        "policyNo":    policy_no,
        "memberId":    member_id,
        "claimType":   claim_type,
        "description": description,
        "claimStatus": "SUBMITTED",
        "submittedAt": now.isoformat() + "Z",
        "updatedAt":   now.isoformat() + "Z",
    })

    logger.info("Claim created: %s for policy %s", claim_no, policy_no)
    return _resp(201, {"message": "Claim submitted successfully", "claimNo": claim_no})


################################################################################
# POST /member/chat — Claude-powered chatbot for the member portal
################################################################################

def _handle_member_chat(event: dict) -> dict:
    """
    Accepts a conversation history and the member's profile, calls Claude
    Sonnet via the Anthropic Messages API, and returns the assistant reply.

    Request body:
        {
            "messages": [{"role": "user"|"assistant", "content": "..."}],
            "member":   { ...member profile fields... },
            "locale":   "fr" | "en"
        }
    """
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _resp(400, {"error": "Invalid JSON"})

    if not ANTHROPIC_API_KEY:
        return _resp(500, {"error": "Chatbot not configured."})

    messages = body.get("messages", [])
    member   = body.get("member", {})
    locale   = body.get("locale", "fr")

    if not messages:
        return _resp(400, {"error": "messages array is required"})

    # ── Date formatter matching the 5 supported locales ───────────────────────
    def fmt_date(raw: str) -> str:
        """Convert ISO or DD/MM/YYYY to the locale's long date format."""
        if not raw or raw in ("N/A", "None", ""):
            return raw or "N/A"
        try:
            from datetime import datetime as dt
            cleaned = raw.replace(" ", "")
            if "/" in cleaned:
                parts = cleaned.split("/")
                if len(parts) == 3:
                    raw = f"{parts[2]}-{parts[1].zfill(2)}-{parts[0].zfill(2)}"
            d = dt.strptime(raw[:10], "%Y-%m-%d")
            en = ["","January","February","March","April","May","June",
                  "July","August","September","October","November","December"]
            fr = ["","Janvier","Février","Mars","Avril","Mai","Juin",
                  "Juillet","Août","Septembre","Octobre","Novembre","Décembre"]
            es = ["","Enero","Febrero","Marzo","Abril","Mayo","Junio",
                  "Julio","Agosto","Septiembre","Octubre","Noviembre","Diciembre"]
            pt = ["","Janeiro","Fevereiro","Março","Abril","Maio","Junho",
                  "Julho","Agosto","Setembro","Outubro","Novembro","Dezembro"]
            if locale == "en":
                return f"{en[d.month]} {d.day}, {d.year}"
            elif locale in ("fr", "ht"):
                return f"{d.day} {fr[d.month]} {d.year}"
            elif locale == "es":
                return f"{d.day} de {es[d.month]} de {d.year}"
            elif locale == "pt":
                return f"{d.day} de {pt[d.month]} de {d.year}"
            else:
                return f"{d.day} {fr[d.month]} {d.year}"
        except Exception:
            return raw

    # ── Build system prompt with full member context ──────────────────────────
    name       = member.get("full_name", "the member")
    member_id  = member.get("memberId", "")
    phone      = member.get("phone", "")
    email      = member.get("email", "")
    address    = member.get("address", "")
    dob        = fmt_date(member.get("date_of_birth", ""))
    status     = member.get("status", True)
    is_active  = status is True or status == "true"
    locality   = member.get("locality") or {}
    commune    = locality.get("commune", "")
    id_number  = member.get("identification_number", "") or member.get("id_number", "")
    id_type    = member.get("identification_type", "")  or member.get("id_type", "")
    cert       = member.get("certificate") or {}
    issued_date = fmt_date(cert.get("issued_date", ""))

    # ── Fetch policy and payment history from kopera-life-insurance ───────────
    policy_context = ""
    try:
        ins_table = dynamodb.Table(LIFE_INSURANCE_TABLE)
        # 1. Get policy references for this member
        refs = ins_table.query(
            KeyConditionExpression="PK = :pk AND begins_with(SK, :sk)",
            ExpressionAttributeValues={
                ":pk": f"MEMBER#{member_id}",
                ":sk": "POLICY#",
            },
        ).get("Items", [])

        policy_lines = []
        for ref in refs:
            pol_no = ref.get("policyNo") or ref["SK"].replace("POLICY#", "")
            pk     = f"POLICY#{pol_no}"

            # Get policy metadata
            meta = ins_table.get_item(Key={"PK": pk, "SK": "METADATA"}).get("Item", {})
            status_pol    = meta.get("policyStatus", "—")
            premium       = str(meta.get("premiumAmount", "—"))
            sum_assured   = str(meta.get("sumAssured", "—"))
            next_due      = fmt_date(meta.get("nextDueDate", ""))
            last_paid_date = fmt_date(meta.get("lastPaidDate", ""))
            last_paid_amt  = str(meta.get("lastPaidAmount", "—"))
            total_paid     = str(meta.get("totalPaid", "0"))
            product        = meta.get("productCode", "—")
            frequency      = meta.get("frequency", "—")

            # Get last 5 payments
            pays = ins_table.query(
                KeyConditionExpression="PK = :pk AND begins_with(SK, :sk)",
                ExpressionAttributeValues={":pk": pk, ":sk": "PAY#"},
                ScanIndexForward=False,
                Limit=5,
            ).get("Items", [])

            pay_lines = []
            for p in pays:
                p_date   = fmt_date(str(p.get("paymentDate", "")))
                p_amt    = str(p.get("amountPaid", "—"))
                p_method = p.get("paymentMethod", "—")
                p_period = p.get("paymentPeriod", "")
                p_ref    = p.get("referenceNo", "—")
                period_str = f" (period: {p_period})" if p_period else ""
                pay_lines.append(
                    f"    • {p_date}: HTG {p_amt} via {p_method}{period_str} — Ref: {p_ref}"
                )

            # Get next pending schedule
            scheds = ins_table.query(
                KeyConditionExpression="PK = :pk AND begins_with(SK, :sk)",
                FilterExpression="attribute_not_exists(paidDate) OR paidDate = :empty",
                ExpressionAttributeValues={":pk": pk, ":sk": "SCHED#", ":empty": ""},
                ScanIndexForward=True,
                Limit=1,
            ).get("Items", [])
            next_sched_due = fmt_date(scheds[0].get("dueDate", "")) if scheds else next_due
            next_sched_amt = str(scheds[0].get("amountDue", premium)) if scheds else premium

            policy_lines.append(
                f"  Policy: {pol_no} | Product: {product} | Status: {status_pol} | "
                f"Frequency: {frequency}\n"
                f"  Premium: HTG {premium}/month | Sum Assured: HTG {sum_assured}\n"
                f"  Last Payment: {last_paid_date} — HTG {last_paid_amt}\n"
                f"  Next Payment Due: {next_sched_due} — HTG {next_sched_amt}\n"
                f"  Total Paid To Date: HTG {total_paid}\n"
                f"  Recent Payment History:\n" +
                ("\n".join(pay_lines) if pay_lines else "    • No payments recorded yet")
            )

        if policy_lines:
            policy_context = "\n\nINSURANCE POLICIES & PAYMENT HISTORY:\n" + \
                             "\n\n".join(policy_lines)
        else:
            policy_context = "\n\nINSURANCE POLICIES: No policies found for this member."
    except Exception as e:
        logger.warning("Could not fetch policy data for chatbot: %s", str(e))
        policy_context = "\n\nINSURANCE POLICIES: Unable to retrieve policy data."

    lang_instruction = (
        "Always detect the language of the user's most recent message and respond in that exact language. "
        "If they write in Haitian Creole (Kreyòl), respond in Kreyòl. "
        "If they write in French, respond in French. "
        "If they write in English, respond in English. "
        "If they write in Spanish, respond in Spanish. "
        "If they write in Portuguese, respond in Portuguese. "
        "Never switch languages unless the user switches first."
    )
    org_descs = {
        "fr": "KAFA (Koperativ Asirans Fòs Ayiti) est une coopérative d'assurance haïtienne.",
        "en": "KAFA (Koperativ Asirans Fòs Ayiti) is a Haitian insurance cooperative.",
        "ht": "KAFA (Koperativ Asirans Fòs Ayiti) se yon kooperativ asirans ayisyen.",
        "es": "KAFA (Koperativ Asirans Fòs Ayiti) es una cooperativa de seguros haitiana.",
        "pt": "KAFA (Koperativ Asirans Fòs Ayiti) é uma cooperativa de seguros haitiana.",
    }
    org_desc = org_descs.get(locale, org_descs["fr"])

    system_prompt = f"""You are the KAFA member assistant — a friendly, helpful AI chatbot for {org_desc}
{lang_instruction}

You are speaking with a verified KAFA member. Here is their complete profile:

- Full Name:     {name}
- Member ID:     {member_id}
- Status:        {"Active" if is_active else "Inactive"}
- Date of Birth: {dob}
- Address:       {address}
- Commune:       {commune}
- Phone:         {phone}
- Email:         {email}
- ID Type:       {id_type}
- ID Number:     {id_number}
- Certificate:   {cert.get("certificate_id", "None")} (issued: {issued_date})
{policy_context}

Your role:
- Answer questions about their membership, status, personal information, policies, and payment history using the data above.
- Explain KAFA cooperative benefits and services warmly.
- Keep replies concise and conversational (2–4 sentences unless more detail is requested).
- Never make up information not in the profile. If you don't know something, say so honestly.
- Never share credentials or sensitive system details."""

    # ── Call Anthropic Messages API ───────────────────────────────────────────
    try:
        response = requests.post(
            "https://api.anthropic.com/v1/messages",
            headers={
                "x-api-key":         ANTHROPIC_API_KEY,
                "anthropic-version": "2023-06-01",
                "content-type":      "application/json",
            },
            json={
                "model":      "claude-sonnet-4-6",
                "max_tokens": 512,
                "system":     system_prompt,
                "messages":   messages,
            },
            timeout=30,
        )
        response.raise_for_status()
        data  = response.json()
        reply = data["content"][0]["text"]
        logger.info("Chat reply generated for member %s", member_id)
        return _resp(200, {"reply": reply})

    except requests.exceptions.Timeout:
        return _resp(504, {"error": "The assistant took too long to respond. Please try again."})
    except Exception as e:
        logger.error("Anthropic API error: %s | response: %s", str(e),
                     getattr(getattr(e, 'response', None), 'text', 'n/a'))
        return _resp(502, {"error": "Assistant unavailable. Please try again."})


################################################################################
# POST /member/login — member self-service login
################################################################################

def _handle_member_login(event: dict) -> dict:
    """
    Allows a cooperative member to log in using their email or phone number
    plus a password. Scans kopera-member for a matching identifier, verifies
    the SHA-256 hashed password stored in the 'credentials' attribute, and
    returns the member's profile (excluding credentials).
    """
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _resp(400, {"error": "Invalid JSON"})

    identifier = body.get("identifier", "").strip()   # email OR phone
    password   = body.get("password", "").strip()

    if not identifier or not password:
        return _resp(400, {"error": "identifier (email or phone) and password are required"})

    password_hash = hashlib.sha256(password.encode()).hexdigest()
    table         = dynamodb.Table(MEMBERS_TABLE)

    # Scan for email match
    resp  = table.scan(FilterExpression=Attr("email").eq(identifier))
    items = resp.get("Items", [])

    # Fall back to phone match if no email hit
    if not items:
        resp  = table.scan(FilterExpression=Attr("phone").eq(identifier))
        items = resp.get("Items", [])

    if not items:
        return _resp(401, {"error": "No member found with that email or phone number."})

    member = items[0]

    stored_hash = member.get("credentials")
    if not stored_hash:
        return _resp(401, {"error": "This account does not have a password set. Please contact your administrator."})

    if stored_hash != password_hash:
        return _resp(401, {"error": "Incorrect password."})

    # Return member profile — never include credentials in the response
    safe_member = {k: v for k, v in member.items() if k != "credentials"}
    # Ensure payment_access defaults to False if not set
    safe_member.setdefault("payment_access", False)
    logger.info("Member login: %s", member.get("memberId"))
    return _resp(200, {"message": "Login successful", "member": safe_member})


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
# POST /members/set-payment-access — admin grants/revokes payment access
################################################################################

def _handle_set_payment_access(event: dict) -> dict:
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _resp(400, {"error": "Invalid JSON"})

    member_id  = body.get("memberId", "").strip()
    company_id = body.get("companyId", "KAFA-001").strip()
    enabled    = bool(body.get("enabled", False))

    if not member_id:
        return _resp(400, {"error": "memberId is required"})

    dynamodb.Table(MEMBERS_TABLE).update_item(
        Key={"memberId": member_id, "companyId": company_id},
        UpdateExpression="SET payment_access = :v",
        ExpressionAttributeValues={":v": enabled},
    )
    action = "granted" if enabled else "revoked"
    logger.info("Payment access %s for member %s", action, member_id)
    return _resp(200, {"message": f"Payment access {action} for {member_id}"})


################################################################################
# GET /member/profile — return fresh member profile (used on dashboard init)
################################################################################

def _handle_get_member_profile(event: dict) -> dict:
    params     = (event.get("queryStringParameters") or {})
    member_id  = params.get("memberId", "").strip()
    company_id = params.get("companyId", "KAFA-001").strip()

    if not member_id:
        return _resp(400, {"error": "memberId is required"})

    member = _db_get_member(member_id, company_id)
    if not member:
        return _resp(404, {"error": "Member not found"})

    safe = {k: v for k, v in member.items() if k != "credentials"}
    safe.setdefault("payment_access", False)
    return _resp(200, {"member": safe})


################################################################################
# POST /member/acknowledge-payment — member dismisses payment notification
################################################################################

def _handle_acknowledge_payment(event: dict) -> dict:
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _resp(400, {"error": "Invalid JSON"})

    member_id  = body.get("memberId", "").strip()
    company_id = body.get("companyId", "KAFA-001").strip()

    if not member_id:
        return _resp(400, {"error": "memberId is required"})

    try:
        dynamodb.Table(MEMBERS_TABLE).update_item(
            Key={"memberId": member_id, "companyId": company_id},
            UpdateExpression="SET payment_notification.#seen = :t",
            ExpressionAttributeNames={"#seen": "seen"},
            ExpressionAttributeValues={":t": True},
        )
    except Exception:
        pass  # Notification may not exist — safe to ignore

    return _resp(200, {"message": "Acknowledged"})


################################################################################
# HTTP response helper
################################################################################

################################################################################
# GET /member/beneficiaries — fetch all beneficiaries for a member
################################################################################

def _handle_get_member_beneficiaries(event: dict) -> dict:
    params    = (event.get("queryStringParameters") or {})
    member_id = params.get("memberId", "").strip()
    if not member_id:
        return _resp(400, {"error": "memberId is required"})

    table = dynamodb.Table(LIFE_INSURANCE_TABLE)

    # 1. Get the member's policy references (MEMBER#<id> → POLICY# items)
    refs = table.query(
        KeyConditionExpression="PK = :pk AND begins_with(SK, :sk)",
        ExpressionAttributeValues={
            ":pk": f"MEMBER#{member_id}",
            ":sk": "POLICY#",
        },
    ).get("Items", [])

    beneficiaries = []
    for ref in refs:
        policy_no = ref.get("policyNo") or ref["SK"].replace("POLICY#", "")
        pk = f"POLICY#{policy_no}"

        # 2. Query all BENEF# items under this policy
        response = table.query(
            KeyConditionExpression="PK = :pk AND begins_with(SK, :sk)",
            ExpressionAttributeValues={":pk": pk, ":sk": "BENEF#"},
        )
        items = response.get("Items", [])
        while "LastEvaluatedKey" in response:
            response = table.query(
                KeyConditionExpression="PK = :pk AND begins_with(SK, :sk)",
                ExpressionAttributeValues={":pk": pk, ":sk": "BENEF#"},
                ExclusiveStartKey=response["LastEvaluatedKey"],
            )
            items.extend(response.get("Items", []))

        for b in items:
            beneficiaries.append({
                "beneficiaryId": b.get("SK", ""),
                "policyNo":      policy_no,
                "name":          b.get("fullName", b.get("name", "—")),
                "relationship":  b.get("relationship", "—"),
                "sharePercent":  int(b["sharePct"]) if "sharePct" in b else (
                                 int(b["sharePercent"]) if "sharePercent" in b else None),
                "isPrimary":     b.get("isPrimary", False),
                "dateOfBirth":   b.get("dateOfBirth", ""),
                "phone":         b.get("phone", ""),
            })

    return _resp(200, {"beneficiaries": beneficiaries, "count": len(beneficiaries)})


################################################################################
# POST /member/beneficiaries — add or update a beneficiary
################################################################################

def _handle_save_member_beneficiary(event: dict) -> dict:
    import uuid, datetime
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _resp(400, {"error": "Invalid JSON"})

    member_id     = body.get("memberId", "").strip()
    policy_no     = body.get("policyNo", "").strip()
    name          = body.get("name", "").strip()
    relationship  = body.get("relationship", "").strip()
    share_percent = body.get("sharePercent")
    beneficiary_id = body.get("beneficiaryId", "").strip()  # empty = new record

    if not member_id:
        return _resp(400, {"error": "memberId is required"})
    if not policy_no:
        return _resp(400, {"error": "policyNo is required"})
    if not name:
        return _resp(400, {"error": "name is required"})
    if not relationship:
        return _resp(400, {"error": "relationship is required"})
    if share_percent is None or not (1 <= int(share_percent) <= 100):
        return _resp(400, {"error": "sharePercent must be between 1 and 100"})

    # Derive SK — reuse existing or generate new
    if beneficiary_id and beneficiary_id.startswith("BENEF#"):
        sk = beneficiary_id
    elif beneficiary_id:
        sk = f"BENEF#{beneficiary_id}"
    else:
        sk = f"BENEF#{uuid.uuid4().hex[:8].upper()}"

    now = datetime.datetime.utcnow().isoformat() + "Z"
    table = dynamodb.Table(LIFE_INSURANCE_TABLE)

    item = {
        "PK":           f"POLICY#{policy_no}",
        "SK":           sk,
        "entity_type":  "BENEFICIARY",
        "policyNo":     policy_no,
        "memberId":     member_id,
        "fullName":     name,
        "name":         name,          # keep both for compatibility
        "relationship": relationship,
        "sharePct":     int(share_percent),
        "sharePercent": int(share_percent),
        "updatedAt":    now,
    }
    # Preserve createdAt on update
    if not beneficiary_id:
        item["createdAt"] = now

    table.put_item(Item=item)

    logger.info("Saved beneficiary %s for policy %s member %s", sk, policy_no, member_id)
    return _resp(201, {"beneficiaryId": sk, "message": "Beneficiary saved"})


################################################################################
# GET /member/partners — funeral service partner directory
################################################################################

def _handle_get_partners(event: dict) -> dict:
    """Return hardcoded partner list (or from DynamoDB if PARTNERS table added later)."""
    partners = [
        {
            "partnerId":  "PARTNER#001",
            "name":       "Pompes Funèbres Nationale",
            "phone":      "+509 2940-0000",
            "email":      "contact@pfn.ht",
            "address":    "Route de Delmas 75",
            "city":       "Port-au-Prince",
        },
        {
            "partnerId":  "PARTNER#002",
            "name":       "Services Funéraires Caraïbes",
            "phone":      "+509 3700-1111",
            "email":      "info@sfcaraibes.ht",
            "address":    "Blvd 15 Octobre",
            "city":       "Cap-Haïtien",
        },
        {
            "partnerId":  "PARTNER#003",
            "name":       "Maison du Dernier Repos",
            "phone":      "+509 2810-2222",
            "email":      "mdr@funeraires.ht",
            "address":    "Rue des Capois 12",
            "city":       "Port-au-Prince",
        },
    ]
    return _resp(200, {"partners": partners, "count": len(partners)})


################################################################################
# GET /member/documents — list member documents
# POST /member/documents/upload — request presigned PUT URL
################################################################################

def _handle_get_documents(event: dict) -> dict:
    params    = event.get("queryStringParameters") or {}
    member_id = params.get("memberId", "").strip()
    if not member_id:
        return _resp(400, {"error": "memberId is required"})

    table = dynamodb.Table(LIFE_INSURANCE_TABLE)
    documents = []
    kwargs = {
        "KeyConditionExpression": "PK = :pk AND begins_with(SK, :sk)",
        "ExpressionAttributeValues": {":pk": f"MEMBER#{member_id}", ":sk": "DOCUMENT#"},
    }
    while True:
        response = table.query(**kwargs)
        for item in response.get("Items", []):
            documents.append({
                "documentId": item.get("SK", ""),
                "name":       item.get("name", "—"),
                "docType":    item.get("docType", ""),
                "uploadedAt": item.get("uploadedAt", ""),
                "url":        item.get("downloadUrl", ""),
            })
        if "LastEvaluatedKey" not in response:
            break
        kwargs["ExclusiveStartKey"] = response["LastEvaluatedKey"]

    return _resp(200, {"documents": documents, "count": len(documents)})


def _handle_request_upload_url(event: dict) -> dict:
    import uuid, datetime
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _resp(400, {"error": "Invalid JSON"})

    member_id = body.get("memberId", "").strip()
    name      = body.get("name", "document").strip()
    doc_type  = body.get("docType", "Autre").strip()

    if not member_id:
        return _resp(400, {"error": "memberId is required"})

    doc_id  = f"DOC#{uuid.uuid4().hex[:8].upper()}"
    now     = datetime.datetime.utcnow().isoformat() + "Z"
    s3_key  = f"members/{member_id}/documents/{doc_id}/{name}"

    # Generate presigned PUT URL (10-minute expiry)
    upload_url = s3_client.generate_presigned_url(
        "put_object",
        Params={"Bucket": CERTS_BUCKET, "Key": s3_key, "ContentType": "application/octet-stream"},
        ExpiresIn=600,
    )

    # Generate presigned GET URL for later download
    download_url = s3_client.generate_presigned_url(
        "get_object",
        Params={"Bucket": CERTS_BUCKET, "Key": s3_key},
        ExpiresIn=86400,
    )

    # Store document record in DynamoDB
    dynamodb.Table(LIFE_INSURANCE_TABLE).put_item(Item={
        "PK":          f"MEMBER#{member_id}",
        "SK":          f"DOCUMENT#{doc_id}",
        "entity_type": "DOCUMENT",
        "memberId":    member_id,
        "documentId":  doc_id,
        "name":        name,
        "docType":     doc_type,
        "s3Key":       s3_key,
        "downloadUrl": download_url,
        "uploadedAt":  now,
    })

    return _resp(201, {"uploadUrl": upload_url, "documentId": doc_id})


################################################################################
# POST /member/death-report — report death + SES notification
################################################################################

ADMIN_EMAIL = os.environ.get("ADMIN_EMAIL", "admin@kafa.org")

def _handle_death_report(event: dict) -> dict:
    import uuid, datetime
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _resp(400, {"error": "Invalid JSON"})

    member_id      = body.get("memberId", "").strip()
    member_name    = body.get("memberName", "—")
    policy_no      = body.get("policyNo", "—")
    date_of_death  = body.get("dateOfDeath", "—")
    declarant_name = body.get("declarantName", "—")
    declarant_phone = body.get("declarantPhone", "")
    relationship   = body.get("relationship", "—")
    notes          = body.get("notes", "")

    if not member_id:
        return _resp(400, {"error": "memberId is required"})
    if not date_of_death or date_of_death == "—":
        return _resp(400, {"error": "dateOfDeath is required"})
    if not declarant_name or declarant_name == "—":
        return _resp(400, {"error": "declarantName is required"})

    report_id = uuid.uuid4().hex[:8].upper()
    now       = datetime.datetime.utcnow().isoformat() + "Z"

    # Store report in DynamoDB
    dynamodb.Table(LIFE_INSURANCE_TABLE).put_item(Item={
        "PK":           f"MEMBER#{member_id}",
        "SK":           f"DEATH#{report_id}",
        "entity_type":  "DEATH_REPORT",
        "memberId":     member_id,
        "memberName":   member_name,
        "policyNo":     policy_no,
        "dateOfDeath":  date_of_death,
        "declarantName": declarant_name,
        "declarantPhone": declarant_phone,
        "relationship": relationship,
        "notes":        notes,
        "reportedAt":   now,
        "status":       "PENDING",
    })

    # Send SES email notification to admin
    try:
        ses_client = boto3.client("ses", region_name=AWS_REGION)
        email_body = (
            f"DEATH REPORT — {now}\n\n"
            f"Assuré:        {member_name} ({member_id})\n"
            f"Police:        {policy_no}\n"
            f"Date décès:    {date_of_death}\n"
            f"Déclarant:     {declarant_name}\n"
            f"Téléphone:     {declarant_phone}\n"
            f"Relation:      {relationship}\n"
            f"Notes:         {notes}\n"
            f"Report ID:     {report_id}\n"
        )
        ses_client.send_email(
            Source=ADMIN_EMAIL,
            Destination={"ToAddresses": [ADMIN_EMAIL]},
            Message={
                "Subject": {"Data": f"[KAFA] Déclaration de décès — {member_name}"},
                "Body":    {"Text": {"Data": email_body}},
            },
        )
        logger.info("Death report email sent for member %s report %s", member_id, report_id)
    except Exception as e:
        logger.error("SES send failed: %s", str(e))
        # Don't fail the whole request if email fails — record is already stored

    return _resp(201, {"reportId": report_id, "message": "Death report received"})


################################################################################
# POST /member/enrollment — express enrollment request
################################################################################

def _handle_enrollment(event: dict) -> dict:
    import uuid, datetime
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _resp(400, {"error": "Invalid JSON"})

    member_id = body.get("memberId", "").strip()
    name      = body.get("name", "").strip()
    phone     = body.get("phone", "").strip()
    email     = body.get("email", "").strip()
    address   = body.get("address", "").strip()
    plan      = body.get("plan", "BASIC").strip().upper()

    if not member_id:
        return _resp(400, {"error": "memberId is required"})
    if not name:
        return _resp(400, {"error": "name is required"})

    enrollment_id = uuid.uuid4().hex[:8].upper()
    now           = datetime.datetime.utcnow().isoformat() + "Z"

    dynamodb.Table(LIFE_INSURANCE_TABLE).put_item(Item={
        "PK":           f"MEMBER#{member_id}",
        "SK":           f"ENROLLMENT#{enrollment_id}",
        "entity_type":  "ENROLLMENT",
        "memberId":     member_id,
        "name":         name,
        "phone":        phone,
        "email":        email,
        "address":      address,
        "plan":         plan,
        "status":       "PENDING",
        "submittedAt":  now,
    })

    # Notify admin via SES
    try:
        ses_client = boto3.client("ses", region_name=AWS_REGION)
        email_body = (
            f"EXPRESS ENROLLMENT — {now}\n\n"
            f"Nom:       {name}\n"
            f"ID:        {member_id}\n"
            f"Téléphone: {phone}\n"
            f"Email:     {email}\n"
            f"Adresse:   {address}\n"
            f"Formule:   {plan}\n"
            f"Ref:       {enrollment_id}\n"
        )
        ses_client.send_email(
            Source=ADMIN_EMAIL,
            Destination={"ToAddresses": [ADMIN_EMAIL]},
            Message={
                "Subject": {"Data": f"[KAFA] Demande d'adhésion — {name}"},
                "Body":    {"Text": {"Data": email_body}},
            },
        )
    except Exception as e:
        logger.error("SES send failed for enrollment: %s", str(e))

    return _resp(201, {"enrollmentId": enrollment_id, "message": "Enrollment request received"})


def _resp(status_code: int, body: dict) -> dict:
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type":                "application/json",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Headers": "Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token,X-Amz-Content-Sha256",
            "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
        },
        "body": json.dumps(body, default=str),
    }
