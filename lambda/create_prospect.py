"""
Lambda: create_prospect.py
--------------------------
Handles public application form submissions.

Route:  POST /prospects
Body:   {firstName, lastName, phone, email, plan?, message?,
         address?, commune?, gender?, profession?, birthDatePlace?,
         idType?, idNumber?}

Actions:
  1. Write prospect record to kopera-prospect with status="pending"
  2. Send notification email to kontak@kafayiti.com (non-blocking)

Returns 201 with {prospectId, notificationSent}.
"""

import json
import os
import secrets
import time
from datetime import datetime, timezone

import boto3

dynamodb = boto3.resource("dynamodb", region_name="us-east-1")
ses = boto3.client("ses", region_name="us-east-1")

PROSPECTS_TABLE = os.environ.get("PROSPECTS_TABLE", "kopera-prospect")
NOTIFY_EMAIL    = "kontak@kafayiti.com"
CC_EMAIL        = "kafa509@gmail.com"
ADMIN_PORTAL    = "https://admin.kafayiti.com"

CORS = {
    "Access-Control-Allow-Origin":  "*",
    "Access-Control-Allow-Headers": (
        "Content-Type,X-Amz-Date,Authorization,X-Api-Key,"
        "X-Amz-Security-Token,X-Amz-Content-Sha256"
    ),
    "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
}


def lambda_handler(event, context):
    if event.get("httpMethod") == "OPTIONS":
        return {"statusCode": 200, "headers": CORS, "body": ""}

    try:
        body = json.loads(event.get("body") or "{}")
    except (json.JSONDecodeError, TypeError):
        return _err(400, "Invalid JSON body")

    first_name = body.get("firstName", "").strip()
    last_name  = body.get("lastName", "").strip()
    phone      = body.get("phone", "").strip()

    if not first_name or not phone:
        return _err(400, "firstName and phone are required")

    prospect_id = f"P{int(time.time() * 1000)}-{secrets.token_hex(3).upper()}"

    item = {
        "id":              prospect_id,
        "firstName":       first_name,
        "lastName":        last_name,
        "phone":           phone,
        "email":           body.get("email", "").strip(),
        "plan":            body.get("plan", ""),
        "message":         body.get("message", ""),
        "address":         body.get("address", ""),
        "commune":         body.get("commune", ""),
        "gender":          body.get("gender", ""),
        "profession":      body.get("profession", ""),
        "birthDatePlace":  body.get("birthDatePlace", ""),
        "idType":          body.get("idType", ""),
        "idNumber":        body.get("idNumber", ""),
        "status":          "pending",
        "createdAt":       datetime.now(timezone.utc).isoformat(),
    }

    dynamodb.Table(PROSPECTS_TABLE).put_item(Item=item)

    notification_sent = False
    try:
        _notify_kontak(item)
        notification_sent = True
    except Exception as e:
        print(f"[create_prospect] kontak@ notification failed (non-blocking): {e}")

    return {
        "statusCode": 201,
        "headers": CORS,
        "body": json.dumps({"prospectId": prospect_id, "notificationSent": notification_sent}),
    }


def _notify_kontak(prospect: dict) -> None:
    name    = f"{prospect['firstName']} {prospect['lastName']}".strip()
    plan    = prospect.get("plan") or "N/A"
    phone   = prospect.get("phone", "")
    email   = prospect.get("email", "")
    commune = prospect.get("commune", "")

    prospect_id = prospect.get("id", "")
    detail_url  = f"{ADMIN_PORTAL}/?prospect={prospect_id}"

    ses.send_email(
        Source="KAFA <noreply@kafayiti.com>",
        Destination={
            "ToAddresses": [NOTIFY_EMAIL],
            "CcAddresses": [CC_EMAIL],
        },
        Message={
            "Subject": {"Data": f"New KAFA Prospect: {name}"},
            "Body": {
                "Html": {
                    "Data": f"""
<div style="font-family:sans-serif;max-width:600px;margin:0 auto">
  <div style="background:#1a5c2e;padding:20px 32px">
    <h2 style="color:#fff;margin:0">New Membership Application</h2>
  </div>
  <div style="padding:24px 32px;background:#fff">
    <table style="width:100%;border-collapse:collapse">
      <tr><td style="padding:8px 0;color:#666;width:140px">Name</td>
          <td style="padding:8px 0;font-weight:bold">{name}</td></tr>
      <tr><td style="padding:8px 0;color:#666">Phone</td>
          <td style="padding:8px 0">{phone}</td></tr>
      <tr><td style="padding:8px 0;color:#666">Email</td>
          <td style="padding:8px 0">{email}</td></tr>
      <tr><td style="padding:8px 0;color:#666">Commune</td>
          <td style="padding:8px 0">{commune}</td></tr>
      <tr><td style="padding:8px 0;color:#666">Plan selected</td>
          <td style="padding:8px 0;color:#1a5c2e;font-weight:bold">{plan}</td></tr>
    </table>
    <div style="margin-top:24px;text-align:center">
      <a href="{detail_url}"
         style="background:#1a5c2e;color:#fff;padding:12px 28px;
                border-radius:6px;text-decoration:none;font-weight:bold">
        Voir le dossier du prospect
      </a>
    </div>
    <p style="margin-top:16px;text-align:center;font-size:12px;color:#999">
      ID: {prospect_id}
    </p>
  </div>
</div>"""
                }
            },
        },
    )


def _err(code: int, msg: str) -> dict:
    return {"statusCode": code, "headers": CORS, "body": json.dumps({"error": msg})}
