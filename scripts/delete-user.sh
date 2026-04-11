#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/synapse-admin.sh"

USERNAME="${1:-}"

if [[ -z "$USERNAME" ]]; then
    echo "Usage: delete-user.sh <username>" >&2
    exit 1
fi

USER_ID="@${USERNAME}:${DOMAIN}"

# Verify user exists
USER_RESPONSE=$(synapse_admin_api GET "/_synapse/admin/v2/users/${USER_ID}")
EXISTS=$(echo "$USER_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print('yes' if d.get('name') else 'no')" 2>/dev/null || echo "no")

if [[ "$EXISTS" != "yes" ]]; then
    echo "ERROR: User ${USER_ID} not found" >&2
    exit 1
fi

# Deactivate and erase
echo "Deactivating user ${USER_ID}..."
RESULT=$(synapse_admin_api POST "/_synapse/admin/v1/deactivate/${USER_ID}" '{"erase": true}')

SUCCESS=$(echo "$RESULT" | python3 -c "import sys,json; print('yes' if json.load(sys.stdin).get('id_server_unbind_result') == 'success' else 'no')" 2>/dev/null || echo "no")

if [[ "$SUCCESS" == "yes" ]]; then
    echo "User ${USER_ID} has been deactivated and erased."
    echo ""
    echo "Note: Synapse reserves deactivated usernames. To reactivate this user later:"
    echo "  ./deploy.sh --reactivate-user ${USERNAME} --password 'NewPassword'"
else
    echo "WARNING: Deactivation returned unexpected response:" >&2
    echo "$RESULT" >&2
fi
