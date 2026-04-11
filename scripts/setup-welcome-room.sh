#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/synapse-admin.sh"

ADMIN_USERNAME="${1:-}"

if [[ -z "$ADMIN_USERNAME" ]]; then
    echo "Usage: setup-welcome-room.sh <admin-username>" >&2
    echo "The admin user will be the only one who can post in the room." >&2
    exit 1
fi

ADMIN_USER_ID="@${ADMIN_USERNAME}:${DOMAIN}"
ROOM_ALIAS="announcements"
ROOM_ALIAS_FULL="#${ROOM_ALIAS}:${DOMAIN}"

echo "Setting up welcome/announcements room..."

# Check if room already exists
RESOLVE_RESPONSE=$(synapse_admin_api GET "/_matrix/client/v3/directory/room/%23${ROOM_ALIAS}%3A${DOMAIN}" 2>/dev/null || echo "{}")
EXISTING_ROOM_ID=$(echo "$RESOLVE_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('room_id',''))" 2>/dev/null || echo "")

if [[ -n "$EXISTING_ROOM_ID" ]]; then
    echo "Room ${ROOM_ALIAS_FULL} already exists (${EXISTING_ROOM_ID})"
    echo "Updating power levels..."
    ROOM_ID="$EXISTING_ROOM_ID"
else
    echo "Creating room ${ROOM_ALIAS_FULL}..."

    # Create room as admin user. Use the admin API to create it.
    CREATE_RESPONSE=$(synapse_admin_api POST "/_matrix/client/v3/createRoom" "{
        \"room_alias_name\": \"${ROOM_ALIAS}\",
        \"name\": \"Announcements\",
        \"topic\": \"Important announcements from the server admin\",
        \"preset\": \"public_chat\",
        \"visibility\": \"public\",
        \"initial_state\": [
            {
                \"type\": \"m.room.guest_access\",
                \"content\": {\"guest_access\": \"forbidden\"}
            }
        ]
    }")

    ROOM_ID=$(echo "$CREATE_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('room_id',''))" 2>/dev/null || echo "")

    if [[ -z "$ROOM_ID" ]]; then
        echo "ERROR: Failed to create room" >&2
        echo "$CREATE_RESPONSE" >&2
        exit 1
    fi

    echo "Room created: ${ROOM_ID}"
fi

# Make sure the actual admin user is in the room
echo "Ensuring ${ADMIN_USER_ID} is in the room..."
synapse_admin_api POST "/_synapse/admin/v1/join/${ROOM_ID}" \
    "{\"user_id\": \"${ADMIN_USER_ID}\"}" > /dev/null 2>&1 || true

# Set power levels: admin user = 100, everyone else can't send messages
echo "Setting power levels (only ${ADMIN_USERNAME} can post)..."
synapse_admin_api PUT "/_matrix/client/v3/rooms/${ROOM_ID}/state/m.room.power_levels" "{
    \"ban\": 100,
    \"events_default\": 100,
    \"invite\": 100,
    \"kick\": 100,
    \"redact\": 100,
    \"state_default\": 100,
    \"users_default\": 0,
    \"events\": {
        \"m.room.name\": 100,
        \"m.room.power_levels\": 100,
        \"m.room.history_visibility\": 100,
        \"m.room.canonical_alias\": 100,
        \"m.room.avatar\": 100,
        \"m.room.tombstone\": 100,
        \"m.room.encryption\": 100,
        \"m.room.topic\": 100
    },
    \"users\": {
        \"${ADMIN_USER_ID}\": 100,
        \"@invite-admin:${DOMAIN}\": 100
    }
}" > /dev/null

# Set room history visibility so new members can see past messages
echo "Setting history visibility..."
synapse_admin_api PUT "/_matrix/client/v3/rooms/${ROOM_ID}/state/m.room.history_visibility" \
    '{"history_visibility": "shared"}' > /dev/null

echo ""
echo "Done! Room ${ROOM_ALIAS_FULL} is ready."
echo ""
echo "  Room ID:    ${ROOM_ID}"
echo "  Admin:      ${ADMIN_USER_ID} (can post)"
echo "  Others:     Read-only (auto-joined on registration)"
echo ""
echo "New users will automatically join this room when they register."
