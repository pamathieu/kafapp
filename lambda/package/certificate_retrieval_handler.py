import os, io, json, logging, boto3
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
import requests
from requests.auth import HTTPBasicAuth

logger = logging.getLogger()
logger.setLevel(logging.INFO)

MEMBERS_TABLE        = os.environ["MEMBERS_TABLE"]
CERTS_BUCKET         = os.environ["CERTS_BUCKET"]
API_BASE_URL         = os.environ["API_BASE_URL"]
AWS_REGION           = os.environ.get("AWS_REGION", "us-east-1")
TWILIO_ACCOUNT_SID   = os.environ["TWILIO_ACCOUNT_SID"]
TWILIO_AUTH_TOKEN    = os.environ["TWILIO_AUTH_TOKEN"]
TWILIO_WHATSAPP_FROM = os.environ["TWILIO_WHATSAPP_FROM"]
PRESIGN_EXPIRY       = 86400

_session  = boto3.session.Session()
dynamodb  = boto3.resource("dynamodb")
s3_client = boto3.client("s3", region_name=AWS_REGION,
    endpoint_url=f"https://s3.{AWS_REGION}.amazonaws.com",
    config=boto3.session.Config(signature_version="s3v4",
        s3={"addressing_style":"path"}))

def lambda_handler(event, context):
    logger.info("Event: %s", json.dumps(event))
    method   = event.get("httpMethod", "GET")
    resource = event.get("resource", "/retrieve")
    if method == "GET" and resource == "/retrieve":
        return _handle_retrieve(event)
    return _response(404, {"error": f"Route not found: {method} {resource}"})

def _handle_retrieve(event):
    params = event.get("queryStringParameters") or {}
    phone  = params.get("phone", "").strip()
    if not phone:
        return _response(400, {"error": "phone query parameter is required"})
    member = _find_member_by_phone(phone)
    if not member:
        return _response(404, {"error": f"No member found with phone number: {phone}"})
    member_id  = member["memberId"]
    company_id = member["companyId"]
    full_name  = member.get("full_name", member_id)
    api_member  = _apigw_get(f"/members?memberId={member_id}&companyId={company_id}")
    certificate = api_member.get("certificate") or member.get("certificate")
    if not certificate:
        return _response(404, {"error": "No certificate found", "member_id": member_id})
    pdf_s3_url  = certificate.get("pdf_s3_url",  "")
    jpeg_s3_url = certificate.get("jpeg_s3_url", "")
    pdf_download  = _presign(pdf_s3_url)  if pdf_s3_url  else None
    jpeg_download = _presign(jpeg_s3_url) if jpeg_s3_url else None
    logger.info("Sending WhatsApp to %s", phone)
    whatsapp_status = _send_whatsapp(phone, full_name, pdf_download, certificate.get("certificate_id",""))
    logger.info("WhatsApp status: %s", whatsapp_status)
    return _response(200, {
        "member_id": member_id, "company_id": company_id,
        "full_name": full_name, "phone": phone,
        "certificate_id": certificate.get("certificate_id"),
        "issued_date": certificate.get("issued_date"),
        "whatsapp": whatsapp_status,
        "documents": {
            "pdf":  {"s3_url": pdf_s3_url,  "download_url": pdf_download,  "expires_in": "24 hours"},
            "jpeg": {"s3_url": jpeg_s3_url, "download_url": jpeg_download, "expires_in": "24 hours"},
        },
    })

def _send_whatsapp(to, name, pdf_url, cert_id):
    digits = "".join(c for c in to if c.isdigit())
    if not digits.startswith("1"):
        digits = f"1{digits}"
    to_wa = f"whatsapp:+{digits}"
    msg = (f"Bonjour {name} 👋\n\nVotre Certificat Officiel d'Adhésion KAFA est prêt.\n\n"
           f"📄 Téléchargez votre certificat ici :\n{pdf_url}\n\n"
           f"🔑 Certificat ID : {cert_id}\n⏳ Ce lien expire dans 24 heures.\n\n"
           f"— Koperativ Asirans Fòs Ayiti (KAFA)")
    url = f"https://api.twilio.com/2010-04-01/Accounts/{TWILIO_ACCOUNT_SID}/Messages.json"
    try:
        resp = requests.post(url, auth=HTTPBasicAuth(TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN),
            data={"From": TWILIO_WHATSAPP_FROM, "To": to_wa, "Body": msg}, timeout=10)
        resp.raise_for_status()
        sid = resp.json().get("sid","")
        logger.info("WhatsApp sent to %s SID: %s", to_wa, sid)
        return {"status": "sent", "to": to_wa, "sid": sid}
    except Exception as exc:
        logger.error("WhatsApp failed: %s", exc)
        return {"status": "failed", "to": to_wa, "error": str(exc)}

def _find_member_by_phone(phone):
    digits   = "".join(c for c in phone if c.isdigit())
    variants = {phone, digits, f"+1{digits}", f"1{digits}"}
    table    = dynamodb.Table(MEMBERS_TABLE)
    scan_kwargs = {"FilterExpression": "attribute_exists(phone)",
        "ProjectionExpression": "memberId, companyId, full_name, phone, certificate, issued_date"}
    while True:
        resp = table.scan(**scan_kwargs)
        for item in resp.get("Items", []):
            stored = item.get("phone","")
            if stored in variants or "".join(c for c in stored if c.isdigit()) == digits:
                return item
        last_key = resp.get("LastEvaluatedKey")
        if not last_key: break
        scan_kwargs["ExclusiveStartKey"] = last_key
    return None

def _apigw_get(path):
    url   = f"{API_BASE_URL.rstrip('/')}{path}"
    creds = _session.get_credentials().get_frozen_credentials()
    aws_req = AWSRequest(method="GET", url=url)
    SigV4Auth(creds, "execute-api", AWS_REGION).add_auth(aws_req)
    try:
        resp = requests.get(url, headers=dict(aws_req.headers), timeout=10)
        if resp.status_code == 404: return {}
        resp.raise_for_status()
        payload = resp.json()
        return payload.get("Item", payload) if isinstance(payload, dict) else {}
    except Exception as exc:
        logger.error("APIGW failed: %s", exc)
        return {}

def _presign(s3_url):
    if not s3_url or not s3_url.startswith("s3://"): return None
    without_prefix = s3_url[len("s3://"):]
    bucket, _, key = without_prefix.partition("/")
    try:
        url = s3_client.generate_presigned_url("get_object",
            Params={"Bucket": bucket, "Key": key}, ExpiresIn=PRESIGN_EXPIRY)
        logger.info("Pre-signed URL generated for key: %s", key)
        return url
    except Exception as exc:
        logger.error("Pre-sign failed: %s", exc)
        return None

def _response(status_code, body):
    return {"statusCode": status_code, "headers": {"Content-Type": "application/json"},
            "body": json.dumps(body, default=str)}
