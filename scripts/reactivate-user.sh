#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/synapse-admin.sh"

USERNAME="${1:-}"
PASSWORD="${2:-}"

if [[ -z "$USERNAME" ]]; then
    echo "Usage: reactivate-user.sh <username> [password]" >&2
    exit 1
fi

if [[ -z "$PASSWORD" ]]; then
    PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 20)
    echo "Generated password: ${PASSWORD}"
fi

USER_ID="@${USERNAME}:${DOMAIN}"

echo "Reactivating user ${USER_ID}..."
RESULT=$(synapse_admin_api PUT "/_synapse/admin/v2/users/${USER_ID}" \
    "{\"deactivated\": false, \"password\": \"${PASSWORD}\"}")

DEACTIVATED=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('deactivated', True))" 2>/dev/null || echo "True")

if [[ "$DEACTIVATED" == "False" ]]; then
    echo "User ${USER_ID} has been reactivated."
else
    echo "ERROR: Failed to reactivate user" >&2
    echo "$RESULT" >&2
    exit 1
fi
