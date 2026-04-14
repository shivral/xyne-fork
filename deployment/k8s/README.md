# Xyne Kubernetes Installation

Quick installation scripts for deploying Xyne on Kubernetes single-node clusters.

## Supported Operating Systems

- **Ubuntu/Debian** - `install.sh`
- **RHEL/CentOS/Rocky Linux** - `install-rhel.sh`

## Prerequisites

- Fresh VM or machine (tested on Ubuntu 24.04 and RHEL 9)
- Minimum 4 CPU cores, 8GB RAM
- Root access (`sudo`)
- Internet connectivity

## Installation Methods

### Method 1: Quick Install (Recommended)

Download and run the installer script directly:

#### Ubuntu/Debian

```bash
curl -fsSL https://raw.githubusercontent.com/shivral/xyne-fork/feature/deploy-xyne-k8s-clean/deployment/k8s/install.sh -o install.sh
chmod +x install.sh
sudo ./install.sh
```

#### RHEL/CentOS/Rocky Linux

```bash
curl -fsSL https://raw.githubusercontent.com/shivral/xyne-fork/feature/deploy-xyne-k8s-clean/deployment/k8s/install-rhel.sh -o install-rhel.sh
chmod +x install-rhel.sh
sudo ./install-rhel.sh
```

### Method 2: GCP VM Creation + Installation

Use the automated VM creation scripts to spin up a GCP instance and install Xyne:

#### Ubuntu

```bash
./create-and-install.sh
```

#### RHEL

```bash
./create-and-install-rhel.sh
```

## Configuration

### Required Secrets

Before deployment completes, you'll be prompted to configure these secrets:

1. **GOOGLE_CLIENT_ID** - OAuth client ID for Google Workspace integration
2. **GOOGLE_CLIENT_SECRET** - OAuth client secret
3. **LITELLM_API_KEY** - API key for LiteLLM service

The installer will pause and open a text editor (nano for Ubuntu, vi for RHEL) for you to enter these values.

### How to Get Secrets

**Google OAuth Credentials:**
1. Go to [Google Cloud Console](https://console.cloud.google.com/)
2. Create OAuth 2.0 credentials
3. Follow [Xyne's Service Account integration guide](https://docs.xynehq.com/authentication/service-accounts)

**LiteLLM API Key:**
- Configure according to your LLM provider (OpenAI, Anthropic, etc.)
- See [LiteLLM documentation](https://docs.litellm.ai/)

### Updating Secrets After Installation

If you need to change secrets after deployment:

```bash
# Edit the configmap
vi /tmp/xyne-k8s-manifests/xyne/configmap.yaml

# Apply changes
kubectl apply -f /tmp/xyne-k8s-manifests/xyne/configmap.yaml

# Restart the application
kubectl rollout restart deployment/xyne-app -n xyne
```

## What Gets Installed

The installation script performs the following:

1. **System Dependencies** - curl, ca-certificates, Docker, containerd
2. **Kubernetes 1.29** - kubeadm, kubelet, kubectl
3. **Flannel CNI** - Pod networking
4. **Helm 3** - Package manager
5. **Local Path Provisioner** - Storage class
6. **Istio Service Mesh** - Ingress gateway, mutual TLS
7. **Vespa** - Vector database (Docker container on host)
8. **PostgreSQL** - Database (StatefulSet)
9. **Xyne Application** - Main app and sync worker

## Post-Installation

After successful installation, you'll see output like:

```
==============================
 Xyne K8s deployment complete!
==============================

  App endpoint (on this machine):  http://10.0.0.31:30080/

  For local access from your laptop, run:
    ssh -L 3000:10.0.0.31:30080 <user>@<this-machine-ip> -N
  Then open: http://localhost:3000
```

### Accessing the Application

**From the VM:**
```bash
curl http://localhost:30080
```

**From your laptop (via SSH tunnel):**
```bash
ssh -L 3000:<VM-INTERNAL-IP>:30080 <user>@<VM-EXTERNAL-IP> -N
# Then open http://localhost:3000 in your browser
```

### Verifying Installation

Check all pods are running:
```bash
kubectl get pods -A
```

Check Xyne app logs:
```bash
kubectl logs -n xyne -l app=xyne-app -c xyne-app -f
```

Check Vespa health:
```bash
curl http://localhost:8080/state/v1/health
```

## Troubleshooting

### Pods Not Starting

```bash
kubectl get pods -A
kubectl describe pod <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace>
```

### Istio Ingress Issues

```bash
kubectl get svc istio-ingress -n istio-system
kubectl logs -n istio-system -l app=istio-ingress
```

### Vespa Connection Errors

```bash
docker logs vespa
docker ps | grep vespa
```

### RHEL Package Conflicts

If you encounter package conflicts on RHEL, the `--allowerasing` flag is already included in the script to handle conflicting preinstalled packages.

## Architecture

```
┌─────────────────────────────────────────┐
│         Istio Ingress Gateway           │
│            (NodePort 30080)             │
└──────────────┬──────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────┐
│         Xyne Application Pods           │
│  ┌──────────────┐  ┌─────────────────┐ │
│  │  xyne-app    │  │ xyne-app-sync   │ │
│  └──────────────┘  └─────────────────┘ │
└───┬──────────────────────────┬──────────┘
    │                          │
    ▼                          ▼
┌─────────────┐        ┌──────────────────┐
│ PostgreSQL  │        │ Vespa (on host)  │
│ StatefulSet │        │   Docker         │
└─────────────┘        └──────────────────┘
```

## Cleanup

To completely remove the Xyne installation:

```bash
# Delete Kubernetes resources
kubectl delete namespace xyne
kubectl delete namespace istio-system

# Stop Vespa
docker stop vespa
docker rm vespa

# Reset Kubernetes cluster (optional - removes everything)
sudo kubeadm reset -f
```

## Support

- **Documentation**: https://docs.xynehq.com
- **Slack Community**: [Join Xyne Slack](https://join.slack.com/t/xynerds/shared_invite/zt-34w0oz03a-BkG~YzkkSZ~T8PzoZti7lA)
- **GitHub Issues**: https://github.com/xynehq/xyne/issues

## License

Apache 2.0 - See [LICENSE](../../LICENSE) for details.
