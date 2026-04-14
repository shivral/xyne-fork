#!/usr/bin/env bash
set -euo pipefail

# --- 1. PROXY & ENVIRONMENT SETUP ---
export http_proxy="${http_proxy:-}"
export https_proxy="${https_proxy:-}"
export no_proxy="localhost,127.0.0.1,${no_proxy:-},10.96.0.0/12,10.244.0.0/16"

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
  [[ $EUID -eq 0 ]] || die "Run as root: sudo -E $0"
}

# --- 2. SYSTEM DEPENDENCIES & CONFLICT RESOLUTION ---
install_dependencies() {
  log "Fixing local hostname resolution..."
  if ! grep -q "$(hostname)" /etc/hosts; then
    echo "127.0.0.1 $(hostname)" >> /etc/hosts
  fi

  log "Handling OpenSSL FIPS provider file conflict..."
  # Resolves the 'fips.so' transaction test error from your first screenshot
  dnf remove -y openssl-fips-provider-so --allowerasing || true
  rpm -e --nodeps openssl-fips-provider-so 2>/dev/null || true

  log "Updating dnf and installing base utilities..."
  dnf clean all && dnf makecache
  dnf update -y --allowerasing --setopt=tsflags=replacefiles
  dnf install -y -q --allowerasing --setopt=tsflags=replacefiles \
    curl ca-certificates gnupg socat conntrack ipset iproute-tc yum-utils device-mapper-persistent-data lvm2

  log "Installing Docker & Containerd..."
  dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  dnf install -y --allowerasing --best --setopt=install_weak_deps=False --setopt=tsflags=replacefiles \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  log "Configuring Systemd Proxy for Containerd..."
  mkdir -p /etc/systemd/system/containerd.service.d
  cat <<EOF > /etc/systemd/system/containerd.service.d/http-proxy.conf
[Service]
Environment="HTTP_PROXY=${http_proxy}"
Environment="HTTPS_PROXY=${https_proxy}"
Environment="NO_PROXY=localhost,127.0.0.1,${HOST_IP},10.96.0.0/12,10.244.0.0/16,$(hostname)"
EOF

  log "Applying Containerd configuration with TLS Bypass path..."
  mkdir -p /etc/containerd
  containerd config default > /etc/containerd/config.toml
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  # Point to certs directory for SSL/x509 bypass
  sed -i 's|config_path = ""|config_path = "/etc/containerd/certs.d"|' /etc/containerd/config.toml

  log "Creating Registry SSL overrides (Fixes x509 Unknown Authority)..."
  # Override for Kubernetes Registry
  mkdir -p /etc/containerd/certs.d/registry.k8s.io
  cat <<EOF > /etc/containerd/certs.d/registry.k8s.io/hosts.toml
server = "https://registry.k8s.io"
[host."https://registry.k8s.io"]
  skip_verify = true
EOF

  # Override for Docker Hub
  mkdir -p /etc/containerd/certs.d/docker.io
  cat <<EOF > /etc/containerd/certs.d/docker.io/hosts.toml
server = "https://registry-1.docker.io"
[host."https://registry-1.docker.io"]
  skip_verify = true
EOF

  systemctl daemon-reload
  systemctl enable --now containerd
  systemctl restart containerd
}

# --- 3. KUBERNETES INSTALLATION ---
install_kubeadm() {
  log "Installing K8s binaries (v1.29) with SSL/GPG bypass..."
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
  
  dnf install -y -q --allowerasing 'dnf-command(versionlock)' || true
  dnf versionlock add kubelet kubeadm kubectl

  swapoff -a
  sed -i '/swap/d' /etc/fstab

  cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
  modprobe overlay && modprobe br_netfilter

  cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
  sysctl --system -q

  setenforce 0 2>/dev/null || true
  sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config
  systemctl enable --now kubelet
}

# --- 4. CLUSTER INITIALIZATION ---
init_cluster() {
  log "Pre-pulling images with TLS bypass active..."
  # If this succeeds, the x509 error is resolved
  kubeadm config images pull --cri-socket=unix:///run/containerd/containerd.sock

  log "Initializing Cluster at ${HOST_IP}..."
  kubeadm init \
    --pod-network-cidr=10.244.0.0/16 \
    --apiserver-advertise-address="${HOST_IP}" \
    --cri-socket=unix:///run/containerd/containerd.sock

  mkdir -p "$HOME/.kube"
  cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
  chown "$(id -u):$(id -g)" "$HOME/.kube/config"

  log "Untainting control-plane..."
  kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true
}

# --- 5. NETWORKING & STORAGE ---
install_cni() {
  log "Installing Flannel CNI..."
  # -k bypasses curl SSL issues
  curl -sSL -k https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml | kubectl apply -f -
  log "Waiting for Node Ready..."
  kubectl wait --for=condition=Ready node --all --timeout=120s
}

install_helm() {
  log "Installing Helm 3..."
  curl -fsSL -k https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash || true
  export PATH="/usr/local/bin:$PATH"
}

install_local_path_provisioner() {
  log "Installing local-path storage provisioner..."
  kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.26/deploy/local-path-storage.yaml
  kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
}

# --- 6. VESPA & ISTIO ---
start_vespa() {
  log "Starting Vespa container..."
  if docker ps --format '{{.Names}}' | grep -q '^vespa$'; then
    log "Vespa already running."
  else
    docker run -d --name vespa --hostname vespa-container --restart always \
      -p 8080:8080 -p 8081:8081 -p 19071:19071 vespaengine/vespa
  fi
}

install_istio() {
  log "Installing Istio via Helm..."
  helm repo add istio https://istio-release.storage.googleapis.com/charts 2>/dev/null || true
  helm repo update

  kubectl apply -f "${SCRIPT_DIR}/namespaces/namespaces.yaml"

  helm upgrade --install istio-base istio/base -n istio-system -f "${SCRIPT_DIR}/helm/istio-base-values.yaml" --wait
  helm upgrade --install istiod istio/istiod -n istio-system -f "${SCRIPT_DIR}/helm/istiod-values.yaml" --wait

  kubectl label namespace istio-system istio-injection=enabled --overwrite

  helm upgrade --install istio-ingress istio/gateway -n istio-system -f "${SCRIPT_DIR}/helm/istio-ingress-values.yaml" --wait --timeout=120s || true
}

# --- 7. APP DEPLOYMENT (XYNE) ---
install_xyne() {
  log "Deploying Xyne Namespace components..."
  kubectl apply -f "${SCRIPT_DIR}/xyne/configmap.yaml"
  kubectl apply -f "${SCRIPT_DIR}/xyne/secrets.yaml"

  log "Patching Vespa service with Host IP..."
  sed "s/HOST_IP_PLACEHOLDER/${HOST_IP}/g" "${SCRIPT_DIR}/xyne/vespa-external-service.yaml" | kubectl apply -f -
  
  kubectl apply -f "${SCRIPT_DIR}/xyne/db-statefulset.yaml"
  kubectl rollout status statefulset/xyne-db -n xyne --timeout=180s

  kubectl apply -f "${SCRIPT_DIR}/istio/destination-rules.yaml"
  kubectl apply -f "${SCRIPT_DIR}/xyne/app-deployment.yaml"
  kubectl apply -f "${SCRIPT_DIR}/xyne/app-sync-deployment.yaml"
}

install_istio_routing() {
  log "Applying Mesh Routing policies..."
  kubectl apply -f "${SCRIPT_DIR}/istio/gateway.yaml"
  kubectl apply -f "${SCRIPT_DIR}/istio/virtual-services.yaml"
  kubectl apply -f "${SCRIPT_DIR}/istio/peer-authentication.yaml"
  kubectl apply -f "${SCRIPT_DIR}/istio/envoy-filters.yaml"
}

# --- 8. SUMMARY ---
print_summary() {
  INGRESS_PORT=$(kubectl get svc istio-ingress -n istio-system -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}' 2>/dev/null || echo "30080")
  echo ""
  log "=========================================="
  log "  DEPLOYMENT COMPLETE"
  log "  Endpoint: http://${HOST_IP}:${INGRESS_PORT}/"
  log "=========================================="
}

# --- EXECUTION FLOW ---
require_root
install_dependencies
install_kubeadm
init_cluster
install_cni
install_helm
install_local_path_provisioner
start_vespa
install_istio
install_xyne
install_istio_routing
print_summary