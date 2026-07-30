# TC-002 — Prospect Applies, Admin Converts, Member Self-Pays

**Portals involved:** Public application form · Admin (`:5500`) · Member self-service (`:5501`)  
**Environment:** Local dev (`dev/run_local_dev.sh`) or staging  
**Stripe test card:** `4242 4242 4242 4242` · any future expiry · any CVC  

---

## Prerequisites

- [ ] Local dev environment is running (backend `:8000`, admin `:5500`, member `:5501`, Stripe CLI forwarding both webhook endpoints)
- [ ] At least one insurance plan exists (e.g. Basic, Standard)
- [ ] `kontak@kafayiti.com` notification email is configured and reachable for testing
- [ ] You have admin credentials (`admin` / `kafa2026` for local dev)

---

## Step 1 — Prospect selects a plan before filling out the application

1. [ ] Open the public application / landing page
2. [ ] **Select a plan** (e.g. Standard) before filling in any personal details
3. [ ] Fill in the prospect application form:
   - **Full name** — e.g. `Marie Claire Prospect`
   - **Phone number** — e.g. `5090000002`
   - **Email** — e.g. `tc002.prospect@example.com`
   - Any other required fields
4. [ ] Submit the form

**Expected result:**
- [ ] Prospect is created successfully (confirmation shown on screen or redirect)
- [ ] `kontak@kafayiti.com` receives a notification email about the new prospect

---

## Step 2 — Admin reviews prospect and confirms plan is visible

1. [ ] Log in to the admin portal (`http://localhost:5500`)
2. [ ] Navigate to **Prospects**
3. [ ] Find the newly created prospect (`Marie Claire Prospect` or filter by email/phone)
4. [ ] Open the prospect detail

**Expected result:**
- [ ] Prospect details are displayed correctly (name, phone, email)
- [ ] The **plan selected by the prospect** (Standard) is visible on the prospect detail page

---

## Step 3 — Admin converts prospect to member

1. [ ] On the prospect detail page, click **Convert to Member** (or equivalent action)
2. [ ] Confirm the conversion in any dialog

**Expected result:**
- [ ] Prospect is removed from the Prospects list (or marked as converted)
- [ ] A new member record is created for `Marie Claire Prospect`
- [ ] Member's status is **Inactive / Pending** with reason **"Did not pay membership share"**
- [ ] Member receives a **confirmation email** containing a **password creation link**

---

## Step 4 — Member creates their password

1. [ ] Check the email inbox for `tc002.prospect@example.com`
2. [ ] Open the confirmation email and click the **password creation link**
3. [ ] Set a password (e.g. `TestPass2025!`)
4. [ ] Confirm password is accepted and redirects to the member portal login

**Expected result:**
- [ ] Password is created successfully
- [ ] Member can log in to the self-service portal at `http://localhost:5501`

---

## Step 5 — Member logs in and sees pending state

1. [ ] Log in to the member self-service portal (`http://localhost:5501`) as `Marie Claire Prospect`
2. [ ] View the **Dashboard**

**Expected result:**
- [ ] Member status badge shows **Inactive** (or **Pending**)
- [ ] A pending membership banner appears: *"If you want your status to remain active, pay the membership share"* (or equivalent translated text)
- [ ] The **Preferred** tab in Buy Shares is disabled / greyed out

---

## Step 6 — Member pays membership share (first — always required first)

1. [ ] On the dashboard, either:
   - Click the **pending membership banner** → "Pay Share", or
   - Go to **Quick Actions → Buy Shares** or **Services → Buy Shares**
2. [ ] The **Membership** tab is selected by default
3. [ ] Enter amount: `50` (minimum $50, multiples of $50)
4. [ ] Enter Stripe test card: `4242 4242 4242 4242` · `12/34` · `123`
5. [ ] Submit

**Expected result:**
- [ ] Success screen appears ("Share Purchased" or equivalent)
- [ ] After returning to the dashboard:
  - [ ] Pending membership banner is **gone**
  - [ ] Member status shows **Active**
  - [ ] Membership share total reflects `$50.00`
  - [ ] **Preferred** tab in Buy Shares is now **enabled**

---

## Step 7 — Member pays preferred share

1. [ ] Navigate to **Quick Actions → Buy Shares** or **Services → Buy Shares**
2. [ ] Select the **Preferred** tab (should now be enabled)
3. [ ] Enter amount: `500` (minimum $500)
4. [ ] Enter Stripe test card: `4242 4242 4242 4242` · `12/34` · `123`
5. [ ] Submit

**Expected result:**
- [ ] Success screen appears
- [ ] After returning to the dashboard:
  - [ ] Preferred share total reflects `$500.00`
  - [ ] APR is displayed (e.g. `4.00%` for $500)

---

## Step 8 — Member pays policy premium

1. [ ] Navigate to the **Policies** tab (or **Pay Now** button on dashboard)
2. [ ] If member has multiple policies, a policy picker appears — select the correct one
3. [ ] Confirm the premium amount
4. [ ] Enter Stripe test card: `4242 4242 4242 4242` · `12/34` · `123`
5. [ ] Submit

**Expected result:**
- [ ] Payment success screen appears
- [ ] After returning to the dashboard:
  - [ ] Policy **next due date** advances by one month
  - [ ] Payment notification displays the correct **US$** amount (not HTG)

---

## Step 9 — Verify all 3 payments in Payment History

1. [ ] Navigate to the **Payment History** section in the member portal
2. [ ] Confirm all 3 payments are listed:
   - [ ] **Membership Share** — status Succeeded/Pending, amount US$50.00
   - [ ] **Preferred Share** — status Succeeded/Pending, amount US$500.00
   - [ ] **Policy Premium** — status Succeeded, amount in US$
3. [ ] Amounts all display as **US$** (not HTG)

---

## Step 10 — Verify from admin side

1. [ ] Log in to the admin portal (`http://localhost:5500`)
2. [ ] Open the member record for `Marie Claire Prospect`
3. [ ] Confirm:
   - [ ] Member status is **Active**
   - [ ] **Shares** card shows membership `$50.00` and preferred `$500.00`
   - [ ] **Payment History** card lists all 3 payments
   - [ ] Policy **next due date** is one month after the premium payment

---

## Pass / Fail

| Step | Result | Notes |
|------|--------|-------|
| 1 — Prospect applies with plan selected | ☐ Pass ☐ Fail | |
| 2 — Admin sees plan on prospect detail | ☐ Pass ☐ Fail | |
| 3 — Admin converts prospect → member, email sent | ☐ Pass ☐ Fail | |
| 4 — Member creates password via email link | ☐ Pass ☐ Fail | |
| 5 — Member sees pending state on login | ☐ Pass ☐ Fail | |
| 6 — Membership share paid, status → active | ☐ Pass ☐ Fail | |
| 7 — Preferred share paid | ☐ Pass ☐ Fail | |
| 8 — Policy premium paid, due date advances | ☐ Pass ☐ Fail | |
| 9 — Payment History shows all 3 payments in USD | ☐ Pass ☐ Fail | |
| 10 — Admin portal reflects all changes | ☐ Pass ☐ Fail | |
