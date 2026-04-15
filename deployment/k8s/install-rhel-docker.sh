#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORTABLE_DIR="${SCRIPT_DIR}/../portable"

PROXY="http://10.201.6.100:1080"
NO_PROXY_LIST="localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.local"

export HTTP_PROXY="${PROXY}"
export HTTPS_PROXY="${PROXY}"
export http_proxy="${PROXY}"
export https_proxy="${PROXY}"
export NO_PROXY="${NO_PROXY_LIST}"
export no_proxy="${NO_PROXY_LIST}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[install]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC} $*"; }
die()  { echo -e "${RED}[error]${NC} $*"; exit 1; }

require_root() {
  [[ $EUID -eq 0 ]] || die "Run as root: sudo $0"
}

install_docker() {
  if command -v docker &>/dev/null; then
    log "Docker already installed, skipping."
    return
  fi

  log "Disabling SSL verification for dnf (TLS-intercepting proxy)..."
  echo "sslverify=false" >> /etc/dnf/dnf.conf
  echo "proxy=${PROXY}" >> /etc/dnf/dnf.conf

  log "Installing Docker..."
  dnf clean all
  dnf makecache --nogpgcheck || true

  rpm -e --nodeps openssl-fips-provider-so 2>/dev/null || true
  rpm -e --nodeps containers-common 2>/dev/null || true

  dnf update -y --allowerasing --setopt=tsflags=replacefiles \
    --exclude=openssl-fips-provider-so --nogpgcheck

  dnf install -y -q --allowerasing --nogpgcheck \
    curl ca-certificates gnupg yum-utils \
    device-mapper-persistent-data lvm2

  dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  sed -i 's/gpgcheck=1/gpgcheck=0/' /etc/yum.repos.d/docker-ce.repo

  dnf install -y --allowerasing --best --nogpgcheck --setopt=install_weak_deps=False \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable --now docker
  log "Docker installed."
}

configure_docker_proxy() {
  log "Configuring Docker daemon proxy..."
  mkdir -p /etc/systemd/system/docker.service.d
  cat > /etc/systemd/system/docker.service.d/proxy.conf <<EOF
[Service]
Environment="HTTP_PROXY=${PROXY}"
Environment="HTTPS_PROXY=${PROXY}"
Environment="NO_PROXY=${NO_PROXY_LIST}"
EOF
  systemctl daemon-reload
  systemctl restart docker
  log "Docker proxy configured."
}

configure_firewall() {
  if systemctl is-active --quiet firewalld; then
    log "Opening required ports in firewalld..."
    firewall-cmd --permanent --add-port=3000/tcp
    firewall-cmd --permanent --add-port=3010/tcp
    firewall-cmd --permanent --add-port=8080/tcp
    firewall-cmd --permanent --add-port=8081/tcp
    firewall-cmd --permanent --add-port=19071/tcp
    firewall-cmd --permanent --add-port=5432/tcp
    firewall-cmd --reload
  else
    warn "firewalld not active, skipping firewall rules."
  fi
}

pull_images() {
  log "Pulling all required Docker images..."
  for image in \
    xynehq/xyne:latest \
    vespaengine/vespa:latest \
    postgis/postgis:15-3.5-alpine \
    rancher/busybox:1.31.1; do
    log "Pulling ${image}..."
    docker pull "$image"
  done
}

setup_env() {
  log "Setting up .env file..."
  cd "${PORTABLE_DIR}"

  if [ ! -f .env ]; then
    cp .env.default .env
  fi

  HOST_IP=$(hostname -I | awk '{print $1}')

  for var in \
    "HTTP_PROXY=${PROXY}" \
    "HTTPS_PROXY=${PROXY}" \
    "http_proxy=${PROXY}" \
    "https_proxy=${PROXY}" \
    "NO_PROXY=${NO_PROXY_LIST}" \
    "no_proxy=${NO_PROXY_LIST}" \
    "DOCKER_UID=1000" \
    "DOCKER_GID=1000" \
    "NODE_ENV=production" \
    "EMBEDDING_MODEL=bge-small-en-v1.5"; do
    key="${var%%=*}"
    val="${var#*=}"
    if grep -q "^${key}=" .env 2>/dev/null; then
      sed -i "s|^${key}=.*|${key}=${val}|" .env
    else
      echo "${key}=${val}" >> .env
    fi
  done

  DOCKER_GROUP_ID=$(getent group docker | cut -d: -f3 2>/dev/null || echo "999")
  if grep -q "^DOCKER_GROUP_ID=" .env 2>/dev/null; then
    sed -i "s|^DOCKER_GROUP_ID=.*|DOCKER_GROUP_ID=${DOCKER_GROUP_ID}|" .env
  else
    echo "DOCKER_GROUP_ID=${DOCKER_GROUP_ID}" >> .env
  fi

  log "HOST_IP: ${HOST_IP}"
  log ".env configured."
}

setup_dirs() {
  log "Creating data directories..."
  cd "${PORTABLE_DIR}"
  DATA_DIR="./data"
  mkdir -p "${DATA_DIR}"/{postgres-data,vespa-data,app-uploads,app-logs,app-assets,app-migrations,app-downloads,vespa-models}
  mkdir -p "${DATA_DIR}/vespa-data/tmp"

  docker network create xyne 2>/dev/null || true
  log "Directories and network ready."
}

setup_permissions() {
  log "Setting directory permissions via busybox containers..."
  cd "${PORTABLE_DIR}"
  DATA_DIR="./data"

  for dir in postgres-data vespa-data vespa-models app-uploads app-logs app-assets app-migrations app-downloads; do
    docker run --rm \
      -v "$(pwd)/${DATA_DIR}/${dir}:/data" \
      rancher/busybox:1.31.1 chown -R 1000:1000 /data 2>/dev/null || true
  done

  log "Permissions set."
}

start_services() {
  log "Starting infrastructure + app services (CPU mode)..."
  cd "${PORTABLE_DIR}"

  cp docker-compose.app-version.yml docker-compose.app.yml
  cp docker-compose.sync-version.yml docker-compose.sync.yml

  docker compose \
    -f docker-compose.yml \
    -f docker-compose.infrastructure-cpu.yml \
    -f docker-compose.app.yml \
    -f docker-compose.sync.yml \
    up -d --force-recreate

  log "All services started."
}

print_summary() {
  HOST_IP=$(hostname -I | awk '{print $1}')
  echo ""
  log "=============================="
  log " Xyne Docker deployment done!"
  log "=============================="
  echo ""
  echo "  App:  http://${HOST_IP}:3000"
  echo ""
  echo "  SSH tunnel from laptop:"
  echo "    ssh -L 3000:${HOST_IP}:3000 <user>@<this-machine-ip> -N"
  echo "  Then open: http://localhost:3000"
  echo ""
  docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

require_root
install_docker
configure_docker_proxy
configure_firewall
pull_images
setup_env
setup_dirs
setup_permissions
start_services
print_summary
