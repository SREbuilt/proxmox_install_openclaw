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
ssh -L 18789:localhost:18789 openclaw@<VM_IP>

# Then open in your browser:
# http://localhost:18789
# Enter the auth token printed at the end of setup
```

#### 5. Verify security

```bash
ssh openclaw@<VM_IP>
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
│ In-Container/VM iptables (defense in depth) │
│  ✓ Same rules as above, enforced inside     │
│  ✓ Survives Proxmox firewall misconfiguration│
├─────────────────────────────────────────────┤
│ IPv6 Disabled                               │
│  ✓ Prevents bypass of IPv4-only rules       │
├─────────────────────────────────────────────┤
│ OpenClaw Hardened Config                    │
│  ✓ Gateway: loopback only                   │
│  ✓ Auth: 256-bit random token               │
│  ✓ Tools: deny automation/runtime/fs        │
│  ✓ Exec: deny + always ask                  │
│  ✓ Sessions: per-channel-peer isolation     │
│  ✓ Elevated tools: disabled                 │
│  ✓ FS: workspace-only                       │
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

| Factor | VM | LXC |
|-|-|-|
| **Isolation** | ★★★★★ Hypervisor | ★★★★ Kernel namespaces |
| **RAM overhead** | ~200MB for OS | ~100MB for OS |
| **Desktop/GUI** | No (headless) | Yes (noVNC + LXQt) |
| **Chrome browser** | No | Yes (with sandbox) |
| **Setup complexity** | Simpler (Docker) | More components |
| **Best for** | Headless AI gateway | Interactive setup/browsing |

**Recommendation**: Use VM if you only need the API gateway. Use LXC if you
want the desktop experience for onboarding and browser-based channel setup.

---

## Post-Setup: Connecting Channels

After setup, configure your messaging channels:
1. Access the dashboard (via SSH tunnel)
2. Or run the onboard wizard: `openclaw onboard`
3. Follow prompts to connect WhatsApp, Telegram, Discord, etc.

## Maintenance

```bash
# Update OpenClaw (VM):
ssh openclaw@<VM_IP> 'docker compose pull && docker compose up -d'

# Update OpenClaw (LXC):
pct exec <VMID> -- npm update -g openclaw

# Security audit:
openclaw security audit --deep

# Check services:
systemctl status openclaw-gateway  # LXC
docker compose ps                   # VM
```
