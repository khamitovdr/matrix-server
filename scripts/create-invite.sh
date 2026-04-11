#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${PROJECT_DIR}/.env"
COMPOSE_FILE="${PROJECT_DIR}/docker-compose.yml"

USES="${1:-1}"
EXPIRES="${2:-24h}"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: .env not found" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

SYNAPSE_CMD="docker compose -f ${COMPOSE_FILE} exec -T synapse"
SYNAPSE_URL="http://localhost:8008"
ADMIN_USER="invite-admin"
ADMIN_PASSWORD="$(echo "${SYNAPSE_REGISTRATION_SHARED_SECRET}" | openssl dgst -sha256 | awk '{print $NF}')"

# ── Parse expiry duration to seconds ─────────────────────────────────────────

parse_expiry() {
    local duration="$1"
    local number="${duration%[hd]*}"
    local unit="${duration##*[0-9]}"

    if [[ -z "$number" || -z "$unit" ]]; then
        echo "ERROR: Invalid duration format '${duration}'. Use Nh (hours) or Nd (days)." >&2
        exit 1
    fi

    case "$unit" in
        h) echo $((number * 3600)) ;;
        d) echo $((number * 86400)) ;;
        *) echo "ERROR: Unknown unit '${unit}'. Use h (hours) or d (days)." >&2; exit 1 ;;
    esac
}

EXPIRY_SECONDS=$(parse_expiry "$EXPIRES")
EXPIRY_MS=$(( ($(date +%s) + EXPIRY_SECONDS) * 1000 ))

# ── Ensure admin account exists ──────────────────────────────────────────────

ensure_admin() {
    # Try to log in first
    local login_response
    login_response=$($SYNAPSE_CMD curl -s -X POST "${SYNAPSE_URL}/_matrix/client/v3/login" \
        -H "Content-Type: application/json" \
        -d "{
            \"type\": \"m.login.password\",
            \"identifier\": {\"type\": \"m.id.user\", \"user\": \"${ADMIN_USER}\"},
            \"password\": \"${ADMIN_PASSWORD}\"
        }")

    local token
    token=$(echo "$login_response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || echo "")

    if [[ -n "$token" ]]; then
        echo "$token"
        return
    fi

    # Admin doesn't exist yet — create it
    echo "Creating system admin account..." >&2

    local nonce_response
    nonce_response=$($SYNAPSE_CMD curl -s "${SYNAPSE_URL}/_synapse/admin/v1/register")
    local nonce
    nonce=$(echo "$nonce_response" | python3 -c "import sys,json; print(json.load(sys.stdin)['nonce'])")

    local mac
    mac=$(printf '%s\0%s\0%s\0%s' "$nonce" "$ADMIN_USER" "$ADMIN_PASSWORD" "admin" \
        | openssl dgst -sha1 -hmac "$SYNAPSE_REGISTRATION_SHARED_SECRET" \
        | awk '{print $NF}')

    local register_response
    register_response=$($SYNAPSE_CMD curl -s -X POST "${SYNAPSE_URL}/_synapse/admin/v1/register" \
        -H "Content-Type: application/json" \
        -d "{
            \"nonce\": \"${nonce}\",
            \"username\": \"${ADMIN_USER}\",
            \"password\": \"${ADMIN_PASSWORD}\",
            \"mac\": \"${mac}\",
            \"admin\": true
        }")

    token=$(echo "$register_response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || echo "")

    if [[ -z "$token" ]]; then
        echo "ERROR: Failed to create admin account" >&2
        echo "$register_response" >&2
        exit 1
    fi

    echo "$token"
}

# ── Create registration token ────────────────────────────────────────────────

ACCESS_TOKEN=$(ensure_admin)

TOKEN_RESPONSE=$($SYNAPSE_CMD curl -s -X POST \
    "${SYNAPSE_URL}/_synapse/admin/v1/registration_tokens/new" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"uses_allowed\": ${USES}, \"expiry_time\": ${EXPIRY_MS}}")

TOKEN=$(echo "$TOKEN_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])" 2>/dev/null || echo "")

if [[ -z "$TOKEN" ]]; then
    echo "ERROR: Failed to create registration token" >&2
    echo "$TOKEN_RESPONSE" >&2
    exit 1
fi

# ── Output invite link ───────────────────────────────────────────────────────

INVITE_URL="https://${SUBDOMAIN_ELEMENT}.${DOMAIN}/#/register?registrationToken=${TOKEN}"

echo ""
echo "Invite link created!"
echo ""
echo "  URL:     ${INVITE_URL}"
echo "  Uses:    ${USES}"
echo "  Expires: ${EXPIRES}"
echo ""
echo "Send this link to the person you want to invite."
