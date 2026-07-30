"""
certificate_retrieval.py — KAFA Certificate Retrieval Lambda

Given a phone number as the unique identifier:
  1. Scan kopera-member table to find the member with that phone number
  2. Call the certificate-handler API (GET /members) to confirm the record
  3. Read the certificate attribute and extract S3 PDF + JPEG URLs
  4. Generate pre-signed URLs so the documents can be downloaded directly
  5. Send the PDF link to the member's WhatsApp via Twilio (if configured)
  6. Return the pre-signed URLs to the caller

Route:
    GET /retrieve?phone=561-303-4161

Deployed in prod as a standalone Lambda (certplatform-prod-certificate-retrieval),
separate from the main certificate-handler Lambda (handler.py). Mirrored here so
local dev can serve the same route.
"""

import os
import json
import logging
import boto3
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
import requests
from requests.auth import HTTPBasicAuth

################################################################################
# Bootstrap
################################################################################

logger = logging.getLogger()
logger.setLevel(logging.INFO)

MEMBERS_TABLE        = os.environ.get("MEMBERS_TABLE", "kopera-member")
CERTS_BUCKET         = os.environ.get("CERTS_BUCKET", "kopera-certificate")
API_BASE_URL         = os.environ.get("API_BASE_URL", "")
AWS_REGION           = os.environ.get("AWS_REGION", "us-east-1")

# WhatsApp delivery is optional — skipped if Twilio isn't configured (e.g. local dev).
TWILIO_ACCOUNT_SID   = os.environ.get("TWILIO_ACCOUNT_SID", "")
TWILIO_AUTH_TOKEN    = os.environ.get("TWILIO_AUTH_TOKEN", "")
TWILIO_WHATSAPP_FROM = os.environ.get("TWILIO_WHATSAPP_FROM", "")

# Pre-signed URL expiry — 24 hours
PRESIGN_EXPIRY = 86400

# Long-lived IAM credentials for pre-signed URL generation, if provided.
# Lambda temporary credentials expire in ~1hr, invalidating 24hr pre-signed URLs.
S3_ACCESS_KEY_ID     = os.environ.get("S3_ACCESS_KEY_ID")
S3_SECRET_ACCESS_KEY = os.environ.get("S3_SECRET_ACCESS_KEY")

_session = boto3.session.Session()
dynamodb = boto3.resource("dynamodb")

_s3_kwargs = dict(
    region_name  = AWS_REGION,
    endpoint_url = f"https://s3.{AWS_REGION}.amazonaws.com",
    config       = boto3.session.Config(
        signature_version = "s3v4",
        s3                = {"addressing_style": "path"},
    ),
)
if S3_ACCESS_KEY_ID and S3_SECRET_ACCESS_KEY:
    _s3_kwargs["aws_access_key_id"]     = S3_ACCESS_KEY_ID
    _s3_kwargs["aws_secret_access_key"] = S3_SECRET_ACCESS_KEY

s3_client = boto3.client("s3", **_s3_kwargs)

################################################################################
# Entry Point
################################################################################

def lambda_handler(event, context):
    if event.get("httpMethod") == "OPTIONS":
        return _response(200, {})

    logger.info("Event: %s", json.dumps(event))

    method   = event.get("httpMethod", "GET")
    resource = event.get("resource", "/retrieve")

    if method == "GET" and resource == "/retrieve":
        return _handle_retrieve(event)

    return _response(404, {"error": f"Route not found: {method} {resource}"})


################################################################################
# GET /retrieve?phone=561-303-4161
################################################################################

def _handle_retrieve(event: dict) -> dict:
    params = event.get("queryStringParameters") or {}
    phone  = params.get("phone", "").strip()

    if not phone:
        return _response(400, {"error": "phone query parameter is required"})

    logger.info("Looking up member with phone: %s", phone)

    member = _find_member_by_phone(phone)
    if not member:
        return _response(404, {"error": f"No member found with phone number: {phone}"})

    member_id  = member["memberId"]
    company_id = member["companyId"]
    full_name  = member.get("full_name", member_id)

    logger.info("Member found: %s (%s)", full_name, member_id)

    # Confirm record via the certificate-handler API (defends against stale scans)
    api_member = _apigw_get(f"/members?memberId={member_id}&companyId={company_id}")
    certificate = (api_member or {}).get("certificate") or member.get("certificate")

    if not certificate:
        return _response(404, {
            "error":     "No certificate found for this member",
            "member_id": member_id,
            "full_name": full_name,
            "hint":      "Run the certificate generation pipeline first",
        })

    pdf_s3_url  = certificate.get("pdf_s3_url",  "")
    jpeg_s3_url = certificate.get("jpeg_s3_url", "")

    if not pdf_s3_url and not jpeg_s3_url:
        return _response(404, {"error": "Certificate record exists but contains no S3 URLs"})

    pdf_download  = _presign(pdf_s3_url)  if pdf_s3_url  else None
    jpeg_download = _presign(jpeg_s3_url) if jpeg_s3_url else None

    whatsapp_status = _send_whatsapp(
        to      = phone,
        name    = full_name,
        pdf_url = pdf_download,
        cert_id = certificate.get("certificate_id", ""),
    )

    return _response(200, {
        "member_id":        member_id,
        "company_id":       company_id,
        "full_name":        full_name,
        "phone":            phone,
        "certificate_id":   certificate.get("certificate_id"),
        "issued_date":      certificate.get("issued_date"),
        "whatsapp":         whatsapp_status,
        "documents": {
            "pdf": {
                "s3_url":       pdf_s3_url,
                "download_url": pdf_download,
                "expires_in":   f"{PRESIGN_EXPIRY // 3600} hours",
            },
            "jpeg": {
                "s3_url":       jpeg_s3_url,
                "download_url": jpeg_download,
                "expires_in":   f"{PRESIGN_EXPIRY // 3600} hours",
            },
        },
    })


################################################################################
# Twilio — send WhatsApp message with PDF link (best-effort, optional)
################################################################################

def _send_whatsapp(to: str, name: str, pdf_url: str | None, cert_id: str) -> dict:
    if not (TWILIO_ACCOUNT_SID and TWILIO_AUTH_TOKEN and TWILIO_WHATSAPP_FROM):
        return {"status": "skipped", "reason": "Twilio not configured"}
    if not pdf_url:
        return {"status": "skipped", "reason": "No PDF URL to send"}

    digits = "".join(c for c in to if c.isdigit())
    if not digits.startswith("1"):
        digits = f"1{digits}"
    to_whatsapp = f"whatsapp:+{digits}"

    message = (
        f"Bonjour {name} \U0001F44B\n\n"
        f"Votre Certificat Officiel d'Adhésion KAFA est prêt.\n\n"
        f"\U0001F4C4 Téléchargez votre certificat ici :\n{pdf_url}\n\n"
        f"\U0001F511 Certificat ID : {cert_id}\n"
        f"⏳ Ce lien expire dans 24 heures.\n\n"
        f"— Koperativ Asirans Fòs Ayiti (KAFA)"
    )

    url = f"https://api.twilio.com/2010-04-01/Accounts/{TWILIO_ACCOUNT_SID}/Messages.json"

    try:
        resp = requests.post(
            url,
            auth = HTTPBasicAuth(TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN),
            data = {"From": TWILIO_WHATSAPP_FROM, "To": to_whatsapp, "Body": message},
            timeout = 10,
        )
        resp.raise_for_status()
        sid = resp.json().get("sid", "")
        logger.info("WhatsApp sent to %s — SID: %s", to_whatsapp, sid)
        return {"status": "sent", "to": to_whatsapp, "sid": sid}
    except Exception as exc:
        logger.error("WhatsApp send failed: %s", exc)
        return {"status": "failed", "to": to_whatsapp, "error": str(exc)}


################################################################################
# DynamoDB — scan kopera-member for a phone number
################################################################################

def _find_member_by_phone(phone: str) -> dict | None:
    digits   = "".join(c for c in phone if c.isdigit())
    variants = {phone, digits, f"+1{digits}", f"1{digits}"}
    table    = dynamodb.Table(MEMBERS_TABLE)

    scan_kwargs = {
        "FilterExpression": "attribute_exists(phone)",
        "ProjectionExpression": "memberId, companyId, full_name, phone, certificate, issued_date",
    }

    while True:
        resp = table.scan(**scan_kwargs)
        for item in resp.get("Items", []):
            stored        = item.get("phone", "")
            stored_digits = "".join(c for c in stored if c.isdigit())
            if stored in variants or stored_digits == digits:
                return item
        last_key = resp.get("LastEvaluatedKey")
        if not last_key:
            break
        scan_kwargs["ExclusiveStartKey"] = last_key

    return None


################################################################################
# API Gateway — SigV4-signed GET
################################################################################

def _apigw_get(path: str) -> dict:
    if not API_BASE_URL:
        return {}
    url   = f"{API_BASE_URL.rstrip('/')}{path}"
    creds = _session.get_credentials().get_frozen_credentials()

    aws_req = AWSRequest(method="GET", url=url)
    SigV4Auth(creds, "execute-api", AWS_REGION).add_auth(aws_req)

    try:
        resp = requests.get(url, headers=dict(aws_req.headers), timeout=10)
        if resp.status_code == 404:
            return {}
        resp.raise_for_status()
        payload = resp.json()
        if isinstance(payload, dict) and "Item" in payload:
            return payload["Item"]
        return payload or {}
    except Exception as exc:
        logger.error("API Gateway call failed: %s", exc)
        return {}


################################################################################
# S3 — generate pre-signed URL
################################################################################

def _presign(s3_url: str) -> str | None:
    if not s3_url or not s3_url.startswith("s3://"):
        return None
    without_prefix = s3_url[len("s3://"):]
    bucket, _, key = without_prefix.partition("/")
    try:
        url = s3_client.generate_presigned_url(
            "get_object",
            Params    = {"Bucket": bucket, "Key": key},
            ExpiresIn = PRESIGN_EXPIRY,
        )
        logger.info("Pre-signed URL generated for key: %s", key)
        return url
    except Exception as exc:
        logger.error("Failed to generate pre-signed URL for %s: %s", s3_url, exc)
        return None


################################################################################
# HTTP response helper
################################################################################

def _response(status_code: int, body: dict) -> dict:
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type":                 "application/json",
            "Access-Control-Allow-Origin":  "*",
            "Access-Control-Allow-Headers": "Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token,X-Amz-Content-Sha256",
            "Access-Control-Allow-Methods": "GET,OPTIONS",
        },
        "body": json.dumps(body, default=str),
    }
