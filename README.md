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
| **chisel** | Reverse tunnel carrying the homeserver's Navidrome |

## Prerequisites

- A VPS running Ubuntu 24.04 with SSH access
- A domain with DNS records pointing to the VPS
- S3-compatible storage (Yandex Object Storage) — two buckets: media + backups
- `yq` installed locally (`brew install yq` on macOS)
- If your network cannot open `:22` to the VPS, set `vps.ssh_jump` in
  `config.yaml` to a host that can reach it

## DNS Records

Create A records pointing to your VPS IP:

```
matrix.example.com  → VPS_IP
element.example.com → VPS_IP
livekit.example.com → VPS_IP
turn.example.com    → VPS_IP
admin.example.com   → VPS_IP
example.com         → VPS_IP
music.example.com   → VPS_IP
tunnel.example.com  → VPS_IP
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
./deploy.sh --tunnel-secret            # Print the Navidrome tunnel credential
./deploy.sh --ssh-secret               # Print the homeserver SSH tunnel credentials
./deploy.sh --logs chisel              # Also the homeserver SSH tunnel

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

## Tunnels from the homeserver

The homeserver in the flat runs Navidrome and has no public address. It dials
out to the `chisel` service here over `wss://tunnel.<domain>` and hands over
Navidrome's port; Caddy serves it at `https://music.<domain>`.

Nothing new is open on the firewall — the control channel rides the same 443
as everything else, and chisel's own listener is unpublished, reachable only
from `matrix-net`.

The homeserver half lives in the `music` repo (`deploy/`). Its design is
`docs/superpowers/specs/2026-08-29-navidrome-tunnel-design.md` there.

```bash
./deploy.sh --tunnel-secret     # print the credential for the music repo
./deploy.sh --logs chisel       # who connected, and any ACL denials
```

**Rotating the credential:** delete the `CHISEL_AUTH_PASS=` line from `.env`
on the VPS, run `./deploy.sh --deploy`, then `--tunnel-secret`, and paste the
new line into the music repo's `deploy/.env` and redeploy there. The tunnel is
down in between.

**If `music.<domain>` shows "the library is offline":** the homeserver is not
connected. That is the intended page, not a Caddy fault — check the homeserver
before looking here.

### The homeserver's SSH

The same chisel server carries the homeserver's `sshd`, dialled in at
`https://music.<domain>/__tunnel/ssh`. `ssh homeserver` from a laptop
anywhere lands on the machine in the flat; nothing new is open on the
firewall and nothing at home listens.

Three chisel users, one anchored pattern each: `navidrome-tunnel` opens
Navidrome's listener, `ssh-tunnel` opens the SSH one, and `ssh-client` — the
credential that travels — may only dial it. `ssh-client`'s pattern has no
`R:` prefix, which is what stops it claiming a listener of its own.

The SSH listener binds the chisel container's **loopback**, unlike
Navidrome's `0.0.0.0`: Caddy has to reach Navidrome's, and nothing outside
chisel ever reaches this one, so no other container on `matrix-net` can open
a connection to the homeserver's `sshd`.

```bash
./deploy.sh --ssh-secret        # credentials + the ~/.ssh/config block
```

**Rotating:** delete `SSH_TUNNEL_PASS=` and/or `SSH_CLIENT_PASS=` from `.env`
on the VPS, `./deploy.sh --deploy`, then `--ssh-secret`, and paste into the
music repo's `deploy/.env`. Rotating `SSH_CLIENT_PASS` alone is the cheap
move when a laptop goes missing — it does not touch the homeserver's leg.

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
| `https://music.<domain>` | Navidrome player, tunnelled from the homeserver (+ /__tunnel/ssh dial-in) |
| `https://tunnel.<domain>` | chisel control channel (WebSocket only; 404s otherwise) |
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

The server includes [mautrix-telegram](https://docs.mau.fi/bridges/go/telegram/) for bridging Telegram chats into Matrix. Each user logs in with their own Telegram account (puppet mode).

Chats are **not bridged automatically** — users choose which Telegram chats to bring into Matrix.

### Server Setup

1. Get API credentials from [my.telegram.org/apps](https://my.telegram.org/apps)
2. Add to `config.yaml`:
   ```yaml
   telegram:
     api_id: "12345678"
     api_hash: "abcdef1234567890abcdef1234567890"
     admin_user: your_matrix_username
   ```
3. Deploy: `./deploy.sh --deploy`

### User Guide

#### 1. Log in

Start a DM with `@telegrambot:<domain>` in Element, then:

```
login phone +79001234567
```

The bot will send a verification code to your Telegram app. Enter it when prompted. If you have 2FA enabled, you'll be asked for your password too.

Alternatively, use QR code login:

```
login qr
```

Then scan the QR code in Telegram app (Settings → Devices → Link Desktop Device).

#### 2. Bridge a chat

Chats are not mirrored automatically. To bridge a specific Telegram chat:

**Step 1** — Find the chat ID in Telegram. Open the chat in [Telegram Web](https://web.telegram.org), the URL will look like `web.telegram.org/a/#-1001878356647`. The number after `#` is the chat ID.

**Step 2** — Convert the ID to bridge format:

| Chat type | Telegram URL ID | Bridge format |
|---|---|---|
| Channel / Supergroup | `-100` + number (e.g. `-1001878356647`) | `channel:` + number without `-100` (e.g. `channel:1878356647`) |
| Basic group | `-` + number (e.g. `-5085993104`) | `chat:` + number without `-` (e.g. `chat:5085993104`) |
| Direct message | positive number (e.g. `141732486`) | `user:` + number (e.g. `user:141732486`) |

**Step 3** — Add the chat to your allow list and create the portal:

```
filter allow -1001878356647
create-portal channel:1878356647
```

A new Matrix room will appear for this Telegram chat.

#### 3. Manage bridged chats

All commands are sent as DMs to `@telegrambot:<domain>`:

| Command | Description |
|---|---|
| `help` | Show all available commands |
| `login phone <number>` | Log in with phone number |
| `login qr` | Log in with QR code |
| `logout <login ID>` | Disconnect from Telegram |
| `filter allow <chat ID>` | Allow bridging a specific chat |
| `create-portal <bridge format ID>` | Create a Matrix room for a Telegram chat |
| `sync-chats` | Re-sync chat list from Telegram |
| `list-logins` | Show your connected Telegram accounts |

To stop bridging a chat, open the bridged Matrix room and send:

```
!tg unbridge
```

### Permissions

- **Bridge admin** (`telegram.admin_user`): Full bridge control, can manage all portals
- **Server users**: Can log in and bridge their own chats
- **External users**: No access (bridge is private to your server)
