#!/usr/bin/env python3
"""
add_status_attribute.py
Adds a `status` = True attribute to every member in kopera-member
who doesn't already have one.
"""
import boto3

TABLE_NAME = "kopera-member"
dynamodb = boto3.resource("dynamodb", region_name="us-east-1")
table = dynamodb.Table(TABLE_NAME)

def run():
    updated = 0
    skipped = 0
    scan_kwargs = {}

    while True:
        resp = table.scan(**scan_kwargs)
        for item in resp.get("Items", []):
            if "status" not in item:
                table.update_item(
                    Key={
                        "memberId": item["memberId"],
                        "companyId": item["companyId"],
                    },
                    UpdateExpression="SET #s = :v",
                    ExpressionAttributeNames={"#s": "status"},
                    ExpressionAttributeValues={":v": True},
                )
                print(f"  ✓ {item['memberId']} — status set to True")
                updated += 1
            else:
                print(f"  · {item['memberId']} — already has status={item['status']}")
                skipped += 1

        last_key = resp.get("LastEvaluatedKey")
        if not last_key:
            break
        scan_kwargs["ExclusiveStartKey"] = last_key

    print(f"\nDone. Updated: {updated}, Skipped: {skipped}")

if __name__ == "__main__":
    run()
