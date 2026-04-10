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

TIMESTAMP=$(date +%Y-%m-%d-%H%M%S)
DUMP_FILE="/tmp/matrix-backup-${TIMESTAMP}.sql.gz"
S3_PATH="backups/postgres/${DOMAIN}-${TIMESTAMP}.sql.gz"
MC_ALIAS="matrix-backup"

echo "=== Starting backup at ${TIMESTAMP} ==="

# Configure mc alias
mc alias set "$MC_ALIAS" "$S3_BACKUP_ENDPOINT" "$S3_BACKUP_ACCESS_KEY" "$S3_BACKUP_SECRET_KEY" --api S3v4 --quiet

# Dump database
echo "Dumping PostgreSQL..."
docker compose -f "${PROJECT_DIR}/docker-compose.yml" exec -T postgres \
    pg_dump -U synapse -d synapse | gzip > "$DUMP_FILE"

DUMP_SIZE=$(du -h "$DUMP_FILE" | cut -f1)
echo "Dump size: ${DUMP_SIZE}"

# Upload to S3
echo "Uploading to S3..."
mc cp "$DUMP_FILE" "${MC_ALIAS}/${S3_BACKUP_BUCKET}/${S3_PATH}" --quiet

# Clean up local file
rm -f "$DUMP_FILE"

# Prune old backups
echo "Pruning backups older than ${BACKUP_RETENTION_DAYS} days..."
CUTOFF_DATE=$(date -d "-${BACKUP_RETENTION_DAYS} days" +%Y-%m-%d 2>/dev/null || date -v-"${BACKUP_RETENTION_DAYS}"d +%Y-%m-%d)

mc ls "${MC_ALIAS}/${S3_BACKUP_BUCKET}/backups/postgres/" --quiet | while read -r line; do
    FILENAME=$(echo "$line" | awk '{print $NF}')
    # Extract date from filename: domain-YYYY-MM-DD-HHMMSS.sql.gz
    FILE_DATE=$(echo "$FILENAME" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)
    if [[ -n "$FILE_DATE" && "$FILE_DATE" < "$CUTOFF_DATE" ]]; then
        echo "Deleting old backup: $FILENAME"
        mc rm "${MC_ALIAS}/${S3_BACKUP_BUCKET}/backups/postgres/${FILENAME}" --quiet
    fi
done

echo "=== Backup complete ==="
