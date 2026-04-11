# Invite Mechanism Design

## Overview

Allow admins to generate invite links so new users can register and set their own passwords. Uses Synapse's native registration token API — no custom UI.

## Flow

1. Admin runs `./deploy.sh --invite` (optionally `--uses N`, `--expires DURATION`)
2. Script calls Synapse's admin API to create a registration token
3. Outputs invite link: `https://element.<domain>/#/register?registrationToken=TOKEN`
4. Admin sends link to invitee
5. User opens link, Element Web shows registration form with token pre-filled
6. User picks username + password, registers, logged in immediately

## CLI

```bash
./deploy.sh --invite                          # Single-use, expires in 24h
./deploy.sh --invite --uses 5                 # 5 uses, expires in 24h
./deploy.sh --invite --uses 5 --expires 48h   # 5 uses, expires in 48 hours
```

## Defaults

- **Uses:** 1 (single-use)
- **Expiry:** 24 hours

## Changes

### configs/synapse/homeserver.yaml.template

Replace `enable_registration: false` with:

```yaml
enable_registration: true
registration_requires_token: true
```

Registration is open but gated by tokens. Without a valid token, registration is rejected.

### scripts/create-invite.sh (new)

Runs on the VPS. Calls Synapse's admin API:

- **Endpoint:** `POST /_synapse/admin/v1/registration_tokens/new`
- **Auth:** Requires admin access token (obtained via shared registration secret or existing admin user)
- **Payload:** `{"uses_allowed": N, "expiry_time": UNIX_TIMESTAMP}`
- **Auth method:** Use shared registration secret to create a temporary admin token, or call the API from inside the Synapse container using the admin API with the shared secret

The script reuses the existing admin user creation flow from `create-user.sh`:
1. Register a temporary admin user via the nonce-based registration endpoint (using `SYNAPSE_REGISTRATION_SHARED_SECRET`)
2. Log in as the admin to get an access token
3. Call `/_synapse/admin/v1/registration_tokens/new` with the access token
4. Output the invite link
5. All curl calls run inside the Synapse container (same pattern as `create-user.sh`)

The admin user is created once and reused across invocations. Username: `_invite_admin` (prefixed with underscore to indicate it's a system account).

### deploy.sh

Add `--invite`, `--uses`, `--expires` flags:

```bash
--invite              Generate an invite link
--uses N              Number of registrations allowed (default: 1)
--expires DURATION    Token expiry. Supports: Nh (hours), Nd (days). Default: 24h
```

These delegate to `scripts/create-invite.sh` over SSH.

## Compatibility

- Existing `--create-user` continues to work for direct admin account creation
- Both mechanisms coexist: admin-created accounts + self-registration via token
