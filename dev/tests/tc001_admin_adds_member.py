#!/usr/bin/env python3
"""
TC-001 — Admin Adds Member; All Three Payments via Self-Service Portal

Data is processed THROUGH the portals using Playwright:
  Admin portal (localhost:5500):
    1.  Admin fills Create Member form → member created (pending)
    3.  Admin clicks "Send Password Setup Email" on member detail screen
    4.  Admin clicks "Create Policy" and selects BASIC plan

  Member portal (localhost:5501):
    6.  Member logs in → pending status banner visible
    7.  Member navigates to Buy Shares → pays MEMBERSHIP share ($50)
    9.  Member pays PREFERRED share ($500)
    11. Member pays POLICY PREMIUM ($10 BASIC)

  Backend verification (API):
    2.  DB confirms member is pending
    5.  API sets member credentials (simulates clicking the emailed setup link)
    8.  DB confirms member is now ACTIVE after membership share payment
    10. API confirms both shares SUCCEEDED
    12. API confirms policy nextDueDate advanced
    13. API confirms all 3 payments visible

  Stripe:
    kafaConfirmPayment() is mocked via JS injection so Flutter thinks payments
    succeed instantly.  The captured client_secret is confirmed via Stripe test
    API and the webhook fires to update the backend.

Requirements:
  - Admin portal running at :5500  (Flutter web, build/web-admin-local)
  - Member portal running at :5501 (Flutter web, build/web-member-local)
  - Backend running at :8000       (dev/local_server.py)
  - .env.local with STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET, SHARE_WEBHOOK_SECRET

Usage:
    source .env.local && python3 dev/tests/tc001_admin_adds_member.py
"""

import sys, os
from pathlib import Path

# Re-exec with the project venv if needed
_venv_py = Path(__file__).resolve().parents[2] / "dev" / "venv" / "bin" / "python3"
if _venv_py.exists() and Path(sys.executable).resolve() != _venv_py.resolve():
    os.execv(str(_venv_py), [str(_venv_py)] + sys.argv)

import sys
import time
from datetime import date, timedelta
from pathlib import Path

import stripe
from playwright.sync_api import sync_playwright

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from helpers import (
    COMPANY_ID, API_BASE,
    step, check, require,
    api, db_get_member,
    db_delete_member, db_delete_policy, db_delete_shares, db_delete_payments,
    confirm_stripe_pi,
    print_summary,
)
from portal_helpers import (
    admin_open, admin_login, admin_create_member, admin_open_member,
    admin_send_password_email, admin_create_policy,
    member_open, member_login,
    member_buy_share, member_pay_premium,
    text_present, wait_for_text, get_all_text,
)

# ── Stripe keys (loaded from .env.local via helpers.py) ──────────────────────
stripe.api_key       = os.environ.get("STRIPE_SECRET_KEY", "")
WEBHOOK_SECRET       = os.environ.get("STRIPE_WEBHOOK_SECRET", "")
SHARE_WEBHOOK_SECRET = os.environ.get("SHARE_WEBHOOK_SECRET", "")

# ── Test data (static — deleted in teardown) ──────────────────────────────────
MEMBER_NAME = "TC001 Portal Member"
PHONE       = "5090000101"
EMAIL       = "tc001.test@kafa-noemail.invalid"
COMMUNE     = "Léogâne"
PLAN        = "Basic Plan"       # plan card label in Create Policy dialog
PLAN_CODE   = "BASIC"
PREMIUM_USD = 10
SHARE_MBR   = 5000              # $50 in cents
SHARE_PREF  = 50000             # $500 in cents
MEMBER_PASS = "TC001pass!"

# Filled during run, used in teardown
member_id: str = ""
policy_no: str = ""


def run() -> int:
    global member_id, policy_no

    print(f"\n{'='*60}")
    print("  TC-001 — Admin Adds Member (Portal-Driven)")
    print(f"  Backend:       {API_BASE}")
    print(f"  Admin portal:  http://localhost:5500")
    print(f"  Member portal: http://localhost:5501")
    print("=" * 60)

    if not stripe.api_key:
        print("\n  ERROR: STRIPE_SECRET_KEY not set — source .env.local first.\n")
        sys.exit(1)
    if not SHARE_WEBHOOK_SECRET or not WEBHOOK_SECRET:
        print("\n  ERROR: STRIPE_WEBHOOK_SECRET / SHARE_WEBHOOK_SECRET not set.\n")
        sys.exit(1)

    _teardown(silent=True)

    with sync_playwright() as pw:
        browser = pw.chromium.launch(
            headless=os.environ.get("HEADLESS", "").lower() in ("1", "true"),
            slow_mo=150,
        )
        ctx = browser.new_context(viewport={"width": 1280, "height": 900})
        admin_pg = ctx.new_page()
        mbr_pg   = ctx.new_page()

        try:
            return _run_steps(admin_pg, mbr_pg)
        finally:
            browser.close()


def _run_steps(admin_pg, mbr_pg) -> int:
    global member_id, policy_no

    # ── Step 1: Admin creates member via portal ───────────────────────────────
    step("1. Admin creates member via portal (Commune, Name, Phone, Email)")
    admin_open(admin_pg)
    admin_login(admin_pg)

    generated_id = admin_create_member(
        admin_pg,
        name=MEMBER_NAME,
        phone=PHONE,
        email=EMAIL,
        commune=COMMUNE,
    )
    member_id = generated_id
    require(bool(member_id), f"Member ID generated by portal: {member_id!r}")
    print(f"    → Member: {member_id}")

    # ── Step 2: Verify member is pending in DB ────────────────────────────────
    step("2. Member starts as pending — did not pay membership share")
    member = db_get_member(member_id)
    require(member is not None, "Member record exists in DynamoDB")
    check(member.get("status") is False,  "status == False (inactive/pending)")
    check(member.get("reason") == "Did not pay membership share",
          'reason == "Did not pay membership share"')
    check(member.get("full_name") == MEMBER_NAME, f"full_name == {MEMBER_NAME!r}")
    check(member.get("phone")     == PHONE,        f"phone == {PHONE!r}")
    check(member.get("email")     == EMAIL,         f"email == {EMAIL!r}")

    # ── Step 3: Admin sends password setup email via portal ───────────────────
    step("3. Admin clicks 'Send Password Setup Email' on member detail screen")
    admin_open_member(admin_pg, member_id)
    found = admin_send_password_email(admin_pg)
    check(found, "Send Password Setup Email button found and clicked")
    # SES unavailable in local dev — success/fail snackbar is fine either way
    admin_pg.wait_for_timeout(1500)

    # ── Step 4: Admin creates BASIC policy via portal ─────────────────────────
    step("4. Admin creates BASIC policy via portal")
    admin_create_policy(admin_pg, plan=PLAN)

    # Capture the policy number from the backend after portal creates it
    time.sleep(1)
    r = api("GET", f"/member/policy?memberId={member_id}")
    require(r.status_code == 200, f"GET /member/policy → 200 (got {r.status_code})")
    policies = r.json().get("policies", [])
    require(len(policies) >= 1, "At least one policy created for member")
    policy_no = policies[0].get("policy", {}).get("policyNo", "")
    require(bool(policy_no), f"policyNo captured: {policy_no!r}")
    premium = policies[0].get("policy", {}).get("premiumAmount", "")
    check(str(premium) == str(PREMIUM_USD), f"premiumAmount == {PREMIUM_USD}")
    print(f"    → Policy: {policy_no}")

    # ── Step 5: Member uses email link to create password (simulated via API) ──
    step("5. Member creates password via setup link (simulates clicking emailed link)")
    r = api("POST", "/members/set-credentials", json={
        "memberId":  member_id,
        "companyId": COMPANY_ID,
        "password":  MEMBER_PASS,
    })
    require(r.status_code == 200,
            f"POST /members/set-credentials → 200 (got {r.status_code}: {r.text[:120]})")

    # ── Step 6: Member logs in via portal — still pending ─────────────────────
    step("6. Member logs in to portal — status banner shows pending")
    member_open(mbr_pg)
    member_login(mbr_pg, identifier=EMAIL, password=MEMBER_PASS)

    r = api("POST", "/member/login", json={"identifier": EMAIL, "password": MEMBER_PASS})
    require(r.status_code == 200, f"POST /member/login → 200 (got {r.status_code})")
    logged = r.json().get("member", {})
    check(logged.get("memberId") == member_id, f"Logged-in memberId == {member_id}")
    check(logged.get("status") is False,        "Status == False (pending) before share payment")

    # ── Step 7: Member pays MEMBERSHIP share via portal ($50) ─────────────────
    step("7. Member pays membership share via portal ($50) — Stripe mock")
    cs_mbr = member_buy_share(mbr_pg, share_type="membership", amount_usd=50)
    check(bool(cs_mbr), f"client_secret captured: {cs_mbr[:20]}...")

    confirm_stripe_pi(cs_mbr, SHARE_MBR, "/member/shares/webhook", SHARE_WEBHOOK_SECRET)
    time.sleep(1)

    # ── Step 8: Member is now ACTIVE ──────────────────────────────────────────
    step("8. Membership share paid — member is now ACTIVE")
    member = db_get_member(member_id)
    require(member is not None, "Member record still exists")
    check(member.get("status") is True, "status == True (active)")
    check(not member.get("reason"), "reason cleared after membership share")

    r = api("GET", f"/member/shares?memberId={member_id}")
    require(r.status_code == 200, f"GET /member/shares → 200 (got {r.status_code})")
    shares = r.json().get("shares", [])
    mbr_sh = [s for s in shares if s.get("shareType") == "membership"]
    check(len(mbr_sh) == 1, "Exactly 1 membership share record")
    if mbr_sh:
        check(mbr_sh[0].get("status") == "SUCCEEDED", "Membership share SUCCEEDED")
        check(float(mbr_sh[0].get("amount", 0)) == SHARE_MBR / 100,
              f"Amount == ${SHARE_MBR/100:.2f}")

    # ── Step 9: Member pays PREFERRED share via portal ($500) ─────────────────
    step("9. Member pays preferred share via portal ($500) — Stripe mock")
    cs_pref = member_buy_share(mbr_pg, share_type="preferred", amount_usd=500)
    check(bool(cs_pref), f"client_secret captured for preferred share")

    confirm_stripe_pi(cs_pref, SHARE_PREF, "/member/shares/webhook", SHARE_WEBHOOK_SECRET)
    time.sleep(1)

    # ── Step 10: Both shares visible and SUCCEEDED ────────────────────────────
    step("10. Both share records visible on self-service portal")
    r = api("GET", f"/member/shares?memberId={member_id}")
    require(r.status_code == 200, f"GET /member/shares → 200 (got {r.status_code})")
    shares  = r.json().get("shares", [])
    pref_sh = [s for s in shares if s.get("shareType") == "preferred"]
    check(len(shares)   == 2, "Total of 2 share records")
    check(len(pref_sh)  == 1, "Exactly 1 preferred share record")
    if pref_sh:
        check(pref_sh[0].get("status") == "SUCCEEDED", "Preferred share SUCCEEDED")
        apr = pref_sh[0].get("apr", 0) or pref_sh[0].get("aprRate", 0)
        check(float(apr) > 0, f"APR recorded for preferred share: {apr}%")
        check(float(pref_sh[0].get("amount", 0)) == SHARE_PREF / 100,
              f"Amount == ${SHARE_PREF/100:.2f}")

    # ── Step 11: Member pays policy PREMIUM via portal ($10 BASIC) ────────────
    step("11. Member pays policy premium via portal ($10 BASIC) — Stripe mock")
    cs_prem = member_pay_premium(mbr_pg)
    check(bool(cs_prem), "client_secret captured for premium payment")

    confirm_stripe_pi(cs_prem, PREMIUM_USD * 100, "/payments/webhook", WEBHOOK_SECRET)
    time.sleep(1)

    # ── Step 12: Policy nextDueDate advances ──────────────────────────────────
    step("12. Policy nextDueDate advances after premium payment")
    today = date.today()
    r = api("GET", f"/member/policy?memberId={member_id}")
    require(r.status_code == 200, f"GET /member/policy → 200 (got {r.status_code})")
    policies = r.json().get("policies", [])
    matching = [p for p in policies if p.get("policy", {}).get("policyNo") == policy_no]
    check(len(matching) == 1, f"Policy {policy_no} visible in portal")
    if matching:
        pol      = matching[0].get("policy", {})
        pmt_hist = matching[0].get("paymentHistory", [])
        next_due = pol.get("nextDueDate", "")
        try:
            nd = date.fromisoformat(next_due)
            check(nd >= today, f"nextDueDate {next_due} is current or future")
        except ValueError:
            check(False, f"nextDueDate not a valid date: {next_due!r}")
        check(pol.get("lastPaidDate") not in ("", None), "lastPaidDate is set")
        check(len(pmt_hist) >= 1, f"Payment in history (got {len(pmt_hist)})")

    # ── Step 13: All 3 payments confirmed ─────────────────────────────────────
    step("13. All 3 payments confirmed (2 shares + 1 premium)")
    r = api("GET", f"/member/shares?memberId={member_id}")
    all_shares = r.json().get("shares", []) if r.status_code == 200 else []
    check(len(all_shares) == 2, f"2 share payments visible (got {len(all_shares)})")

    r2 = api("GET", f"/admin/payments?memberId={member_id}")
    if r2.status_code == 200:
        pmts = r2.json().get("payments", [])
        check(len(pmts) >= 1, f"At least 1 premium payment visible (got {len(pmts)})")
        if pmts:
            check(pmts[0].get("policyId") == policy_no,
                  f"Premium payment linked to policy {policy_no}")
    else:
        check(False, f"GET /admin/payments → 200 (got {r2.status_code})")

    return print_summary("TC-001")


def _teardown(silent: bool = False) -> None:
    if not silent:
        print("\n  ── Teardown: removing test data ──")
    try:
        if policy_no:
            db_delete_payments(policy_no)
            db_delete_policy(policy_no)
    except Exception as e:
        if not silent:
            print(f"    Warning: policy/payment cleanup: {e}")
    try:
        if member_id:
            db_delete_shares(member_id)
    except Exception as e:
        if not silent:
            print(f"    Warning: shares cleanup: {e}")
    try:
        if member_id:
            db_delete_member(member_id)
    except Exception as e:
        if not silent:
            print(f"    Warning: member cleanup: {e}")
    if not silent:
        print("  ── Teardown complete ──")


if __name__ == "__main__":
    exit_code = 1
    try:
        exit_code = run()
    except AssertionError:
        print_summary("TC-001")
    except Exception as e:
        print(f"\n  UNEXPECTED ERROR: {e}")
        import traceback
        traceback.print_exc()
    finally:
        _teardown()
    sys.exit(exit_code)
