#!/usr/bin/env bash
# Shared helper for Synapse admin API operations.
# Source this file — do not execute directly.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${PROJECT_DIR}/.env"
COMPOSE_FILE="${PROJECT_DIR}/docker-compose.yml"

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

# Cached token
_ADMIN_TOKEN=""

# Get an admin access token. Creates the admin account on first call.
get_admin_token() {
    if [[ -n "$_ADMIN_TOKEN" ]]; then
        echo "$_ADMIN_TOKEN"
        return
    fi
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
        _ADMIN_TOKEN="$token"
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

    _ADMIN_TOKEN="$token"
    echo "$token"
}

# Call a Synapse admin API endpoint.
# Usage: synapse_admin_api GET /path
#        synapse_admin_api POST /path '{"json":"body"}'
synapse_admin_api() {
    local method="$1"
    local path="$2"
    local body="${3:-}"
    local token
    token=$(get_admin_token)

    if [[ -n "$body" ]]; then
        $SYNAPSE_CMD curl -s -X "$method" "${SYNAPSE_URL}${path}" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            -d "$body"
    else
        $SYNAPSE_CMD curl -s -X "$method" "${SYNAPSE_URL}${path}" \
            -H "Authorization: Bearer ${token}"
    fi
}
