import json
import boto3
import os
from boto3.dynamodb.conditions import Attr

dynamodb = boto3.resource('dynamodb', region_name='us-east-1')
TABLE = os.environ.get('PROSPECTS_TABLE', 'kopera-prospect')

CORS = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Content-Sha256,X-Amz-Security-Token',
    'Access-Control-Allow-Methods': 'GET,OPTIONS',
}

def lambda_handler(event, context):
    method = event.get('httpMethod', 'GET')
    if method == 'OPTIONS':
        return {'statusCode': 200, 'headers': CORS, 'body': ''}

    try:
        table = dynamodb.Table(TABLE)
        items = []
        kwargs = {}
        while True:
            resp = table.scan(**kwargs)
            items.extend(resp.get('Items', []))
            last = resp.get('LastEvaluatedKey')
            if not last:
                break
            kwargs['ExclusiveStartKey'] = last

        prospects = []
        for item in items:
            # Flatten nested data map if present
            data = item.get('data', {}) or {}
            prospects.append({
                'id':              item.get('id', ''),
                'firstName':       item.get('firstName', ''),
                'lastName':        item.get('lastName', ''),
                'phone':           item.get('phone', ''),
                'email':           item.get('email', ''),
                'memberNumber':    item.get('memberNumber', ''),
                'message':         item.get('message', ''),
                'createdAt':       item.get('createdAt', ''),
                'address':         item.get('address') or data.get('address', ''),
                'commune':         item.get('commune') or data.get('commune', ''),
                'gender':          item.get('gender') or data.get('gender', ''),
                'profession':      item.get('profession') or data.get('profession', ''),
                'birthDatePlace':  item.get('birthDatePlace') or data.get('birthDatePlace', ''),
                'idType':          item.get('idType') or data.get('idType', ''),
                'idNumber':        item.get('idNumber') or data.get('idNumber', ''),
                'idIssueDetails':  item.get('idIssueDetails') or data.get('idIssueDetails', ''),
                'idExpirationDate':item.get('idExpirationDate') or data.get('idExpirationDate', ''),
                'accepterNote':    item.get('accepterNote', ''),
                'status':          item.get('status', ''),
            })

        # Sort newest first
        prospects.sort(key=lambda p: p.get('createdAt', ''), reverse=True)

        return {
            'statusCode': 200,
            'headers': CORS,
            'body': json.dumps({'prospects': prospects, 'count': len(prospects)}),
        }
    except Exception as e:
        return {
            'statusCode': 500,
            'headers': CORS,
            'body': json.dumps({'error': str(e)}),
        }
