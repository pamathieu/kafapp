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
logger.setLevel(logging.INFO)

_session  = boto3.session.Session()
dynamodb  = boto3.resource("dynamodb")
s3_client = boto3.client("s3")
ses       = boto3.client("ses", region_name="us-east-1")

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

################################################################################
# Router
################################################################################

def lambda_handler(event, context):
    logger.info("Event: %s", json.dumps(event))

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

    # ── POST /member/login — member self-service login ────────────────────────
    if method == "POST" and resource == "/member/login":
        return _handle_member_login(event)

    # ── POST /member/profile/update — member edits their own profile ──────────
    if method == "POST" and resource == "/member/profile/update":
        return _handle_member_profile_update(event)

    # ── POST /members/set-credentials — admin sets member password ────────────
    if method == "POST" and resource == "/members/set-credentials":
        return _handle_set_member_credentials(event)

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
        member_id  = body.get("memberId") or body.get("member_id")
        company_id = body.get("companyId") or body.get("company_id")
        if not member_id or not company_id:
            raise KeyError("memberId / companyId")
    except (KeyError, json.JSONDecodeError) as exc:
        return _resp(400, {"error": f"Missing field: {exc}"})

    try:
        import io, uuid
        from datetime import datetime, timezone

        member  = _apigw_get(f"/members?memberId={member_id}&companyId={company_id}")
        company = _apigw_get(f"/companies?companyId={company_id}")

        if not member:  return _resp(404, {"error": f"Member not found: {member_id}"})
        if not company: return _resp(404, {"error": f"Company not found: {company_id}"})

        status = member.get("status", True)
        is_active = status if isinstance(status, bool) else str(status).lower() == "true"
        if not is_active:
            return _resp(400, {"error": "Cannot generate certificate for an inactive member"})

        # Import PDF/JPEG generation from the shared module
        from certificate_engine import generate_pdf, generate_jpeg

        certificate_id = f"CERT-{uuid.uuid4().hex[:8].upper()}"
        issued_date    = datetime.now(timezone.utc).strftime("%d / %m / %Y")
        timestamp      = datetime.now(timezone.utc).isoformat()

        pdf_bytes  = generate_pdf(member, company, certificate_id, issued_date, s3_client=s3)
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

    # ── First-time password setup flow ────────────────────────────────────────
    setup_password = body.get("setupPassword", "").strip()
    setup_token    = body.get("setupToken", "").strip()
    if setup_password and setup_token:
        if len(setup_password) < 6:
            return _resp(400, {"error": "Password must be at least 6 characters"})
        table = dynamodb.Table(MEMBERS_TABLE)
        resp  = table.scan(FilterExpression=Attr("setupToken").eq(setup_token))
        items = resp.get("Items", [])
        if not items:
            return _resp(401, {"error": "Invalid setup link."})
        member = items[0]
        if member.get("credentials"):
            return _resp(409, {"error": "Password already set. Please log in normally."})
        expiry_str = member.get("setupTokenExpiry", "")
        if expiry_str and datetime.fromisoformat(expiry_str) < datetime.now(timezone.utc):
            return _resp(410, {"error": "This setup link has expired. Request a new one from the login screen."})
        pw_hash = hashlib.sha256(setup_password.encode()).hexdigest()
        table.update_item(
            Key={"memberId": member["memberId"], "companyId": member.get("companyId", "KAFA-001")},
            UpdateExpression="SET credentials = :h, setupToken = :null, setupTokenExpiry = :null",
            ExpressionAttributeValues={":h": pw_hash, ":null": None},
        )
        logger.info("First-time password setup for member: %s", member["memberId"])
        safe = {k: v for k, v in member.items() if k not in ("credentials", "setupToken", "setupTokenExpiry")}
        return _resp(200, {"message": "Password created successfully", "member": safe})

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

def _handle_request_password_reset(event: dict) -> dict:
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _resp(400, {"error": "Invalid JSON"})

    identifier = body.get("identifier", "").strip()
    if not identifier:
        return _resp(400, {"error": "identifier (member ID, email, or phone) required"})

    table = dynamodb.Table(MEMBERS_TABLE)

    items = []
    for attr in ("memberId", "email", "phone"):
        resp = table.scan(FilterExpression=Attr(attr).eq(identifier))
        items = resp.get("Items", [])
        if items:
            break

    # Always return success to avoid leaking whether an account exists
    if not items:
        return _resp(200, {"message": "If an account exists, a reset link has been sent to the email on file."})

    member   = items[0]
    email    = (member.get("email") or "").strip()
    member_id = member.get("memberId", "")

    if not email:
        return _resp(400, {"error": "No email address on file for this account. Please contact KAFA."})

    token  = secrets.token_urlsafe(150)   # 200 URL-safe chars
    expiry = (datetime.now(timezone.utc) + timedelta(hours=24)).isoformat()

    table.update_item(
        Key={"memberId": member_id, "companyId": member.get("companyId", "KAFA-001")},
        UpdateExpression="SET setupToken = :t, setupTokenExpiry = :e",
        ExpressionAttributeValues={":t": token, ":e": expiry},
    )

    name = member.get("full_name") or f"{member.get('firstName', '')} {member.get('lastName', '')}".strip() or "Member"
    link = f"https://member.kafayiti.com?setup={token}"
    html = f"""
    <div style="font-family:sans-serif;max-width:600px;margin:0 auto">
      <div style="background:#1a5c2e;padding:24px 32px;text-align:center">
        <h1 style="color:#fff;margin:0;font-size:22px">KAFA — Kooperativ Asirans Fanmi Ayisyen</h1>
      </div>
      <div style="padding:32px;background:#fff">
        <h2 style="color:#1a5c2e;margin-top:0">Password Setup Request</h2>
        <p>Hello {name},</p>
        <p>A password setup link was requested for your KAFA member account. Click the button below to create your password. <strong>This link expires in 24 hours.</strong></p>
        <div style="text-align:center;margin:32px 0">
          <a href="{link}"
             style="background:#1a5c2e;color:#fff;padding:14px 32px;border-radius:6px;text-decoration:none;font-weight:bold;font-size:16px;display:inline-block">
            Set Up Password
          </a>
        </div>
        <p style="color:#888;font-size:13px">If you did not request this, you can ignore this email. Your account remains secure.</p>
        <p>If you have questions, contact us at <a href="mailto:info@kafayiti.com" style="color:#1a5c2e">info@kafayiti.com</a> or call (509) 3500-0326.</p>
      </div>
      <div style="background:#f0f0f0;padding:16px 32px;text-align:center;font-size:12px;color:#888">
        KAFA — 874 Rue Ste Catherine, Léogâne, Haïti
      </div>
    </div>"""

    ses.send_email(
        Source="KAFA <noreply@kafayiti.com>",
        Destination={"ToAddresses": [email]},
        Message={
            "Subject": {"Data": "KAFA — Password Setup Link"},
            "Body":    {"Html": {"Data": html}},
        },
    )

    logger.info("Password reset link sent for member: %s", member_id)
    return _resp(200, {"message": "If an account exists, a reset link has been sent to the email on file."})


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
                "referenceNo":   s.get("SK", ""),
                "amountPaid":    float(s.get("paidAmount", 0)),
                "paymentPeriod": s.get("dueDate", ""),
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
        logger.exception("Failed to list documents for %s", member_id)
        return _resp(500, {"error": str(exc)})


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
# HTTP response helper
################################################################################

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