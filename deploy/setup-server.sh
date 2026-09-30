#!/bin/bash
# deploy/setup-server.sh
# One-time setup of a ManageIQ Docker host (safe to re-run).
#
# Usage, on the server, from a checkout of this repo:
#   sudo bash deploy/setup-server.sh
#
# Supports Amazon Linux 2023 and Ubuntu. Optional overrides:
#   APP_DIR=/opt/manageiq  COMPOSE_VERSION=v2.x.y  sudo -E bash deploy/setup-server.sh
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/manageiq}"
COMPOSE_VERSION="${COMPOSE_VERSION:-latest}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="$(uname -m)"   # x86_64 or aarch64

log()  { echo -e "\n==> $*"; }
warn() { echo "!!  $*" >&2; }

[ "$(id -u)" -eq 0 ] || { echo "Please run as root: sudo bash $0"; exit 1; }
. /etc/os-release
log "OS: ${PRETTY_NAME}   arch: ${ARCH}   repo: ${REPO_DIR}   target: ${APP_DIR}"

# ------------------------------------------------------------------
# 1. Base packages + Docker
# ------------------------------------------------------------------
case "$ID" in
  amzn)
    log "Installing packages (dnf)"
    dnf install -y docker git openssl unzip
    ;;
  ubuntu|debian)
    log "Installing packages (apt)"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y docker.io git openssl unzip curl
    ;;
  *)
    echo "Unsupported OS: $ID (supported: Amazon Linux 2023, Ubuntu)"; exit 1 ;;
esac

log "Configuring Docker log rotation (prevents logs from filling the disk)"
if [ ! -f /etc/docker/daemon.json ]; then
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "3" }
}
JSON
else
  echo "    /etc/docker/daemon.json exists, leaving it unchanged"
fi

log "Enabling Docker service"
systemctl enable docker
systemctl restart docker

for u in ec2-user ubuntu ssm-user; do
  if id "$u" >/dev/null 2>&1; then usermod -aG docker "$u"; echo "    added $u to docker group"; fi
done

# ------------------------------------------------------------------
# 2. Docker Compose plugin
# ------------------------------------------------------------------
if docker compose version >/dev/null 2>&1; then
  log "Docker Compose already installed: $(docker compose version --short)"
else
  log "Installing Docker Compose plugin (${COMPOSE_VERSION})"
  if [ "$COMPOSE_VERSION" = "latest" ]; then
    URL="https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${ARCH}"
  else
    URL="https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-${ARCH}"
  fi
  mkdir -p /usr/local/lib/docker/cli-plugins
  curl -fsSL "$URL" -o /usr/local/lib/docker/cli-plugins/docker-compose
  chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
  docker compose version
fi

# ------------------------------------------------------------------
# 3. AWS CLI (needed by deploy.sh for ECR login)
# ------------------------------------------------------------------
if command -v aws >/dev/null 2>&1; then
  log "AWS CLI already installed: $(aws --version 2>&1)"
else
  log "Installing AWS CLI v2"
  TMP="$(mktemp -d)"
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${ARCH}.zip" -o "$TMP/awscli.zip"
  unzip -q "$TMP/awscli.zip" -d "$TMP"
  "$TMP/aws/install"
  rm -rf "$TMP"
fi

# SSM agent is preinstalled on Amazon Linux 2023 and Ubuntu AMIs; just check it.
if systemctl list-units --all | grep -q amazon-ssm-agent; then
  log "SSM agent present"
else
  warn "SSM agent not found. GitHub Actions deploys need it (preinstalled on AL2023/Ubuntu AMIs)."
fi

# ------------------------------------------------------------------
# 4. Application directory
# ------------------------------------------------------------------
log "Preparing ${APP_DIR}"
mkdir -p "${APP_DIR}/docker" "${APP_DIR}/certs"

# Files managed in the repo: always refreshed from the repo on every run
copy() {
  if [ -f "${REPO_DIR}/$1" ]; then
    install -m "$3" "${REPO_DIR}/$1" "${APP_DIR}/$2"
    echo "    updated $2"
  else
    warn "missing in repo: $1"
  fi
}
copy deploy/docker-compose.prod.yml docker-compose.yml 644
copy deploy/deploy.sh               deploy.sh          755
copy nginx.conf                     nginx.conf         644
copy docker/entrypoint.sh           docker/entrypoint.sh 755

if [ -f "${REPO_DIR}/docker/BUILD" ]; then
  copy docker/BUILD docker/BUILD 644
elif [ ! -f "${APP_DIR}/docker/BUILD" ]; then
  echo "docker" > "${APP_DIR}/docker/BUILD"
fi

# Server-only files: created once, NEVER overwritten
if [ ! -f "${APP_DIR}/.env" ]; then
  log "Creating ${APP_DIR}/.env from template (with generated secrets)"
  cp "${REPO_DIR}/deploy/.env.example" "${APP_DIR}/.env"
  sed -i "s|^SECRET_KEY_BASE=.*|SECRET_KEY_BASE=$(openssl rand -hex 64)|" "${APP_DIR}/.env"
  sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=$(openssl rand -hex 24)|"        "${APP_DIR}/.env"
  NEED_ENV_EDIT=1
else
  echo "    .env exists, leaving it unchanged"
fi
chmod 600 "${APP_DIR}/.env"

# GUID = this ManageIQ server's identity. Must exist as a FILE before
# docker compose starts (otherwise Docker creates a directory there).
if [ ! -s "${APP_DIR}/docker/GUID" ]; then
  cat /proc/sys/kernel/random/uuid > "${APP_DIR}/docker/GUID"
  log "Generated server GUID: $(cat "${APP_DIR}/docker/GUID")"
else
  echo "    GUID exists: $(cat "${APP_DIR}/docker/GUID")"
fi

if [ ! -f "${APP_DIR}/certs/manageiq.crt" ] || [ ! -f "${APP_DIR}/certs/manageiq.key" ]; then
  warn "No TLS certificate found. Creating a SELF-SIGNED one so nginx can start."
  warn "Replace certs/manageiq.crt and certs/manageiq.key with a real certificate for production."
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "${APP_DIR}/certs/manageiq.key" -out "${APP_DIR}/certs/manageiq.crt" \
    -subj "/CN=$(hostname -f 2>/dev/null || hostname)" 2>/dev/null
  chmod 600 "${APP_DIR}/certs/manageiq.key"
fi

# ------------------------------------------------------------------
# Done
# ------------------------------------------------------------------
log "Server setup complete."
echo
echo "Next steps:"
if [ "${NEED_ENV_EDIT:-0}" = 1 ]; then
  echo "  1. Edit ${APP_DIR}/.env and fill in ECR_REGISTRY, ECR_REPOSITORY, AWS_REGION, DB_USER"
else
  echo "  1. Check ${APP_DIR}/.env is correct"
fi
echo "  2. Deploy an image that exists in ECR:"
echo "       sudo ${APP_DIR}/deploy.sh <commit-sha>"