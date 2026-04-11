#!/usr/bin/env bash
set -euo pipefail

echo "=== Matrix Server VPS Provisioning ==="

# Use sudo if not root
SUDO=""
if [[ "$(id -u)" -ne 0 ]]; then
    SUDO="sudo"
fi

# Update system
echo "Updating packages..."
$SUDO apt-get update -qq
$SUDO apt-get upgrade -y -qq

# Install prerequisites
$SUDO apt-get install -y -qq curl gnupg lsb-release ufw openssl gettext-base qrencode

# Install Docker if not present
if ! command -v docker &> /dev/null; then
    echo "Installing Docker..."
    curl -fsSL https://get.docker.com | $SUDO sh
fi

# Ensure Docker starts on boot
$SUDO systemctl enable docker
$SUDO systemctl start docker

# Add current user to docker group (so docker works without sudo)
if ! groups | grep -q docker; then
    $SUDO usermod -aG docker "$USER"
    echo "Added $USER to docker group. May need re-login for group to take effect."
fi

# Install yq
if ! command -v yq &> /dev/null; then
    echo "Installing yq..."
    YQ_VERSION="v4.44.1"
    ARCH=$(dpkg --print-architecture)
    curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${ARCH}" -o /tmp/yq
    $SUDO mv /tmp/yq /usr/local/bin/yq
    $SUDO chmod +x /usr/local/bin/yq
fi

# Install MinIO client (mc) for S3 operations
if ! command -v mc &> /dev/null; then
    echo "Installing MinIO client..."
    ARCH=$(dpkg --print-architecture)
    curl -fsSL "https://dl.min.io/client/mc/release/linux-${ARCH}/mc" -o /tmp/mc
    $SUDO mv /tmp/mc /usr/local/bin/mc
    $SUDO chmod +x /usr/local/bin/mc
fi

# Configure UFW firewall
echo "Configuring firewall..."
$SUDO ufw --force reset
$SUDO ufw default deny incoming
$SUDO ufw default allow outgoing

$SUDO ufw allow 22/tcp        # SSH
$SUDO ufw allow 80/tcp        # HTTP
$SUDO ufw allow 443/tcp       # HTTPS
$SUDO ufw allow 443/udp       # HTTP/3 (QUIC)
$SUDO ufw allow 3478/udp      # STUN/TURN
$SUDO ufw allow 3478/tcp      # TURN TCP
$SUDO ufw allow 7880/tcp      # LiveKit WebSocket
$SUDO ufw allow 7881/tcp      # LiveKit WebRTC TCP
$SUDO ufw allow 50000:50200/udp  # LiveKit RTC UDP

# coturn media relay ports from config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
if [[ -f "${PROJECT_DIR}/.env" ]]; then
    # shellcheck source=/dev/null
    source "${PROJECT_DIR}/.env"
    $SUDO ufw allow "${COTURN_MIN_PORT}:${COTURN_MAX_PORT}/udp"
fi

$SUDO ufw --force enable

# Create deploy directory structure
DEPLOY_DIR="${PROJECT_DIR}"
mkdir -p "${DEPLOY_DIR}/configs/caddy"
mkdir -p "${DEPLOY_DIR}/configs/synapse"
mkdir -p "${DEPLOY_DIR}/configs/element"
mkdir -p "${DEPLOY_DIR}/configs/livekit"
mkdir -p "${DEPLOY_DIR}/configs/coturn"

echo "=== Provisioning complete ==="
