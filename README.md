# Matrix Server

Self-hosted Matrix messaging server with audio/video calling. Single `deploy.sh` command deploys everything to a VPS.

## Stack

| Service | Purpose |
|---|---|
| **Synapse** | Matrix homeserver |
| **PostgreSQL 16** | Database |
| **Element Web** | Web client |
| **Synapse Admin** | Admin panel |
| **LiveKit** | Audio/video calls (WebRTC SFU) |
| **lk-jwt-service** | JWT tokens for Element Call |
| **mautrix-telegram** | Telegram bridge (puppet mode) |
| **coturn** | TURN/STUN relay for NAT traversal |
| **Caddy 2** | Reverse proxy, automatic TLS |

## Prerequisites

- A VPS running Ubuntu 24.04 with SSH access
- A domain with DNS records pointing to the VPS
- S3-compatible storage (Yandex Object Storage) — two buckets: media + backups
- `yq` installed locally (`brew install yq` on macOS)

## DNS Records

Create A records pointing to your VPS IP:

```
matrix.example.com  → VPS_IP
element.example.com → VPS_IP
livekit.example.com → VPS_IP
turn.example.com    → VPS_IP
admin.example.com   → VPS_IP
example.com         → VPS_IP
```

## Quick Start

```bash
# 1. Configure
cp config.example.yaml config.yaml
# Edit config.yaml with your domain, VPS IP, and S3 credentials

# 2. First-time setup (installs Docker, firewall, tools, then deploys)
./deploy.sh --provision --deploy

# 3. Create your first user
./deploy.sh --create-user alice

# 4. Set up announcements room (optional)
./deploy.sh --setup-welcome-room alice
```

## Commands

```bash
# Deployment
./deploy.sh --provision --deploy       # First-time full setup
./deploy.sh --deploy                   # Update config and redeploy
./deploy.sh --logs                     # All service logs (follows)
./deploy.sh --logs synapse             # Single service logs

# User management
./deploy.sh --create-user <name>       # Create user (auto-generates password)
./deploy.sh --create-user <name> --password 'pass'  # With specific password
./deploy.sh --list-users               # Show all users with metadata
./deploy.sh --delete-user <name>       # Deactivate and erase a user
./deploy.sh --reactivate-user <name>   # Reactivate a deleted user
./deploy.sh --reactivate-user <name> --password 'pass'  # With specific password

# Invitations
./deploy.sh --invite                           # Single-use invite link (24h expiry)
./deploy.sh --invite --uses 5 --expires 48h    # 5-use invite, expires in 48h

# Rooms
./deploy.sh --setup-welcome-room <admin>  # Create read-only announcements room

# Backup & restore
./deploy.sh --backup-now               # Trigger immediate database backup
./deploy.sh --restore                  # List available backups
./deploy.sh --restore <TIMESTAMP>      # Restore from specific backup
```

## Configuration

All config lives in `config.yaml` (gitignored). See `config.example.yaml` for all options.

Key settings:

| Setting | Description |
|---|---|
| `domain` | Your domain (becomes the Matrix server name) |
| `vps.host` | VPS IP address |
| `vps.user` | SSH user (supports non-root with sudo) |
| `vps.ssh_key` | Optional — omit to use default SSH key |
| `s3.media.*` | S3 bucket for media storage |
| `s3.backup.*` | S3 bucket for database backups |
| `media_cache.max_upload_size_mb` | Max file upload size (default: 100 MB) |
| `media_cache.min_free_gb` | Disk cleanup threshold (default: 30 GB) |
| `backup.cron` | Backup schedule (default: daily at 3am) |
| `backup.retention_days` | How long to keep backups (default: 14 days) |
| `telegram.api_id` | Telegram API ID from [my.telegram.org](https://my.telegram.org/apps) |
| `telegram.api_hash` | Telegram API hash |
| `telegram.admin_user` | Your Matrix username (bridge admin permissions) |

## Secrets

Auto-generated on first deploy and stored in `.env` on the VPS. Re-deploying preserves existing secrets. These are never committed to git:

- PostgreSQL password
- Synapse registration shared secret, macaroon key, form secret
- LiveKit API key/secret
- coturn auth secret
- Telegram bridge DB password, appservice tokens

## Architecture

```
Internet → Caddy (TLS) → Synapse / Element / LiveKit / Synapse Admin
                        → coturn (host networking, direct UDP)
                        → lk-jwt-service (internal)
         Synapse → PostgreSQL (internal)
         Synapse → Yandex Object Storage (S3, media)
         backup.sh → Yandex Object Storage (S3, backups)
```

- **Federation:** Disabled (private server)
- **Registration:** Token-gated (invite links via `--invite`, or direct via `--create-user`)
- **Media:** Stored in S3 with local disk as hot cache; old files evicted when disk runs low
- **Backups:** PostgreSQL dumped daily to S3, configurable retention
- **Reboot resistance:** All containers `restart: unless-stopped`, Docker enabled at boot

## Subdomains

| URL | Service |
|---|---|
| `https://matrix.<domain>` | Synapse homeserver API |
| `https://element.<domain>` | Element Web client |
| `https://admin.<domain>` | Synapse Admin panel |
| `https://livekit.<domain>` | LiveKit signaling |
| `https://livekit.<domain>/jwt` | LiveKit JWT service |
| `https://<domain>` | Redirects to Element, serves `.well-known` |

## Firewall Ports

Opened automatically by `--provision`:

| Port | Protocol | Service |
|---|---|---|
| 22 | TCP | SSH |
| 80, 443 | TCP | Caddy (HTTP/HTTPS) |
| 443 | UDP | HTTP/3 (QUIC) |
| 3478 | TCP/UDP | coturn STUN/TURN |
| 7880 | TCP | LiveKit WebSocket |
| 7881 | TCP | LiveKit WebRTC TCP |
| 50000-50200 | UDP | LiveKit RTC |
| 49152-49200 | UDP | coturn media relay (configurable) |

## VPS File Layout

```
~/matrix-server/              # deploy_dir from config.yaml
├── .env                      # Auto-generated secrets + config values
├── config.yaml               # Copied from local machine
├── docker-compose.yml
├── Dockerfile.synapse
├── data/synapse/             # Synapse signing key + media cache
├── configs/                  # Rendered config files
│   ├── caddy/Caddyfile
│   ├── synapse/homeserver.yaml
│   ├── element/config.json
│   ├── livekit/livekit.yaml
│   └── coturn/turnserver.conf
└── scripts/                  # Operational scripts
```

## Troubleshooting

```bash
# View logs (from local machine)
./deploy.sh --logs synapse

# SSH into VPS
ssh <user>@<host>

# Check service status
cd ~/matrix-server && docker compose ps

# Restart a single service
docker compose restart synapse

# Restart everything
docker compose down && docker compose up -d

# Check Synapse health
curl https://matrix.<domain>/_matrix/client/versions
```

## Admin Panel

Web-based admin UI at `https://admin.<domain>` powered by [Synapse Admin](https://github.com/etkecc/synapse-admin). Requires a Matrix account with admin privileges.

### Making a user admin

```bash
# From the VPS (one-time, via Synapse admin API)
ssh <user>@<host>
cd ~/matrix-server && source .env
ADMIN_PASSWORD=$(echo "$SYNAPSE_REGISTRATION_SHARED_SECRET" | openssl dgst -sha256 | awk '{print $NF}')
TOKEN=$(docker compose exec -T synapse curl -s -X POST http://localhost:8008/_matrix/client/v3/login \
  -H "Content-Type: application/json" \
  -d "{\"type\":\"m.login.password\",\"identifier\":{\"type\":\"m.id.user\",\"user\":\"invite-admin\"},\"password\":\"${ADMIN_PASSWORD}\"}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
docker compose exec -T synapse curl -s -X PUT \
  "http://localhost:8008/_synapse/admin/v2/users/@USERNAME:DOMAIN" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"admin": true}'
```

Replace `USERNAME` and `DOMAIN` with actual values.

### Features

- View and manage all users (deactivate, reset passwords, admin status)
- Browse and manage rooms (delete, purge history, view members)
- View server statistics and event reports
- Manage registration tokens
- View user sessions, devices, and IP addresses

## Telegram Bridge

The server includes [mautrix-telegram](https://docs.mau.fi/bridges/python/telegram/index.html) for bridging Telegram chats into Matrix. Each user logs in with their own Telegram account (puppet mode).

### Setup

1. Get API credentials from [my.telegram.org/apps](https://my.telegram.org/apps)
2. Add to `config.yaml`:
   ```yaml
   telegram:
     api_id: "12345678"
     api_hash: "abcdef1234567890abcdef1234567890"
     admin_user: your_matrix_username
   ```
3. Deploy: `./deploy.sh --deploy`

### Usage

1. In Element, start a DM with `@telegrambot:<domain>`
2. Send `login`
3. The bot will ask for your phone number, then a Telegram verification code
4. Once logged in, your Telegram chats appear as Matrix rooms

### Bridge Commands

Send these as DMs to `@telegrambot:<domain>`:

| Command | Description |
|---|---|
| `login` | Log in to your Telegram account |
| `logout` | Disconnect Telegram |
| `ping` | Check bridge status |
| `sync` | Force-sync Telegram chats |
| `help` | Show all available commands |

### Permissions

- **Bridge admin** (`telegram.admin_user`): Full bridge control, can manage all portals
- **Server users**: Can log in and use the bridge normally
- **External users**: No access (bridge is private to your server)
