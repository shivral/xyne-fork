#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[setup]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC} $*"; }
die()  { echo -e "${RED}[error]${NC} $*"; exit 1; }

PROJECT="${GCP_PROJECT:-xyne-spaces-sbx}"
ZONE="${GCP_ZONE:-asia-south1-b}"
VM_NAME="${VM_NAME:-xyne-k8s-test}"
MACHINE_TYPE="${MACHINE_TYPE:-custom-64-131072}"
NETWORK="${GCP_NETWORK:-xyne-spaces-sbx}"
SUBNET="${GCP_SUBNET:-xyne-spaces-sbx-gke}"
DISK_SIZE="${DISK_SIZE:-200GB}"

usage() {
  echo "Usage: $0 [options]"
  echo ""
  echo "Options:"
  echo "  --project   GCP project  (default: $PROJECT)"
  echo "  --zone      GCP zone     (default: $ZONE)"
  echo "  --name      VM name      (default: $VM_NAME)"
  echo "  --machine   Machine type (default: $MACHINE_TYPE)"
  echo "  --network   VPC network  (default: $NETWORK)"
  echo "  --subnet    Subnet       (default: $SUBNET)"
  echo "  --disk      Disk size    (default: $DISK_SIZE)"
  echo "  --delete    Delete VM after printing summary (for CI)"
  echo "  -h, --help  Show this help"
  echo ""
  echo "Environment variables override defaults (same names uppercased, e.g. GCP_PROJECT)."
}

DELETE_AFTER=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)  PROJECT="$2";      shift 2 ;;
    --zone)     ZONE="$2";         shift 2 ;;
    --name)     VM_NAME="$2";      shift 2 ;;
    --machine)  MACHINE_TYPE="$2"; shift 2 ;;
    --network)  NETWORK="$2";      shift 2 ;;
    --subnet)   SUBNET="$2";       shift 2 ;;
    --disk)     DISK_SIZE="$2";    shift 2 ;;
    --delete)   DELETE_AFTER=true; shift   ;;
    -h|--help)  usage; exit 0      ;;
    *) die "Unknown option: $1"    ;;
  esac
done

ssh() {
  gcloud compute ssh "$VM_NAME" \
    --zone="$ZONE" \
    --project="$PROJECT" \
    --tunnel-through-iap \
    --command="$1" 2>&1
}

create_vm() {
  log "Creating VM '$VM_NAME' ($MACHINE_TYPE) in $ZONE..."

  ZONES_TO_TRY=("$ZONE")
  REGION="${ZONE%-*}"
  for z in a b c; do
    candidate="${REGION}-${z}"
    [[ "$candidate" != "$ZONE" ]] && ZONES_TO_TRY+=("$candidate")
  done

  for z in "${ZONES_TO_TRY[@]}"; do
    log "Trying zone: $z"
    if gcloud compute instances create "$VM_NAME" \
        --zone="$z" \
        --project="$PROJECT" \
        --machine-type="$MACHINE_TYPE" \
        --network="$NETWORK" \
        --subnet="$SUBNET" \
        --no-address \
        --image-family=ubuntu-2204-lts \
        --image-project=ubuntu-os-cloud \
        --boot-disk-size="$DISK_SIZE" \
        --boot-disk-type=pd-ssd \
        --metadata=enable-oslogin=true \
        --no-service-account \
        --no-scopes 2>&1; then
      ZONE="$z"
      log "VM created in zone $ZONE"
      return
    else
      warn "Zone $z unavailable, trying next..."
    fi
  done

  die "Could not create VM in any zone. Try a different region with --zone."
}

wait_for_ssh() {
  log "Waiting for VM to accept SSH..."
  for i in $(seq 1 30); do
    if ssh "echo ok" 2>/dev/null | grep -q ok; then
      log "SSH ready."
      return
    fi
    sleep 5
  done
  die "VM never became SSH-accessible after 150s."
}

copy_files() {
  log "Copying deployment files to VM..."
  gcloud compute scp --recurse \
    "$SCRIPT_DIR" \
    "${VM_NAME}:/tmp/k8s" \
    --zone="$ZONE" \
    --project="$PROJECT" \
    --tunnel-through-iap 2>&1
  log "Files copied."
}

run_install() {
  log "Starting install.sh in tmux on VM (logs → /tmp/install.log)..."
  ssh "chmod +x /tmp/k8s/install.sh && tmux new-session -d -s install 'sudo bash /tmp/k8s/install.sh 2>&1 | tee /tmp/install.log; echo \"EXIT_CODE=\$?\" >> /tmp/install.log'"
  log "Install running. Tailing log (Ctrl+C safe — install continues on VM)..."
  gcloud compute ssh "$VM_NAME" \
    --zone="$ZONE" \
    --project="$PROJECT" \
    --tunnel-through-iap \
    -- "tail -f /tmp/install.log" 2>&1 || true
}

wait_for_app() {
  log "Waiting for xyne-app to be healthy (up to 10 min)..."
  VM_IP=$(gcloud compute instances describe "$VM_NAME" \
    --zone="$ZONE" \
    --project="$PROJECT" \
    --format="get(networkInterfaces[0].networkIP)" 2>/dev/null)

  for i in $(seq 1 60); do
    RESULT=$(ssh "curl -sf http://localhost:30080/health 2>/dev/null || true")
    if echo "$RESULT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    pg = d['services']['postgres']['status']
    vs = d['services']['vespa']['status']
    print(f'postgres:{pg} vespa:{vs}')
    sys.exit(0 if pg == 'healthy' and vs == 'healthy' else 1)
except: sys.exit(1)
" 2>/dev/null; then
      log "App is healthy!"
      echo ""
      log "=============================="
      log " Xyne is up and running!"
      log "=============================="
      echo ""
      echo "  VM internal IP : $VM_IP"
      echo "  VM name        : $VM_NAME  (zone: $ZONE)"
      echo ""
      echo "  To access from your Mac:"
      echo "    gcloud compute ssh $VM_NAME \\"
      echo "      --zone=$ZONE --project=$PROJECT --tunnel-through-iap \\"
      echo "      -- -L 3000:localhost:30080 -N"
      echo "    Then open: http://localhost:3000"
      echo ""
      return 0
    fi
    sleep 10
  done
  warn "App not healthy after 10 min. Check: gcloud compute ssh $VM_NAME --zone=$ZONE --project=$PROJECT --tunnel-through-iap --command 'sudo kubectl logs -n xyne -l app=xyne-app -c xyne-app --tail=30'"
  return 1
}

create_vm
wait_for_ssh
copy_files
run_install
wait_for_app

if $DELETE_AFTER; then
  warn "Deleting VM (--delete flag set)..."
  gcloud compute instances delete "$VM_NAME" --zone="$ZONE" --project="$PROJECT" --quiet
fi
