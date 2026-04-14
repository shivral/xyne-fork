#!/usr/bin/env bash
set -euo pipefail

# --- 1. PROXY & ENVIRONMENT ---
# We force these into the environment for every sub-shell
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

# --- 2. PRE-FLIGHT CONNECTIVITY CHECK ---
check_connectivity() {
  log "Testing proxy connectivity to Kubernetes registry..."
  # Use -k to ignore SSL for this check. If this fails, IT is blocking the URL.
  if ! curl -Is -k --connect-timeout 5 https://registry.k8s.io/v2/ > /dev/null; then
    die "Proxy cannot reach registry.k8s.io. Check your proxy settings or IT firewall."
  fi
  log "Connectivity test passed."
}

# --- 3. SYSTEM PREP & CONFLICTS ---
install_dependencies() {
  log "Fixing local hostname and crypto-policies..."
  if ! grep -q "$(hostname)" /etc/hosts; then
    echo "127.0.0.1 $(hostname)" >> /etc/hosts
  fi
  # Allows RHEL to accept certificates from older/corporate proxies
  update-crypto-policies --set DEFAULT:AD-SIGS || true

  log "Removing conflicting OpenSSL FIPS provider..."
  dnf remove -y openssl-fips-provider-so --allowerasing || true
  rpm -e --nodeps openssl-fips-provider-so 2>/dev/null || true

  log "Updating dnf cache and system..."
  dnf clean all && dnf makecache
  dnf update -y --allowerasing --setopt=tsflags=replacefiles
  dnf install -y -q --allowerasing --setopt=tsflags=replacefiles \
    curl ca-certificates gnupg socat conntrack ipset iproute-tc yum-utils device-mapper-persistent-data lvm2

  log "Installing Docker & Containerd..."
  dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  dnf install -y --allowerasing --setopt=tsflags=replacefiles \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  log "Setting up Containerd Systemd Proxy..."
  mkdir -p /etc/systemd/system/containerd.service.d
  cat <<EOF > /etc/systemd/system/containerd.service.d/http-proxy.conf
[Service]
Environment="HTTP_PROXY=${http_proxy}"
Environment="HTTPS_PROXY=${https_proxy}"
Environment="NO_PROXY=${no_proxy}"
EOF

  log "WRITING DEFINITIVE CONTAINERD CONFIG (FORCE TLS BYPASS)..."
  mkdir -p /etc/containerd
  # We use Version 2 syntax which is strict on indentation.
  cat <<EOF > /etc/containerd/config.toml
version = 2
[plugins]
  [plugins."io.containerd.grpc.v1.cri"]
    [plugins."io.containerd.grpc.v1.cri".containerd]
      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes]
        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
          runtime_type = "io.containerd.runc.v2"
          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
            SystemdCgroup = true
    [plugins."io.containerd.grpc.v1.cri".registry]
      [plugins."io.containerd.grpc.v1.cri".registry.configs]
        [plugins."io.containerd.grpc.v1.cri".registry.configs."registry.k8s.io".tls]
          insecure_skip_verify = true
        [plugins."io.containerd.grpc.v1.cri".registry.configs."docker.io".tls]
          insecure_skip_verify = true
EOF

  systemctl daemon-reload
  systemctl enable --now containerd
  systemctl restart containerd
}

# --- 4. KUBERNETES INSTALL ---
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

# --- 5. CLUSTER INITIALIZATION ---
init_cluster() {
  log "PRE-PULLING IMAGES (If this hangs, the Proxy is dropping the connection)..."
  kubeadm reset -f || true
  
  # We use a longer timeout and explicit socket to force the new config to load
  if ! kubeadm config images pull --cri-socket=unix:///run/containerd/containerd.sock; then
    warn "The bypass didn't work. Trying to manually pull 'pause' image as a test..."
    # Attempting to pull the most basic image via containerd's CLI directly
    crictl pull registry.k8s.io/pause:3.9 || die "CRICTL failed. IT is likely blocking HTTPS Head requests."
  fi

  log "Initializing Cluster..."
  kubeadm init \
    --pod-network-cidr=10.244.0.0/16 \
    --apiserver-advertise-address="${HOST_IP}" \
    --cri-socket=unix:///run/containerd/containerd.sock

  mkdir -p "$HOME/.kube"
  cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
  chown "$(id -u):$(id -g)" "$HOME/.kube/config"
  kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true
}

# --- 6. INFRA & APPS ---
install_cni() {
  log "Installing Flannel CNI..."
  curl -sSL -k https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml | kubectl apply -f -
  kubectl wait --for=condition=Ready node --all --timeout=120s
}

install_helm() {
  log "Installing Helm..."
  curl -fsSL -k https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash || true
}

install_local_path_provisioner() {
  log "Installing storage provisioner..."
  kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.26/deploy/local-path-storage.yaml
  kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
}

start_vespa() {
  log "Starting Vespa..."
  docker ps -a --format '{{.Names}}' | grep -q "^vespa$" && docker rm -f vespa || true
  docker run -d --name vespa --hostname vespa-container --restart always \
    -p 8080:8080 -p 8081:8081 -p 19071:19071 vespaengine/vespa
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
  log "Applying Routing Rules..."
  kubectl apply -f "${SCRIPT_DIR}/istio/gateway.yaml"
  kubectl apply -f "${SCRIPT_DIR}/istio/virtual-services.yaml"
  kubectl apply -f "${SCRIPT_DIR}/istio/peer-authentication.yaml"
  kubectl apply -f "${SCRIPT_DIR}/istio/envoy-filters.yaml"
}

# --- 7. EXECUTION ---
require_root
check_connectivity
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
log "SUCCESS! Reach app at: http://${HOST_IP}:${INGRESS_PORT}/"