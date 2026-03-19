#!/bin/bash
# ============================================================================
#  NemoClaw-Cloud Serverless Installer
#  Deploy OpenClaw as a Nebius Serverless Endpoint with Token Factory inference
# ============================================================================
#
#  This deploys a lightweight OpenClaw container (no GPU required) that uses
#  Nebius Token Factory for inference. The endpoint runs on CPU (AMD EPYC Genoa)
#  and calls Token Factory's API for model inference.
#
#  Usage:
#    ./install-serverless.sh                                  # Deploy with defaults
#    ./install-serverless.sh --model deepseek-ai/DeepSeek-R1-0528  # Different model
#    ./install-serverless.sh --name my-agent                   # Custom endpoint name
#    ./install-serverless.sh --preemptible                     # Cheaper (can be preempted)
#    ./install-serverless.sh --token-factory-key <KEY>          # Provide TF key
#
# ============================================================================

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
MODEL="${MODEL:-deepseek-ai/DeepSeek-R1-0528}"
ENDPOINT_NAME="${ENDPOINT_NAME:-openclaw-serverless}"
PREEMPTIBLE=false
TOKEN_FACTORY_KEY="${TOKEN_FACTORY_KEY:-}"
REGISTRY_ID=""
IMAGE_TAG="latest"

# ── Parse args ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --model)              MODEL="$2"; shift 2 ;;
    --name)               ENDPOINT_NAME="$2"; shift 2 ;;
    --preemptible)        PREEMPTIBLE=true; shift ;;
    --token-factory-key)  TOKEN_FACTORY_KEY="$2"; shift 2 ;;
    --registry)           REGISTRY_ID="$2"; shift 2 ;;
    --help|-h)            echo "Usage: $0 [--model MODEL_ID] [--name NAME] [--preemptible] [--token-factory-key KEY]"; exit 0 ;;
    *)                    echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[OpenClaw]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step() { echo -e "\n${CYAN}━━━ Step $1: $2 ━━━${NC}"; }

# ── Banner ───────────────────────────────────────────────────────────────────
echo -e "${BLUE}"
cat << 'BANNER'
   ___                    ____ _
  / _ \ _ __   ___ _ __  / ___| | __ ___      __
 | | | | '_ \ / _ \ '_ \| |   | |/ _` \ \ /\ / /
 | |_| | |_) |  __/ | | | |___| | (_| |\ V  V /
  \___/| .__/ \___|_| |_|\____|_|\__,_| \_/\_/
       |_|           Serverless on Nebius ☁️
BANNER
echo -e "${NC}"
log "Mode:       Nebius Serverless (CPU + Token Factory)"
log "Model:      $MODEL (via Token Factory)"
log "Endpoint:   $ENDPOINT_NAME"
log "GPU:        None (CPU-only container)"
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

# Check Docker
if ! command -v docker &>/dev/null; then
  err "Docker is required to build the container image. Install Docker first."
fi

# Check auth
if ! nebius iam whoami &>/dev/null; then
  log "Please authenticate with Nebius..."
  nebius iam whoami
fi

WHOAMI=$(nebius iam whoami 2>/dev/null | grep "email:" | awk '{print $2}' || echo "authenticated")
log "Logged in as: $WHOAMI"

# Get project
PROJECT_ID=$(nebius iam project list --format json 2>/dev/null | \
  python3 -c "import sys,json; items=json.load(sys.stdin).get('items',[]); print(items[0]['metadata']['id'] if items else '')" 2>/dev/null || echo "")

if [ -z "$PROJECT_ID" ]; then
  err "No projects found. Create one at console.nebius.com first."
fi
log "Project: $PROJECT_ID"

# Token Factory key
if [ -z "$TOKEN_FACTORY_KEY" ]; then
  echo ""
  echo -e "${YELLOW}Token Factory API key is required for inference.${NC}"
  echo -e "Get one at: ${CYAN}https://tokenfactory.nebius.com${NC}"
  echo ""
  read -rp "Enter your Token Factory API key: " TOKEN_FACTORY_KEY
  if [ -z "$TOKEN_FACTORY_KEY" ]; then
    err "Token Factory API key is required."
  fi
fi
log "Token Factory: configured"

# ============================================================================
#  PHASE 2: Build Lightweight Docker Image (CPU-only)
# ============================================================================
step 2 "Building OpenClaw container image (CPU-only, AMD64)"

BUILD_DIR=$(mktemp -d)
log "Build dir: $BUILD_DIR"

cat > "$BUILD_DIR/Dockerfile" << 'DOCKERFILE'
# Lightweight OpenClaw container for Nebius Serverless
# No GPU required - uses Token Factory for inference
FROM node:22-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates netcat-openbsd procps \
    && rm -rf /var/lib/apt/lists/*

# Install OpenClaw
RUN npm install -g openclaw@2026.3.11

# Create non-root user
RUN useradd -m -s /bin/bash openclaw

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 8080 18789

USER openclaw
WORKDIR /home/openclaw

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
DOCKERFILE

cat > "$BUILD_DIR/entrypoint.sh" << 'ENTRYPOINT'
#!/bin/bash
set -e

MODEL="${INFERENCE_MODEL:-deepseek-ai/DeepSeek-R1-0528}"
TF_KEY="${TOKEN_FACTORY_API_KEY}"
TF_URL="${TOKEN_FACTORY_URL:-https://api.tokenfactory.nebius.com/v1}"

echo "=== OpenClaw Serverless ==="
echo "Model: $MODEL"
echo "Inference: Token Factory"

if [ -z "$TF_KEY" ]; then
  echo "ERROR: TOKEN_FACTORY_API_KEY is required"
  exit 1
fi

# Configure OpenClaw
mkdir -p ~/.openclaw
cat > ~/.openclaw/openclaw.json << OCJSON
{
  "agents": {
    "defaults": {
      "model": {
        "primary": "token-factory/${MODEL}"
      }
    }
  },
  "models": {
    "mode": "merge",
    "providers": {
      "token-factory": {
        "baseUrl": "${TF_URL}",
        "apiKey": "${TF_KEY}",
        "api": "openai-completions",
        "models": [{"id": "${MODEL}", "name": "Token Factory"}]
      }
    }
  },
  "gateway": {
    "port": 18789,
    "mode": "local",
    "bind": "lan",
    "auth": {"mode": "none"}
  }
}
OCJSON

openclaw models set "token-factory/${MODEL}" 2>/dev/null || true
echo "OpenClaw configured."

# Start OpenClaw gateway in background
openclaw gateway &
GATEWAY_PID=$!
echo "Gateway started (PID: $GATEWAY_PID)"

# Health check on port 8080
echo "Health check on :8080"
while true; do
  echo -e "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"status\":\"healthy\",\"service\":\"openclaw-serverless\",\"model\":\"${MODEL}\",\"inference\":\"token-factory\"}" \
    | nc -l -p 8080 -q 1 2>/dev/null || true
done
ENTRYPOINT

# Build for linux/amd64 (AMD EPYC Genoa)
log "Building for linux/amd64..."
docker buildx build \
  --platform linux/amd64 \
  -t "openclaw-serverless:${IMAGE_TAG}" \
  "$BUILD_DIR" 2>&1 | tail -5

rm -rf "$BUILD_DIR"
log "Image built: openclaw-serverless:${IMAGE_TAG}"

# ============================================================================
#  PHASE 3: Push to Nebius Container Registry
# ============================================================================
step 3 "Pushing image to Nebius Container Registry"

# Find or create registry
if [ -z "$REGISTRY_ID" ]; then
  REGISTRY_ID=$(nebius registry list --format json 2>/dev/null | \
    python3 -c "import sys,json; items=json.load(sys.stdin).get('items',[]); r=items[0]['metadata']['id'] if items else ''; print(r.replace('registry-','') if r.startswith('registry-') else r)" 2>/dev/null || echo "")
fi

if [ -z "$REGISTRY_ID" ]; then
  log "Creating container registry..."
  REGISTRY_RESULT=$(nebius registry create \
    --name openclaw-registry \
    --parent-id "$PROJECT_ID" \
    --format json)
  REGISTRY_ID=$(echo "$REGISTRY_RESULT" | python3 -c "import sys,json; r=json.load(sys.stdin)['metadata']['id']; print(r.replace('registry-','') if r.startswith('registry-') else r)")
fi
log "Registry: $REGISTRY_ID"

# Docker login
nebius iam get-access-token | docker login cr.us-central1.nebius.cloud --username iam --password-stdin

# Tag and push
REMOTE_IMAGE="cr.us-central1.nebius.cloud/${REGISTRY_ID}/openclaw-serverless:${IMAGE_TAG}"
docker tag "openclaw-serverless:${IMAGE_TAG}" "$REMOTE_IMAGE"
log "Pushing $REMOTE_IMAGE..."
docker push "$REMOTE_IMAGE" 2>&1 | tail -3
log "Image pushed!"

# ============================================================================
#  PHASE 4: Deploy Serverless Endpoint
# ============================================================================
step 4 "Deploying Nebius Serverless Endpoint"

PREEMPT_FLAG=""
if [ "$PREEMPTIBLE" = true ]; then
  PREEMPT_FLAG="--preemptible"
fi

# Find subnet
SUBNET_ID=$(nebius vpc subnet list --format json 2>/dev/null | \
  python3 -c "import sys,json; items=json.load(sys.stdin).get('items',[]); print(items[0]['metadata']['id'] if items else '')" 2>/dev/null || echo "")

SUBNET_FLAG=""
if [ -n "$SUBNET_ID" ]; then
  SUBNET_FLAG="--subnet-id $SUBNET_ID"
fi

log "Creating endpoint: $ENDPOINT_NAME"
ENDPOINT_RESULT=$(nebius ai endpoint create \
  --name "$ENDPOINT_NAME" \
  --image "$REMOTE_IMAGE" \
  --container-port 8080 \
  --env "TOKEN_FACTORY_API_KEY=${TOKEN_FACTORY_KEY}" \
  --env "INFERENCE_MODEL=${MODEL}" \
  --env "NODE_ENV=production" \
  --public \
  $SUBNET_FLAG \
  $PREEMPT_FLAG \
  --format json 2>&1)

ENDPOINT_ID=$(echo "$ENDPOINT_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['metadata']['id'])" 2>/dev/null || echo "unknown")

log "Endpoint ID: $ENDPOINT_ID"

# ============================================================================
#  DONE
# ============================================================================
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  OpenClaw Serverless is deploying!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${CYAN}Endpoint:${NC}  $ENDPOINT_NAME"
echo -e "  ${CYAN}ID:${NC}        $ENDPOINT_ID"
echo -e "  ${CYAN}Model:${NC}     $MODEL (via Token Factory)"
echo -e "  ${CYAN}GPU:${NC}       None (CPU-only)"
echo ""
echo -e "  ${YELLOW}Check status:${NC}"
echo -e "    nebius ai endpoint get --id $ENDPOINT_ID --format json"
echo ""
echo -e "  ${YELLOW}View logs:${NC}"
echo -e "    nebius ai endpoint logs --id $ENDPOINT_ID"
echo ""
echo -e "  ${YELLOW}SSH into the endpoint:${NC}"
echo -e "    nebius ai endpoint ssh --id $ENDPOINT_ID"
echo ""
echo -e "  ${YELLOW}Stop (saves money):${NC}"
echo -e "    nebius ai endpoint stop --id $ENDPOINT_ID"
echo ""
echo -e "  ${YELLOW}Delete:${NC}"
echo -e "    nebius ai endpoint delete --id $ENDPOINT_ID"
echo ""
