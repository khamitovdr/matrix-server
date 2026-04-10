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
    # shellcheck source=/dev/null
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
