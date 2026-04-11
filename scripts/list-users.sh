#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/synapse-admin.sh"

RESPONSE=$(synapse_admin_api GET "/_synapse/admin/v2/users?guests=false&limit=100")

python3 -c "
import sys, json
from datetime import datetime

data = json.load(sys.stdin)
users = data.get('users', [])

# Filter out system accounts
users = [u for u in users if not u['name'].startswith('@invite-admin:')]

if not users:
    print('No users found.')
    sys.exit(0)

print(f'{'Username':<30} {'Admin':<7} {'Active':<8} {'Created':<12} {'Last seen':<12}')
print('-' * 69)

for u in users:
    name = u['name'].split(':')[0].lstrip('@')
    admin = 'yes' if u.get('admin', False) else 'no'
    active = 'yes' if not u.get('deactivated', False) else 'no'

    ts = u.get('creation_ts', 0)
    created = datetime.fromtimestamp(ts).strftime('%Y-%m-%d') if ts else 'unknown'

    last = u.get('last_seen_ts')
    last_seen = datetime.fromtimestamp(last / 1000).strftime('%Y-%m-%d') if last else 'never'

    print(f'{name:<30} {admin:<7} {active:<8} {created:<12} {last_seen:<12}')

print(f'\nTotal: {len(users)} user(s)')
" <<< "$RESPONSE"
