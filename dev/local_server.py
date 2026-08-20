#!/usr/bin/env python3
"""
local_server.py — local dev backend for the KAFA admin + member Flutter portals.

Routes plain HTTP requests to the *same* Lambda handler functions used in
production (handler.py + lambda/*.py), translating Flask requests into the
API Gateway "event" dict shape those functions already expect. This is a
thin adapter, not a reimplementation — the business logic is untouched.

Data source:
  - MEMBERS_TABLE / LIFE_INSURANCE_TABLE point at the dev tables
    (kopera-member-dev / kopera-life-insurance-dev), matching the
    certplatform-dev-certificate-handler Lambda configuration used by
    devadmin.kafayiti.com and devmember.kafayiti.com.
  - Only the Stripe keys are sandboxed (sk_test_/pk_test_ from .env.local —
    see lambda/create_payment_intent.py and lambda/stripe_webhook.py, which
    prefer STRIPE_SECRET_KEY/STRIPE_WEBHOOK_SECRET env vars over SSM when
    set). Test payments are written into kopera-life-insurance-dev,
    tagged with sandbox PaymentIntent IDs.

Run:  python3 dev/local_server.py
"""

import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "lambda"))

from dotenv import load_dotenv  # noqa: E402
load_dotenv(ROOT / ".env.local")

os.environ.setdefault("MEMBERS_TABLE", "kopera-member-dev")
os.environ.setdefault("LIFE_INSURANCE_TABLE", "kopera-life-insurance-dev")
os.environ.setdefault("COMPANIES_TABLE", "kopera-company")
os.environ.setdefault("ADMIN_TABLE", "kopera-admin")
os.environ.setdefault("LOCALITIES_TABLE", "kopera-localities")
os.environ.setdefault("CERTS_BUCKET", "kopera-certificate")
os.environ.setdefault("ASSETS_BUCKET", "kopera-asset")
os.environ.setdefault("SHARES_TABLE", "kopera-share")
os.environ.setdefault("ENVIRONMENT", "dev")
os.environ.setdefault("API_BASE_URL", "http://localhost:8000")

from flask import Flask, Response, request  # noqa: E402

import handler as certificate_handler  # noqa: E402
import create_payment_intent  # noqa: E402
import stripe_webhook  # noqa: E402
import list_member_payments  # noqa: E402
import list_prospects  # noqa: E402
import update_prospect  # noqa: E402
import list_chats  # noqa: E402
import create_prospect        # noqa: E402
import create_share_intent   # noqa: E402
import create_share_checkout  # noqa: E402
import share_webhook          # noqa: E402
import certificate_retrieval  # noqa: E402

app = Flask(__name__)


def _invoke(lambda_fn, resource: str, path_params: dict | None = None) -> Response:
    event = {
        "httpMethod": request.method,
        "resource": resource,
        "path": request.path,
        "headers": dict(request.headers),
        "queryStringParameters": dict(request.args) or None,
        "pathParameters": path_params,
        "body": request.get_data(as_text=True) or None,
        "requestContext": {"authorizer": {"claims": {}}},
    }
    result = lambda_fn(event, None)
    resp = Response(result.get("body", ""), status=result.get("statusCode", 200))
    for key, value in (result.get("headers") or {}).items():
        resp.headers[key] = value
    resp.headers.setdefault("Access-Control-Allow-Origin", "*")
    return resp


@app.before_request
def _cors_preflight():
    if request.method == "OPTIONS":
        resp = Response("", status=200)
        resp.headers["Access-Control-Allow-Origin"] = "*"
        resp.headers["Access-Control-Allow-Headers"] = (
            "Content-Type,Authorization,Stripe-Signature,"
            "X-Amz-Date,X-Api-Key,X-Amz-Security-Token,X-Amz-Content-Sha256"
        )
        resp.headers["Access-Control-Allow-Methods"] = "GET,POST,PATCH,PUT,DELETE,OPTIONS"
        return resp


# ── Routes served by the monolith certificate_handler Lambda (handler.py) ─────
_HANDLER_ROUTES = {
    "/lookup": ["GET"],
    "/members": ["GET", "POST"],
    "/companies": ["GET", "POST"],
    "/certificates": ["POST"],
    "/members/list": ["GET"],
    "/members/edit": ["POST"],
    "/members/update": ["POST"],
    "/localities": ["GET"],
    "/member/login": ["POST"],
    "/member/profile/update": ["POST"],
    "/members/set-credentials": ["POST"],
    "/members/send-password-setup": ["POST"],
    "/member/request-password-reset": ["POST"],
    "/members/create": ["POST"],
    "/auth/login": ["POST"],
    "/member/policy": ["GET"],
    "/member/documents": ["GET"],
    "/member/documents/upload": ["POST"],
    "/members/policies/create": ["POST"],
    "/member/shares": ["GET"],
    "/member/payment": ["POST"],
    "/member/shares/manual": ["POST"],
    "/member/acknowledge-payment": ["POST"],
    "/member/beneficiaries": ["GET", "POST"],
}

for _path, _methods in _HANDLER_ROUTES.items():
    def _make_view(resource):
        def _view():
            return _invoke(certificate_handler.lambda_handler, resource)
        return _view

    app.add_url_rule(
        _path,
        endpoint=f"handler{_path}",
        view_func=_make_view(_path),
        methods=_methods + ["OPTIONS"],
    )
    # Register the -dev variant so local builds with API_ENV_SUFFIX=-dev
    # use the same URL shape as devadmin/devmember.kafayiti.com.
    # The handler still receives the canonical (non-dev) resource path.
    if _path.startswith('/members/') or _path == '/members':
        _dev_path = '/members-dev' + _path[len('/members'):]
        app.add_url_rule(
            _dev_path,
            endpoint=f"handler_dev{_path}",
            view_func=_make_view(_path),
            methods=_methods + ["OPTIONS"],
        )
    elif _path.startswith('/member/') or _path == '/member':
        _dev_path = '/member-dev' + _path[len('/member'):]
        app.add_url_rule(
            _dev_path,
            endpoint=f"handler_dev{_path}",
            view_func=_make_view(_path),
            methods=_methods + ["OPTIONS"],
        )


@app.route("/certificates/<certificateId>", methods=["GET", "OPTIONS"])
def certificate_item(certificateId):
    return _invoke(
        certificate_handler.lambda_handler,
        "/certificates/{certificateId}",
        {"certificateId": certificateId},
    )


# ── Payments — sandbox Stripe keys, dev DynamoDB table ─────────────────────────
@app.route("/payments/create-intent", methods=["POST", "OPTIONS"])
def payments_create_intent():
    return _invoke(create_payment_intent.lambda_handler, "/payments/create-intent")


@app.route("/payments/webhook", methods=["POST", "OPTIONS"])
def payments_webhook():
    return _invoke(stripe_webhook.lambda_handler, "/payments/webhook")


@app.route("/admin/payments", methods=["GET", "OPTIONS"])
def admin_payments():
    return _invoke(list_member_payments.lambda_handler, "/admin/payments")


# ── Prospects + chat history ───────────────────────────────────────────────────
@app.route("/prospects", methods=["GET", "POST", "OPTIONS"])
def prospects_root():
    if request.method == "POST":
        return _invoke(create_prospect.lambda_handler, "/prospects")
    return _invoke(list_prospects.lambda_handler, "/prospects")


@app.route("/prospects/<prospectId>", methods=["PATCH", "OPTIONS"])
def prospects_update(prospectId):
    return _invoke(update_prospect.lambda_handler, "/prospects/{id}", {"id": prospectId})


@app.route("/prospects-dev/<prospectId>", methods=["PATCH", "OPTIONS"])
def prospects_dev_update(prospectId):
    # Dev route: uses kopera-member-dev and devmember.kafayiti.com via .env.local overrides.
    return _invoke(update_prospect.lambda_handler, "/prospects/{id}", {"id": prospectId})


@app.route("/chats", methods=["GET", "OPTIONS"])
def chats_list():
    return _invoke(list_chats.lambda_handler, "/chats")


# ── Certificate retrieval — separate Lambda in prod (certificate-retrieval) ────
@app.route("/retrieve", methods=["GET", "OPTIONS"])
def certificate_retrieve():
    return _invoke(certificate_retrieval.lambda_handler, "/retrieve")


# ── Shares — sandbox Stripe keys, real kopera-share table ─────────────────────
@app.route("/member/shares/create-intent", methods=["POST", "OPTIONS"])
@app.route("/member-dev/shares/create-intent", methods=["POST", "OPTIONS"])
def shares_create_intent():
    return _invoke(create_share_intent.lambda_handler, "/member/shares/create-intent")


@app.route("/member/shares/checkout-session", methods=["POST", "OPTIONS"])
@app.route("/member-dev/shares/checkout-session", methods=["POST", "OPTIONS"])
def shares_checkout_session():
    return _invoke(create_share_checkout.lambda_handler, "/member/shares/checkout-session")


@app.route("/member/shares/webhook", methods=["POST", "OPTIONS"])
@app.route("/member-dev/shares/webhook", methods=["POST", "OPTIONS"])
def shares_webhook():
    return _invoke(share_webhook.lambda_handler, "/member/shares/webhook")


if __name__ == "__main__":
    port = int(os.environ.get("LOCAL_SERVER_PORT", "8000"))
    using_sandbox = bool(os.environ.get("STRIPE_SECRET_KEY"))
    print(f"KAFA local dev backend → http://localhost:{port}")
    print(f"  members table:        {os.environ['MEMBERS_TABLE']}")
    print(f"  life-insurance table: {os.environ['LIFE_INSURANCE_TABLE']}")
    print(f"  stripe key source:    {'sandbox override (.env.local)' if using_sandbox else 'SSM — LIVE KEY, set STRIPE_SECRET_KEY in .env.local'}")
    if not using_sandbox:
        print("  WARNING: no STRIPE_SECRET_KEY override set — this will fetch the LIVE key from SSM.")
    app.run(host="0.0.0.0", port=port, debug=True, use_reloader=False)
