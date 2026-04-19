# OpenClaw on Proxmox — Hardened Setup Guide
## For your Intel N150 / 16GB RAM / Home Assistant environment

> **Important note on Niklas Steenfatt**: Research shows that Niklas Steenfatt's
> YouTube channel (@NiklasSteenfatt) does **not** contain OpenClaw AI assistant
> content. His "OpenClaw" project is an unrelated **robotic arm** project. The
> security guidance in this guide comes from OpenClaw's **official documentation**
> (docs.openclaw.ai/gateway/security) and community best practices.

---

## Corrections to Previous Directions

Based on official OpenClaw documentation, these earlier decisions have been
**overruled**:

| Previous Direction | Official Recommendation | Why |
|-|-|-|
| Gateway bind: `lan` | Gateway bind: **`loopback`** | Official hardened baseline. LAN bind expands attack surface. |
| Node.js 22 | **Node.js 24** (recommended) | 22.14+ works but 24 is the official recommendation |
| No tool restrictions | **Deny all automation/runtime/fs tools** | Official hardened baseline denies dangerous tool groups |
| No security audit | Run **`openclaw security audit --fix`** | Official post-setup step; catches misconfigurations |
| Token in .desktop files | **Never embed tokens in files** | Leakage via screenshots/backups |

---

## Option 1: VM Setup (Strongest Isolation — Recommended)

**Best for**: Maximum security. Full hypervisor isolation means even a complete
compromise inside the VM cannot reach the Proxmox host or other VMs.

### Prerequisites
- Proxmox VE 8.x+ with root access
- SSH public key on the Proxmox host (`~/.ssh/id_ed25519.pub`)
- Your Z.AI API key

### Step-by-Step

#### 1. Generate an SSH key (if you don't have one yet)

On the Proxmox host, check whether a key already exists:

```bash
ls ~/.ssh/id_ed25519.pub
```

If the file does not exist, generate a new Ed25519 key pair:

```bash
ssh-keygen -t ed25519 -C "openclaw-vm" -N "" -f ~/.ssh/id_ed25519
```

- `-t ed25519` — modern, fast, secure key type
- `-N ""` — empty passphrase (required for unattended VM provisioning)
- The command creates `~/.ssh/id_ed25519` (private) and `~/.ssh/id_ed25519.pub` (public)

#### 2. Copy the script to your Proxmox host

```bash
# From your workstation, SCP the script to Proxmox:
scp niklas_setup-openclaw-vm.sh root@<PROXMOX_IP>:/root/
ssh root@<PROXMOX_IP>

# Install jq (not included in Proxmox by default, needed by the script):
apt update && apt install -y jq

chmod +x /root/niklas_setup-openclaw-vm.sh

# Fix Windows line endings (CRLF → LF), required if the file was
# created/edited on Windows:
sed -i 's/\r$//' /root/niklas_setup-openclaw-vm.sh
```

#### 3. Run the setup (fire and forget)

```bash
./niklas_setup-openclaw-vm.sh \
    --zai-api-key "your-zai-api-key-here" \
    --ssh-pubkey ~/.ssh/id_ed25519.pub
```

The script will:
- Download a Debian 12 cloud image (cached for reuse)
- Create a VM with 3GB RAM, 2 cores, 16GB disk
- Configure Proxmox firewall (blocks LAN, allows internet)
- Boot the VM with cloud-init (installs Docker + OpenClaw automatically)
- Wait for the VM to come online
- Inject your Z.AI API key via SSH (never stored in cloud-init)
- Apply hardened OpenClaw configuration
- Run `openclaw security audit --fix`
- Verify health

#### 4. Access OpenClaw (via SSH tunnel)

```bash
# From your workstation:
ssh -L 18789:localhost:18789 claw@<VM_IP>

# Then open in your browser:
# http://localhost:18789
# Enter the auth token printed at the end of setup
```

#### 5. Verify security

```bash
ssh claw@<VM_IP>
docker compose exec openclaw-gateway node openclaw.mjs security audit --deep
```

---

## Option 2: LXC Setup (Lighter Weight, Desktop Included)

**Best for**: Lower resource usage, includes a full remote desktop (noVNC) with
Chrome browser for the OpenClaw onboarding wizard and dashboard.

### Prerequisites
- Proxmox VE 8.x+ with root access
- Your Z.AI API key (optional — can configure later via desktop wizard)

### Step-by-Step

#### 1. Generate an SSH key (recommended for secure access)

While the LXC setup uses password authentication for the container, an SSH key
on the Proxmox host is recommended for secure management:

```bash
# Check if a key already exists:
ls ~/.ssh/id_ed25519.pub

# If not, generate one:
ssh-keygen -t ed25519 -C "proxmox-admin" -N "" -f ~/.ssh/id_ed25519
```

You can later copy it into the container for key-based SSH access:
```bash
pct exec <VMID> -- mkdir -p /root/.ssh
pct push <VMID> ~/.ssh/id_ed25519.pub /root/.ssh/authorized_keys
```

#### 2. Copy the script to your Proxmox host

```bash
scp niklas_setup-openclaw-lxc.sh root@<PROXMOX_IP>:/root/
ssh root@<PROXMOX_IP>

# Install jq (not included in Proxmox by default, needed by the script):
apt update && apt install -y jq

chmod +x /root/niklas_setup-openclaw-lxc.sh

# Fix Windows line endings (CRLF → LF), required if the file was
# created/edited on Windows:
sed -i 's/\r$//' /root/niklas_setup-openclaw-lxc.sh
```

#### 3. Run the setup

```bash
./niklas_setup-openclaw-lxc.sh \
    --password "your-container-password" \
    --zai-api-key "your-zai-api-key-here"
```

Or interactively (password prompted, API key via desktop wizard later):
```bash
./niklas_setup-openclaw-lxc.sh
```

The script will:
- Download a Debian 13 template
- Create an **unprivileged** LXC container (3GB RAM, 2 cores, 16GB disk)
- Configure Proxmox firewall + in-container iptables
- Install Node.js 24, OpenClaw, LXQt desktop, Chrome, VNC/noVNC
- Configure OpenClaw with hardened baseline
- Set up all services as non-root user `openclaw`
- Run security audit

#### 4. Access the Remote Desktop (via SSH tunnel)

```bash
# From your workstation:
ssh -L 6080:localhost:6080 root@<CONTAINER_IP>

# Then open in your browser:
# http://localhost:6080/vnc.html
# Enter the VNC password printed at the end of setup
```

#### 5. Use OpenClaw

From the remote desktop:
- Click **"OpenClaw Setup Wizard"** to run onboarding
- Click **"OpenClaw Dashboard"** to open the control UI
- The dashboard is at http://127.0.0.1:18789 (accessible from inside the container)

#### 6. Verify security

```bash
pct exec <VMID> -- su - openclaw -c 'openclaw security audit --deep'
```

---

## Security Layers (Both Options)

```
┌─────────────────────────────────────────────┐
│ Proxmox Firewall (host-enforced)            │
│  ✓ Default policy: DROP in + DROP out       │
│  ✓ Allow: gateway IP (for routing)          │
│  ✓ Allow: DNS server                        │
│  ✓ Block: LAN subnet (192.168.178.0/24)    │
│  ✓ Block: ALL RFC1918 (10/8, 172.16/12)    │
│  ✓ Allow: internet (everything else)        │
│  ✓ Inbound: SSH only from LAN              │
├─────────────────────────────────────────────┤
│ In-Container/VM Hardening (defense in depth) │
│  ✓ Docker cap_drop: NET_RAW, NET_ADMIN,      │
│    SYS_ADMIN                                  │
│  ✓ security_opt: no-new-privileges            │
│  ✓ network_mode: host + loopback bind only    │
│  Note: In-VM iptables removed (conflicts with │
│  Docker). Proxmox firewall is sufficient.     │
├─────────────────────────────────────────────┤
│ IPv6 Disabled                               │
│  ✓ Prevents bypass of IPv4-only rules       │
├─────────────────────────────────────────────┤
│ OpenClaw Hardened Config                    │
│  ✓ Gateway: loopback only                   │
│  ✓ Auth: 256-bit random token               │
│  ✓ Tools profile: "coding" (Skills nutzbar) │
│  ✓ Exec: "full" with ask "off" (für Skills) │
│  ✓ Deny: sessions_spawn, sessions_send      │
│  ✓ Sessions: per-channel-peer isolation     │
│  ✓ Elevated tools: disabled                 │
│  ✓ FS: workspace-only                       │
│  Note: Initial setup uses "messaging" profile│
│  Upgrade to "coding" when adding Skills     │
│  (see openclaw-home-assistant-integration.md)│
├─────────────────────────────────────────────┤
│ OS-Level Hardening                          │
│  ✓ Non-root service user                    │
│  ✓ File permissions: 700/600                │
│  ✓ Unattended security upgrades             │
│  ✓ Chrome sandbox enabled (LXC only)        │
│  ✓ Docker cap drops (VM only)               │
└─────────────────────────────────────────────┘
```

---

## Which Option to Choose?

| Factor | OpenClaw VM | OpenClaw LXC | Hermes VM |
|-|-|-|-|
| **Isolation** | ★★★★★ Hypervisor | ★★★★ Kernel NS | ★★★★★ Hypervisor |
| **RAM** | 4 GB | 3 GB | 3 GB |
| **Desktop/GUI** | No (headless) | Yes (noVNC) | Dashboard (web) |
| **Browser** | No | Yes (Chrome) | Optional |
| **Setup** | Script (fire&forget) | Script | Script (fire&forget) |
| **Skills** | SKILL.md + ClawHub | SKILL.md + ClawHub | Auto-generated |
| **Memory** | Session hooks | Session hooks | Persistent (auto) |
| **Open Source** | No | No | Yes (MIT) |
| **Best for** | Proven gateway | Desktop setup | Open-source alternative |

**Recommendation**: Use VM if you only need the API gateway. Use LXC if you
want the desktop experience for onboarding and browser-based channel setup.

---

## Option 3: Hermes Agent VM (Alternative to OpenClaw)

**Best for**: Side-by-side comparison with OpenClaw. Hermes Agent by Nous
Research is an open-source (MIT) autonomous agent with persistent memory,
auto-generated skills, and scheduled automations.

| Aspekt | OpenClaw (VM 100) | Hermes Agent (VM 101) |
|--------|-------------------|----------------------|
| Hersteller | OpenClaw | Nous Research |
| Lizenz | Proprietary | MIT (Open Source) |
| LLM Provider | Z.AI (nativ) | Z.AI (GLM_API_KEY) |
| Model | zai/glm-4.7 | zai/glm-4.7 |
| Docker Image | ghcr.io/openclaw/openclaw | nousresearch/hermes-agent |
| Gateway Port | 18789 | 8642 |
| Dashboard Port | — (gleicher Port) | 9119 |
| VM IP | 192.168.178.80 | 192.168.178.81 |
| RAM | 4 GB | 3 GB |
| Channels | Telegram, WhatsApp, etc. | Telegram, Discord, Slack, etc. |
| Skills | Workspace-basiert (SKILL.md) | Auto-generiert + installierbar |
| Memory | Hooks + Session-Memory | Persistent (MEMORY.md, USER.md) |
| Sandbox | Docker cap_drop | Local/Docker/SSH/Modal/Singularity |
| Whisper/Audio | Lokaler Whisper Container | Nicht integriert (separat) |

### Prerequisites
- Proxmox VE 8.x+ with root access
- SSH public key on the Proxmox host
- Z.AI API key
- Optional: Telegram bot token, HA long-lived token

### Step-by-Step

#### 1. Copy the script to your Proxmox host

```bash
scp setup-hermes-vm.sh root@<PROXMOX_IP>:/root/
ssh root@<PROXMOX_IP>

# Install jq if not already:
apt install -y jq

chmod +x /root/setup-hermes-vm.sh
sed -i 's/\r$//' /root/setup-hermes-vm.sh
```

#### 2. Run the setup (fire and forget)

```bash
./setup-hermes-vm.sh \
    --zai-api-key "your-zai-api-key" \
    --ssh-pubkey ~/.ssh/id_ed25519.pub \
    --ha-token "your-ha-long-lived-token"
```

With Telegram:
```bash
./setup-hermes-vm.sh \
    --zai-api-key "your-zai-api-key" \
    --ssh-pubkey ~/.ssh/id_ed25519.pub \
    --ha-token "your-ha-long-lived-token" \
    --telegram-token "your-telegram-bot-token"
```

The script will:
- Download Debian 12 cloud image (cached, shared with OpenClaw)
- Create VM 101 with 3GB RAM, 2 cores, 16GB disk
- Configure Proxmox firewall (blocks LAN, allows HA + Grafana + internet)
- Deploy Hermes via Docker Compose (gateway + dashboard)
- Disable IPv6 (prevent firewall bypass)
- Enable NIC firewall after setup completes
- Wait for health check

#### 3. Access Hermes (via SSH tunnel)

```bash
# From your workstation:
ssh -L 8642:localhost:8642 -L 9119:localhost:9119 hermes@192.168.178.81

# Dashboard: http://localhost:9119
# Gateway API: http://localhost:8642
```

From Windows:
```powershell
ssh -i C:\Users\bvogel\.ssh\id_ed25519_openclaw ^
    -L 8642:localhost:8642 -L 9119:localhost:9119 ^
    hermes@192.168.178.81
```

#### 4. Configure Telegram (if not set during setup)

```bash
ssh hermes@192.168.178.81
nano ~/.hermes/.env
# Add: TELEGRAM_BOT_TOKEN=your-token
cd ~/hermes && docker compose restart hermes
```

#### 5. Verify security

```bash
# Internet works
ssh hermes@192.168.178.81 "curl -sf --max-time 5 https://cloud.debian.org > /dev/null && echo INTERNET_OK"

# HA accessible
ssh hermes@192.168.178.81 "curl -sf --max-time 5 http://192.168.178.88:8123/api/ && echo HA_OK"

# Rest of LAN blocked
ssh hermes@192.168.178.81 "curl -sf --max-time 3 http://192.168.178.108:8006 2>/dev/null && echo LAN_EXPOSED || echo LAN_BLOCKED"
```

### Hermes Directory Structure

```
~/.hermes/
├── .env            ← API keys (GLM_API_KEY, HA_TOKEN, TELEGRAM_BOT_TOKEN)
├── config.yaml     ← Settings (model, terminal, memory, tools)
├── SOUL.md         ← Agent personality/identity
├── memories/       ← Persistent memory (auto-managed)
├── skills/         ← Agent-created skills
├── sessions/       ← Conversation history
├── cron/           ← Scheduled jobs
├── hooks/          ← Event hooks
└── logs/           ← Runtime logs
```

### Hermes CLI (inside VM)

```bash
# Interactive chat
cd ~/hermes && docker compose exec -it hermes hermes

# View config
docker compose exec hermes hermes config

# Set a value
docker compose exec hermes hermes config set model zai/glm-5.1

# Health check
curl -sf http://127.0.0.1:8642/health

# Logs
docker compose logs --tail 50 hermes
docker compose logs --tail 20 hermes-dashboard
```

### Hermes Maintenance

```bash
# Update Hermes
cd ~/hermes
docker compose pull
docker compose up -d

# Restart
docker compose restart hermes

# Backup (.hermes contains all state)
tar czf ~/hermes-backup-$(date +%Y%m%d).tar.gz ~/.hermes/
```

---

## Post-Setup: Connecting Channels

After setup, configure your messaging channels:
1. Access the dashboard (via SSH tunnel)
2. Or run the onboard wizard: `openclaw onboard`
3. Follow prompts to connect WhatsApp, Telegram, Discord, etc.

## Maintenance

```bash
# Update OpenClaw (VM 100):
ssh claw@192.168.178.80 'cd ~/openclaw && docker compose pull && docker compose up -d'

# Update Hermes (VM 101):
ssh hermes@192.168.178.81 'cd ~/hermes && docker compose pull && docker compose up -d'

# Update OpenClaw (LXC):
pct exec <VMID> -- npm update -g openclaw

# Security audit (OpenClaw):
ssh claw@192.168.178.80 'cd ~/openclaw && docker compose exec openclaw-gateway node openclaw.mjs security audit --deep'

# Check services:
ssh claw@192.168.178.80 'cd ~/openclaw && docker compose ps'      # OpenClaw
ssh hermes@192.168.178.81 'cd ~/hermes && docker compose ps'       # Hermes
```
