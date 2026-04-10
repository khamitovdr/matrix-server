#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${PROJECT_DIR}/.env"

USERNAME="${1:-}"
PASSWORD="${2:-}"

if [[ -z "$USERNAME" ]]; then
    echo "Usage: create-user.sh <username> [password]" >&2
    exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: .env not found. Run generate-env.sh first." >&2
    exit 1
fi

# shellcheck disable=SC1090,SC1091
source "$ENV_FILE"

SYNAPSE_URL="http://localhost:8008"
# Resolve Synapse container's port via Docker
SYNAPSE_URL="http://$(docker compose -f "${PROJECT_DIR}/docker-compose.yml" port synapse 8008 2>/dev/null || echo "localhost:8008")"

# Generate password if not provided
if [[ -z "$PASSWORD" ]]; then
    PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 20)
    echo "Generated password: ${PASSWORD}"
fi

# Step 1: Get a nonce
NONCE_RESPONSE=$(curl -s "${SYNAPSE_URL}/_synapse/admin/v1/register")
NONCE=$(echo "$NONCE_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['nonce'])")

# Step 2: Compute HMAC
# HMAC = HMAC-SHA1(shared_secret, nonce + "\x00" + username + "\x00" + password + "\x00" + "notadmin")
MAC=$(printf '%s\0%s\0%s\0%s' "$NONCE" "$USERNAME" "$PASSWORD" "notadmin" \
    | openssl dgst -sha1 -hmac "$SYNAPSE_REGISTRATION_SHARED_SECRET" \
    | awk '{print $NF}')

# Step 3: Register
REGISTER_RESPONSE=$(curl -s -X POST "${SYNAPSE_URL}/_synapse/admin/v1/register" \
    -H "Content-Type: application/json" \
    -d "{
        \"nonce\": \"${NONCE}\",
        \"username\": \"${USERNAME}\",
        \"password\": \"${PASSWORD}\",
        \"mac\": \"${MAC}\",
        \"admin\": false
    }")

# Check result
if echo "$REGISTER_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('user_id',''))" 2>/dev/null | grep -q "@"; then
    USER_ID=$(echo "$REGISTER_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['user_id'])")
    echo "Successfully created user: ${USER_ID}"
else
    echo "ERROR: Failed to create user" >&2
    echo "$REGISTER_RESPONSE" >&2
    exit 1
fi
