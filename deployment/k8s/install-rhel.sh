#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST_IP=$(hostname -I | awk '{print $1}')

export NO_PROXY="localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,${HOST_IP},.svc,.svc.cluster.local"
export no_proxy="${NO_PROXY}"

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

install_dependencies() {
  log "Installing system dependencies..."
  log "Cleaning dnf cache..."
  dnf clean all
  dnf makecache
  
  log "Removing conflicting packages before update..."
  rpm -e --nodeps openssl-fips-provider-so 2>/dev/null || true
  rpm -e --nodeps containers-common 2>/dev/null || true

  log "Updating system (excluding openssl-fips-provider-so to prevent file conflict)..."
  dnf update -y --allowerasing --setopt=tsflags=replacefiles \
    --exclude=openssl-fips-provider-so

  rpm -e --nodeps openssl-fips-provider-so 2>/dev/null || true
  dnf install -y -q --allowerasing \
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
  dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  
  dnf install -y --allowerasing --best --setopt=install_weak_deps=False docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable --now docker
  systemctl enable --now containerd

  log "Configuring containerd for kubeadm..."
  mkdir -p /etc/containerd
  containerd config default > /etc/containerd/config.toml
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  sed -i 's|sandbox_image = ".*"|sandbox_image = "registry.k8s.io/pause:3.10.1"|' /etc/containerd/config.toml

  systemctl restart containerd
}

prefetch_images() {
  log "Pre-fetching all Docker images before containerd is configured..."
  for image in \
    docker/desktop-kubernetes-apiserver:v1.29.0 \
    docker/desktop-kubernetes-controller-manager:v1.29.0 \
    docker/desktop-kubernetes-scheduler:v1.29.0 \
    docker/desktop-kubernetes-proxy:v1.29.0 \
    docker/desktop-kubernetes-coredns:v1.11.1 \
    docker/desktop-kubernetes-pause:3.9 \
    docker/desktop-kubernetes-pause:3.10 \
    docker/desktop-kubernetes-etcd:3.5.16-0 \
    flannel/flannel:v0.28.2 \
    flannel/flannel-cni-plugin:v1.9.0-flannel1 \
    rancher/local-path-provisioner:v0.0.26 \
    rancher/busybox:1.31.1 \
    istio/pilot:1.29.2 \
    istio/proxyv2:1.29.2 \
    istio/install-cni:1.29.2 \
    postgis/postgis:15-3.5-alpine \
    xynehq/xyne:latest \
    vespaengine/vespa \
    rancher/hardened-cni-plugins:v1.4.0-build20240122; do
    docker pull "$image"
  done
}

install_kubeadm() {
  log "Installing kubeadm, kubelet, kubectl (v1.29)..."
  
  cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.29/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.29/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

  dnf install -y -q --disableexcludes=kubernetes --allowerasing kubelet kubeadm kubectl
  
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

  log "Disabling SELinux (required for proper Kubernetes networking)..."
  setenforce 0 2>/dev/null || true
  sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config

  systemctl enable --now kubelet
}

init_cluster() {
  log "Resetting any previous kubeadm state..."
  systemctl stop kubelet 2>/dev/null || true
  kubeadm reset -f 2>/dev/null || true
  rm -rf /etc/kubernetes /var/lib/etcd /var/lib/kubelet/config.yaml
  systemctl stop kubelet 2>/dev/null || true

  log "Pre-installing CNI plugin binaries from rancher/hardened-cni-plugins (already pre-pulled)..."
  mkdir -p /opt/cni/bin
  docker run --rm \
    -v /opt/cni/bin:/host/opt/cni/bin \
    rancher/hardened-cni-plugins:v1.4.0-build20240122 \
    sh -c "cp /opt/cni/bin/* /host/opt/cni/bin/ && chmod +x /host/opt/cni/bin/*"

  log "Disabling proxy for kubelet and containerd to avoid TLS issues..."
  NO_PROXY_LIST="localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,${HOST_IP},.svc,.svc.cluster.local"

  mkdir -p /etc/systemd/system/kubelet.service.d
  cat > /etc/systemd/system/kubelet.service.d/no-proxy.conf <<EOF
[Service]
Environment="NO_PROXY=${NO_PROXY_LIST}"
Environment="no_proxy=${NO_PROXY_LIST}"
Environment="HTTP_PROXY="
Environment="HTTPS_PROXY="
Environment="http_proxy="
Environment="https_proxy="
EOF

  mkdir -p /etc/systemd/system/containerd.service.d
  cat > /etc/systemd/system/containerd.service.d/no-proxy.conf <<EOF
[Service]
Environment="NO_PROXY=${NO_PROXY_LIST}"
Environment="no_proxy=${NO_PROXY_LIST}"
Environment="HTTP_PROXY="
Environment="HTTPS_PROXY="
Environment="http_proxy="
Environment="https_proxy="
EOF

  systemctl daemon-reload
  systemctl restart containerd

  log "Initializing kubeadm single-node cluster (IP: ${HOST_IP})..."

  log "Pre-pulling kubeadm images via Docker Hub then importing into containerd..."
  declare -A IMAGES=(
    ["registry.k8s.io/kube-apiserver:v1.29.0"]="docker/desktop-kubernetes-apiserver:v1.29.0"
    ["registry.k8s.io/kube-controller-manager:v1.29.0"]="docker/desktop-kubernetes-controller-manager:v1.29.0"
    ["registry.k8s.io/kube-scheduler:v1.29.0"]="docker/desktop-kubernetes-scheduler:v1.29.0"
    ["registry.k8s.io/kube-proxy:v1.29.0"]="docker/desktop-kubernetes-proxy:v1.29.0"
    ["registry.k8s.io/coredns/coredns:v1.11.1"]="docker/desktop-kubernetes-coredns:v1.11.1"
    ["registry.k8s.io/pause:3.9"]="docker/desktop-kubernetes-pause:3.9"
    ["registry.k8s.io/pause:3.10"]="docker/desktop-kubernetes-pause:3.10"
    ["registry.k8s.io/etcd:3.5.16-0"]="docker/desktop-kubernetes-etcd:3.5.16-0"
  )
  for target in "${!IMAGES[@]}"; do
    mirror="${IMAGES[$target]}"
    docker pull "$mirror"
    docker tag "$mirror" "$target"
    docker save "$target" | ctr -n k8s.io images import --base-name "$target" -
  done

  ctr -n k8s.io images tag registry.k8s.io/pause:3.10 registry.k8s.io/pause:3.10.1 2>/dev/null || true

  log "Images now in containerd k8s.io namespace:"
  ctr -n k8s.io images ls | grep registry.k8s.io

  kubeadm init \
    --kubernetes-version=v1.29.0 \
    --pod-network-cidr=10.244.0.0/16 \
    --apiserver-advertise-address="${HOST_IP}" \
    --cri-socket=unix:///run/containerd/containerd.sock \
    --ignore-preflight-errors=SystemVerification || true

  mkdir -p "$HOME/.kube"
  cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
  chown "$(id -u):$(id -g)" "$HOME/.kube/config"

  log "Waiting for API server to be reachable..."
  for i in $(seq 1 30); do
    kubectl get nodes &>/dev/null && break
    sleep 5
  done

  log "Applying missing bootstrap resources..."
  kubeadm init phase bootstrap-token 2>/dev/null || true
  kubeadm init phase addon all \
    --kubernetes-version=v1.29.0 \
    --pod-network-cidr=10.244.0.0/16 \
    --apiserver-advertise-address="${HOST_IP}" 2>/dev/null || true

  log "Removing control-plane taint so workloads can schedule on this node..."
  kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true
}

install_cni() {
  log "Installing Flannel CNI..."

  log "Pre-pulling Flannel images via Docker then importing into containerd..."
  declare -A FLANNEL_IMAGES=(
    ["ghcr.io/flannel-io/flannel:v0.28.2"]="flannel/flannel:v0.28.2"
    ["ghcr.io/flannel-io/flannel-cni-plugin:v1.9.0-flannel1"]="flannel/flannel-cni-plugin:v1.9.0-flannel1"
  )
  for target in "${!FLANNEL_IMAGES[@]}"; do
    mirror="${FLANNEL_IMAGES[$target]}"
    docker pull "$mirror"
    docker tag "$mirror" "$target"
    docker save "$target" | ctr -n k8s.io images import --base-name "$target" -
  done

  log "Applying Flannel manifest (embedded, no network required)..."
  kubectl apply -f - <<'FLANNEL_EOF'
---
kind: Namespace
apiVersion: v1
metadata:
  name: kube-flannel
  labels:
    k8s-app: flannel
    pod-security.kubernetes.io/enforce: privileged
---
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  labels:
    k8s-app: flannel
  name: flannel
rules:
- apiGroups:
  - ""
  resources:
  - pods
  verbs:
  - get
- apiGroups:
  - ""
  resources:
  - nodes
  verbs:
  - get
  - list
  - watch
- apiGroups:
  - ""
  resources:
  - nodes/status
  verbs:
  - patch
---
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  labels:
    k8s-app: flannel
  name: flannel
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: flannel
subjects:
- kind: ServiceAccount
  name: flannel
  namespace: kube-flannel
---
apiVersion: v1
kind: ServiceAccount
metadata:
  labels:
    k8s-app: flannel
  name: flannel
  namespace: kube-flannel
---
kind: ConfigMap
apiVersion: v1
metadata:
  name: kube-flannel-cfg
  namespace: kube-flannel
  labels:
    tier: node
    k8s-app: flannel
    app: flannel
data:
  cni-conf.json: |
    {
      "name": "cbr0",
      "cniVersion": "0.3.1",
      "plugins": [
        {
          "type": "flannel",
          "delegate": {
            "hairpinMode": true,
            "isDefaultGateway": true
          }
        },
        {
          "type": "portmap",
          "capabilities": {
            "portMappings": true
          }
        }
      ]
    }
  net-conf.json: |
    {
      "Network": "10.244.0.0/16",
      "EnableNFTables": false,
      "Backend": {
        "Type": "vxlan"
      }
    }
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: kube-flannel-ds
  namespace: kube-flannel
  labels:
    tier: node
    app: flannel
    k8s-app: flannel
spec:
  selector:
    matchLabels:
      app: flannel
  template:
    metadata:
      labels:
        tier: node
        app: flannel
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: kubernetes.io/os
                operator: In
                values:
                - linux
      hostNetwork: true
      priorityClassName: system-node-critical
      tolerations:
      - operator: Exists
        effect: NoSchedule
      serviceAccountName: flannel
      initContainers:
      - name: install-cni-plugin
        image: ghcr.io/flannel-io/flannel-cni-plugin:v1.9.0-flannel1
        command:
        - cp
        args:
        - -f
        - /flannel
        - /opt/cni/bin/flannel
        volumeMounts:
        - name: cni-plugin
          mountPath: /opt/cni/bin
      - name: install-cni
        image: ghcr.io/flannel-io/flannel:v0.28.2
        command:
        - cp
        args:
        - -f
        - /etc/kube-flannel/cni-conf.json
        - /etc/cni/net.d/10-flannel.conflist
        volumeMounts:
        - name: cni
          mountPath: /etc/cni/net.d
        - name: flannel-cfg
          mountPath: /etc/kube-flannel/
      containers:
      - name: kube-flannel
        image: ghcr.io/flannel-io/flannel:v0.28.2
        command:
        - /opt/bin/flanneld
        args:
        - --ip-masq
        - --kube-subnet-mgr
        resources:
          requests:
            cpu: "100m"
            memory: "50Mi"
        securityContext:
          privileged: false
          capabilities:
            add: ["NET_ADMIN", "NET_RAW"]
        env:
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: EVENT_QUEUE_DEPTH
          value: "5000"
        - name: CONT_WHEN_CACHE_NOT_READY
          value: "false"
        volumeMounts:
        - name: run
          mountPath: /run/flannel
        - name: flannel-cfg
          mountPath: /etc/kube-flannel/
        - name: xtables-lock
          mountPath: /run/xtables.lock
      volumes:
      - name: run
        hostPath:
          path: /run/flannel
      - name: cni-plugin
        hostPath:
          path: /opt/cni/bin
      - name: cni
        hostPath:
          path: /etc/cni/net.d
      - name: flannel-cfg
        configMap:
          name: kube-flannel-cfg
      - name: xtables-lock
        hostPath:
          path: /run/xtables.lock
          type: FileOrCreate
FLANNEL_EOF

  log "Waiting for node to be Ready..."
  kubectl wait --for=condition=Ready node --all --timeout=300s
}

install_helm() {
  export PATH="/usr/local/bin:$PATH"

  if command -v helm &>/dev/null; then
    log "Helm already installed, skipping."
    return
  fi

  log "Installing Helm..."
  HELM_VERSION="v3.14.0"
  curl -fsSLk --proxy-insecure "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
    | tar -xz -C /tmp
  mv /tmp/linux-amd64/helm /usr/local/bin/helm
  chmod +x /usr/local/bin/helm

  if /usr/local/bin/helm version &>/dev/null; then
    log "Helm installed successfully: $(/usr/local/bin/helm version --short)"
  else
    die "Helm installation failed - binary not found at /usr/local/bin/helm"
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
    log "Vespa container created and started."
  fi

  log "Waiting for Vespa to be ready (up to 120s)..."
  for i in $(seq 1 24); do
    if curl -sf "http://localhost:8080/state/v1/health" | grep -q '"code":"up"'; then
      log "Vespa is ready."
      return
    fi
    sleep 5
  done
  warn "Vespa not ready after 120s — continuing anyway. Check: docker logs vespa"
}

install_istio() {
  log "Installing Istio via Helm..."
  helm repo add istio https://istio-release.storage.googleapis.com/charts \
    --insecure-skip-tls-verify 2>/dev/null || true
  helm repo update --insecure-skip-tls-verify

  ISTIO_VERSION="1.29.2"

  log "Pre-pulling Istio images via Docker then importing into containerd..."
  for image in \
    "istio/pilot:${ISTIO_VERSION}" \
    "istio/proxyv2:${ISTIO_VERSION}" \
    "istio/install-cni:${ISTIO_VERSION}"; do
    docker pull "$image"
    docker save "$image" | ctr -n k8s.io images import --base-name "docker.io/$image" -
  done

  kubectl apply -f "${SCRIPT_DIR}/namespaces/namespaces.yaml"

  helm upgrade --install istio-base istio/base \
    -n istio-system \
    --version "${ISTIO_VERSION}" \
    -f "${SCRIPT_DIR}/helm/istio-base-values.yaml" \
    --wait

  helm upgrade --install istiod istio/istiod \
    -n istio-system \
    --version "${ISTIO_VERSION}" \
    -f "${SCRIPT_DIR}/helm/istiod-values.yaml" \
    --wait

  kubectl label namespace istio-system istio-injection=enabled --overwrite

  helm upgrade --install istio-ingress istio/gateway \
    -n istio-system \
    --version "${ISTIO_VERSION}" \
    -f "${SCRIPT_DIR}/helm/istio-ingress-values.yaml" \
    --wait --timeout=120s || true

  log "Waiting for istio-ingress pod to be ready..."
  kubectl rollout restart deployment/istio-ingress -n istio-system
  kubectl rollout status deployment/istio-ingress -n istio-system --timeout=120s
}

install_local_path_provisioner() {
  log "Installing local-path storage provisioner..."

  for image in rancher/local-path-provisioner:v0.0.26; do
    docker pull "$image"
    docker save "$image" | ctr -n k8s.io images import --base-name "$image" -
  done

  docker pull rancher/busybox:1.31.1
  docker tag rancher/busybox:1.31.1 docker.io/library/busybox:latest
  docker save docker.io/library/busybox:latest | ctr -n k8s.io images import --base-name "docker.io/library/busybox:latest" -
  ctr -n k8s.io images tag docker.io/library/busybox:latest docker.io/library/busybox:latest 2>/dev/null || true

  log "Applying local-path-provisioner manifest (embedded, no network required)..."
  kubectl apply -f - <<'LOCAL_PATH_EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: local-path-storage
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: local-path-provisioner-service-account
  namespace: local-path-storage
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: local-path-provisioner-role
  namespace: local-path-storage
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch", "create", "patch", "update", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: local-path-provisioner-role
rules:
  - apiGroups: [""]
    resources: ["nodes", "persistentvolumeclaims", "configmaps", "pods", "pods/log"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["persistentvolumes"]
    verbs: ["get", "list", "watch", "create", "patch", "update", "delete"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "patch"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: local-path-provisioner-bind
  namespace: local-path-storage
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: local-path-provisioner-role
subjects:
  - kind: ServiceAccount
    name: local-path-provisioner-service-account
    namespace: local-path-storage
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: local-path-provisioner-bind
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: local-path-provisioner-role
subjects:
  - kind: ServiceAccount
    name: local-path-provisioner-service-account
    namespace: local-path-storage
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: local-path-provisioner
  namespace: local-path-storage
spec:
  replicas: 1
  selector:
    matchLabels:
      app: local-path-provisioner
  template:
    metadata:
      labels:
        app: local-path-provisioner
    spec:
      serviceAccountName: local-path-provisioner-service-account
      containers:
        - name: local-path-provisioner
          image: rancher/local-path-provisioner:v0.0.26
          imagePullPolicy: IfNotPresent
          command:
            - local-path-provisioner
            - --debug
            - start
            - --config
            - /etc/config/config.json
          volumeMounts:
            - name: config-volume
              mountPath: /etc/config/
          env:
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
      volumes:
        - name: config-volume
          configMap:
            name: local-path-config
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-path
provisioner: rancher.io/local-path
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
---
kind: ConfigMap
apiVersion: v1
metadata:
  name: local-path-config
  namespace: local-path-storage
data:
  config.json: |-
    {
            "nodePathMap":[
            {
                    "node":"DEFAULT_PATH_FOR_NON_LISTED_NODES",
                    "paths":["/opt/local-path-provisioner"]
            }
            ]
    }
  setup: |-
    #!/bin/sh
    set -eu
    mkdir -m 0777 -p "$VOL_DIR"
  teardown: |-
    #!/bin/sh
    set -eu
    rm -rf "$VOL_DIR"
  helperPod.yaml: |-
    apiVersion: v1
    kind: Pod
    metadata:
      name: helper-pod
    spec:
      priorityClassName: system-node-critical
      tolerations:
        - key: node.kubernetes.io/disk-pressure
          operator: Exists
          effect: NoSchedule
      containers:
      - name: helper-pod
        image: docker.io/library/busybox:latest
        imagePullPolicy: Never
LOCAL_PATH_EOF
  kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
  log "Waiting for local-path provisioner..."
  kubectl rollout status deployment/local-path-provisioner -n local-path-storage --timeout=60s
}

install_xyne() {
  log "Applying xyne namespace manifests..."
  kubectl apply -f "${SCRIPT_DIR}/xyne/configmap.yaml"
  kubectl apply -f "${SCRIPT_DIR}/xyne/secrets.yaml"

  log "Pre-pulling xyne application images via Docker then importing into containerd..."
  for image in \
    "postgis/postgis:15-3.5-alpine" \
    "xynehq/xyne:latest"; do
    docker pull "$image"
    docker save "$image" | ctr -n k8s.io images import --base-name "docker.io/$image" -
  done

  log "Patching Vespa Endpoints with host IP: ${HOST_IP}..."
  sed "s/HOST_IP_PLACEHOLDER/${HOST_IP}/g" \
    "${SCRIPT_DIR}/xyne/vespa-external-service.yaml" \
    | kubectl apply -f -

  kubectl apply -f "${SCRIPT_DIR}/xyne/db-statefulset.yaml"

  log "Waiting for Postgres to be ready..."
  kubectl rollout status statefulset/xyne-db -n xyne --timeout=180s

  log "Applying Istio destination rules and sidecar policy before app starts..."
  kubectl apply -f "${SCRIPT_DIR}/istio/destination-rules.yaml"

  kubectl apply -f "${SCRIPT_DIR}/xyne/app-deployment.yaml"
  kubectl apply -f "${SCRIPT_DIR}/xyne/app-sync-deployment.yaml"

  log "Waiting for xyne-app-sync to be ready..."
  kubectl rollout status deployment/xyne-app-sync -n xyne --timeout=300s

  log "xyne-app is initialising in the background (DB migrate + Vespa schema deploy on first boot)."
  log "It will be ready within ~5 min. Check: kubectl logs -n xyne -l app=xyne-app -c xyne-app -f"
}

install_istio_routing() {
  log "Applying Istio routing (Gateway, VirtualServices, DestinationRules)..."
  kubectl apply -f "${SCRIPT_DIR}/istio/gateway.yaml"
  kubectl apply -f "${SCRIPT_DIR}/istio/virtual-services.yaml"
  kubectl apply -f "${SCRIPT_DIR}/istio/peer-authentication.yaml"
  kubectl apply -f "${SCRIPT_DIR}/istio/envoy-filters.yaml"

  log "Waiting 15s for istiod to program ingress gateway..."
  sleep 15

  INGRESS_POD=$(kubectl get pod -n istio-system -l app=istio-ingress -o jsonpath='{.items[0].metadata.name}')
  LISTENERS=$(kubectl exec -n istio-system "$INGRESS_POD" -- curl -s http://localhost:15000/listeners 2>/dev/null)
  if echo "$LISTENERS" | grep -q "0.0.0.0_8080"; then
    log "Istio ingress gateway is active (listener on port 8080 confirmed)."
  else
    warn "Istio ingress listener not detected. Check: kubectl exec -n istio-system $INGRESS_POD -- curl -s http://localhost:15000/listeners"
  fi
}

print_summary() {
  INGRESS_PORT=$(kubectl get svc istio-ingress -n istio-system \
    -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}' 2>/dev/null || echo "30080")

  echo ""
  log "=============================="
  log " Xyne K8s deployment complete!"
  log "=============================="
  echo ""
  echo "  App endpoint (on this machine):  http://${HOST_IP}:${INGRESS_PORT}/"
  echo ""
  echo "  For local access from your laptop, run:"
  echo "    ssh -L 3000:${HOST_IP}:${INGRESS_PORT} <user>@<this-machine-ip> -N"
  echo "  Then open: http://localhost:3000"
  echo ""
  kubectl get pods -A --field-selector=status.phase!=Running 2>/dev/null \
    | grep -v "^NAMESPACE" \
    | grep -v "Completed" \
    && warn "Some pods are not Running — check above." || log "All pods Running."
  echo ""
  warn "Before production use — update secrets.yaml with real values:"
  warn "  kubectl apply -f ${SCRIPT_DIR}/xyne/secrets.yaml"
}

require_root
install_dependencies
prefetch_images
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
