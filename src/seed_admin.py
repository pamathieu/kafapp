"""
seed_admin.py — Create the initial admin record in kopera-admin DynamoDB table.

Password is stored as a SHA-256 hash — never in plaintext.

Usage:
    python seed_admin.py
    python seed_admin.py --username admin --password kafa2026
"""

import boto3
import hashlib
import argparse

TABLE_NAME = "kopera-admin"
REGION     = "us-east-1"

def hash_password(password: str) -> str:
    return hashlib.sha256(password.encode("utf-8")).hexdigest()

def seed_admin(username: str, password: str):
    db    = boto3.resource("dynamodb", region_name=REGION)
    table = db.Table(TABLE_NAME)

    password_hash = hash_password(password)

    table.put_item(Item={
        "username":      username,
        "password_hash": password_hash,
    })

    print(f"✅ Admin '{username}' seeded successfully.")
    print(f"   Password hash (SHA-256): {password_hash[:16]}...")
    print(f"   Table: {TABLE_NAME}")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Seed admin credentials into DynamoDB")
    parser.add_argument("--username", default="admin",    help="Admin username")
    parser.add_argument("--password", default="kafa2026", help="Admin password")
    args = parser.parse_args()

    seed_admin(args.username, args.password)
