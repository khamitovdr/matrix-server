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

MC_ALIAS="matrix-media"
SYNAPSE_CONTAINER="synapse"
MEDIA_PATH="/data/media_store"

# Get free disk space in GB
get_free_gb() {
    df --output=avail / | tail -1 | awk '{printf "%.0f", $1/1024/1024}'
}

FREE_GB=$(get_free_gb)
echo "Current free disk space: ${FREE_GB} GB (target: ${MIN_FREE_GB} GB)"

if [[ "$FREE_GB" -ge "$MIN_FREE_GB" ]]; then
    echo "Sufficient free space. No cleanup needed."
    exit 0
fi

NEED_TO_FREE=$((MIN_FREE_GB - FREE_GB))
echo "Need to free approximately ${NEED_TO_FREE} GB"

# Configure mc for S3 verification
mc alias set "$MC_ALIAS" "$S3_MEDIA_ENDPOINT" "$S3_MEDIA_ACCESS_KEY" "$S3_MEDIA_SECRET_KEY" --api S3v4 --quiet

# Use process substitution to avoid subshell (so FREED_BYTES updates correctly)
FREED_BYTES=0
TARGET_BYTES=$((NEED_TO_FREE * 1024 * 1024 * 1024))

while read -r _atime size filepath; do
    if [[ "$FREED_BYTES" -ge "$TARGET_BYTES" ]]; then
        break
    fi

    # Extract relative path for S3 check
    RELATIVE_PATH="${filepath#"${MEDIA_PATH}"/}"

    # Verify file exists in S3 before deleting locally
    if mc stat "${MC_ALIAS}/${S3_MEDIA_BUCKET}/${RELATIVE_PATH}" &> /dev/null; then
        docker compose -f "${PROJECT_DIR}/docker-compose.yml" exec -T "$SYNAPSE_CONTAINER" \
            rm -f "$filepath"
        FREED_BYTES=$((FREED_BYTES + size))
        echo "Deleted: ${RELATIVE_PATH} ($(numfmt --to=iec-i "$size" 2>/dev/null || echo "${size} bytes"))"
    else
        echo "Skipped (not in S3): ${RELATIVE_PATH}"
    fi
done < <(docker compose -f "${PROJECT_DIR}/docker-compose.yml" exec -T "$SYNAPSE_CONTAINER" \
    find "$MEDIA_PATH/local_content" -type f -printf '%A@ %s %p\n' 2>/dev/null \
    | sort -n)

FREED_MB=$((FREED_BYTES / 1024 / 1024))
echo "Cleanup complete. Freed approximately ${FREED_MB} MB."
echo "Free disk space now: $(get_free_gb) GB"
