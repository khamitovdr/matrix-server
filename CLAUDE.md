# CLAUDE.md

## Pitfalls learned the hard way

- **Synapse usernames** cannot start with `_` (use `invite-admin` not `_invite_admin`)
- **Synapse requires `report_stats`** field in homeserver.yaml or it won't start
- **Synapse `/sync` returns 500** for appservice users — bridge encryption must use `appservice: true` mode (MSC3202), never `/sync` polling
- **Synapse `deactivate` with `erase: true`** deletes the profile row but reactivation doesn't recreate it — set `displayname` in the reactivate PUT to avoid a crash when user tries to change their display name
- **Docker Compose `.env` files** don't support quoted values — quotes become part of the value. Don't quote values with spaces either; instead, don't put values with spaces in `.env` (cron expressions are read from config.yaml directly)
- **mautrix-telegram Go bridge** config format uses `network:` not `telegram:`, `database:` not `appservice.database:`. Using Python-era format triggers "legacy migration" which resets encryption settings to defaults. Always use the Go native format.
- **mautrix-telegram** must be started with `-n` flag to prevent config overwriting, and config mounted at `/config/config.yaml` (not `/data/config.yaml` which the bridge owns)
- **mautrix-telegram data dir** is owned by uid 1337 — needs `sudo` for file operations
- **Synapse data dir** is owned by uid 991 — needs `sudo chown` after creation
- **Caddy** doesn't auto-reload bind-mounted Caddyfile — must run `caddy reload` after deploy
- **coturn** needs `network_mode: host` for proper NAT traversal
- **Element Web** does not auto-fill registration tokens from URL parameters
- **Yandex Object Storage** does not require a region field

## Deploy flow ordering

1. Copy files to VPS
2. Generate .env (needs yq — provision must run first on fresh VPS)
3. Render templates (needs .env)
4. Start postgres first, wait for healthy
5. Create bridge DB if missing (needs running postgres)
6. Start all services
7. Reload Caddy config
