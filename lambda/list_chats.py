import json
import boto3
from boto3.dynamodb.conditions import Attr

dynamodb = boto3.resource('dynamodb', region_name='us-east-1')
table    = dynamodb.Table('kopera-chat')

CORS = {
    'Access-Control-Allow-Origin':  '*',
    'Access-Control-Allow-Headers': '*',
    'Access-Control-Allow-Methods': 'GET,OPTIONS',
}

def lambda_handler(event, context):
    if event.get('httpMethod') == 'OPTIONS':
        return {'statusCode': 200, 'headers': CORS, 'body': ''}

    try:
        params    = event.get('queryStringParameters') or {}
        chat_type = params.get('type')
        limit     = int(params.get('limit', 200))

        kwargs = {'Limit': min(limit, 500)}

        if chat_type:
            types = [t.strip() for t in chat_type.split(',') if t.strip()]
            if len(types) == 1:
                kwargs['FilterExpression'] = Attr('conversationType').eq(types[0])
            elif len(types) > 1:
                from boto3.dynamodb.conditions import Or
                kwargs['FilterExpression'] = Or(*[Attr('conversationType').eq(t) for t in types])

        result = table.scan(**kwargs)
        items  = result.get('Items', [])

        # Sort newest first
        items.sort(key=lambda x: x.get('timestamp', ''), reverse=True)

        # Group by sessionId
        sessions = {}
        for item in items:
            sid = item.get('sessionId', 'unknown')

            if sid not in sessions:
                sessions[sid] = {
                    'sessionId':        sid,
                    'conversationType': item.get('conversationType', ''),
                    'lastTimestamp':    item.get('timestamp', ''),
                    'browser':          item.get('browser', ''),
                    'os':               item.get('os', ''),
                    'deviceType':       item.get('deviceType', ''),
                    'location':         item.get('location', ''),
                    'ipAddress':        item.get('ipAddress', ''),
                    'memberName':       item.get('memberName', ''),
                    'memberId':         item.get('memberId', ''),
                    'messages':         [],
                }

            # Fill memberName/memberId from any item that has them
            if not sessions[sid]['memberName'] and item.get('memberName'):
                sessions[sid]['memberName'] = item['memberName']
            if not sessions[sid]['memberId'] and item.get('memberId'):
                sessions[sid]['memberId'] = item['memberId']

            # Always append the message
            sessions[sid]['messages'].append({
                'timestamp':         item.get('timestamp', ''),
                'userMessage':       item.get('userMessage', ''),
                'assistantResponse': item.get('assistantResponse', ''),
                'fromCache':         item.get('fromCache', False),
            })

        session_list = sorted(
            sessions.values(),
            key=lambda s: s['lastTimestamp'],
            reverse=True,
        )

        return {
            'statusCode': 200,
            'headers': CORS,
            'body': json.dumps({'sessions': session_list}),
        }

    except Exception as e:
        return {
            'statusCode': 500,
            'headers': CORS,
            'body': json.dumps({'error': str(e)}),
        }
