#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${PROJECT_DIR}/.env"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: .env not found at $ENV_FILE" >&2
    echo "Run generate-env.sh first." >&2
    exit 1
fi

# Export all variables from .env for envsubst
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# Build the list of variable names for envsubst (prevents replacing Caddy placeholders like {uri})
ENV_VARS=$(grep -v '^#' "$ENV_FILE" | grep -v '^$' | cut -d= -f1 | sed 's/^/\$/g' | tr '\n' ' ')

# Render each template
TEMPLATE_COUNT=0
while IFS= read -r template; do
    output="${template%.template}"
    envsubst "$ENV_VARS" < "$template" > "$output"
    echo "Rendered: $output"
    TEMPLATE_COUNT=$((TEMPLATE_COUNT + 1))
done < <(find "$PROJECT_DIR/configs" -name '*.template' -type f)

echo "Rendered $TEMPLATE_COUNT config files."
