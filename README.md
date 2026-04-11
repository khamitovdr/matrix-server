# Matrix Server

Self-hosted Matrix messaging server with audio/video calling. Single `deploy.sh` command deploys everything to a VPS.

## Stack

| Service | Purpose |
|---|---|
| **Synapse** | Matrix homeserver |
| **PostgreSQL 16** | Database |
| **Element Web** | Web client |
| **LiveKit** | Audio/video calls (WebRTC SFU) |
| **lk-jwt-service** | JWT tokens for Element Call |
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
```

## Commands

```bash
./deploy.sh --provision --deploy       # First-time full setup
./deploy.sh --deploy                   # Update config and redeploy
./deploy.sh --create-user <name>       # Create user (auto-generates password)
./deploy.sh --create-user <name> --password 'pass'  # Create user with specific password
./deploy.sh --backup-now               # Trigger immediate database backup
./deploy.sh --restore                  # List available backups
./deploy.sh --restore <TIMESTAMP>      # Restore from specific backup
./deploy.sh --invite                           # Generate single-use invite link (24h expiry)
./deploy.sh --invite --uses 5 --expires 48h    # 5-use invite, expires in 48h
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

## Secrets

Auto-generated on first deploy and stored in `.env` on the VPS. Re-deploying preserves existing secrets. These are never committed to git:

- PostgreSQL password
- Synapse registration shared secret, macaroon key, form secret
- LiveKit API key/secret
- coturn auth secret

## Architecture

```
Internet → Caddy (TLS) → Synapse / Element / LiveKit
                        → coturn (host networking, direct UDP)
                        → lk-jwt-service (internal)
         Synapse → PostgreSQL (internal)
         Synapse → Yandex Object Storage (S3, media)
         backup.sh → Yandex Object Storage (S3, backups)
```

- **Federation:** Disabled (private server)
- **Registration:** Disabled (admin-only via `--create-user`)
- **Media:** Stored in S3 with local disk as hot cache; old files evicted when disk runs low
- **Backups:** PostgreSQL dumped daily to S3, configurable retention
- **Reboot resistance:** All containers `restart: unless-stopped`, Docker enabled at boot

## Subdomains

| URL | Service |
|---|---|
| `https://matrix.<domain>` | Synapse homeserver API |
| `https://element.<domain>` | Element Web client |
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
# SSH into VPS
ssh <user>@<host>

# Check service logs
cd ~/matrix-server && docker compose logs <service>
# Services: caddy, synapse, postgres, element, livekit, livekit-jwt, coturn

# Restart a single service
docker compose restart synapse

# Restart everything
docker compose down && docker compose up -d

# Check Synapse health
curl https://matrix.<domain>/_matrix/client/versions
```
