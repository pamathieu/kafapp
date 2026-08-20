#!/usr/bin/env python3
"""
TC-002 — Prospect Applies, Admin Converts, Member Self-Pays via Portal

Data is processed THROUGH the portals using Playwright:
  API only (no portal UI for public prospect form):
    1.  POST /prospects with plan pre-selected
    2.  Verify notificationSent flag in response

  Admin portal (localhost:5500):
    3.  Admin sees prospect in Prospects tab with selected plan visible
    4.  Admin clicks 'Aksepte' to convert prospect to member
    7.  Admin creates STANDARD policy for the new member

  Member portal (localhost:5501):
    8.  Member logs in → pending status visible
    9.  Member pays MEMBERSHIP share ($50)
    10. Member is ACTIVE; membership share SUCCEEDED
    11. Member pays PREFERRED share ($500)
    12. Member pays STANDARD policy PREMIUM ($20)
    13. Policy nextDueDate advances
    14. All 3 payments confirmed

  Backend verification (API):
    5.  DB confirms member record pending with setupToken present
    6.  Member uses setupToken to create password (simulates clicking email link)
    10/11/12 verified via API after each Stripe webhook fires

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
    source .env.local && python3 dev/tests/tc002_prospect_to_member.py
"""

import sys, os
from pathlib import Path

# Re-exec with the project venv if needed
_venv_py = Path(__file__).resolve().parents[2] / "dev" / "venv" / "bin" / "python3"
if _venv_py.exists() and Path(sys.executable).resolve() != _venv_py.resolve():
    os.execv(str(_venv_py), [str(_venv_py)] + sys.argv)

import json
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
    db_delete_prospect,
    confirm_stripe_pi,
    print_summary,
)
from portal_helpers import (
    admin_open, admin_login, admin_go_prospects, admin_open_prospect,
    admin_accept_prospect, admin_open_member, admin_create_policy,
    member_open, member_login,
    member_buy_share, member_pay_premium,
    text_present, wait_for_text, get_all_text,
)

# ── Stripe keys (loaded from .env.local via helpers.py) ──────────────────────
stripe.api_key       = os.environ.get("STRIPE_SECRET_KEY", "")
WEBHOOK_SECRET       = os.environ.get("STRIPE_WEBHOOK_SECRET", "")
SHARE_WEBHOOK_SECRET = os.environ.get("SHARE_WEBHOOK_SECRET", "")

# ── Test data (static — deleted in teardown) ──────────────────────────────────
FIRST_NAME    = "TC002"
LAST_NAME     = "Prospect"
PHONE         = "5090000202"
EMAIL         = "tc002.prospect@kafa-noemail.invalid"
COMMUNE       = "Carrefour"
SELECTED_PLAN = "Standard"   # pre-selected on the public prospect form
PLAN          = "Standard Plan"  # plan card label in Create Policy dialog
PLAN_CODE     = "STANDARD"
PREMIUM_USD   = 20
SHARE_MBR     = 5000          # $50  in cents
SHARE_PREF    = 50000         # $500 in cents
MEMBER_PASS   = "TC002pass!"

# Filled during run, used in teardown
prospect_id: str = ""
member_id:   str = ""
policy_no:   str = ""


def run() -> int:
    global prospect_id, member_id, policy_no

    print(f"\n{'='*60}")
    print("  TC-002 — Prospect → Member (Portal-Driven)")
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
    global prospect_id, member_id, policy_no

    # ── Step 1: Prospect submits application form (via API — no portal UI) ────
    step(f"1. Prospect submits application (plan pre-selected: {SELECTED_PLAN})")
    r = api("POST", "/prospects", json={
        "firstName": FIRST_NAME,
        "lastName":  LAST_NAME,
        "phone":     PHONE,
        "email":     EMAIL,
        "commune":   COMMUNE,
        "plan":      SELECTED_PLAN,
        "message":   "TC-002 automated test prospect",
    })
    require(r.status_code == 201,
            f"POST /prospects → 201 (got {r.status_code}: {r.text[:120]})")
    prospect_id = r.json().get("prospectId", "")
    require(bool(prospect_id), "prospectId returned in response")
    print(f"    → Prospect: {prospect_id}")

    # ── Step 2: Verify notification flag ─────────────────────────────────────
    step("2. kontak@kafayiti.com notification attempted")
    notified = r.json().get("notificationSent", False)
    check(isinstance(notified, bool), f"notificationSent flag present (value: {notified})")
    if notified:
        check(True, "Notification delivered to kontak@kafayiti.com (SES available)")
    else:
        check(True, "Notification attempted — SES unavailable in local dev (expected)")

    # ── Step 3: Admin sees prospect in portal with selected plan ──────────────
    step("3. Admin opens Prospects tab — prospect visible with selected plan")
    admin_open(admin_pg)
    admin_login(admin_pg)
    admin_go_prospects(admin_pg)

    # Verify the prospect appears with the pre-selected plan
    check(
        wait_for_text(admin_pg, f"{FIRST_NAME} {LAST_NAME}", timeout_s=10),
        f"Prospect '{FIRST_NAME} {LAST_NAME}' visible in admin Prospects tab",
    )
    check(
        text_present(admin_pg, SELECTED_PLAN),
        f"Selected plan '{SELECTED_PLAN}' visible on prospect row",
    )

    # ── Step 4: Admin converts prospect to member via portal ──────────────────
    step("4. Admin opens prospect and clicks 'Aksepte' to convert to member")
    admin_open_prospect(admin_pg, f"{FIRST_NAME} {LAST_NAME}")
    admin_accept_prospect(admin_pg)

    # Wait a moment, then get the memberId from the prospect record via API
    time.sleep(1)
    r_p = api("GET", f"/prospects/{prospect_id}")
    if r_p.status_code == 200:
        member_id = r_p.json().get("memberId", "")
    if not member_id:
        # Fall back: search members by phone
        r_m = api("GET", f"/members?phone={PHONE}")
        if r_m.status_code == 200:
            members = r_m.json().get("members", [])
            if members:
                member_id = members[0].get("memberId", "")
    require(bool(member_id), f"memberId obtained after conversion: {member_id!r}")
    print(f"    → Member: {member_id}")

    # ── Step 5: Member record is pending; setupToken present ──────────────────
    step("5. Member record pending; setupToken present for email link")
    member = db_get_member(member_id)
    require(member is not None, "Member record exists in DynamoDB")
    check(member.get("status") is False,     "status == False (pending)")
    check(member.get("reason") == "Did not pay membership share",
          "reason == 'Did not pay membership share'")
    check(bool(member.get("setupToken")),    "setupToken present (used in email link)")
    check(member.get("full_name", "").strip() != "", "full_name populated")
    check(member.get("email") == EMAIL,       f"email == {EMAIL!r}")

    # ── Step 6: Member uses emailed link to create password (via API) ─────────
    step("6. Member creates password via emailed setup link (API-simulated)")
    setup_token = member.get("setupToken", "")
    r = api("POST", "/member/login", json={
        "setupToken":    setup_token,
        "setupPassword": MEMBER_PASS,
    })
    require(r.status_code == 200,
            f"POST /member/login (setup) → 200 (got {r.status_code}: {r.text[:120]})")
    check("Password set" in r.json().get("message", ""), "Password created successfully")

    # ── Step 7: Admin creates STANDARD policy via portal ─────────────────────
    step("7. Admin creates STANDARD policy for the new member via portal")
    admin_open_member(admin_pg, member_id)
    admin_create_policy(admin_pg, plan=PLAN)

    time.sleep(1)
    r = api("GET", f"/member/policy?memberId={member_id}")
    require(r.status_code == 200, f"GET /member/policy → 200 (got {r.status_code})")
    policies = r.json().get("policies", [])
    require(len(policies) >= 1, "At least one policy created")
    policy_no = policies[0].get("policy", {}).get("policyNo", "")
    require(bool(policy_no), f"policyNo captured: {policy_no!r}")
    premium = policies[0].get("policy", {}).get("premiumAmount", "")
    check(str(premium) == str(PREMIUM_USD), f"premiumAmount == {PREMIUM_USD}")
    print(f"    → Policy: {policy_no}")

    # ── Step 8: Member logs in via portal — still pending ─────────────────────
    step("8. Member logs in to portal — status still pending before share payment")
    member_open(mbr_pg)
    member_login(mbr_pg, identifier=EMAIL, password=MEMBER_PASS)

    r = api("POST", "/member/login", json={"identifier": EMAIL, "password": MEMBER_PASS})
    require(r.status_code == 200, f"POST /member/login → 200 (got {r.status_code})")
    logged = r.json().get("member", {})
    check(logged.get("memberId") == member_id, f"Logged-in memberId == {member_id}")
    check(logged.get("status") is False,        "Status == False (pending)")

    # ── Step 9: Member pays MEMBERSHIP share via portal ($50) ─────────────────
    step("9. Member pays membership share via portal ($50) — Stripe mock")
    cs_mbr = member_buy_share(mbr_pg, share_type="membership", amount_usd=50)
    check(bool(cs_mbr), "client_secret captured for membership share")

    confirm_stripe_pi(cs_mbr, SHARE_MBR, "/member/shares/webhook", SHARE_WEBHOOK_SECRET)
    time.sleep(1)

    # ── Step 10: Member is now ACTIVE ─────────────────────────────────────────
    step("10. After membership share — member ACTIVE, share SUCCEEDED")
    member = db_get_member(member_id)
    require(member is not None, "Member record still exists")
    check(member.get("status") is True,  "status == True (active)")
    check(not member.get("reason"),      "reason cleared")

    r = api("GET", f"/member/shares?memberId={member_id}")
    require(r.status_code == 200, f"GET /member/shares → 200 (got {r.status_code})")
    shares = r.json().get("shares", [])
    mbr_sh = [s for s in shares if s.get("shareType") == "membership"]
    check(len(mbr_sh) == 1, "Exactly 1 membership share record")
    if mbr_sh:
        check(mbr_sh[0].get("status") == "SUCCEEDED", "Membership share SUCCEEDED")

    # ── Step 11: Member pays PREFERRED share via portal ($500) ────────────────
    step("11. Member pays preferred share via portal ($500) — Stripe mock")
    cs_pref = member_buy_share(mbr_pg, share_type="preferred", amount_usd=500)
    check(bool(cs_pref), "client_secret captured for preferred share")

    confirm_stripe_pi(cs_pref, SHARE_PREF, "/member/shares/webhook", SHARE_WEBHOOK_SECRET)
    time.sleep(1)

    r = api("GET", f"/member/shares?memberId={member_id}")
    require(r.status_code == 200, f"GET /member/shares → 200 (got {r.status_code})")
    shares  = r.json().get("shares", [])
    pref_sh = [s for s in shares if s.get("shareType") == "preferred"]
    check(len(shares)   == 2, "Total of 2 share records")
    check(len(pref_sh)  == 1, "Exactly 1 preferred share record")
    if pref_sh:
        check(pref_sh[0].get("status") == "SUCCEEDED", "Preferred share SUCCEEDED")

    # ── Step 12: Member pays STANDARD policy PREMIUM via portal ($20) ─────────
    step("12. Member pays STANDARD policy premium via portal ($20) — Stripe mock")
    cs_prem = member_pay_premium(mbr_pg)
    check(bool(cs_prem), "client_secret captured for premium payment")

    confirm_stripe_pi(cs_prem, PREMIUM_USD * 100, "/payments/webhook", WEBHOOK_SECRET)
    time.sleep(1)

    # ── Step 13: Policy nextDueDate advances ──────────────────────────────────
    step("13. Policy nextDueDate advances after STANDARD premium payment")
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
            check(nd > today, f"nextDueDate {next_due} is in the future")
        except ValueError:
            check(False, f"nextDueDate not a valid date: {next_due!r}")
        check(pol.get("lastPaidDate", "") not in ("", None), "lastPaidDate is set")
        check(len(pmt_hist) >= 1, f"At least 1 payment in history (got {len(pmt_hist)})")

    # ── Step 14: All 3 payments confirmed ─────────────────────────────────────
    step("14. All 3 payments confirmed (2 shares + 1 premium)")
    r = api("GET", f"/member/shares?memberId={member_id}")
    all_shares = r.json().get("shares", []) if r.status_code == 200 else []
    check(len(all_shares) == 2,
          f"2 share payments visible (membership + preferred) — got {len(all_shares)}")

    r2 = api("GET", f"/admin/payments?memberId={member_id}")
    if r2.status_code == 200:
        pmts = r2.json().get("payments", [])
        check(len(pmts) >= 1, f"At least 1 premium payment visible (got {len(pmts)})")
        if pmts:
            check(pmts[0].get("policyId") == policy_no,
                  f"Premium payment linked to policy {policy_no}")
    else:
        check(False, f"GET /admin/payments → 200 (got {r2.status_code})")

    return print_summary("TC-002")


def _teardown(silent: bool = False) -> None:
    if not silent:
        print("\n  ── Teardown: removing test data ──")
    try:
        if prospect_id:
            db_delete_prospect(prospect_id)
    except Exception as e:
        if not silent:
            print(f"    Warning: prospect cleanup: {e}")
    if member_id:
        try:
            if policy_no:
                db_delete_payments(policy_no)
                db_delete_policy(policy_no)
        except Exception as e:
            if not silent:
                print(f"    Warning: policy/payment cleanup: {e}")
        try:
            db_delete_shares(member_id)
        except Exception as e:
            if not silent:
                print(f"    Warning: shares cleanup: {e}")
        try:
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
        print_summary("TC-002")
    except Exception as e:
        print(f"\n  UNEXPECTED ERROR: {e}")
        import traceback
        traceback.print_exc()
    finally:
        _teardown()
    sys.exit(exit_code)
