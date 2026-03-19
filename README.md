# NemoClaw-Cloud

Deploy [NemoClaw](https://github.com/NVIDIA/NemoClaw) / [OpenClaw](https://openclaw.ai) on [Nebius Cloud](https://nebius.com) in one command. Two deployment options:

| | **GPU VM** | **Serverless** |
|---|---|---|
| Script | `install-vm.sh` | `install-serverless.sh` |
| Inference | Local GPU (Nemotron via vLLM) | Nebius Token Factory API |
| GPU required | Yes (H100/H200/B200/L40S) | No (CPU-only) |
| Best for | Full control, local inference, development | Zero-ops, pay-per-use, production |
| Cost | ~$3-5/hr (always-on VM) | Pay per request |

---

## Option A: GPU VM (Local Nemotron Inference)

Run Nemotron directly on a Nebius GPU. No external API keys needed.

### Quick Start

```bash
git clone https://github.com/colygon/NemoClaw-Cloud.git
cd NemoClaw-Cloud
./install-vm.sh
```

### What It Does

1. Creates a GPU VM on Nebius with Ubuntu + CUDA
2. Installs OpenClaw + NemoClaw + vLLM
3. Downloads NVIDIA Nemotron and loads it on the GPU
4. Configures OpenClaw to use local inference

### Options

```bash
./install-vm.sh --model nano       # Nemotron-3-Nano-4B (8GB, fast)
./install-vm.sh --model nano30     # Nemotron-3-Nano-30B MoE (60GB, balanced)
./install-vm.sh --model super      # Nemotron-3-Super-120B (120GB, best) [default]

./install-vm.sh --gpu h100         # NVIDIA H100 (80GB VRAM)
./install-vm.sh --gpu h200         # NVIDIA H200 (141GB VRAM) [default]
./install-vm.sh --gpu b200         # NVIDIA B200 (180GB VRAM)
./install-vm.sh --gpu l40s         # NVIDIA L40S (48GB VRAM, budget)

./install-vm.sh --disk 500         # Custom disk size (GB)
./install-vm.sh --name my-vm       # Custom VM name
./install-vm.sh --skip-vm          # Install on current machine (no VM)
```

### After Installation

```bash
# SSH into the VM
ssh -i ~/.ssh/id_ed25519 nemoclaw@<PUBLIC_IP>

# Interactive chat with the agent
openclaw tui --session main

# One-shot task
openclaw agent --local --session-id task1 \
  -m "Build a Python web scraper" --timeout 120

# Check Nemotron/vLLM logs
tail -f ~/vllm.log

# Stop VM (saves money)
nebius compute instance stop --id <INSTANCE_ID>
```

### Architecture

```
┌──────────────────────────────────────┐
│         Nebius GPU VM                │
│  ┌──────────────┐  ┌─────────────┐  │
│  │  OpenClaw    │──│ vLLM Server │  │
│  │  + NemoClaw  │  │ (port 8000) │  │
│  │  Agent       │  │             │  │
│  │  Framework   │  │ Nemotron-3  │  │
│  └──────────────┘  │ on GPU      │  │
│                    └─────────────┘  │
│  GPU: NVIDIA H200 (141GB HBM3e)    │
└──────────────────────────────────────┘
```

---

## Option B: Serverless (Token Factory Inference)

Lightweight CPU-only container using Nebius Token Factory for inference. No GPU needed.

### Quick Start

```bash
git clone https://github.com/colygon/NemoClaw-Cloud.git
cd NemoClaw-Cloud
./install-serverless.sh
```

You'll be prompted for your Token Factory API key ([get one here](https://tokenfactory.nebius.com)).

### What It Does

1. Builds a lightweight Docker image (~200MB) with OpenClaw
2. Pushes it to Nebius Container Registry
3. Deploys as a Nebius Serverless Endpoint (CPU-only)
4. Configures OpenClaw to use Token Factory for inference

### Options

```bash
./install-serverless.sh --model deepseek-ai/DeepSeek-R1-0528     # [default]
./install-serverless.sh --model meta-llama/Llama-3.1-70B-Instruct # Llama
./install-serverless.sh --name my-agent                           # Custom name
./install-serverless.sh --preemptible                              # Cheaper
./install-serverless.sh --token-factory-key <KEY>                  # Non-interactive
```

### After Deployment

```bash
# Check endpoint status
nebius ai endpoint get --id <ENDPOINT_ID> --format json

# View logs
nebius ai endpoint logs --id <ENDPOINT_ID>

# SSH into the running endpoint
nebius ai endpoint ssh --id <ENDPOINT_ID>

# Stop endpoint
nebius ai endpoint stop --id <ENDPOINT_ID>
```

### Architecture

```
┌────────────────────────────────┐
│  Nebius Serverless Endpoint    │
│  ┌──────────────────────────┐  │
│  │  OpenClaw Agent          │  │
│  │  (CPU-only container)    │  │
│  └──────────┬───────────────┘  │
│             │ HTTPS            │
│  ┌──────────▼───────────────┐  │
│  │  Nebius Token Factory    │  │
│  │  (inference API)         │  │
│  └──────────────────────────┘  │
│  CPU: AMD EPYC Genoa           │
└────────────────────────────────┘
```

---

## Prerequisites

- [Nebius Cloud](https://console.nebius.com) account
- macOS or Linux terminal
- Docker (for serverless option)
- [Nebius CLI](https://docs.nebius.com/cli/overview) (auto-installed by scripts)

## Model Comparison (GPU VM)

| Model | Params | Active | VRAM | Disk | Quality |
|-------|--------|--------|------|------|---------|
| Nemotron-3-Nano-4B | 4B | 4B | ~8GB | 50GB | Good |
| Nemotron-3-Nano-30B | 30B | 3B (MoE) | ~30GB | 100GB | Great |
| Nemotron-3-Super-120B | 120B | 12B (MoE) | ~130GB | 300GB | Best |

## GPU Pricing (Nebius Cloud)

| GPU | VRAM | Approx Cost |
|-----|------|-------------|
| H100 SXM | 80 GB | ~$3/hr |
| H200 SXM | 141 GB | ~$4/hr |
| B200 SXM | 180 GB | ~$5/hr |
| L40S PCIe | 48 GB | ~$1.5/hr |

## Troubleshooting

| Issue | Fix |
|-------|-----|
| `PermissionDenied` | Run `nebius iam whoami` to re-authenticate |
| vLLM OOM | Use `--model nano` or `--model nano30` |
| Disk full | Use `--disk 500` for more space |
| SSH timeout | Wait 2-3 min for cloud-init |
| Docker build fails (ARM) | Script uses `--platform linux/amd64` for Nebius |
| Token Factory 401 | Check API key at tokenfactory.nebius.com |

## License

MIT
