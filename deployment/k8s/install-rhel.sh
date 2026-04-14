#!/usr/bin/env bash
set -euo pipefail

# --- 1. PROXY & ENVIRONMENT ---
export http_proxy="${http_proxy:-}"
export https_proxy="${https_proxy:-}"
export no_proxy="localhost,127.0.0.1,10.96.0.0/12,10.244.0.0/16,$(hostname),$(hostname -I | tr ' ' ',')"

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

# --- 2. SYSTEM DEPENDENCIES & TRUST ---
install_dependencies() {
  log "Fixing local hostname resolution..."
  if ! grep -q "$(hostname)" /etc/hosts; then
    echo "127.0.0.1 $(hostname)" >> /etc/hosts
  fi

  log "Attempting to 'steal' and trust the proxy certificate..."
  # This grabs whatever cert the proxy is using and forces RHEL to trust it
  openssl s_client -showcerts -connect registry.k8s.io:443 </dev/null 2>/dev/null | openssl x509 -outform PEM > /tmp/proxy-ca.crt || true
  if [ -s /tmp/proxy-ca.crt ]; then
    cp /tmp/proxy-ca.crt /etc/pki/ca-trust/source/anchors/proxy-k8s-fix.crt
    update-ca-trust extract
    log "Proxy cert added to system trust."
  fi

  log "Removing conflicting OpenSSL FIPS provider..."
  dnf remove -y openssl-fips-provider-so --allowerasing || true
  rpm -e --nodeps openssl-fips-provider-so 2>/dev/null || true

  log "Updating dnf and installing base utilities..."
  dnf clean all && dnf makecache
  dnf update -y --allowerasing --setopt=tsflags=replacefiles
  dnf install -y -q --allowerasing --setopt=tsflags=replacefiles \
    curl ca-certificates gnupg socat conntrack ipset iproute-tc yum-utils device-mapper-persistent-data lvm2

  log "Installing Docker & Containerd..."
  dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  dnf install -y --allowerasing --setopt=tsflags=replacefiles \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  log "Configuring Docker to treat K8s registries as INSECURE..."
  # This bypasses the 'negative serial number' x509 error by skipping validation
  mkdir -p /etc/docker
  cat <<EOF > /etc/docker/daemon.json
{
  "insecure-registries": [
    "registry.k8s.io",
    "asia-south1-docker.pkg.dev",
    "gcr.io",
    "k8s.gcr.io"
  ],
  "exec-opts": ["native.cgroupdriver=systemd"]
}
EOF

  log "Configuring Proxy for systemd services..."
  for svc in docker containerd; do
    mkdir -p /etc/systemd/system/${svc}.service.d
    cat <<EOF > /etc/systemd/system/${svc}.service.d/http-proxy.conf
[Service]
Environment="HTTP_PROXY=${http_proxy}"
Environment="HTTPS_PROXY=${https_proxy}"
Environment="NO_PROXY=${no_proxy}"
EOF
  done

  log "Configuring Containerd (SystemdCgroup)..."
  mkdir -p /etc/containerd
  containerd config default > /etc/containerd/config.toml
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

  systemctl daemon-reload
  systemctl enable --now docker containerd
  systemctl restart docker containerd
}

# --- 3. KUBERNETES INSTALLATION ---
install_kubeadm() {
  log "Installing K8s binaries..."
  cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.29/rpm/
enabled=1
gpgcheck=0
sslverify=0
EOF

  dnf install -y -q --disableexcludes=kubernetes --allowerasing --setopt=tsflags=replacefiles \
    kubelet kubeadm kubectl
  
  swapoff -a
  sed -i '/swap/d' /etc/fstab
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

# --- 4. THE INSECURE-MULE BYPASS ---
init_cluster() {
  log "Cleaning previous attempts..."
  kubeadm reset -f || true

  log "Pulling images via INSECURE DOCKER and transferring to Containerd..."
  # Explicitly using v1.29.15 to avoid the dl.k8s.io version-check timeout
  K8S_IMAGES=$(kubeadm config images list --kubernetes-version v1.29.15)
  
  for img in $K8S_IMAGES; do
    log "Docker pulling (Insecure Mode): $img"
    if docker pull "$img"; then
        log "Sideloading $img into Containerd..."
        docker save "$img" | ctr -n k8s.io images import -
    else
        warn "Failed to pull $img. Your proxy might be blocking the domain asia-south1-docker.pkg.dev entirely."
    fi
  done

  log "Initializing Cluster (Using pre-loaded images)..."
  kubeadm init \
    --kubernetes-version=v1.29.15 \
    --pod-network-cidr=10.244.0.0/16 \
    --apiserver-advertise-address="${HOST_IP}" \
    --cri-socket=unix:///run/containerd/containerd.sock

  mkdir -p "$HOME/.kube"
  cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
  chown "$(id -u):$(id -g)" "$HOME/.kube/config"
  kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true
}

# --- 5. INFRASTRUCTURE & APPS ---
install_cni() {
  log "Installing Flannel CNI..."
  curl -sSL -k https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml | kubectl apply -f -
  kubectl wait --for=condition=Ready node --all --timeout=120s
}

install_helm() {
  log "Installing Helm..."
  curl -fsSL -k https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash || true
  export PATH="/usr/local/bin:$PATH"
}

install_local_path_provisioner() {
  log "Installing storage provisioner..."
  kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.26/deploy/local-path-storage.yaml
  kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
}

start_vespa() {
  log "Starting Vespa container..."
  docker ps -a --format '{{.Names}}' | grep -q "^vespa$" && docker rm -f vespa || true
  docker run -d --name vespa --hostname vespa-container --restart always \
    -p 8080:8080 -p 8081:8081 -p 19071:19071 vespaengine/vespa
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

install_xyne() {
  log "Deploying Xyne Stack..."
  kubectl apply -f "${SCRIPT_DIR}/xyne/configmap.yaml"
  kubectl apply -f "${SCRIPT_DIR}/xyne/secrets.yaml"
  sed "s/HOST_IP_PLACEHOLDER/${HOST_IP}/g" "${SCRIPT_DIR}/xyne/vespa-external-service.yaml" | kubectl apply -f -
  kubectl apply -f "${SCRIPT_DIR}/xyne/db-statefulset.yaml"
  kubectl rollout status statefulset/xyne-db -n xyne --timeout=180s
  kubectl apply -f "${SCRIPT_DIR}/istio/destination-rules.yaml"
  kubectl apply -f "${SCRIPT_DIR}/xyne/app-deployment.yaml"
  kubectl apply -f "${SCRIPT_DIR}/xyne/app-sync-deployment.yaml"
}

install_istio_routing() {
  log "Applying Mesh Routing..."
  kubectl apply -f "${SCRIPT_DIR}/istio/gateway.yaml"
  kubectl apply -f "${SCRIPT_DIR}/istio/virtual-services.yaml"
  kubectl apply -f "${SCRIPT_DIR}/istio/peer-authentication.yaml"
  kubectl apply -f "${SCRIPT_DIR}/istio/envoy-filters.yaml"
}

# --- EXECUTION ---
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

INGRESS_PORT=$(kubectl get svc istio-ingress -n istio-system -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}' 2>/dev/null || echo "30080")
log "SUCCESS! http://${HOST_IP}:${INGRESS_PORT}/"