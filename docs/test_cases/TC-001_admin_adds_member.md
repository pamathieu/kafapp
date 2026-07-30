# TC-001 — Admin Adds Member and Completes All Payments

**Portals involved:** Admin (`:5500`) · Member self-service (`:5501`)  
**Environment:** Local dev (`dev/run_local_dev.sh`) or staging  
**Stripe test card:** `4242 4242 4242 4242` · any future expiry · any CVC  

---

## Prerequisites

- [ ] Local dev environment is running (backend `:8000`, admin `:5500`, member `:5501`, Stripe CLI forwarding both webhook endpoints)
- [ ] At least one insurance plan exists in the system (e.g. Basic or Standard)
- [ ] You have admin credentials (`admin` / `kafa2026` for local dev)

---

## Step 1 — Admin creates the member

1. [ ] Log in to the admin portal (`http://localhost:5500`)
2. [ ] Navigate to **Members** → **Add Member**
3. [ ] Fill in the following required fields:
   - **Commune** — select any valid commune
   - **Full name** — e.g. `Jean Pierre Test`
   - **Phone number** — e.g. `5090000001`
   - **Email** — e.g. `tc001.test@example.com`
4. [ ] Submit the form

**Expected result:**
- [ ] Member appears in the members list
- [ ] Member status shows **Inactive / Pending**
- [ ] Member's reason reads **"Did not pay membership share"** (visible in member detail)

---

## Step 2 — Admin sends password creation email

1. [ ] Open the newly created member's detail page
2. [ ] Click **Send Password Reset** (or equivalent action that emails a password creation link)
3. [ ] Confirm a success toast/message appears

**Expected result:**
- [ ] Member receives an email with a password creation / reset link
- [ ] *(In local dev: check the email provider logs or use a test inbox like Mailtrap)*

---

## Step 3 — Admin creates a policy for the member

1. [ ] On the member detail page, navigate to the **Policies** section
2. [ ] Click **Add Policy**
3. [ ] Select a plan (e.g. Basic)
4. [ ] Fill in any required policy fields and confirm
5. [ ] Submit

**Expected result:**
- [ ] Policy appears under the member's policies with status **Pending** (or **Active** depending on plan config)
- [ ] Policy displays a **next due date**

---

## Step 4 — Admin pays membership share (activates member)

1. [ ] On the member detail page, navigate to the **Shares** section
2. [ ] Click **Collect Share**
3. [ ] Select **Membership** tab
4. [ ] Enter an amount (minimum $50, in multiples of $50) — e.g. `50`
5. [ ] Select payment method (Cash, MonCash, or Stripe test card)
6. [ ] Submit

**Expected result:**
- [ ] Membership share appears in **Payment History** with status **Succeeded**
- [ ] Member status changes from **Inactive** to **Active**
- [ ] The **"Did not pay membership share"** reason is removed from the member record
- [ ] Membership share total on the Shares card updates (e.g. `$50.00`)

---

## Step 5 — Admin pays preferred share

1. [ ] Still in the **Shares** section, click **Collect Share** again
2. [ ] Select **Preferred** tab — it should now be **enabled** (not greyed out)
3. [ ] Enter an amount (minimum $500) — e.g. `500`
4. [ ] Select payment method
5. [ ] Submit

**Expected result:**
- [ ] Preferred share appears in **Payment History** with status **Succeeded**
- [ ] Preferred share total on the Shares card updates (e.g. `$500.00`)
- [ ] APR bracket is displayed correctly based on amount

---

## Step 6 — Admin pays policy premium

1. [ ] Navigate to the **Policies** section on the member detail page
2. [ ] Click **Pay Premium** (or **Record Payment**) on the policy
3. [ ] Select payment method and confirm the amount
4. [ ] Submit

**Expected result:**
- [ ] Payment appears in **Payment History** with status **Succeeded**
- [ ] Policy **next due date** advances by one month
- [ ] Policy **last paid date** and **last paid amount** are updated

---

## Step 7 — Verify self-service portal reflects all payments

1. [ ] Log in to the member self-service portal (`http://localhost:5501`) using the member's credentials
2. [ ] On the **Dashboard**, confirm:
   - [ ] Member status badge shows **Active**
   - [ ] No pending membership banner is shown
   - [ ] Payment notification (if not yet dismissed) shows the correct USD amount
3. [ ] Navigate to **Services → Buy Shares**:
   - [ ] **Membership** tab is enabled
   - [ ] **Preferred** tab is enabled (member already has a membership share)
   - [ ] Membership total shows `$50.00`
   - [ ] Preferred total shows `$500.00`
4. [ ] Navigate to **Policies** tab:
   - [ ] Policy appears with status **Active**
   - [ ] **Next due date** matches the month after the premium was paid
5. [ ] Navigate to **Payment History** (on member detail or dashboard):
   - [ ] All 3 payments are listed: membership share, preferred share, policy premium
   - [ ] Amounts display as **US$** (not HTG)

---

## Pass / Fail

| Step | Result | Notes |
|------|--------|-------|
| 1 — Member created | ☐ Pass ☐ Fail | |
| 2 — Password email sent | ☐ Pass ☐ Fail | |
| 3 — Policy created | ☐ Pass ☐ Fail | |
| 4 — Membership share paid, status active | ☐ Pass ☐ Fail | |
| 5 — Preferred share paid | ☐ Pass ☐ Fail | |
| 6 — Policy premium paid | ☐ Pass ☐ Fail | |
| 7 — Self-service portal reflects all payments | ☐ Pass ☐ Fail | |
