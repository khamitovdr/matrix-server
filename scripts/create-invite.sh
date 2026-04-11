#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/synapse-admin.sh"

USES="${1:-1}"
EXPIRES="${2:-24h}"

# ── Parse expiry duration to seconds ────���────────────────────────────────────

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

# ── Create registration token ��─────────────────────��─────────────────────────

TOKEN_RESPONSE=$(synapse_admin_api POST "/_synapse/admin/v1/registration_tokens/new" \
    "{\"uses_allowed\": ${USES}, \"expiry_time\": ${EXPIRY_MS}}")

TOKEN=$(echo "$TOKEN_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])" 2>/dev/null || echo "")

if [[ -z "$TOKEN" ]]; then
    echo "ERROR: Failed to create registration token" >&2
    echo "$TOKEN_RESPONSE" >&2
    exit 1
fi

# ── Output invite link ──────────────────────���────────────────────────────────

REGISTER_URL="https://${SUBDOMAIN_ELEMENT}.${DOMAIN}/#/register"

echo ""
echo "Invite created!"
echo ""
echo "  Link:    ${REGISTER_URL}"
echo "  Token:   ${TOKEN}"
echo "  Uses:    ${USES}"
echo "  Expires: ${EXPIRES}"
echo ""
echo "Send the link and token to the person you want to invite."
echo "They open the link, pick a username and password, and paste the token when asked."
