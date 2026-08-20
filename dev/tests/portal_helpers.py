"""
portal_helpers.py — Playwright helpers for KAFA admin + member portals.

Flutter web (CanvasKit) rendering notes:
  - All widget rendering is on a WebGL canvas; there is no standard DOM.
  - Flutter creates a parallel flt-semantics accessibility overlay.
  - Semantics must be explicitly enabled by clicking the hidden placeholder.
  - Text inputs create real DOM inputs; type varies by TextInputType:
      TextInputType.text         → input[type='text']
      TextInputType.emailAddress → input[type='email']
      TextInputType.phone        → input[type='tel']
      TextInputType.number       → input[type='number']
      maxLines > 1               → textarea (NOT counted in text inputs)
  - Button clicks work by resolving the flt-semantics element's bounding box
    and dispatching a mouse click at those coordinates on the canvas.
  - Enter key works for form fields with onSubmitted handlers (e.g. login).

Stripe mock (inject_stripe_mock):
  - Overrides window.kafaConfirmPayment to capture client_secret and return
    {ok: true} immediately, so Flutter thinks the payment succeeded without
    going through Stripe.js.  The test then confirms the captured PI via the
    Stripe test API and fires the webhook to update the backend.
"""

import json as _json
import time

ADMIN_URL  = "http://localhost:5500"
MEMBER_URL = "http://localhost:5501"

# Selector that covers all text-like input types Flutter web creates
_TEXT_INPUT_SEL = (
    "input[type='text'], input[type='email'], "
    "input[type='tel'], input[type='number'], "
    "input[type='search'], input[type='url']"
)

_SEM_JS = (
    "const el=document.querySelector('flt-semantics-placeholder');"
    "if(el)el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true}));"
)

_BTN_COORDS_JS = """
(text) => {
    const b = Array.from(document.querySelectorAll("flt-semantics[role='button']"))
        .find(el => {
            const t = (el.textContent || el.getAttribute('aria-label') || '');
            return t.includes(text);
        });
    if (!b) return null;
    const r = b.getBoundingClientRect();
    return { x: r.left + r.width/2, y: r.top + r.height/2 };
}
"""

_SEM_COORDS_JS = """
(text) => {
    const node = Array.from(document.querySelectorAll('flt-semantics'))
        .find(el => (el.textContent || el.getAttribute('aria-label') || '').includes(text));
    if (!node) return null;
    const r = node.getBoundingClientRect();
    return { x: r.left + r.width/2, y: r.top + r.height/2 };
}
"""

_TXT_NODES_JS = """
() => Array.from(document.querySelectorAll("flt-semantics"))
          .map(n => (n.textContent||'').trim())
          .filter(t => t && t.length < 200)
"""

_BTN_LIST_JS = """
() => Array.from(document.querySelectorAll("flt-semantics[role='button']"))
          .map(b => (b.textContent || b.getAttribute('aria-label') || '').trim().replace(/\\n/g,' '))
"""

# Overrides kafaConfirmPayment to capture the client_secret and immediately
# return {ok: true}.  Requires inject_stripe_mock() to be called once per page.
_STRIPE_MOCK_JS = """
window._kafaLastCS = '';
window.kafaConfirmPayment = function(clientSecret) {
    window._kafaLastCS = clientSecret;
    return Promise.resolve(JSON.stringify({ ok: true }));
};
"""


def enable_semantics(page, wait_ms: int = 1500) -> None:
    """Trigger Flutter's accessibility/semantic overlay."""
    page.evaluate(_SEM_JS)
    page.wait_for_timeout(wait_ms)


def inject_stripe_mock(page) -> None:
    """
    Override kafaConfirmPayment so Flutter thinks the payment succeeded instantly.
    Call this once after a page is loaded and semantics are enabled.
    The captured client_secret is available via pop_captured_cs().
    """
    page.evaluate(_STRIPE_MOCK_JS)


def pop_captured_cs(page, timeout_s: int = 12) -> str:
    """
    Wait until kafaConfirmPayment has been called and return the captured
    client_secret, then reset the slot for the next call.
    """
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        cs = page.evaluate("window._kafaLastCS || ''")
        if cs:
            page.evaluate("window._kafaLastCS = ''")
            return cs
        time.sleep(0.3)
    return ""


def click_btn(page, text_fragment: str, timeout_s: int = 10) -> bool:
    """
    Click a flt-semantics[role='button'] that contains text_fragment.
    Returns True if found and clicked.
    """
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        coords = page.evaluate(_BTN_COORDS_JS, text_fragment)
        if coords:
            page.mouse.click(coords["x"], coords["y"])
            page.wait_for_timeout(300)
            return True
        page.wait_for_timeout(400)
    return False


def click_sem(page, text_fragment: str, timeout_s: int = 10) -> bool:
    """
    Click ANY flt-semantics node (not just buttons) that contains text_fragment.
    Useful for list items (member rows, prospect rows) that have no role='button'.
    """
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        coords = page.evaluate(_SEM_COORDS_JS, text_fragment)
        if coords:
            page.mouse.click(coords["x"], coords["y"])
            page.wait_for_timeout(300)
            return True
        page.wait_for_timeout(400)
    return False


def wait_for_text(page, text_fragment: str, timeout_s: int = 10) -> bool:
    """Wait until any flt-semantics node contains text_fragment."""
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        nodes = page.evaluate(_TXT_NODES_JS)
        if any(text_fragment in n for n in nodes):
            return True
        page.wait_for_timeout(400)
    return False


def text_present(page, text_fragment: str) -> bool:
    nodes = page.evaluate(_TXT_NODES_JS)
    return any(text_fragment in n for n in nodes)


def get_all_buttons(page) -> list[str]:
    return page.evaluate(_BTN_LIST_JS)


def get_all_text(page) -> list[str]:
    return page.evaluate(_TXT_NODES_JS)


# ── Input helpers ─────────────────────────────────────────────────────────────

def fill_nth_text_input(page, nth: int, value: str) -> None:
    """
    Fill the nth text-like input on the page (covers type='text', 'email',
    'tel', 'number' — but NOT 'password').  textarea elements are excluded.
    """
    page.locator(_TEXT_INPUT_SEL).nth(nth).fill(value)
    page.wait_for_timeout(200)


def fill_password_input(page, value: str) -> None:
    page.locator("input[type='password']").fill(value)
    page.wait_for_timeout(200)


# ── Admin portal ──────────────────────────────────────────────────────────────

def admin_open(page) -> None:
    page.goto(ADMIN_URL)
    page.wait_for_load_state("networkidle")
    page.wait_for_timeout(3000)
    enable_semantics(page)


def admin_login(page, username: str = "admin", password: str = "kafa2026") -> None:
    fill_nth_text_input(page, 0, username)
    fill_password_input(page, password)
    page.locator("input[type='password']").press("Enter")
    page.wait_for_timeout(4000)
    enable_semantics(page)


def admin_go_members(page) -> None:
    click_btn(page, "Tab 2 of 5")
    page.wait_for_timeout(2000)
    enable_semantics(page)


def admin_go_prospects(page) -> None:
    click_btn(page, "Tab 3 of 5")
    page.wait_for_timeout(2000)
    enable_semantics(page)


def admin_create_member(
    page,
    name: str,
    phone: str,
    email: str,
    commune: str = "Léogâne",
) -> str:
    """
    Drive the admin portal to create a new member.
    Returns the generated memberId (read from the form field after commune selection).

    Create Member form — input[type='text'|'email'|'tel'|'number'] order:
      [0]  Commune autocomplete (Autocomplete widget's internal TextField)
      [1]  Member ID (auto-generated, readOnly)
      [2]  Full Name
      [3]  Date of Birth  (left blank)
           Address → textarea (maxLines:2), NOT counted
      [4]  Phone (type='tel')
      [5]  Email (type='email')
      [6]  ID Number
      [7]  ID Type
           Notes → textarea (maxLines:3), NOT counted
    """
    admin_go_members(page)
    assert click_btn(page, "Ajoute"), "Add Member FAB not found"
    page.wait_for_timeout(2000)
    enable_semantics(page)

    # Type commune; autocomplete shows matching suggestions
    fill_nth_text_input(page, 0, commune)
    page.wait_for_timeout(1500)

    # Click the first suggestion matching commune
    assert click_btn(page, commune), f"Commune suggestion '{commune}' not found"
    page.wait_for_timeout(1500)  # member ID auto-generates from sequence API

    # Read the generated member ID before submitting
    generated_id = page.locator(_TEXT_INPUT_SEL).nth(1).input_value()

    fill_nth_text_input(page, 2, name)
    fill_nth_text_input(page, 4, phone)
    fill_nth_text_input(page, 5, email)

    assert click_btn(page, "Kreye Manm"), "Create Member button not found"
    page.wait_for_timeout(3000)
    enable_semantics(page)

    return generated_id


def admin_open_member(page, identifier: str) -> None:
    """
    Navigate to a member's detail screen by clicking their row in the
    Members list.  identifier can be a memberId, phone, or name fragment.
    Uses click_sem (not click_btn) since list rows may lack role='button'.
    """
    admin_go_members(page)
    assert click_sem(page, identifier), f"Member row containing '{identifier}' not found"
    page.wait_for_timeout(2000)
    enable_semantics(page)


def admin_send_password_email(page) -> bool:
    """Click 'Send Password Setup Email' on the member detail screen."""
    found = click_btn(page, "Voye Imèl Pou Konfigire Modpas")
    page.wait_for_timeout(2000)
    return found


def admin_create_policy(page, plan: str = "Basic Plan") -> None:
    """
    Click Create Policy on the member detail screen, select the given plan,
    and confirm.  plan should be 'Basic Plan' or 'Standard Plan' (hardcoded
    English in the source — not localized).
    """
    assert click_btn(page, "Kreye Polis"), "Create Policy button not found"
    page.wait_for_timeout(1500)
    enable_semantics(page)

    assert click_btn(page, plan), f"Plan '{plan}' not found in policy dialog"
    page.wait_for_timeout(500)

    # Second "Kreye Polis" click confirms the selection
    assert click_btn(page, "Kreye Polis"), "Confirm Create Policy button not found"
    page.wait_for_timeout(3000)
    enable_semantics(page)


def admin_open_prospect(page, name_fragment: str) -> None:
    """Open a prospect's detail view from the Prospects tab."""
    admin_go_prospects(page)
    assert click_sem(page, name_fragment), f"Prospect '{name_fragment}' not found"
    page.wait_for_timeout(2000)
    enable_semantics(page)


def admin_accept_prospect(page) -> None:
    """Click the 'Aksepte' status chip to convert a prospect to member."""
    assert click_btn(page, "Aksepte"), "Accepted status button not found"
    page.wait_for_timeout(3000)
    enable_semantics(page)


# ── Member portal ─────────────────────────────────────────────────────────────

def member_open(page) -> None:
    page.goto(MEMBER_URL)
    page.wait_for_load_state("networkidle")
    page.wait_for_timeout(3000)
    enable_semantics(page)
    inject_stripe_mock(page)


def member_login(page, identifier: str, password: str) -> None:
    fill_nth_text_input(page, 0, identifier)
    fill_password_input(page, password)
    page.locator("input[type='password']").press("Enter")
    page.wait_for_timeout(4000)
    enable_semantics(page)
    inject_stripe_mock(page)


def member_go_dashboard(page) -> None:
    """Navigate to the Dashboard tab (Tab 1 of 4)."""
    click_btn(page, "Tab 1 of 4")
    page.wait_for_timeout(2000)
    enable_semantics(page)


def member_buy_share(
    page,
    share_type: str,
    amount_usd: int,
) -> str:
    """
    Drive the portal to buy a share:
      1. Click 'Achte Aksyon' quick-action card on Dashboard
      2. Optionally select 'Privilejye' chip for preferred shares
         (membership is pre-selected for pending members)
      3. Fill amount
      4. Click buy button
      5. Wait for kafaConfirmPayment mock to be called (captures client_secret)

    Returns the captured client_secret so the caller can confirm via Stripe API.

    Member portal bottom nav: Dashboard(1), Policies(2), Services(3), Profile(4)
    Buy Shares is a quick-action card on the Dashboard tab.
    """
    member_go_dashboard(page)

    assert click_btn(page, "Achte Aksyon"), "Buy Shares card not found on Dashboard"
    page.wait_for_timeout(2000)
    enable_semantics(page)

    if share_type == "preferred":
        assert click_btn(page, "Privilejye"), "Preferred chip not found"
        page.wait_for_timeout(1000)
        enable_semantics(page)

    # Amount field is the only number/text input on the shares screen
    fill_nth_text_input(page, 0, str(amount_usd))
    page.wait_for_timeout(500)

    btn_label = "Achte Aksyon Manm" if share_type == "membership" else "Achte Aksyon Privilejye"
    assert click_btn(page, btn_label), f"Buy button '{btn_label}' not found"

    cs = pop_captured_cs(page, timeout_s=15)
    assert cs, f"client_secret not captured for {share_type} share purchase"
    return cs


def member_pay_premium(page) -> str:
    """
    Drive the portal to pay a policy premium:
      1. Click 'Peye Primè' quick-action on Dashboard
      2. Wait for PaymentScreen to open and for kafaConfirmPayment to be called

    Returns the captured client_secret.
    """
    member_go_dashboard(page)

    assert click_btn(page, "Peye Primè"), "Pay Premium card not found on Dashboard"
    page.wait_for_timeout(2000)
    enable_semantics(page)

    # For single-policy members, PaymentScreen opens directly.
    # Click 'Peye Kounye a' (Pay Now) button.
    assert click_btn(page, "Peye Kounye a"), "Pay Now button not found"
    page.wait_for_timeout(2000)

    cs = pop_captured_cs(page, timeout_s=15)
    assert cs, "client_secret not captured for premium payment"
    return cs
