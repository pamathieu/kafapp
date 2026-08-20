import json
import boto3
import os
import uuid
import secrets
from decimal import Decimal
from datetime import datetime, timezone, timedelta

dynamodb = boto3.resource('dynamodb', region_name='us-east-1')
ses      = boto3.client('ses', region_name='us-east-1')
PROSPECTS_TABLE  = os.environ.get('PROSPECTS_TABLE',  'kopera-prospect')
MEMBERS_TABLE    = os.environ.get('MEMBERS_TABLE',    'kopera-member')
COMPANIES_TABLE  = os.environ.get('COMPANIES_TABLE',  'kopera-company')
COMPANY_ID       = os.environ.get('COMPANY_ID',       'KAFA-001')
MEMBER_PORTAL    = os.environ.get('MEMBER_PORTAL_URL', 'https://member.kafayiti.com')
COMPANY_CODE     = '001'

CORS = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Content-Sha256,X-Amz-Security-Token',
    'Access-Control-Allow-Methods': 'GET,PATCH,OPTIONS',
}

VALID_STATUSES = {'accepted', 'pending', 'rejected'}


def lambda_handler(event, context):
    method = event.get('httpMethod', '')
    if method == 'OPTIONS':
        return {'statusCode': 200, 'headers': CORS, 'body': ''}

    prospect_id = (event.get('pathParameters') or {}).get('id')
    if not prospect_id:
        return _err(400, 'Missing prospect id in path')

    try:
        body = json.loads(event.get('body') or '{}')
    except Exception:
        return _err(400, 'Invalid JSON body')

    new_status = body.get('status', '').lower()
    note       = body.get('note')  # optional — note-only update if status omitted

    if not new_status and note is None:
        return _err(400, 'Provide at least one of: status, note')
    if new_status and new_status not in VALID_STATUSES:
        return _err(400, f'status must be one of: {", ".join(VALID_STATUSES)}')

    prospects = dynamodb.Table(PROSPECTS_TABLE)

    # Fetch the prospect first
    resp = prospects.get_item(Key={'id': prospect_id})
    prospect = resp.get('Item')
    if not prospect:
        return _err(404, 'Prospect not found')

    result = {}

    # Note-only update (no status change)
    if not new_status:
        update_expr = 'SET accepterNote = :n, updatedAt = :u'
        prospects.update_item(
            Key={'id': prospect_id},
            UpdateExpression=update_expr,
            ExpressionAttributeValues={
                ':n': note,
                ':u': datetime.now(timezone.utc).isoformat(),
            },
        )
        return {'statusCode': 200, 'headers': CORS,
                'body': json.dumps({'prospectId': prospect_id, 'noteSaved': True})}

    # If accepting, create the member first then send approval email
    if new_status == 'accepted' and prospect.get('status') != 'accepted':
        try:
            member_id   = _generate_member_id(prospect)
            setup_token = _create_member(prospect, member_id)
            result['memberId'] = member_id
            result['memberCreated'] = True
            result['setupLink'] = f'{MEMBER_PORTAL}?setup={setup_token}'
        except Exception as e:
            return _err(500, f'Failed to create member: {str(e)}')
        try:
            _send_approval_email(prospect, member_id, setup_token)
        except Exception as e:
            print(f'Approval email failed (non-blocking): {e}')

    # Update prospect status (and note if provided)
    if note is not None:
        prospects.update_item(
            Key={'id': prospect_id},
            UpdateExpression='SET #s = :s, accepterNote = :n, updatedAt = :u',
            ExpressionAttributeNames={'#s': 'status'},
            ExpressionAttributeValues={
                ':s': new_status,
                ':n': note,
                ':u': datetime.now(timezone.utc).isoformat(),
            },
        )
    else:
        prospects.update_item(
            Key={'id': prospect_id},
            UpdateExpression='SET #s = :s, updatedAt = :u',
            ExpressionAttributeNames={'#s': 'status'},
            ExpressionAttributeValues={
                ':s': new_status,
                ':u': datetime.now(timezone.utc).isoformat(),
            },
        )

    if result.get('memberId'):
        prospects.update_item(
            Key={'id': prospect_id},
            UpdateExpression='SET memberId = :m',
            ExpressionAttributeValues={':m': result['memberId']},
        )

    result['prospectId'] = prospect_id
    result['status']     = new_status

    return {'statusCode': 200, 'headers': CORS, 'body': json.dumps(result)}


def _generate_member_id(prospect):
    # Use existing memberNumber if it already matches the MK format (13 chars)
    existing = (prospect.get('memberNumber') or '').strip()
    if existing and len(existing) == 13 and existing.startswith('MK'):
        return existing
    # Atomically increment sequence in kopera-company and format as MK001XXXXXXXX
    resp = dynamodb.Table(COMPANIES_TABLE).update_item(
        Key={'companyId': COMPANY_ID},
        UpdateExpression='ADD #seq :one',
        ExpressionAttributeNames={'#seq': 'sequence'},
        ExpressionAttributeValues={':one': Decimal('1')},
        ReturnValues='UPDATED_NEW',
    )
    seq = int(resp['Attributes']['sequence'])
    return f'MK{COMPANY_CODE}{seq:08d}'


def _create_member(prospect, member_id):
    members = dynamodb.Table(MEMBERS_TABLE)
    first = prospect.get('firstName', '')
    last  = prospect.get('lastName', '')
    full_name = f'{first} {last}'.strip() or 'Unknown'

    data = prospect.get('data') or {}

    setup_token  = secrets.token_urlsafe(7)   # 10 URL-safe chars
    token_expiry = (datetime.now(timezone.utc) + timedelta(days=7)).isoformat()

    item = {
        'memberId':          member_id,
        'companyId':         COMPANY_ID,
        'full_name':         full_name,
        'phone':             prospect.get('phone') or '',
        'email':             prospect.get('email') or '',
        'address':           prospect.get('address') or data.get('address') or '',
        'date_of_birth':     prospect.get('birthDatePlace') or data.get('birthDatePlace') or '',
        'id_number':         prospect.get('idNumber') or data.get('idNumber') or '',
        'id_type':           prospect.get('idType') or data.get('idType') or '',
        'nationality':       'HTI',
        # New members start pending until they pay their initial membership
        # share — share_webhook.py flips status to True once that succeeds.
        'status':            False,
        'reason':            'Did not pay membership share',
        'notes':             prospect.get('message') or '',
        'issued_date':       datetime.now(timezone.utc).strftime('%d / %m / %Y'),
        'createdAt':         datetime.now(timezone.utc).isoformat(),
        'sourceProspectId':  prospect.get('id', ''),
        'setupToken':        setup_token,
        'setupTokenExpiry':  token_expiry,
    }

    members.put_item(Item=item)
    return setup_token


def _send_approval_email(prospect, member_id, setup_token):
    email = (prospect.get('email') or '').strip()
    if not email:
        return
    first = prospect.get('firstName', '')
    last  = prospect.get('lastName', '')
    name  = f'{first} {last}'.strip() or 'Member'
    html  = f"""
    <div style="font-family:sans-serif;max-width:600px;margin:0 auto">
      <div style="background:#1a5c2e;padding:24px 32px;text-align:center">
        <h1 style="color:#fff;margin:0;font-size:22px">KAFA — Kooperativ Asirans Fòs Ayiti</h1>
      </div>
      <div style="padding:32px;background:#fff">
        <h2 style="color:#1a5c2e;margin-top:0">Congratulations, {name}! 🎉</h2>
        <p>We are pleased to inform you that your KAFA membership application has been <strong>approved</strong>. Welcome to the KAFA family!</p>
        <div style="background:#f0faf4;border-left:4px solid #1a5c2e;padding:16px 20px;margin:24px 0;border-radius:4px">
          <p style="margin:0;font-weight:bold;color:#1a5c2e">Your Member Number</p>
          <p style="margin:8px 0 0;font-size:20px;letter-spacing:1px">{member_id}</p>
        </div>
        <p>You can now access your member portal to view your plan, make payments, and manage your account:</p>
        <div style="text-align:center;margin:32px 0">
          <a href="https://member.kafayiti.com?setup={setup_token}"
             style="background:#1a5c2e;color:#fff;padding:14px 32px;border-radius:6px;text-decoration:none;font-weight:bold;font-size:16px;display:inline-block">
            Access Member Portal
          </a>
        </div>
        <p>If you have any questions, feel free to reach us:</p>
        <ul style="color:#333;line-height:2">
          <li>📧 <a href="mailto:info@kafayiti.com" style="color:#1a5c2e">info@kafayiti.com</a></li>
          <li>📞 (509) 3500-0326 / (509) 4439-8595</li>
          <li>🌐 <a href="https://kafayiti.com" style="color:#1a5c2e">kafayiti.com</a></li>
        </ul>
      </div>
      <div style="background:#f0f0f0;padding:16px 32px;text-align:center;font-size:12px;color:#888">
        KAFA — 874 Rue Ste Catherine, Léogâne, Haïti
      </div>
    </div>"""
    ses.send_email(
        Source='KAFA <noreply@kafayiti.com>',
        Destination={'ToAddresses': [email]},
        Message={
            'Subject': {'Data': 'KAFA — Membership Approved! Welcome to the Family'},
            'Body':    {'Html': {'Data': html}},
        },
    )


def _err(code, msg):
    return {
        'statusCode': code,
        'headers': CORS,
        'body': json.dumps({'error': msg}),
    }
