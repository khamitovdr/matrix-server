# Invite Mechanism Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow admins to generate invite links so new users can self-register with their own passwords, using Synapse's native registration token API.

**Architecture:** Enable token-gated registration in Synapse. New `create-invite.sh` script creates a system admin account (once), uses it to call the registration tokens API, and outputs an Element Web invite link. `deploy.sh` gets `--invite` flag with `--uses` and `--expires` options.

**Tech Stack:** Bash, Synapse Admin API, curl, Docker Compose exec

---

## File Map

| File | Change | Responsibility |
|---|---|---|
| `configs/synapse/homeserver.yaml.template` | Modify | Enable token-gated registration |
| `scripts/create-invite.sh` | Create | Generate registration tokens via Synapse admin API |
| `deploy.sh` | Modify | Add --invite, --uses, --expires flags |

---

### Task 1: Enable Token-Gated Registration in Synapse

**Files:**
- Modify: `configs/synapse/homeserver.yaml.template:42`

- [ ] **Step 1: Update Synapse config template**

In `configs/synapse/homeserver.yaml.template`, replace line 42:

```yaml
enable_registration: false
```

with:

```yaml
enable_registration: true
registration_requires_token: true
```

- [ ] **Step 2: Verify template is valid YAML**

```bash
export DOMAIN=test SUBDOMAIN_MATRIX=m SUBDOMAIN_TURN=t POSTGRES_PASSWORD=x \
       SYNAPSE_REGISTRATION_SHARED_SECRET=x SYNAPSE_MACAROON_SECRET_KEY=x \
       SYNAPSE_FORM_SECRET=x COTURN_AUTH_SECRET=x MAX_UPLOAD_SIZE_MB=100 \
       S3_MEDIA_BUCKET=b S3_MEDIA_ENDPOINT=https://s3 S3_MEDIA_ACCESS_KEY=k S3_MEDIA_SECRET_KEY=s
ENV_VARS='$DOMAIN $SUBDOMAIN_MATRIX $SUBDOMAIN_TURN $POSTGRES_PASSWORD $SYNAPSE_REGISTRATION_SHARED_SECRET $SYNAPSE_MACAROON_SECRET_KEY $SYNAPSE_FORM_SECRET $COTURN_AUTH_SECRET $MAX_UPLOAD_SIZE_MB $S3_MEDIA_BUCKET $S3_MEDIA_ENDPOINT $S3_MEDIA_ACCESS_KEY $S3_MEDIA_SECRET_KEY'
envsubst "$ENV_VARS" < configs/synapse/homeserver.yaml.template | python3 -c "import sys,yaml; yaml.safe_load(sys.stdin); print('VALID')"
```

Expected: `VALID`

- [ ] **Step 3: Commit**

```bash
git add configs/synapse/homeserver.yaml.template
git commit -m "feat: enable token-gated registration in Synapse"
```

---

### Task 2: Create Invite Script

**Files:**
- Create: `scripts/create-invite.sh`

- [ ] **Step 1: Create scripts/create-invite.sh**

```bash
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
ADMIN_USER="_invite_admin"
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
```

- [ ] **Step 2: Make executable and shellcheck**

```bash
chmod +x scripts/create-invite.sh
shellcheck scripts/create-invite.sh
```

Expected: no errors (SC1090 suppressed).

- [ ] **Step 3: Commit**

```bash
git add scripts/create-invite.sh
git commit -m "feat: add invite link generation script"
```

---

### Task 3: Add --invite Flag to deploy.sh

**Files:**
- Modify: `deploy.sh`

- [ ] **Step 1: Add do_invite function**

After the `do_restore()` function (around line 182), add:

```bash
do_invite() {
    local uses="$1"
    local expires="$2"
    echo "Generating invite link..."
    ssh_cmd "bash ${DEPLOY_DIR}/scripts/create-invite.sh '${uses}' '${expires}'"
}
```

- [ ] **Step 2: Add action variables and argument parsing**

In the action variables block (around line 192), add:

```bash
ACTION_INVITE=false
ACTION_USES="1"
ACTION_EXPIRES="24h"
```

In the `while` case statement, add these cases before `--help)`:

```bash
        --invite)       ACTION_INVITE=true; shift ;;
        --uses)         ACTION_USES="$2"; shift 2 ;;
        --expires)      ACTION_EXPIRES="$2"; shift 2 ;;
```

- [ ] **Step 3: Add invite execution**

After the restore execution block (around line 240), add:

```bash
if $ACTION_INVITE; then
    do_invite "$ACTION_USES" "$ACTION_EXPIRES"
fi
```

- [ ] **Step 4: Update usage text**

In the `usage()` function, add these lines to the Options section:

```
  --invite              Generate an invite link for user self-registration
  --uses N              Number of registrations allowed (default: 1)
  --expires DURATION    Token expiry, e.g. 24h, 7d (default: 24h)
```

And add this example:

```
  ./deploy.sh --invite                # Single-use invite, expires in 24h
  ./deploy.sh --invite --uses 5 --expires 48h  # 5 uses, expires in 48h
```

- [ ] **Step 5: Verify shellcheck and help**

```bash
shellcheck deploy.sh
./deploy.sh --help
```

Expected: shellcheck clean, help text shows new --invite options.

- [ ] **Step 6: Commit**

```bash
git add deploy.sh
git commit -m "feat: add --invite flag to deploy.sh"
```

---

### Task 4: Update README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add invite commands to the Commands section**

In the Commands section of `README.md`, add after the `--create-user` lines:

```bash
./deploy.sh --invite                           # Generate single-use invite link (24h expiry)
./deploy.sh --invite --uses 5 --expires 48h    # 5-use invite, expires in 48h
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add invite commands to README"
```
