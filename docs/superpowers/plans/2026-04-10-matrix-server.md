# Matrix Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy a self-hosted Matrix messaging server with audio/video calling to a single VPS via one `deploy.sh` command.

**Architecture:** Docker Compose stack on Ubuntu 24.04 VPS. User provides `config.yaml` with domain, VPS SSH details, and S3 credentials. Scripts on the VPS generate secrets into `.env`, render config templates via `envsubst`, and run `docker compose up -d`. All services auto-restart on reboot. Caddy handles TLS. coturn runs with host networking for proper NAT traversal; all other services use a Docker bridge network.

**Tech Stack:** Synapse, PostgreSQL 16, Element Web, LiveKit, lk-jwt-service, coturn, Caddy 2, Bash, yq, envsubst, MinIO client (mc)

---

## File Map

| File | Responsibility |
|---|---|
| `.gitignore` | Exclude config.yaml, .env, rendered configs |
| `config.example.yaml` | Template for user configuration |
| `Dockerfile.synapse` | Extends Synapse image with S3 storage provider |
| `docker-compose.yml` | All 7 services, volumes, networks |
| `configs/caddy/Caddyfile.template` | Reverse proxy routes, TLS, CORS, .well-known |
| `configs/synapse/homeserver.yaml.template` | Synapse server config |
| `configs/synapse/log.config` | Synapse logging (static, no templating) |
| `configs/element/config.json.template` | Element Web client config |
| `configs/livekit/livekit.yaml.template` | LiveKit SFU config |
| `configs/coturn/turnserver.conf.template` | coturn TURN/STUN config |
| `scripts/generate-env.sh` | Parse config.yaml + generate secrets → .env |
| `scripts/render-configs.sh` | envsubst on all .template files |
| `scripts/provision.sh` | VPS first-time setup (Docker, UFW, yq, mc, cron) |
| `scripts/create-user.sh` | Create Matrix user via Synapse admin API |
| `scripts/backup.sh` | PostgreSQL dump → S3 |
| `scripts/restore.sh` | S3 → PostgreSQL restore |
| `scripts/cleanup-media.sh` | Evict old cached media files from local disk |
| `deploy.sh` | Main entry point, orchestrates all operations over SSH |

---

### Task 1: Repository Foundation

**Files:**
- Create: `.gitignore`
- Create: `config.example.yaml`

- [ ] **Step 1: Create .gitignore**

```gitignore
config.yaml
.env
*.rendered

# Rendered config files (generated from .template)
configs/caddy/Caddyfile
configs/synapse/homeserver.yaml
configs/element/config.json
configs/livekit/livekit.yaml
configs/coturn/turnserver.conf
```

- [ ] **Step 2: Create config.example.yaml**

```yaml
# Matrix Server Configuration
# Copy this file to config.yaml and fill in your values.

domain: example.com
subdomains:
  matrix: matrix
  element: element
  livekit: livekit
  turn: turn

vps:
  host: "1.2.3.4"
  user: root
  ssh_key: ~/.ssh/id_rsa
  deploy_dir: /opt/matrix-server

s3:
  media:
    endpoint: https://storage.yandexcloud.net
    region: ru-central1
    bucket: my-media-bucket
    access_key: YOUR_ACCESS_KEY
    secret_key: YOUR_SECRET_KEY
  backup:
    endpoint: https://storage.yandexcloud.net
    region: ru-central1
    bucket: my-backup-bucket
    access_key: YOUR_ACCESS_KEY
    secret_key: YOUR_SECRET_KEY

media_cache:
  max_upload_size_mb: 100
  cleanup_cron: "0 4 * * *"
  min_free_gb: 30

coturn:
  udp_port_range: "49152-49200"

backup:
  cron: "0 3 * * *"
  retention_days: 14
```

- [ ] **Step 3: Commit**

```bash
git add .gitignore config.example.yaml
git commit -m "feat: add repo foundation with gitignore and example config"
```

---

### Task 2: Docker Compose + Synapse Dockerfile

**Files:**
- Create: `docker-compose.yml`
- Create: `Dockerfile.synapse`
- Create: `configs/synapse/log.config`

- [ ] **Step 1: Create Dockerfile.synapse**

```dockerfile
FROM matrixdotorg/synapse:latest

RUN pip install --no-cache-dir synapse-s3-storage-provider
```

- [ ] **Step 2: Create configs/synapse/log.config**

```yaml
version: 1
formatters:
  precise:
    format: '%(asctime)s - %(name)s - %(lineno)d - %(levelname)s - %(request)s - %(message)s'
handlers:
  console:
    class: logging.StreamHandler
    formatter: precise
loggers:
  synapse.storage.SQL:
    level: WARN
root:
  level: INFO
  handlers: [console]
disable_existing_loggers: false
```

- [ ] **Step 3: Create docker-compose.yml**

```yaml
services:
  caddy:
    image: caddy:2
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    volumes:
      - ./configs/caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    networks:
      - matrix-net
    depends_on:
      synapse:
        condition: service_started
      element:
        condition: service_started

  postgres:
    image: postgres:16
    restart: unless-stopped
    environment:
      POSTGRES_USER: synapse
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: synapse
      POSTGRES_INITDB_ARGS: "--encoding=UTF-8 --lc-collate=C --lc-ctype=C"
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - matrix-net
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U synapse"]
      interval: 10s
      timeout: 5s
      retries: 5

  synapse:
    build:
      context: .
      dockerfile: Dockerfile.synapse
    restart: unless-stopped
    volumes:
      - synapse_data:/data
      - ./configs/synapse/homeserver.yaml:/data/homeserver.yaml:ro
      - ./configs/synapse/log.config:/data/log.config:ro
    depends_on:
      postgres:
        condition: service_healthy
    networks:
      - matrix-net

  element:
    image: vectorim/element-web:latest
    restart: unless-stopped
    volumes:
      - ./configs/element/config.json:/app/config.json:ro
    networks:
      - matrix-net

  livekit:
    image: livekit/livekit-server:latest
    restart: unless-stopped
    ports:
      - "7880:7880"
      - "7881:7881/tcp"
      - "50000-50200:50000-50200/udp"
    volumes:
      - ./configs/livekit/livekit.yaml:/etc/livekit.yaml:ro
    command: --config /etc/livekit.yaml
    networks:
      - matrix-net

  livekit-jwt:
    image: ghcr.io/element-hq/lk-jwt-service:latest
    restart: unless-stopped
    environment:
      LK_JWT_PORT: "8080"
      LIVEKIT_URL: wss://${SUBDOMAIN_LIVEKIT}.${DOMAIN}
      LIVEKIT_KEY: ${LIVEKIT_API_KEY}
      LIVEKIT_SECRET: ${LIVEKIT_API_SECRET}
    networks:
      - matrix-net

  coturn:
    image: coturn/coturn:latest
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./configs/coturn/turnserver.conf:/etc/turnserver.conf:ro
    command: -c /etc/turnserver.conf

volumes:
  postgres_data:
  synapse_data:
  caddy_data:
  caddy_config:

networks:
  matrix-net:
    driver: bridge
```

- [ ] **Step 4: Verify compose file parses**

Create a minimal `.env` for validation, then run `docker compose config`:

```bash
cat > /tmp/matrix-test.env << 'ENVEOF'
POSTGRES_PASSWORD=test
DOMAIN=example.com
SUBDOMAIN_LIVEKIT=livekit
LIVEKIT_API_KEY=testkey
LIVEKIT_API_SECRET=testsecret
ENVEOF

docker compose --env-file /tmp/matrix-test.env config > /dev/null 2>&1 && echo "PASS: compose file valid" || echo "FAIL: compose file invalid"
rm /tmp/matrix-test.env
```

Expected: `PASS: compose file valid`

Note: this will warn about missing config files for volume mounts — that's expected since templates haven't been rendered yet.

- [ ] **Step 5: Commit**

```bash
git add docker-compose.yml Dockerfile.synapse configs/synapse/log.config
git commit -m "feat: add docker compose stack with all services"
```

---

### Task 3: Caddy Configuration Template

**Files:**
- Create: `configs/caddy/Caddyfile.template`

- [ ] **Step 1: Create Caddyfile.template**

```caddyfile
# Matrix homeserver
${SUBDOMAIN_MATRIX}.${DOMAIN} {
	reverse_proxy synapse:8008

	# Allow large media uploads
	request_body {
		max_size ${MAX_UPLOAD_SIZE_MB}m
	}
}

# Element Web client
${SUBDOMAIN_ELEMENT}.${DOMAIN} {
	reverse_proxy element:80
}

# LiveKit signaling + JWT service
${SUBDOMAIN_LIVEKIT}.${DOMAIN} {
	# JWT token service for Element Call
	handle_path /jwt/* {
		reverse_proxy livekit-jwt:8080
	}

	# LiveKit WebSocket signaling
	handle {
		reverse_proxy livekit:7880
	}
}

# Apex domain: .well-known + redirect to Element
${DOMAIN} {
	handle /.well-known/matrix/client {
		header Content-Type application/json
		header Access-Control-Allow-Origin *
		respond `{"m.homeserver":{"base_url":"https://${SUBDOMAIN_MATRIX}.${DOMAIN}"},"org.matrix.msc4143.rtc_foci":[{"type":"livekit","livekit_service_url":"https://${SUBDOMAIN_LIVEKIT}.${DOMAIN}/jwt"}]}`
	}

	handle /.well-known/matrix/server {
		header Content-Type application/json
		header Access-Control-Allow-Origin *
		respond `{"m.server":"${SUBDOMAIN_MATRIX}.${DOMAIN}:443"}`
	}

	handle {
		redir https://${SUBDOMAIN_ELEMENT}.${DOMAIN}{uri} permanent
	}
}
```

- [ ] **Step 2: Commit**

```bash
git add configs/caddy/Caddyfile.template
git commit -m "feat: add Caddy reverse proxy config template"
```

---

### Task 4: Synapse Configuration Template

**Files:**
- Create: `configs/synapse/homeserver.yaml.template`

- [ ] **Step 1: Create homeserver.yaml.template**

```yaml
server_name: "${DOMAIN}"
pid_file: /data/homeserver.pid
public_baseurl: "https://${SUBDOMAIN_MATRIX}.${DOMAIN}/"

listeners:
  - port: 8008
    tls: false
    type: http
    x_forwarded: true
    resources:
      - names: [client, consent]
        compress: false

database:
  name: psycopg2
  args:
    user: synapse
    password: "${POSTGRES_PASSWORD}"
    database: synapse
    host: postgres
    port: 5432
    cp_min: 5
    cp_max: 10

log_config: "/data/log.config"

media_store_path: "/data/media_store"
max_upload_size: "${MAX_UPLOAD_SIZE_MB}M"

media_storage_providers:
  - module: s3_storage_provider.S3StorageProviderBackend
    store_local: true
    store_remote: true
    store_synchronous: true
    config:
      bucket: "${S3_MEDIA_BUCKET}"
      region_name: "${S3_MEDIA_REGION}"
      endpoint_url: "${S3_MEDIA_ENDPOINT}"
      access_key_id: "${S3_MEDIA_ACCESS_KEY}"
      secret_access_key: "${S3_MEDIA_SECRET_KEY}"

enable_registration: false
registration_shared_secret: "${SYNAPSE_REGISTRATION_SHARED_SECRET}"

macaroon_secret_key: "${SYNAPSE_MACAROON_SECRET_KEY}"
form_secret: "${SYNAPSE_FORM_SECRET}"
signing_key_path: "/data/signing.key"

suppress_key_server_warning: true

# Federation disabled
allow_public_rooms_over_federation: false
federation_domain_whitelist: []
trusted_key_servers: []

# TURN for legacy Matrix VoIP (non-Element-Call clients)
turn_uris:
  - "turn:${SUBDOMAIN_TURN}.${DOMAIN}:3478?transport=udp"
  - "turn:${SUBDOMAIN_TURN}.${DOMAIN}:3478?transport=tcp"
turn_shared_secret: "${COTURN_AUTH_SECRET}"
turn_user_lifetime: 86400000
turn_allow_guests: false

# Rate limiting
rc_message:
  per_second: 5
  burst_count: 30
rc_login:
  address:
    per_second: 0.5
    burst_count: 3
  account:
    per_second: 0.5
    burst_count: 3
```

- [ ] **Step 2: Commit**

```bash
git add configs/synapse/homeserver.yaml.template
git commit -m "feat: add Synapse homeserver config template"
```

---

### Task 5: Element Web Configuration Template

**Files:**
- Create: `configs/element/config.json.template`

- [ ] **Step 1: Create config.json.template**

```json
{
    "default_server_config": {
        "m.homeserver": {
            "base_url": "https://${SUBDOMAIN_MATRIX}.${DOMAIN}",
            "server_name": "${DOMAIN}"
        }
    },
    "disable_guests": true,
    "disable_3pid_login": true,
    "brand": "Element",
    "element_call": {
        "url": "https://call.element.dev",
        "use_exclusively": true,
        "participant_limit": 8,
        "brand": "Element Call"
    },
    "features": {
        "feature_video_rooms": true,
        "feature_group_calls": true
    },
    "map_style_url": null
}
```

- [ ] **Step 2: Commit**

```bash
git add configs/element/config.json.template
git commit -m "feat: add Element Web client config template"
```

---

### Task 6: LiveKit Configuration Template

**Files:**
- Create: `configs/livekit/livekit.yaml.template`

- [ ] **Step 1: Create livekit.yaml.template**

```yaml
port: 7880
bind_addresses:
  - ""
rtc:
  tcp_port: 7881
  port_range_start: 50000
  port_range_end: 50200
  use_external_ip: true
keys:
  ${LIVEKIT_API_KEY}: ${LIVEKIT_API_SECRET}
turn:
  enabled: true
  domain: ${SUBDOMAIN_TURN}.${DOMAIN}
  udp_port: 3478
  external_tls: false
logging:
  json: true
  level: info
```

- [ ] **Step 2: Commit**

```bash
git add configs/livekit/livekit.yaml.template
git commit -m "feat: add LiveKit server config template"
```

---

### Task 7: coturn Configuration Template

**Files:**
- Create: `configs/coturn/turnserver.conf.template`

- [ ] **Step 1: Create turnserver.conf.template**

```
# coturn TURN/STUN server configuration

listening-port=3478
min-port=${COTURN_MIN_PORT}
max-port=${COTURN_MAX_PORT}

realm=${SUBDOMAIN_TURN}.${DOMAIN}
server-name=${SUBDOMAIN_TURN}.${DOMAIN}

use-auth-secret
static-auth-secret=${COTURN_AUTH_SECRET}

# External IP for NAT traversal
external-ip=${VPS_EXTERNAL_IP}

# Security
fingerprint
no-cli
no-software-attribute
no-multicast-peers
no-tlsv1
no-tlsv1_1

# Logging
log-file=stdout
verbose
```

- [ ] **Step 2: Commit**

```bash
git add configs/coturn/turnserver.conf.template
git commit -m "feat: add coturn TURN/STUN config template"
```

---

### Task 8: Environment Generation Script

**Files:**
- Create: `scripts/generate-env.sh`

This script runs **on the VPS**. It reads `config.yaml` with `yq`, extracts all config values, generates any missing secrets, and writes the complete `.env` file.

- [ ] **Step 1: Create scripts/generate-env.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${PROJECT_DIR}/config.yaml"
ENV_FILE="${PROJECT_DIR}/.env"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: config.yaml not found at $CONFIG_FILE" >&2
    exit 1
fi

if ! command -v yq &> /dev/null; then
    echo "ERROR: yq is required but not installed" >&2
    exit 1
fi

# Load existing secrets if .env exists (to preserve them across deploys)
declare -A EXISTING_SECRETS
if [[ -f "$ENV_FILE" ]]; then
    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        EXISTING_SECRETS["$key"]="$value"
    done < "$ENV_FILE"
fi

generate_secret() {
    openssl rand -hex 32
}

generate_api_key() {
    # LiveKit API keys are shorter, alphanumeric
    openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 12
}

get_or_generate() {
    local key="$1"
    local generator="${2:-generate_secret}"
    if [[ -n "${EXISTING_SECRETS[$key]:-}" ]]; then
        echo "${EXISTING_SECRETS[$key]}"
    else
        $generator
    fi
}

# Extract config values with yq
DOMAIN=$(yq '.domain' "$CONFIG_FILE")
SUBDOMAIN_MATRIX=$(yq '.subdomains.matrix' "$CONFIG_FILE")
SUBDOMAIN_ELEMENT=$(yq '.subdomains.element' "$CONFIG_FILE")
SUBDOMAIN_LIVEKIT=$(yq '.subdomains.livekit' "$CONFIG_FILE")
SUBDOMAIN_TURN=$(yq '.subdomains.turn' "$CONFIG_FILE")

VPS_HOST=$(yq '.vps.host' "$CONFIG_FILE")

S3_MEDIA_ENDPOINT=$(yq '.s3.media.endpoint' "$CONFIG_FILE")
S3_MEDIA_REGION=$(yq '.s3.media.region' "$CONFIG_FILE")
S3_MEDIA_BUCKET=$(yq '.s3.media.bucket' "$CONFIG_FILE")
S3_MEDIA_ACCESS_KEY=$(yq '.s3.media.access_key' "$CONFIG_FILE")
S3_MEDIA_SECRET_KEY=$(yq '.s3.media.secret_key' "$CONFIG_FILE")

S3_BACKUP_ENDPOINT=$(yq '.s3.backup.endpoint' "$CONFIG_FILE")
S3_BACKUP_REGION=$(yq '.s3.backup.region' "$CONFIG_FILE")
S3_BACKUP_BUCKET=$(yq '.s3.backup.bucket' "$CONFIG_FILE")
S3_BACKUP_ACCESS_KEY=$(yq '.s3.backup.access_key' "$CONFIG_FILE")
S3_BACKUP_SECRET_KEY=$(yq '.s3.backup.secret_key' "$CONFIG_FILE")

MAX_UPLOAD_SIZE_MB=$(yq '.media_cache.max_upload_size_mb' "$CONFIG_FILE")
MEDIA_CLEANUP_CRON=$(yq '.media_cache.cleanup_cron' "$CONFIG_FILE")
MIN_FREE_GB=$(yq '.media_cache.min_free_gb' "$CONFIG_FILE")

COTURN_UDP_PORT_RANGE=$(yq '.coturn.udp_port_range' "$CONFIG_FILE")
COTURN_MIN_PORT="${COTURN_UDP_PORT_RANGE%-*}"
COTURN_MAX_PORT="${COTURN_UDP_PORT_RANGE#*-}"

BACKUP_CRON=$(yq '.backup.cron' "$CONFIG_FILE")
BACKUP_RETENTION_DAYS=$(yq '.backup.retention_days' "$CONFIG_FILE")

# Generate or preserve secrets
POSTGRES_PASSWORD=$(get_or_generate POSTGRES_PASSWORD)
SYNAPSE_REGISTRATION_SHARED_SECRET=$(get_or_generate SYNAPSE_REGISTRATION_SHARED_SECRET)
SYNAPSE_MACAROON_SECRET_KEY=$(get_or_generate SYNAPSE_MACAROON_SECRET_KEY)
SYNAPSE_FORM_SECRET=$(get_or_generate SYNAPSE_FORM_SECRET)
LIVEKIT_API_KEY=$(get_or_generate LIVEKIT_API_KEY generate_api_key)
LIVEKIT_API_SECRET=$(get_or_generate LIVEKIT_API_SECRET)
COTURN_AUTH_SECRET=$(get_or_generate COTURN_AUTH_SECRET)

# Write complete .env
cat > "$ENV_FILE" << EOF
# Auto-generated by generate-env.sh — do not edit manually
# Re-running this script preserves existing secret values

# Domain
DOMAIN=${DOMAIN}
SUBDOMAIN_MATRIX=${SUBDOMAIN_MATRIX}
SUBDOMAIN_ELEMENT=${SUBDOMAIN_ELEMENT}
SUBDOMAIN_LIVEKIT=${SUBDOMAIN_LIVEKIT}
SUBDOMAIN_TURN=${SUBDOMAIN_TURN}

# VPS
VPS_EXTERNAL_IP=${VPS_HOST}

# S3 Media
S3_MEDIA_ENDPOINT=${S3_MEDIA_ENDPOINT}
S3_MEDIA_REGION=${S3_MEDIA_REGION}
S3_MEDIA_BUCKET=${S3_MEDIA_BUCKET}
S3_MEDIA_ACCESS_KEY=${S3_MEDIA_ACCESS_KEY}
S3_MEDIA_SECRET_KEY=${S3_MEDIA_SECRET_KEY}

# S3 Backup
S3_BACKUP_ENDPOINT=${S3_BACKUP_ENDPOINT}
S3_BACKUP_REGION=${S3_BACKUP_REGION}
S3_BACKUP_BUCKET=${S3_BACKUP_BUCKET}
S3_BACKUP_ACCESS_KEY=${S3_BACKUP_ACCESS_KEY}
S3_BACKUP_SECRET_KEY=${S3_BACKUP_SECRET_KEY}

# Media cache
MAX_UPLOAD_SIZE_MB=${MAX_UPLOAD_SIZE_MB}
MEDIA_CLEANUP_CRON=${MEDIA_CLEANUP_CRON}
MIN_FREE_GB=${MIN_FREE_GB}

# coturn
COTURN_MIN_PORT=${COTURN_MIN_PORT}
COTURN_MAX_PORT=${COTURN_MAX_PORT}
COTURN_AUTH_SECRET=${COTURN_AUTH_SECRET}

# Backup
BACKUP_CRON=${BACKUP_CRON}
BACKUP_RETENTION_DAYS=${BACKUP_RETENTION_DAYS}

# Secrets (auto-generated, preserved across deploys)
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
SYNAPSE_REGISTRATION_SHARED_SECRET=${SYNAPSE_REGISTRATION_SHARED_SECRET}
SYNAPSE_MACAROON_SECRET_KEY=${SYNAPSE_MACAROON_SECRET_KEY}
SYNAPSE_FORM_SECRET=${SYNAPSE_FORM_SECRET}
LIVEKIT_API_KEY=${LIVEKIT_API_KEY}
LIVEKIT_API_SECRET=${LIVEKIT_API_SECRET}
EOF

chmod 600 "$ENV_FILE"
echo "Environment file written to $ENV_FILE"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x scripts/generate-env.sh
```

- [ ] **Step 3: Verify with shellcheck**

```bash
shellcheck scripts/generate-env.sh
```

Expected: no errors (warnings about `declare -A` are acceptable — requires bash 4+, which Ubuntu 24.04 has).

- [ ] **Step 4: Commit**

```bash
git add scripts/generate-env.sh
git commit -m "feat: add environment generation script"
```

---

### Task 9: Config Rendering Script

**Files:**
- Create: `scripts/render-configs.sh`

This script runs **on the VPS**. It reads `.env` and substitutes variables into all `.template` files.

- [ ] **Step 1: Create scripts/render-configs.sh**

```bash
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
source "$ENV_FILE"
set +a

# Build the list of variable names for envsubst (prevents replacing Caddy placeholders like {uri})
ENV_VARS=$(grep -v '^#' "$ENV_FILE" | grep -v '^$' | cut -d= -f1 | sed 's/^/\$/g' | tr '\n' ' ')

# Render each template
TEMPLATE_COUNT=0
for template in $(find "$PROJECT_DIR/configs" -name '*.template' -type f); do
    output="${template%.template}"
    envsubst "$ENV_VARS" < "$template" > "$output"
    echo "Rendered: $output"
    TEMPLATE_COUNT=$((TEMPLATE_COUNT + 1))
done

echo "Rendered $TEMPLATE_COUNT config files."
```

- [ ] **Step 2: Make executable**

```bash
chmod +x scripts/render-configs.sh
```

- [ ] **Step 3: Verify with shellcheck**

```bash
shellcheck scripts/render-configs.sh
```

Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add scripts/render-configs.sh
git commit -m "feat: add config rendering script"
```

---

### Task 10: VPS Provisioning Script

**Files:**
- Create: `scripts/provision.sh`

This script runs **on the VPS** (invoked by deploy.sh over SSH). It handles one-time setup.

- [ ] **Step 1: Create scripts/provision.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "=== Matrix Server VPS Provisioning ==="

# Update system
echo "Updating packages..."
apt-get update -qq
apt-get upgrade -y -qq

# Install prerequisites
apt-get install -y -qq curl gnupg lsb-release ufw openssl gettext-base

# Install Docker if not present
if ! command -v docker &> /dev/null; then
    echo "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
fi

# Ensure Docker starts on boot
systemctl enable docker
systemctl start docker

# Install yq
if ! command -v yq &> /dev/null; then
    echo "Installing yq..."
    YQ_VERSION="v4.44.1"
    ARCH=$(dpkg --print-architecture)
    curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${ARCH}" -o /usr/local/bin/yq
    chmod +x /usr/local/bin/yq
fi

# Install MinIO client (mc) for S3 operations
if ! command -v mc &> /dev/null; then
    echo "Installing MinIO client..."
    ARCH=$(dpkg --print-architecture)
    curl -fsSL "https://dl.min.io/client/mc/release/linux-${ARCH}/mc" -o /usr/local/bin/mc
    chmod +x /usr/local/bin/mc
fi

# Configure UFW firewall
echo "Configuring firewall..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

ufw allow 22/tcp        # SSH
ufw allow 80/tcp        # HTTP
ufw allow 443/tcp       # HTTPS
ufw allow 443/udp       # HTTP/3 (QUIC)
ufw allow 3478/udp      # STUN/TURN
ufw allow 3478/tcp      # TURN TCP
ufw allow 7880/tcp      # LiveKit WebSocket
ufw allow 7881/tcp      # LiveKit WebRTC TCP
ufw allow 50000:50200/udp  # LiveKit RTC UDP

# coturn media relay ports from config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
if [[ -f "${PROJECT_DIR}/.env" ]]; then
    source "${PROJECT_DIR}/.env"
    ufw allow "${COTURN_MIN_PORT}:${COTURN_MAX_PORT}/udp"
fi

ufw --force enable

# Create deploy directory structure
DEPLOY_DIR="${PROJECT_DIR}"
mkdir -p "${DEPLOY_DIR}/configs/caddy"
mkdir -p "${DEPLOY_DIR}/configs/synapse"
mkdir -p "${DEPLOY_DIR}/configs/element"
mkdir -p "${DEPLOY_DIR}/configs/livekit"
mkdir -p "${DEPLOY_DIR}/configs/coturn"

echo "=== Provisioning complete ==="
```

- [ ] **Step 2: Make executable**

```bash
chmod +x scripts/provision.sh
```

- [ ] **Step 3: Verify with shellcheck**

```bash
shellcheck scripts/provision.sh
```

Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add scripts/provision.sh
git commit -m "feat: add VPS provisioning script"
```

---

### Task 11: Deploy Orchestrator

**Files:**
- Create: `deploy.sh`

The main entry point. Runs on the user's local machine, orchestrates everything over SSH.

- [ ] **Step 1: Create deploy.sh**

```bash
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
  --help                Show this help

Examples:
  ./deploy.sh --provision --deploy    # First-time full setup
  ./deploy.sh --deploy                # Update config and restart
  ./deploy.sh --create-user alice     # Create user with auto-generated password
  ./deploy.sh --backup-now            # Immediate backup
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
        ".vps.ssh_key"
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
    VPS_SSH_KEY=$(yq '.vps.ssh_key' "$CONFIG_FILE")
    DEPLOY_DIR=$(yq '.vps.deploy_dir' "$CONFIG_FILE")
    DOMAIN=$(yq '.domain' "$CONFIG_FILE")
    SUBDOMAIN_MATRIX=$(yq '.subdomains.matrix' "$CONFIG_FILE")

    SSH_OPTS="-o StrictHostKeyChecking=accept-new -i ${VPS_SSH_KEY}"
}

ssh_cmd() {
    ssh $SSH_OPTS "${VPS_USER}@${VPS_HOST}" "$@"
}

scp_to() {
    scp $SSH_OPTS -r "$1" "${VPS_USER}@${VPS_HOST}:$2"
}

# ── Commands ─────────────────────────────────────────────────────────────────

do_provision() {
    echo "=== Provisioning VPS ==="
    do_copy_files
    ssh_cmd "bash ${DEPLOY_DIR}/scripts/generate-env.sh"
    ssh_cmd "bash ${DEPLOY_DIR}/scripts/provision.sh"
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

    # Build and start
    ssh_cmd "cd ${DEPLOY_DIR} && docker compose build --quiet && docker compose up -d"

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
    ssh_cmd "cat > /tmp/matrix-cron << 'CRONEOF'
# Matrix server backup
${backup_cron} cd ${DEPLOY_DIR} && bash scripts/backup.sh >> /var/log/matrix-backup.log 2>&1
# Matrix server media cache cleanup
${cleanup_cron} cd ${DEPLOY_DIR} && bash scripts/cleanup-media.sh >> /var/log/matrix-cleanup.log 2>&1
CRONEOF
crontab /tmp/matrix-cron
rm /tmp/matrix-cron"

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

# ── Main ─────────────────────────────────────────────────────────────────────

ACTION_PROVISION=false
ACTION_DEPLOY=false
ACTION_CREATE_USER=""
ACTION_PASSWORD=""
ACTION_BACKUP=false
ACTION_RESTORE=""
ACTION_RESTORE_SET=false

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
```

- [ ] **Step 2: Make executable**

```bash
chmod +x deploy.sh
```

- [ ] **Step 3: Verify with shellcheck**

```bash
shellcheck deploy.sh
```

Expected: no errors.

- [ ] **Step 4: Verify help output**

```bash
./deploy.sh --help
```

Expected: usage text prints and exits cleanly.

- [ ] **Step 5: Commit**

```bash
git add deploy.sh
git commit -m "feat: add deploy orchestrator script"
```

---

### Task 12: User Management Script

**Files:**
- Create: `scripts/create-user.sh`

Runs **on the VPS**. Creates a Matrix user via Synapse's admin registration API.

- [ ] **Step 1: Create scripts/create-user.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${PROJECT_DIR}/.env"

USERNAME="${1:-}"
PASSWORD="${2:-}"

if [[ -z "$USERNAME" ]]; then
    echo "Usage: create-user.sh <username> [password]" >&2
    exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: .env not found. Run generate-env.sh first." >&2
    exit 1
fi

source "$ENV_FILE"

SYNAPSE_URL="http://localhost:8008"
# Resolve Synapse container's port via Docker
SYNAPSE_URL="http://$(docker compose -f "${PROJECT_DIR}/docker-compose.yml" port synapse 8008 2>/dev/null || echo "localhost:8008")"

# Generate password if not provided
if [[ -z "$PASSWORD" ]]; then
    PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 20)
    echo "Generated password: ${PASSWORD}"
fi

# Step 1: Get a nonce
NONCE_RESPONSE=$(curl -s "${SYNAPSE_URL}/_synapse/admin/v1/register")
NONCE=$(echo "$NONCE_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['nonce'])")

# Step 2: Compute HMAC
# HMAC = HMAC-SHA1(shared_secret, nonce + "\x00" + username + "\x00" + password + "\x00" + "notadmin")
MAC=$(printf '%s\0%s\0%s\0%s' "$NONCE" "$USERNAME" "$PASSWORD" "notadmin" \
    | openssl dgst -sha1 -hmac "$SYNAPSE_REGISTRATION_SHARED_SECRET" \
    | awk '{print $NF}')

# Step 3: Register
REGISTER_RESPONSE=$(curl -s -X POST "${SYNAPSE_URL}/_synapse/admin/v1/register" \
    -H "Content-Type: application/json" \
    -d "{
        \"nonce\": \"${NONCE}\",
        \"username\": \"${USERNAME}\",
        \"password\": \"${PASSWORD}\",
        \"mac\": \"${MAC}\",
        \"admin\": false
    }")

# Check result
if echo "$REGISTER_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('user_id',''))" 2>/dev/null | grep -q "@"; then
    USER_ID=$(echo "$REGISTER_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['user_id'])")
    echo "Successfully created user: ${USER_ID}"
else
    echo "ERROR: Failed to create user" >&2
    echo "$REGISTER_RESPONSE" >&2
    exit 1
fi
```

- [ ] **Step 2: Make executable and verify**

```bash
chmod +x scripts/create-user.sh
shellcheck scripts/create-user.sh
```

Expected: no errors (SC2086 warnings for SSH_OPTS intentional word splitting are acceptable).

- [ ] **Step 3: Commit**

```bash
git add scripts/create-user.sh
git commit -m "feat: add user creation script via Synapse admin API"
```

---

### Task 13: Backup and Restore Scripts

**Files:**
- Create: `scripts/backup.sh`
- Create: `scripts/restore.sh`

Both run **on the VPS**.

- [ ] **Step 1: Create scripts/backup.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${PROJECT_DIR}/.env"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: .env not found" >&2
    exit 1
fi

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
CUTOFF_DATE=$(date -d "-${BACKUP_RETENTION_DAYS} days" +%Y-%m-%d 2>/dev/null || date -v-${BACKUP_RETENTION_DAYS}d +%Y-%m-%d)

mc ls "${MC_ALIAS}/${S3_BACKUP_BUCKET}/backups/postgres/" --quiet | while read -r line; do
    FILENAME=$(echo "$line" | awk '{print $NF}')
    # Extract date from filename: domain-YYYY-MM-DD-HHMMSS.sql.gz
    FILE_DATE=$(echo "$FILENAME" | grep -oP '\d{4}-\d{2}-\d{2}' | head -1)
    if [[ -n "$FILE_DATE" && "$FILE_DATE" < "$CUTOFF_DATE" ]]; then
        echo "Deleting old backup: $FILENAME"
        mc rm "${MC_ALIAS}/${S3_BACKUP_BUCKET}/backups/postgres/${FILENAME}" --quiet
    fi
done

echo "=== Backup complete ==="
```

- [ ] **Step 2: Create scripts/restore.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${PROJECT_DIR}/.env"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: .env not found" >&2
    exit 1
fi

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
```

- [ ] **Step 3: Make executable and verify**

```bash
chmod +x scripts/backup.sh scripts/restore.sh
shellcheck scripts/backup.sh
shellcheck scripts/restore.sh
```

Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add scripts/backup.sh scripts/restore.sh
git commit -m "feat: add backup and restore scripts for PostgreSQL"
```

---

### Task 14: Media Cleanup Script

**Files:**
- Create: `scripts/cleanup-media.sh`

Runs **on the VPS** via cron. Evicts old cached media files when disk space is low.

- [ ] **Step 1: Create scripts/cleanup-media.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${PROJECT_DIR}/.env"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: .env not found" >&2
    exit 1
fi

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

# Get list of local media files sorted by access time (oldest first)
# The media store structure is: local_content/xx/yy/xxyy...
FREED_BYTES=0
TARGET_BYTES=$((NEED_TO_FREE * 1024 * 1024 * 1024))

# Use process substitution to avoid subshell (so FREED_BYTES updates correctly)
while read -r atime size filepath; do
    if [[ "$FREED_BYTES" -ge "$TARGET_BYTES" ]]; then
        break
    fi

    # Extract relative path for S3 check
    RELATIVE_PATH="${filepath#${MEDIA_PATH}/}"

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
```

- [ ] **Step 2: Make executable and verify**

```bash
chmod +x scripts/cleanup-media.sh
shellcheck scripts/cleanup-media.sh
```

Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add scripts/cleanup-media.sh
git commit -m "feat: add media cache cleanup script"
```

---

### Task 15: Validation Pass

Verify everything works together before first real deployment.

- [ ] **Step 1: Shellcheck all scripts**

```bash
shellcheck deploy.sh scripts/*.sh
```

Expected: no errors. Fix any issues found.

- [ ] **Step 2: Validate Docker Compose with dummy env**

```bash
cat > /tmp/matrix-validate.env << 'EOF'
DOMAIN=example.com
SUBDOMAIN_MATRIX=matrix
SUBDOMAIN_ELEMENT=element
SUBDOMAIN_LIVEKIT=livekit
SUBDOMAIN_TURN=turn
VPS_EXTERNAL_IP=1.2.3.4
POSTGRES_PASSWORD=testpass
SYNAPSE_REGISTRATION_SHARED_SECRET=testsecret
SYNAPSE_MACAROON_SECRET_KEY=testmac
SYNAPSE_FORM_SECRET=testform
LIVEKIT_API_KEY=testkey
LIVEKIT_API_SECRET=testsecret
COTURN_AUTH_SECRET=turnsecret
COTURN_MIN_PORT=49152
COTURN_MAX_PORT=49200
MAX_UPLOAD_SIZE_MB=100
S3_MEDIA_ENDPOINT=https://storage.yandexcloud.net
S3_MEDIA_REGION=ru-central1
S3_MEDIA_BUCKET=test-bucket
S3_MEDIA_ACCESS_KEY=testkey
S3_MEDIA_SECRET_KEY=testsecret
S3_BACKUP_ENDPOINT=https://storage.yandexcloud.net
S3_BACKUP_REGION=ru-central1
S3_BACKUP_BUCKET=test-backup
S3_BACKUP_ACCESS_KEY=testkey
S3_BACKUP_SECRET_KEY=testsecret
BACKUP_CRON=0 3 * * *
BACKUP_RETENTION_DAYS=14
MEDIA_CLEANUP_CRON=0 4 * * *
MIN_FREE_GB=30
EOF

docker compose --env-file /tmp/matrix-validate.env config > /dev/null && echo "PASS" || echo "FAIL"
rm /tmp/matrix-validate.env
```

Expected: `PASS`

- [ ] **Step 3: Verify template rendering with dummy env**

```bash
# Source dummy env and render one template as a test
export DOMAIN=example.com SUBDOMAIN_MATRIX=matrix SUBDOMAIN_ELEMENT=element \
       SUBDOMAIN_LIVEKIT=livekit SUBDOMAIN_TURN=turn MAX_UPLOAD_SIZE_MB=100 \
       VPS_EXTERNAL_IP=1.2.3.4 COTURN_AUTH_SECRET=test COTURN_MIN_PORT=49152 \
       COTURN_MAX_PORT=49200

ENV_VARS='$DOMAIN $SUBDOMAIN_MATRIX $SUBDOMAIN_ELEMENT $SUBDOMAIN_LIVEKIT $SUBDOMAIN_TURN $MAX_UPLOAD_SIZE_MB'
envsubst "$ENV_VARS" < configs/caddy/Caddyfile.template | head -5
```

Expected output should show `example.com` substituted in place of `${DOMAIN}`, with no remaining `${...}` placeholders in the substituted variables.

- [ ] **Step 4: Verify deploy.sh help works**

```bash
./deploy.sh --help
```

Expected: usage text prints cleanly.

- [ ] **Step 5: Fix any issues found, then commit**

```bash
git add -A
git commit -m "fix: address validation findings"
```

Only create this commit if there were actual fixes. Skip if validation passed cleanly.
