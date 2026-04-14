#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST_IP=$(hostname -I | awk '{print $1}')

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[install]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC} $*"; }
die()  { echo -e "${RED}[error]${NC} $*"; exit 1; }

require_root() {
  [[ $EUID -eq 0 ]] || die "Run as root: sudo -E $0 (use -E to preserve proxy settings)"
}

install_dependencies() {
  log "Installing system dependencies..."
  
  # FIX: Aggressively remove the specific package causing the 'fips.so' conflict
  log "Resolving OpenSSL FIPS provider conflicts..."
  dnf remove -y openssl-fips-provider-so --allowerasing || true
  rpm -e --nodeps openssl-fips-provider-so 2>/dev/null || true

  log "Cleaning dnf cache..."
  dnf clean all
  rm -rf /var/cache/dnf
  dnf makecache
  
  log "Removing other conflicting packages before update..."
  rpm -e --nodeps containers-common 2>/dev/null || true
  
  # FIX: Using 'replacefiles' to force overwrite any remaining shared library locks
  log "Updating system packages..."
  dnf update -y --allowerasing --setopt=tsflags=replacefiles
  
  log "Installing core utilities..."
  dnf install -y -q --allowerasing --setopt=tsflags=replacefiles \
    curl \
    ca-certificates \
    gnupg \
    socat \
    conntrack \
    ipset \
    iproute-tc \
    yum-utils \
    device-mapper-persistent-data \
    lvm2

  log "Installing Docker..."
  # Ensure proxy settings are used for adding the repo
  dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  
  dnf install -y --allowerasing --best --setopt=install_weak_deps=False --setopt=tsflags=replacefiles \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable --now docker
  systemctl enable --now containerd

  log "Configuring containerd for kubeadm..."
  mkdir -p /etc/containerd
  containerd config default > /etc/containerd/config.toml
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  systemctl restart containerd
}

install_kubeadm() {
  log "Installing kubeadm, kubelet, kubectl (v1.29)..."
  
  # FIX: Added sslverify=0 for proxy environments
  cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.29/rpm/
enabled=1
gpgcheck=0
sslverify=0
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

  dnf install -y -q --disableexcludes=kubernetes --allowerasing --setopt=tsflags=replacefiles \
    kubelet kubeadm kubectl
  
  log "Installing dnf-plugin-versionlock..."
  dnf install -y -q --allowerasing 'dnf-command(versionlock)' || dnf install -y -q --allowerasing python3-dnf-plugin-versionlock
  
  log "Locking Kubernetes package versions..."
  dnf versionlock add kubelet kubeadm kubectl

  swapoff -a
  sed -i '/swap/d' /etc/fstab

  cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
  modprobe overlay
  modprobe br_netfilter

  cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
  sysctl --system -q

  log "Configuring firewalld for Kubernetes..."
  if systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port=6443/tcp
    firewall-cmd --permanent --add-port=2379-2380/tcp
    firewall-cmd --permanent --add-port=10250/tcp
    firewall-cmd --permanent --add-port=10251/tcp
    firewall-cmd --permanent --add-port=10252/tcp
    firewall-cmd --permanent --add-port=10255/tcp
    firewall-cmd --permanent --add-port=30000-32767/tcp
    firewall-cmd --permanent --add-masquerade
    firewall-cmd --reload
  else
    log "firewalld not active, skipping firewall rules."
  fi

  log "Disabling SELinux..."
  setenforce 0 2>/dev/null || true
  sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config

  systemctl enable --now kubelet
}

init_cluster() {
  log "Initializing kubeadm single-node cluster (IP: ${HOST_IP})..."

  kubeadm init \
    --pod-network-cidr=10.244.0.0/16 \
    --apiserver-advertise-address="${HOST_IP}" \
    --cri-socket=unix:///run/containerd/containerd.sock

  mkdir -p "$HOME/.kube"
  cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
  chown "$(id -u):$(id -g)" "$HOME/.kube/config"

  log "Removing control-plane taint..."
  kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true
}

install_cni() {
  log "Installing Flannel CNI..."
  kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

  log "Waiting for node to be Ready..."
  kubectl wait --for=condition=Ready node --all --timeout=180s
}

install_helm() {
  export PATH="/usr/local/bin:$PATH"
  
  if command -v helm &>/dev/null; then
    log "Helm already installed, skipping."
    return
  fi
  
  log "Installing Helm..."
  # Note: curl may need -k or --insecure if your proxy is doing SSL inspection
  curl -fsSL -k https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash || true
  
  if /usr/local/bin/helm version &>/dev/null; then
    log "Helm installed successfully."
  else
    die "Helm installation failed."
  fi
}

start_vespa() {
  log "Starting Vespa on host via Docker..."
  if docker ps --format '{{.Names}}' | grep -q '^vespa$'; then
    log "Vespa container already running."
  elif docker ps -a --format '{{.Names}}' | grep -q '^vespa$'; then
    docker start vespa
    log "Vespa container started (was stopped)."
  else
    docker run -d \
      --name vespa \
      --hostname vespa-container \
      --restart always \
      -p 8080:8080 \
      -p 8081:8081 \
      -p 19071:19071 \
      vespaengine/vespa
    log "Vespa container created."
  fi

  log "Waiting for Vespa (up to 120s)..."
  for i in $(seq 1 24); do
    if curl -sf "http://localhost:8080/state/v1/health" | grep -q '"code":"up"'; then
      log "Vespa is ready."
      return
    fi
    sleep 5
  done
  warn "Vespa not ready — continuing anyway."
}

install_istio() {
  log "Installing Istio..."
  helm repo add istio https://istio-release.storage.googleapis.com/charts 2>/dev/null || true
  helm repo update

  kubectl apply -f "${SCRIPT_DIR}/namespaces/namespaces.yaml"

  helm upgrade --install istio-base istio/base -n istio-system -f "${SCRIPT_DIR}/helm/istio-base-values.yaml" --wait
  helm upgrade --install istiod istio/istiod -n istio-system -f "${SCRIPT_DIR}/helm/istiod-values.yaml" --wait

  kubectl label namespace istio-system istio-injection=enabled --overwrite

  helm upgrade --install istio-ingress istio/gateway -n istio-system -f "${SCRIPT_DIR}/helm/istio-ingress-values.yaml" --wait --timeout=120s || true

  kubectl rollout restart deployment/istio-ingress -n istio-system
  kubectl rollout status deployment/istio-ingress -n istio-system --timeout=120s
}

install_local_path_provisioner() {
  log "Installing local-path storage provisioner..."
  kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.26/deploy/local-path-storage.yaml
  kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
}

install_xyne() {
  log "Applying xyne manifests..."
  kubectl apply -f "${SCRIPT_DIR}/xyne/configmap.yaml"
  kubectl apply -f "${SCRIPT_DIR}/xyne/secrets.yaml"

  sed "s/HOST_IP_PLACEHOLDER/${HOST_IP}/g" "${SCRIPT_DIR}/xyne/vespa-external-service.yaml" | kubectl apply -f -
  kubectl apply -f "${SCRIPT_DIR}/xyne/db-statefulset.yaml"

  kubectl rollout status statefulset/xyne-db -n xyne --timeout=180s

  kubectl apply -f "${SCRIPT_DIR}/istio/destination-rules.yaml"
  kubectl apply -f "${SCRIPT_DIR}/xyne/app-deployment.yaml"
  kubectl apply -f "${SCRIPT_DIR}/xyne/app-sync-deployment.yaml"

  kubectl rollout status deployment/xyne-app-sync -n xyne --timeout=300s
}

install_istio_routing() {
  log "Applying Istio routing..."
  kubectl apply -f "${SCRIPT_DIR}/istio/gateway.yaml"
  kubectl apply -f "${SCRIPT_DIR}/istio/virtual-services.yaml"
  kubectl apply -f "${SCRIPT_DIR}/istio/peer-authentication.yaml"
  kubectl apply -f "${SCRIPT_DIR}/istio/envoy-filters.yaml"
}

print_summary() {
  INGRESS_PORT=$(kubectl get svc istio-ingress -n istio-system -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}' 2>/dev/null || echo "30080")
  echo ""
  log "=============================="
  log " Deployment complete!"
  log " Endpoint: http://${HOST_IP}:${INGRESS_PORT}/"
  log "=============================="
}

# --- Execution ---
require_root
install_dependencies
install_kubeadm
init_cluster
install_cni
install_helm
install_local_path_provisioner
install_istio
start_vespa
install_xyne
install_istio_routing
print_summary