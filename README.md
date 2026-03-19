# NemoClaw-Cloud

Deploy [NemoClaw](https://github.com/NVIDIA/NemoClaw) on a Nebius GPU VM with local Nemotron inference in one command.

## What This Does

1. Creates a GPU VM on [Nebius Cloud](https://nebius.com) (H100/H200/B200)
2. Installs [OpenClaw](https://openclaw.ai) + NemoClaw
3. Downloads and runs [NVIDIA Nemotron](https://developer.nvidia.com/nemotron) locally via vLLM
4. Configures OpenClaw to use the local GPU for inference

No API keys needed for inference -- the model runs entirely on your GPU.

## Prerequisites

- [Nebius Cloud](https://console.nebius.com) account with GPU quota
- macOS or Linux terminal
- [Nebius CLI](https://docs.nebius.com/cli/overview) (installer will install it if missing)

## Quick Start

```bash
git clone https://github.com/colinlowenberg/NemoClaw-Cloud.git
cd NemoClaw-Cloud
./install.sh
```

That's it. The script will:
- Authenticate you with Nebius (opens browser)
- Create a GPU VM with Ubuntu + CUDA
- Install Node.js, OpenClaw, NemoClaw, vLLM
- Download Nemotron-3-Super-120B and load it on the GPU
- Configure OpenClaw to use local inference

## Options

```bash
# Choose a model size
./install.sh --model nano       # Nemotron-3-Nano-4B (8GB, fast, good for testing)
./install.sh --model nano30     # Nemotron-3-Nano-30B MoE (60GB, great balance)
./install.sh --model super      # Nemotron-3-Super-120B (120GB, best quality) [default]

# Choose GPU
./install.sh --gpu h100         # NVIDIA H100 (80GB VRAM)
./install.sh --gpu h200         # NVIDIA H200 (141GB VRAM) [default]
./install.sh --gpu b200         # NVIDIA B200 (180GB VRAM)
./install.sh --gpu l40s         # NVIDIA L40S (48GB VRAM, cost-effective)

# Custom disk size
./install.sh --disk 500         # 500GB boot disk

# Install on current machine (no VM creation)
./install.sh --skip-vm

# Custom VM name
./install.sh --name my-agent-vm
```

## After Installation

### SSH into the VM
```bash
ssh -i ~/.ssh/id_ed25519 nemoclaw@<PUBLIC_IP>
```

### Chat with the agent (interactive TUI)
```bash
openclaw tui --session main
```

### Run a one-shot task
```bash
openclaw agent --local --session-id task1 -m "Build a Python web scraper for Hacker News"
```

### Check vLLM/Nemotron logs
```bash
tail -f ~/vllm.log
```

### Stop VM (saves money)
```bash
nebius compute instance stop --id <INSTANCE_ID>
```

### Start VM again
```bash
nebius compute instance start --id <INSTANCE_ID>
# Then SSH in and restart vLLM:
bash ~/start-nemotron.sh
```

## Model Comparison

| Model | Params | Active | VRAM | Disk | Quality | Speed |
|-------|--------|--------|------|------|---------|-------|
| Nemotron-3-Nano-4B | 4B | 4B | ~8GB | 50GB | Good | Very Fast |
| Nemotron-3-Nano-30B | 30B | 3B (MoE) | ~30GB | 100GB | Great | Fast |
| Nemotron-3-Super-120B | 120B | 12B (MoE) | ~130GB | 300GB | Best | Fast |

## GPU Pricing (Nebius Cloud)

| GPU | VRAM | Approx Cost |
|-----|------|-------------|
| H100 SXM | 80 GB | ~$3/hr |
| H200 SXM | 141 GB | ~$4/hr |
| B200 SXM | 180 GB | ~$5/hr |
| L40S PCIe | 48 GB | ~$1.5/hr |

## Architecture

```
┌─────────────────────────────────────────┐
│           Nebius GPU VM                  │
│  ┌───────────────┐  ┌────────────────┐  │
│  │   OpenClaw    │──│  vLLM Server   │  │
│  │  + NemoClaw   │  │  (port 8000)   │  │
│  │  Agent        │  │                │  │
│  │  Framework    │  │  Nemotron-3    │  │
│  └───────────────┘  │  Super 120B    │  │
│                     │  on GPU        │  │
│                     └────────────────┘  │
│  GPU: NVIDIA H200 (141GB HBM3e)        │
└─────────────────────────────────────────┘
```

## Troubleshooting

| Issue | Fix |
|-------|-----|
| `PermissionDenied` | Run `nebius iam whoami` to re-authenticate |
| vLLM OOM | Use `--model nano` or `--model nano30` for smaller models |
| Disk full | Use `--disk 500` for more space |
| SSH timeout | Wait 2-3 min after VM creation for cloud-init to finish |
| Model download slow | First run downloads weights (~120GB for Super). Be patient. |

## License

MIT
