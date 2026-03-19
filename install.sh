#!/bin/bash
# ============================================================================
#  NemoClaw-Cloud Installer
#  One-script setup: Nebius GPU VM + Nemotron + NemoClaw/OpenClaw
# ============================================================================
#
#  Usage:
#    ./install.sh                    # Interactive setup
#    ./install.sh --model nano       # Use Nemotron-3-Nano-4B (fast, 8GB)
#    ./install.sh --model super      # Use Nemotron-3-Super-120B (best, 120GB)
#    ./install.sh --gpu h100         # Use H100 instead of H200
#    ./install.sh --disk 300         # Custom disk size in GB
#    ./install.sh --skip-vm          # Skip VM creation (install on current machine)
#
# ============================================================================

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
MODEL_SIZE="${MODEL_SIZE:-super}"
GPU_PLATFORM="${GPU_PLATFORM:-gpu-h200-sxm}"
GPU_PRESET="${GPU_PRESET:-1gpu-16vcpu-200gb}"
DISK_SIZE="${DISK_SIZE:-300}"
VM_NAME="${VM_NAME:-nemoclaw-vm}"
SKIP_VM=false
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_ed25519}"

# ── Model map ────────────────────────────────────────────────────────────────
declare -A MODELS=(
  [nano]="nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16"
  [nano30]="nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8"
  [super]="nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-FP8"
)

declare -A MODEL_DISK=(
  [nano]=50
  [nano30]=100
  [super]=300
)

# ── Parse args ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --model)   MODEL_SIZE="$2"; shift 2 ;;
    --gpu)
      case "$2" in
        h100) GPU_PLATFORM="gpu-h100-sxm" ;;
        h200) GPU_PLATFORM="gpu-h200-sxm" ;;
        b200) GPU_PLATFORM="gpu-b200-sxm" ;;
        l40s) GPU_PLATFORM="gpu-l40s-pcie" ;;
        *)    GPU_PLATFORM="$2" ;;
      esac
      shift 2 ;;
    --disk)    DISK_SIZE="$2"; shift 2 ;;
    --name)    VM_NAME="$2"; shift 2 ;;
    --skip-vm) SKIP_VM=true; shift ;;
    --ssh-key) SSH_KEY_PATH="$2"; shift 2 ;;
    --help|-h) echo "Usage: $0 [--model nano|nano30|super] [--gpu h100|h200|b200|l40s] [--disk GB] [--skip-vm] [--name VM_NAME]"; exit 0 ;;
    *)         echo "Unknown option: $1"; exit 1 ;;
  esac
done

MODEL_ID="${MODELS[$MODEL_SIZE]:-${MODELS[super]}}"
DISK_SIZE="${DISK_SIZE:-${MODEL_DISK[$MODEL_SIZE]:-300}}"

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[NemoClaw]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step() { echo -e "\n${CYAN}━━━ Step $1: $2 ━━━${NC}"; }

# ── Banner ───────────────────────────────────────────────────────────────────
echo -e "${BLUE}"
cat << 'BANNER'
  _   _                       ____ _
 | \ | | ___ _ __ ___   ___  / ___| | __ ___      __
 |  \| |/ _ \ '_ ` _ \ / _ \| |   | |/ _` \ \ /\ / /
 | |\  |  __/ | | | | | (_) | |___| | (_| |\ V  V /
 |_| \_|\___|_| |_| |_|\___/ \____|_|\__,_| \_/\_/
                                         Cloud ☁️
BANNER
echo -e "${NC}"
log "Model:    $MODEL_ID"
log "GPU:      $GPU_PLATFORM ($GPU_PRESET)"
log "Disk:     ${DISK_SIZE}GB"
log "VM Name:  $VM_NAME"
echo ""

# ============================================================================
#  PHASE 1: Prerequisites
# ============================================================================
step 1 "Checking prerequisites"

# Check Nebius CLI
if ! command -v nebius &>/dev/null; then
  log "Installing Nebius CLI..."
  curl -sSL https://storage.ai.nebius.cloud/nebius/install.sh | bash
  export PATH="$HOME/.nebius/bin:$PATH"
fi
log "Nebius CLI: $(nebius version 2>/dev/null | head -1 || echo 'installed')"

# Check auth
if ! nebius iam whoami &>/dev/null; then
  log "Please authenticate with Nebius..."
  nebius iam whoami  # triggers browser OAuth
fi

WHOAMI=$(nebius iam whoami 2>/dev/null | grep "email:" | awk '{print $2}' || echo "authenticated")
log "Logged in as: $WHOAMI"

# Get project and tenant
PROJECT_ID=$(nebius iam project list --format json 2>/dev/null | \
  python3 -c "import sys,json; items=json.load(sys.stdin).get('items',[]); print(items[0]['metadata']['id'] if items else '')" 2>/dev/null || echo "")

if [ -z "$PROJECT_ID" ]; then
  err "No projects found. Create one at console.nebius.com first."
fi

TENANT_ID=$(nebius iam tenant list --format json 2>/dev/null | \
  python3 -c "import sys,json; items=json.load(sys.stdin).get('items',[]); print(items[0]['metadata']['id'] if items else '')" 2>/dev/null || echo "")

log "Project: $PROJECT_ID"
log "Tenant:  $TENANT_ID"

# ============================================================================
#  PHASE 2: Create VM (unless --skip-vm)
# ============================================================================
if [ "$SKIP_VM" = false ]; then

  step 2 "Creating GPU VM on Nebius"

  # ── SSH key ──
  if [ ! -f "$SSH_KEY_PATH" ]; then
    log "Generating SSH key..."
    ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" -C "nemoclaw-vm"
  fi
  SSH_PUB=$(cat "${SSH_KEY_PATH}.pub")
  log "SSH key: ${SSH_KEY_PATH}.pub"

  # ── Boot disk ──
  log "Creating ${DISK_SIZE}GB boot disk..."
  DISK_ID=$(nebius compute disk create \
    --name "${VM_NAME}-boot" \
    --parent-id "$PROJECT_ID" \
    --type network_ssd \
    --size-gibibytes "$DISK_SIZE" \
    --block-size-bytes 4096 \
    --source-image-family-image-family ubuntu22.04-cuda12 \
    --format json 2>&1 | python3 -c "import sys,json; print(json.load(sys.stdin)['metadata']['id'])")
  log "Disk: $DISK_ID"

  # ── Subnet ──
  log "Finding subnet..."
  SUBNET_ID=$(nebius vpc subnet list --format json 2>/dev/null | \
    python3 -c "import sys,json; items=json.load(sys.stdin).get('items',[]); print(items[0]['metadata']['id'] if items else '')" 2>/dev/null || echo "")

  if [ -z "$SUBNET_ID" ]; then
    log "Creating network and subnet..."
    NET_ID=$(nebius vpc network create --name nemoclaw-net --parent-id "$PROJECT_ID" --format json | \
      python3 -c "import sys,json; print(json.load(sys.stdin)['metadata']['id'])")
    sleep 5
    SUBNET_ID=$(nebius vpc subnet create \
      --name nemoclaw-subnet \
      --parent-id "$PROJECT_ID" \
      --network-id "$NET_ID" \
      --ipv4-cidr-blocks '["10.0.0.0/24"]' \
      --format json | python3 -c "import sys,json; print(json.load(sys.stdin)['metadata']['id'])")
  fi
  log "Subnet: $SUBNET_ID"

  # ── Cloud-init ──
  CLOUD_INIT=$(cat <<CINIT
#cloud-config
users:
  - name: nemoclaw
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ${SSH_PUB}

runcmd:
  - curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  - apt-get install -y nodejs python3-pip python3-venv
  - npm install -g openclaw@2026.3.11
  - npm install -g nemoclaw
  - echo "NemoClaw installed" > /var/log/nemoclaw-install.log
CINIT
)

  # ── Create VM ──
  log "Creating VM: $VM_NAME ($GPU_PLATFORM / $GPU_PRESET)..."
  VM_RESULT=$(nebius compute instance create \
    --name "$VM_NAME" \
    --parent-id "$PROJECT_ID" \
    --resources-platform "$GPU_PLATFORM" \
    --resources-preset "$GPU_PRESET" \
    --boot-disk-attach-mode read_write \
    --boot-disk-existing-disk-id "$DISK_ID" \
    --network-interfaces "[{\"name\":\"eth0\",\"subnet_id\":\"${SUBNET_ID}\",\"ip_address\":{},\"public_ip_address\":{}}]" \
    --cloud-init-user-data "$CLOUD_INIT" \
    --format json 2>&1)

  VM_ID=$(echo "$VM_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['metadata']['id'])")
  PUBLIC_IP=$(echo "$VM_RESULT" | python3 -c "import sys,json; nets=json.load(sys.stdin)['status'].get('network_interfaces',[]); print(nets[0]['public_ip_address']['address'].split('/')[0] if nets and nets[0].get('public_ip_address',{}).get('address') else 'pending')")

  log "VM created: $VM_ID"
  log "Public IP: $PUBLIC_IP"

  # ── Wait for SSH ──
  log "Waiting for VM to be ready (this takes ~2 minutes)..."
  for i in $(seq 1 30); do
    if ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=5 "nemoclaw@${PUBLIC_IP}" 'echo OK' &>/dev/null; then
      log "SSH ready!"
      break
    fi
    sleep 10
    printf "."
  done
  echo ""

  # ── Wait for cloud-init to finish ──
  log "Waiting for Node.js and NemoClaw to install..."
  for i in $(seq 1 30); do
    if ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "nemoclaw@${PUBLIC_IP}" 'which openclaw' &>/dev/null; then
      log "OpenClaw installed!"
      break
    fi
    sleep 10
    printf "."
  done
  echo ""

  SSH_CMD="ssh -i $SSH_KEY_PATH nemoclaw@${PUBLIC_IP}"

else
  # ── Skip VM: install locally ──
  SSH_CMD="bash -c"
  PUBLIC_IP="localhost"

  step 2 "Installing NemoClaw locally (--skip-vm)"

  if ! command -v node &>/dev/null; then
    err "Node.js is required. Install it first: https://nodejs.org"
  fi

  if ! command -v openclaw &>/dev/null; then
    log "Installing OpenClaw..."
    npm install -g openclaw@2026.3.11
  fi

  if ! command -v python3 &>/dev/null; then
    err "Python 3 is required for vLLM."
  fi
fi

# ============================================================================
#  PHASE 3: Install vLLM and download Nemotron
# ============================================================================
step 3 "Setting up vLLM + Nemotron ($MODEL_SIZE)"

$SSH_CMD << 'VLLM_SETUP'
#!/bin/bash
set -e

# Create venv if not exists
if [ ! -d "$HOME/vllm-env" ]; then
  echo "Creating Python venv..."
  python3 -m venv "$HOME/vllm-env"
fi

source "$HOME/vllm-env/bin/activate"

# Install vLLM if not installed
if ! python3 -c "import vllm" &>/dev/null; then
  echo "Installing vLLM..."
  pip install vllm 2>&1 | tail -3
fi

echo "vLLM $(python3 -c 'import vllm; print(vllm.__version__)')"
VLLM_SETUP

# ============================================================================
#  PHASE 4: Start Nemotron inference server
# ============================================================================
step 4 "Starting Nemotron inference server"

$SSH_CMD << NEMOTRON_START
#!/bin/bash
source \$HOME/vllm-env/bin/activate
pkill -9 -f "vllm" 2>/dev/null || true
sleep 2

echo "Starting $MODEL_ID..."
echo "First run downloads the model weights (this can take 5-15 minutes)."

nohup python3 -m vllm.entrypoints.openai.api_server \\
  --model "$MODEL_ID" \\
  --host 0.0.0.0 \\
  --port 8000 \\
  --tensor-parallel-size 1 \\
  --trust-remote-code \\
  --max-model-len 32768 \\
  --gpu-memory-utilization 0.90 \\
  --enable-auto-tool-choice \\
  --tool-call-parser hermes \\
  > \$HOME/vllm.log 2>&1 &

echo "vLLM PID: \$!"

# Wait for health
echo "Waiting for model to load..."
for i in \$(seq 1 120); do
  if curl -s http://localhost:8000/health | grep -q "ok" 2>/dev/null; then
    echo ""
    echo "Nemotron is READY!"
    break
  fi
  if [ \$i -eq 120 ]; then
    echo ""
    echo "WARNING: Model not ready after 20 minutes. Check: tail -f ~/vllm.log"
  fi
  printf "."
  sleep 10
done
NEMOTRON_START

# ============================================================================
#  PHASE 5: Configure OpenClaw
# ============================================================================
step 5 "Configuring OpenClaw to use local Nemotron"

$SSH_CMD << OCLAW_CONFIG
#!/bin/bash
mkdir -p \$HOME/.openclaw

cat > \$HOME/.openclaw/openclaw.json << 'OCJSON'
{
  "agents": {
    "defaults": {
      "model": {
        "primary": "local-nemotron/$MODEL_ID"
      }
    }
  },
  "models": {
    "mode": "merge",
    "providers": {
      "local-nemotron": {
        "baseUrl": "http://localhost:8000/v1",
        "apiKey": "local",
        "api": "openai-completions",
        "models": [
          {
            "id": "$MODEL_ID",
            "name": "Nemotron (local GPU)"
          }
        ]
      }
    }
  },
  "gateway": {
    "port": 18789,
    "mode": "local",
    "bind": "lan"
  }
}
OCJSON

openclaw models set "local-nemotron/$MODEL_ID" 2>/dev/null || true
echo "OpenClaw configured for local Nemotron."
OCLAW_CONFIG

# ============================================================================
#  DONE
# ============================================================================
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  NemoClaw-Cloud is ready!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${CYAN}VM:${NC}     $VM_NAME"
echo -e "  ${CYAN}IP:${NC}     $PUBLIC_IP"
echo -e "  ${CYAN}GPU:${NC}    $GPU_PLATFORM"
echo -e "  ${CYAN}Model:${NC}  $MODEL_ID"
echo ""
echo -e "  ${YELLOW}Connect:${NC}"
echo -e "    ssh -i $SSH_KEY_PATH nemoclaw@${PUBLIC_IP}"
echo ""
echo -e "  ${YELLOW}Chat with the agent:${NC}"
echo -e "    ssh -i $SSH_KEY_PATH nemoclaw@${PUBLIC_IP}"
echo -e "    openclaw tui --session main"
echo ""
echo -e "  ${YELLOW}One-shot agent command:${NC}"
echo -e "    ssh -i $SSH_KEY_PATH nemoclaw@${PUBLIC_IP} \\"
echo -e "      'openclaw agent --local --session-id task1 -m \"Build a web scraper\"'"
echo ""
echo -e "  ${YELLOW}Check vLLM logs:${NC}"
echo -e "    ssh -i $SSH_KEY_PATH nemoclaw@${PUBLIC_IP} 'tail -f ~/vllm.log'"
echo ""
echo -e "  ${YELLOW}Stop VM (saves money):${NC}"
echo -e "    nebius compute instance stop --id $VM_ID"
echo ""
