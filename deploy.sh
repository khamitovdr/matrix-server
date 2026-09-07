#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.yaml"

# ── Helpers ──────────────────────────────────────────────────────────────────

usage() {
    cat <<USAGE
Usage: ./deploy.sh [OPTIONS]

Options:
  --provision           First-time VPS setup (Docker, firewall, tools)
  --deploy              Deploy or update the stack
  --create-user NAME    Create a Matrix user
  --password PASS       Password for --create-user (auto-generated if omitted)
  --backup-now          Trigger an immediate database backup
  --restore [TIMESTAMP] Restore database (lists backups if no timestamp given)
  --invite              Generate an invite link for user self-registration
  --uses N              Number of registrations allowed (default: 1)
  --expires DURATION    Token expiry, e.g. 24h, 7d (default: 24h)
  --list-users          List all users with metadata
  --delete-user NAME    Deactivate and erase a user
  --reactivate-user NAME  Reactivate a deactivated user
  --setup-welcome-room NAME  Create read-only announcements room (NAME = admin who can post)
  --logs [SERVICE]      Show logs (all services, or: synapse, caddy, postgres, element, livekit, coturn, chisel)
  --tunnel-secret       Print the Navidrome tunnel credential for the music repo
  --ssh-secret          Print the homeserver SSH tunnel credentials and ssh_config block
  --help                Show this help

Examples:
  ./deploy.sh --provision --deploy    # First-time full setup
  ./deploy.sh --deploy                # Update config and restart
  ./deploy.sh --create-user alice     # Create user with auto-generated password
  ./deploy.sh --backup-now            # Immediate backup
  ./deploy.sh --invite                # Single-use invite, expires in 24h
  ./deploy.sh --invite --uses 5 --expires 48h  # 5 uses, expires in 48h
  ./deploy.sh --list-users            # Show all users
  ./deploy.sh --delete-user alice     # Remove a user
  ./deploy.sh --reactivate-user alice # Reactivate a deleted user
  ./deploy.sh --logs                  # All service logs
  ./deploy.sh --logs synapse          # Synapse logs only
USAGE
    exit 0
}

die() { echo "ERROR: $*" >&2; exit 1; }

check_config() {
    [[ -f "$CONFIG_FILE" ]] || die "config.yaml not found. Copy config.example.yaml and fill in your values."

    if ! command -v yq &> /dev/null; then
        die "yq is required locally to parse config.yaml. Install: brew install yq (macOS) or snap install yq (Linux)"
    fi

    # Validate required fields
    local required_fields=(
        ".domain"
        ".vps.host"
        ".vps.user"
        ".vps.deploy_dir"
        ".s3.media.bucket"
        ".s3.media.access_key"
        ".s3.media.secret_key"
        ".s3.backup.bucket"
        ".s3.backup.access_key"
        ".s3.backup.secret_key"
    )

    for field in "${required_fields[@]}"; do
        local val
        val=$(yq "$field" "$CONFIG_FILE")
        [[ "$val" != "null" && -n "$val" ]] || die "Missing required config field: $field"
    done
}

load_config() {
    VPS_HOST=$(yq '.vps.host' "$CONFIG_FILE")
    VPS_USER=$(yq '.vps.user' "$CONFIG_FILE")
    VPS_SSH_KEY=$(yq '.vps.ssh_key // ""' "$CONFIG_FILE")
    VPS_SSH_JUMP=$(yq '.vps.ssh_jump // ""' "$CONFIG_FILE")
    DEPLOY_DIR=$(yq '.vps.deploy_dir' "$CONFIG_FILE")
    DOMAIN=$(yq '.domain' "$CONFIG_FILE")
    SUBDOMAIN_MATRIX=$(yq '.subdomains.matrix' "$CONFIG_FILE")

    SSH_OPTS=(-o StrictHostKeyChecking=accept-new)
    if [[ -n "$VPS_SSH_KEY" ]]; then
        SSH_OPTS+=(-i "$VPS_SSH_KEY")
    fi
    # Optional. Some networks will not carry a connection to the VPS on :22
    # at all — the flat this is deployed from is one of them — while :443
    # goes through fine. A jump host makes deploy.sh usable from there
    # again. Empty by default: unset, everything behaves exactly as before.
    if [[ -n "$VPS_SSH_JUMP" ]]; then
        SSH_OPTS+=(-J "$VPS_SSH_JUMP")
    fi
}

ssh_cmd() {
    # shellcheck disable=SC2029
    ssh "${SSH_OPTS[@]}" "${VPS_USER}@${VPS_HOST}" "$@"
}

scp_to() {
    scp "${SSH_OPTS[@]}" -r "$1" "${VPS_USER}@${VPS_HOST}:$2"
}

# ── Commands ─────────────────────────────────────────────────────────────────

do_provision() {
    echo "=== Provisioning VPS ==="
    do_copy_files
    ssh_cmd "bash ${DEPLOY_DIR}/scripts/provision.sh"
    ssh_cmd "bash ${DEPLOY_DIR}/scripts/generate-env.sh"
    setup_cron_jobs
    echo "=== Provisioning complete ==="
}

do_copy_files() {
    echo "Copying files to VPS..."
    ssh_cmd "mkdir -p ${DEPLOY_DIR}"

    # Copy project files
    scp_to "${SCRIPT_DIR}/docker-compose.yml" "${DEPLOY_DIR}/"
    scp_to "${SCRIPT_DIR}/Dockerfile.synapse" "${DEPLOY_DIR}/"
    scp_to "${SCRIPT_DIR}/config.yaml" "${DEPLOY_DIR}/"
    ssh_cmd "chmod 600 ${DEPLOY_DIR}/config.yaml"
    scp_to "${SCRIPT_DIR}/scripts" "${DEPLOY_DIR}/"
    scp_to "${SCRIPT_DIR}/configs" "${DEPLOY_DIR}/"
}

do_deploy() {
    echo "=== Deploying stack ==="
    do_copy_files

    # Generate/update .env
    ssh_cmd "bash ${DEPLOY_DIR}/scripts/generate-env.sh"

    # Render config templates
    ssh_cmd "bash ${DEPLOY_DIR}/scripts/render-configs.sh"

    # Create data dirs with correct ownership
    ssh_cmd "mkdir -p ${DEPLOY_DIR}/data/synapse && sudo chown -R 991:991 ${DEPLOY_DIR}/data/synapse"
    ssh_cmd "mkdir -p ${DEPLOY_DIR}/data/mautrix-telegram"

    # Build images and start postgres first (needed for DB creation)
    ssh_cmd "cd ${DEPLOY_DIR} && docker compose build --quiet && docker compose up -d postgres"
    echo "Waiting for PostgreSQL..."
    ssh_cmd "cd ${DEPLOY_DIR} && for i in \$(seq 1 30); do docker compose exec -T postgres pg_isready -U synapse -q && break || sleep 1; done"

    # Create bridge database if it doesn't exist
    ssh_cmd "cd ${DEPLOY_DIR} && source .env && docker compose exec -T postgres psql -U synapse -tc \"SELECT 1 FROM pg_roles WHERE rolname='mautrix_telegram'\" | grep -q 1 || { docker compose exec -T postgres psql -U synapse -c \"CREATE USER mautrix_telegram WITH PASSWORD '\${TELEGRAM_BRIDGE_DB_PASSWORD}'\"; docker compose exec -T postgres psql -U synapse -c 'CREATE DATABASE mautrix_telegram OWNER mautrix_telegram'; }" 2>/dev/null || true

    # Start all services, reload Caddy config
    # Bridge config is mounted read-only at /config/config.yaml (can't be overwritten by migration)
    ssh_cmd "cd ${DEPLOY_DIR} && docker compose up -d && docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null || true"

    # Health check
    echo "Waiting for services to start..."
    sleep 10
    do_health_check
    echo "=== Deploy complete ==="
}

do_health_check() {
    echo "Running health checks..."

    local synapse_url="https://${SUBDOMAIN_MATRIX}.${DOMAIN}/_matrix/client/versions"
    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$synapse_url" 2>/dev/null || echo "000")

    if [[ "$status" == "200" ]]; then
        echo "Synapse is healthy (HTTP $status)"
    else
        echo "WARNING: Synapse health check returned HTTP $status"
        echo "It may still be starting up. Check logs with:"
        echo "  ssh ${VPS_USER}@${VPS_HOST} 'cd ${DEPLOY_DIR} && docker compose logs synapse'"
    fi
}

setup_cron_jobs() {
    echo "Setting up cron jobs..."

    local backup_cron
    local cleanup_cron
    backup_cron=$(yq '.backup.cron' "$CONFIG_FILE")
    cleanup_cron=$(yq '.media_cache.cleanup_cron' "$CONFIG_FILE")

    # Install cron jobs on VPS
    ssh_cmd "sudo tee /etc/cron.d/matrix-server > /dev/null << CRONEOF
# Matrix server backup
${backup_cron} root cd ${DEPLOY_DIR} && bash scripts/backup.sh >> /var/log/matrix-backup.log 2>&1
# Matrix server media cache cleanup
${cleanup_cron} root cd ${DEPLOY_DIR} && bash scripts/cleanup-media.sh >> /var/log/matrix-cleanup.log 2>&1
CRONEOF
sudo chmod 644 /etc/cron.d/matrix-server"

    echo "Cron jobs installed."
}

do_create_user() {
    local username="$1"
    local password="${2:-}"
    echo "Creating user @${username}:${DOMAIN}..."
    ssh_cmd "bash ${DEPLOY_DIR}/scripts/create-user.sh '${username}' '${password}'"
}

do_backup() {
    echo "Triggering backup..."
    ssh_cmd "cd ${DEPLOY_DIR} && bash scripts/backup.sh"
}

do_restore() {
    local timestamp="${1:-}"
    ssh_cmd "cd ${DEPLOY_DIR} && bash scripts/restore.sh '${timestamp}'"
}

sync_scripts() {
    scp_to "${SCRIPT_DIR}/scripts" "${DEPLOY_DIR}/"
}

do_invite() {
    local uses="$1"
    local expires="$2"
    sync_scripts
    echo "Generating invite link..."
    ssh_cmd "bash ${DEPLOY_DIR}/scripts/create-invite.sh '${uses}' '${expires}'"
}

do_list_users() {
    sync_scripts
    ssh_cmd "bash ${DEPLOY_DIR}/scripts/list-users.sh"
}

do_delete_user() {
    local username="$1"
    sync_scripts
    ssh_cmd "bash ${DEPLOY_DIR}/scripts/delete-user.sh '${username}'"
}

do_setup_welcome_room() {
    sync_scripts
    echo "Setting up welcome room..."
    ssh_cmd "bash ${DEPLOY_DIR}/scripts/setup-welcome-room.sh '${1}'"
}

do_logs() {
    local service="${1:-}"
    if [[ -n "$service" ]]; then
        ssh_cmd "cd ${DEPLOY_DIR} && docker compose logs --tail 100 -f '${service}'"
    else
        ssh_cmd "cd ${DEPLOY_DIR} && docker compose logs --tail 100 -f"
    fi
}

do_reactivate_user() {
    local username="$1"
    local password="${2:-}"
    sync_scripts
    ssh_cmd "bash ${DEPLOY_DIR}/scripts/reactivate-user.sh '${username}' '${password}'"
}

do_tunnel_secret() {
    local env_lines user pass subdomain_tunnel
    env_lines=$(ssh_cmd "grep -E '^CHISEL_AUTH_(USER|PASS)=' ${DEPLOY_DIR}/.env") \
        || die "no tunnel credential on the VPS yet — run ./deploy.sh --deploy first"

    user=$(printf '%s\n' "$env_lines" | sed -n 's/^CHISEL_AUTH_USER=//p')
    pass=$(printf '%s\n' "$env_lines" | sed -n 's/^CHISEL_AUTH_PASS=//p')
    [[ -n "$user" && -n "$pass" ]] \
        || die "CHISEL_AUTH_USER/CHISEL_AUTH_PASS missing from ${DEPLOY_DIR}/.env"

    subdomain_tunnel=$(yq '.subdomains.tunnel // "tunnel"' "$CONFIG_FILE")

    cat <<TUNNELEOF
Paste these two lines into the music repo's deploy/.env:

TUNNEL_URL=https://${subdomain_tunnel}.${DOMAIN}
CHISEL_AUTH=${user}:${pass}

Then run deploy/bin/deploy.sh from that repo.
TUNNELEOF
}

do_ssh_secret() {
    local env_lines t_user t_pass c_user c_pass subdomain_music
    env_lines=$(ssh_cmd "grep -E '^SSH_(TUNNEL|CLIENT)_(USER|PASS)=' ${DEPLOY_DIR}/.env") \
        || die "no ssh tunnel credential on the VPS yet — run ./deploy.sh --deploy first"

    t_user=$(printf '%s\n' "$env_lines" | sed -n 's/^SSH_TUNNEL_USER=//p')
    t_pass=$(printf '%s\n' "$env_lines" | sed -n 's/^SSH_TUNNEL_PASS=//p')
    c_user=$(printf '%s\n' "$env_lines" | sed -n 's/^SSH_CLIENT_USER=//p')
    c_pass=$(printf '%s\n' "$env_lines" | sed -n 's/^SSH_CLIENT_PASS=//p')
    [[ -n "$t_user" && -n "$t_pass" && -n "$c_user" && -n "$c_pass" ]] \
        || die "SSH_TUNNEL_*/SSH_CLIENT_* missing from ${DEPLOY_DIR}/.env"

    subdomain_music=$(yq '.subdomains.music // "music"' "$CONFIG_FILE")

    cat <<SSHEOF
Paste these three lines into the music repo's deploy/.env:

SSH_TUNNEL_AUTH=${t_user}:${t_pass}
SSH_CLIENT_AUTH=${c_user}:${c_pass}
SSH_DIAL_URL=https://${subdomain_music}.${DOMAIN}/__tunnel/ssh

Then run deploy/bin/deploy.sh from that repo, and add a block like this to
~/.ssh/config — HostKeyAlias is the homeserver's LAN address, so the
tunnelled connection is checked against the host key you already learned at
home instead of trusting a new one blind:

Host homeserver
    User <your account on the homeserver>
    HostKeyAlias <the homeserver's LAN address>
    ProxyCommand <path to the music repo>/deploy/bin/ssh-tunnel.sh
    ServerAliveInterval 30

SSH_TUNNEL_AUTH belongs to the homeserver's container. SSH_CLIENT_AUTH is
the one that travels — copying it to a laptop is copying a key to the flat.
SSHEOF
}

# ── Main ─────────────────────────────────────────────────────────────────────

ACTION_PROVISION=false
ACTION_DEPLOY=false
ACTION_CREATE_USER=""
ACTION_PASSWORD=""
ACTION_BACKUP=false
ACTION_RESTORE=""
ACTION_RESTORE_SET=false
ACTION_INVITE=false
ACTION_USES="1"
ACTION_EXPIRES="24h"
ACTION_LIST_USERS=false
ACTION_DELETE_USER=""
ACTION_REACTIVATE_USER=""
ACTION_SETUP_WELCOME=""
ACTION_LOGS=false
ACTION_LOGS_SERVICE=""
ACTION_TUNNEL_SECRET=false
ACTION_SSH_SECRET=false

[[ $# -eq 0 ]] && usage

while [[ $# -gt 0 ]]; do
    case "$1" in
        --provision)    ACTION_PROVISION=true; shift ;;
        --deploy)       ACTION_DEPLOY=true; shift ;;
        --create-user)  ACTION_CREATE_USER="$2"; shift 2 ;;
        --password)     ACTION_PASSWORD="$2"; shift 2 ;;
        --backup-now)   ACTION_BACKUP=true; shift ;;
        --restore)
            ACTION_RESTORE_SET=true
            if [[ -n "${2:-}" && "${2:-}" != --* ]]; then
                ACTION_RESTORE="$2"; shift 2
            else
                shift
            fi
            ;;
        --invite)       ACTION_INVITE=true; shift ;;
        --uses)         ACTION_USES="$2"; shift 2 ;;
        --expires)      ACTION_EXPIRES="$2"; shift 2 ;;
        --list-users)   ACTION_LIST_USERS=true; shift ;;
        --tunnel-secret) ACTION_TUNNEL_SECRET=true; shift ;;
        --ssh-secret)   ACTION_SSH_SECRET=true; shift ;;
        --delete-user)  ACTION_DELETE_USER="$2"; shift 2 ;;
        --reactivate-user) ACTION_REACTIVATE_USER="$2"; shift 2 ;;
        --setup-welcome-room) ACTION_SETUP_WELCOME="$2"; shift 2 ;;
        --logs)
            ACTION_LOGS=true
            if [[ -n "${2:-}" && "${2:-}" != --* ]]; then
                ACTION_LOGS_SERVICE="$2"; shift 2
            else
                shift
            fi
            ;;
        --help)         usage ;;
        *)              die "Unknown option: $1" ;;
    esac
done

check_config
load_config

if $ACTION_PROVISION; then
    do_provision
fi

if $ACTION_DEPLOY; then
    do_deploy
fi

if [[ -n "$ACTION_CREATE_USER" ]]; then
    do_create_user "$ACTION_CREATE_USER" "$ACTION_PASSWORD"
fi

if $ACTION_BACKUP; then
    do_backup
fi

if $ACTION_RESTORE_SET; then
    do_restore "$ACTION_RESTORE"
fi

if $ACTION_INVITE; then
    do_invite "$ACTION_USES" "$ACTION_EXPIRES"
fi

if $ACTION_LIST_USERS; then
    do_list_users
fi

if $ACTION_TUNNEL_SECRET; then
    do_tunnel_secret
fi

if $ACTION_SSH_SECRET; then
    do_ssh_secret
fi

if [[ -n "$ACTION_DELETE_USER" ]]; then
    do_delete_user "$ACTION_DELETE_USER"
fi

if [[ -n "$ACTION_REACTIVATE_USER" ]]; then
    do_reactivate_user "$ACTION_REACTIVATE_USER" "$ACTION_PASSWORD"
fi

if [[ -n "$ACTION_SETUP_WELCOME" ]]; then
    do_setup_welcome_room "$ACTION_SETUP_WELCOME"
fi

if $ACTION_LOGS; then
    do_logs "$ACTION_LOGS_SERVICE"
fi
