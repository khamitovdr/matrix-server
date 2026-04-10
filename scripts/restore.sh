#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${PROJECT_DIR}/.env"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: .env not found" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

TIMESTAMP="${1:-}"
MC_ALIAS="matrix-backup"

# Configure mc alias
mc alias set "$MC_ALIAS" "$S3_BACKUP_ENDPOINT" "$S3_BACKUP_ACCESS_KEY" "$S3_BACKUP_SECRET_KEY" --api S3v4 --quiet

# If no timestamp, list available backups
if [[ -z "$TIMESTAMP" ]]; then
    echo "Available backups:"
    mc ls "${MC_ALIAS}/${S3_BACKUP_BUCKET}/backups/postgres/" --quiet | awk '{print $NF}' | sort -r
    echo ""
    echo "Usage: restore.sh <YYYY-MM-DD-HHMMSS>"
    exit 0
fi

S3_PATH="backups/postgres/${DOMAIN}-${TIMESTAMP}.sql.gz"
DUMP_FILE="/tmp/matrix-restore-${TIMESTAMP}.sql.gz"

echo "=== Starting restore from ${TIMESTAMP} ==="

# Download backup
echo "Downloading backup..."
mc cp "${MC_ALIAS}/${S3_BACKUP_BUCKET}/${S3_PATH}" "$DUMP_FILE" --quiet

if [[ ! -f "$DUMP_FILE" ]]; then
    echo "ERROR: Backup not found: ${S3_PATH}" >&2
    exit 1
fi

# Stop Synapse to prevent writes
echo "Stopping Synapse..."
docker compose -f "${PROJECT_DIR}/docker-compose.yml" stop synapse

# Drop and recreate database
echo "Recreating database..."
docker compose -f "${PROJECT_DIR}/docker-compose.yml" exec -T postgres \
    psql -U synapse -d postgres -c "DROP DATABASE IF EXISTS synapse;"
docker compose -f "${PROJECT_DIR}/docker-compose.yml" exec -T postgres \
    psql -U synapse -d postgres -c "CREATE DATABASE synapse ENCODING 'UTF8' LC_COLLATE='C' LC_CTYPE='C' TEMPLATE template0;"

# Restore
echo "Restoring database..."
gunzip -c "$DUMP_FILE" | docker compose -f "${PROJECT_DIR}/docker-compose.yml" exec -T postgres \
    psql -U synapse -d synapse --quiet

# Clean up
rm -f "$DUMP_FILE"

# Restart Synapse
echo "Restarting Synapse..."
docker compose -f "${PROJECT_DIR}/docker-compose.yml" start synapse

echo "=== Restore complete ==="
