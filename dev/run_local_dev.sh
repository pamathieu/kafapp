#!/usr/bin/env bash
# run_local_dev.sh — local dev environment for testing KAFA Stripe payments.
#
# Builds and serves the admin + member Flutter web portals locally, starts
# the local backend (dev/local_server.py) against the kopera-*-dev DynamoDB
# tables, and forwards Stripe sandbox webhooks via the Stripe CLI.
#
# Usage:  dev/run_local_dev.sh
# Stop:   Ctrl+C (cleans up all background processes)

set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -f .env.local ]]; then
  echo "Missing .env.local — copy dev/.env.local.example or create one with STRIPE_SECRET_KEY / STRIPE_PUBLISHABLE_KEY set." >&2
  exit 1
fi

set -a
source .env.local
set +a

PORT="${LOCAL_SERVER_PORT:-8000}"
ADMIN_PORT="${ADMIN_PORT:-5500}"
MEMBER_PORT="${MEMBER_PORT:-5501}"

PIDS=()
cleanup() {
  echo
  echo "Shutting down local dev environment..."
  for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM

# ── 1. Stripe CLI — forward sandbox webhooks to the local backend ─────────────
# Two separate listeners: premium payments and share purchases are different
# webhook endpoints, each needs its own forwarding session/signing secret.
echo "Starting stripe listen (payments)..."
dev/bin/stripe listen --api-key "$STRIPE_SECRET_KEY" \
  --forward-to "localhost:$PORT/payments/webhook" \
  > /tmp/kafa_stripe_listen.log 2>&1 &
PIDS+=($!)

echo "Starting stripe listen (shares)..."
dev/bin/stripe listen --api-key "$STRIPE_SECRET_KEY" \
  --forward-to "localhost:$PORT/member/shares/webhook" \
  > /tmp/kafa_stripe_listen_shares.log 2>&1 &
PIDS+=($!)

_read_webhook_secret() {
  local logfile="$1" secret=""
  for _ in $(seq 1 20); do
    secret=$(grep -o 'whsec_[a-zA-Z0-9]*' "$logfile" | head -1 || true)
    [[ -n "$secret" ]] && break
    sleep 0.5
  done
  echo "$secret"
}

WEBHOOK_SECRET=$(_read_webhook_secret /tmp/kafa_stripe_listen.log)
SHARE_WEBHOOK_SECRET=$(_read_webhook_secret /tmp/kafa_stripe_listen_shares.log)
if [[ -z "$WEBHOOK_SECRET" || -z "$SHARE_WEBHOOK_SECRET" ]]; then
  echo "Could not read webhook secret(s) from stripe listen — see /tmp/kafa_stripe_listen*.log" >&2
  exit 1
fi
export STRIPE_WEBHOOK_SECRET="$WEBHOOK_SECRET"
export SHARE_WEBHOOK_SECRET="$SHARE_WEBHOOK_SECRET"
echo "Webhook secrets: payments=$WEBHOOK_SECRET shares=$SHARE_WEBHOOK_SECRET"

# ── 2. Local backend ────────────────────────────────────────────────────────
echo "Starting local backend on :$PORT..."
dev/venv/bin/python3 dev/local_server.py > /tmp/kafa_local_server.log 2>&1 &
PIDS+=($!)
sleep 1

# ── 3. Build + serve the admin and member Flutter web portals ────────────────
echo "Building admin portal..."
flutter build web --dart-define=PORTAL=admin \
  --dart-define=API_ENV_SUFFIX=-dev \
  --dart-define=STRIPE_KEY="$STRIPE_PUBLISHABLE_KEY" \
  --dart-define=API_BASE_URL="http://localhost:$PORT" \
  --dart-define=MEMBER_PORTAL_URL="${MEMBER_PORTAL_URL:-https://devmember.kafayiti.com}" \
  > /tmp/kafa_build_admin.log 2>&1
rm -rf build/web-admin-local && mv build/web build/web-admin-local

echo "Building member portal..."
flutter build web --dart-define=PORTAL=member \
  --dart-define=API_ENV_SUFFIX=-dev \
  --dart-define=STRIPE_KEY="$STRIPE_PUBLISHABLE_KEY" \
  --dart-define=API_BASE_URL="http://localhost:$PORT" \
  > /tmp/kafa_build_member.log 2>&1
rm -rf build/web-member-local && mv build/web build/web-member-local

(cd build/web-admin-local && python3 -m http.server "$ADMIN_PORT" > /tmp/kafa_admin_http.log 2>&1) &
PIDS+=($!)
(cd build/web-member-local && python3 -m http.server "$MEMBER_PORT" > /tmp/kafa_member_http.log 2>&1) &
PIDS+=($!)

cat <<EOF

KAFA local dev environment is up:
  Admin portal:   http://localhost:$ADMIN_PORT   (login: admin / kafa2026)
  Member portal:  http://localhost:$MEMBER_PORT  (log in with a real member's email/phone + password)
  Backend API:    http://localhost:$PORT
  Stripe webhook: forwarding to /payments/webhook (logs: /tmp/kafa_stripe_listen.log)

Test card: 4242 4242 4242 4242, any future expiry, any CVC.
Data uses kopera-member-dev / kopera-life-insurance-dev, matching the
devadmin/devmember subdomains. API paths use the -dev suffix (API_ENV_SUFFIX=-dev)
so local and deployed dev environments are identical. Only the Stripe key is
sandboxed — test payments are written to the dev tables, same as the deployed dev Lambdas.

Press Ctrl+C to stop everything.
EOF

wait
