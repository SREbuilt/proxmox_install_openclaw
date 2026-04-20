#!/bin/bash
###############################################################################
# niklas_setup-openclaw-vm.sh — Fire-and-forget OpenClaw VM on Proxmox
#
# Strategy (same as proven Hermes v8 script):
#   Phase 1: Proxmox-native cloud-init (user, SSH key, password, IP)
#   Phase 2: Wait for boot (handle first-boot kernel panic automatically)
#   Phase 3: SSH into VM → install Docker → deploy OpenClaw
#
# Includes: Z.AI GLM provider, Telegram, shared Whisper (LXC 102),
#   Home Assistant + Grafana firewall whitelist, hardened tool config
#
# Usage:
#   ./niklas_setup-openclaw-vm.sh \
#       --zai-api-key "KEY" --ssh-pubkey ~/.ssh/id_ed25519.pub
#
# Optional:
#       --vm-id 100  --vm-ip 192.168.178.80  --gateway 192.168.178.1
#       --ram 4096   --disk 256  --bridge vmbr0  --user claw
#       --telegram-token "TOKEN"  --ha-token "TOKEN"  --password "PASS"
#
# Prerequisites: Proxmox VE 8.x+, jq, SSH key pair
###############################################################################

set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────

VM_ID=100
VM_IP="192.168.178.80"
GATEWAY="192.168.178.1"
RAM=4096
DISK=256
BRIDGE="vmbr0"
USER="claw"
PASSWORD=""
ZAI_KEY=""
SSH_PUBKEY_FILE=""
TELEGRAM_TOKEN=""
HA_TOKEN=""
HA_URL="http://192.168.178.88:8123"
GRAFANA_URL="https://192.168.178.98/proxy/grafana"

HA_IP="192.168.178.88"
HA_PORT="8123"
GRAFANA_IP="192.168.178.98"
GRAFANA_PORT="443"

WHISPER_IP="192.168.178.82"
WHISPER_PORT="8000"

CLOUD_IMG_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
CLOUD_IMG_PATH="/var/lib/vz/template/iso/debian-12-generic-amd64.qcow2"

# ─── Colors ──────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; exit 1; }

# ─── Parse arguments ────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vm-id)          VM_ID="$2";          shift 2 ;;
        --vm-ip)          VM_IP="$2";          shift 2 ;;
        --gateway)        GATEWAY="$2";        shift 2 ;;
        --ram)            RAM="$2";            shift 2 ;;
        --disk)           DISK="$2";           shift 2 ;;
        --bridge)         BRIDGE="$2";         shift 2 ;;
        --user)           USER="$2";           shift 2 ;;
        --password)       PASSWORD="$2";       shift 2 ;;
        --zai-api-key)    ZAI_KEY="$2";        shift 2 ;;
        --ssh-pubkey)     SSH_PUBKEY_FILE="$2"; shift 2 ;;
        --telegram-token) TELEGRAM_TOKEN="$2"; shift 2 ;;
        --ha-token)       HA_TOKEN="$2";       shift 2 ;;
        *)                fail "Unknown argument: $1" ;;
    esac
done

# ─── Validate ────────────────────────────────────────────────────────────────

[[ -z "$ZAI_KEY" ]] && fail "Missing --zai-api-key"
[[ -z "$SSH_PUBKEY_FILE" ]] && fail "Missing --ssh-pubkey"
[[ ! -f "$SSH_PUBKEY_FILE" ]] && fail "SSH pubkey not found: $SSH_PUBKEY_FILE"
command -v jq &>/dev/null || fail "jq not installed. Run: apt install -y jq"
command -v qm &>/dev/null || fail "Must run on a Proxmox host"

[[ -z "$PASSWORD" ]] && PASSWORD=$(openssl rand -base64 12)

ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$VM_IP" 2>/dev/null || true

SSH_CMD="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes"

GATEWAY_TOKEN=$(openssl rand -hex 32)

info "═══════════════════════════════════════════════════"
info "  OpenClaw VM Setup — Fire & Forget"
info "═══════════════════════════════════════════════════"
info "  VM ID:     $VM_ID"
info "  VM IP:     $VM_IP"
info "  RAM:       ${RAM}MB  Disk: ${DISK}GB"
info "  User:      $USER  Password: $PASSWORD"
info "  CPU:       x86-64-v2-AES"
info "  Z.AI:      ${ZAI_KEY:0:8}..."
info "  Telegram:  ${TELEGRAM_TOKEN:+configured}${TELEGRAM_TOKEN:-(not set)}"
info "  HA Token:  ${HA_TOKEN:+configured}${HA_TOKEN:-(not set)}"
info "  GW Token:  ${GATEWAY_TOKEN:0:16}..."
info "═══════════════════════════════════════════════════"

###############################################################################
# Step 1/8: Download Debian cloud image
###############################################################################

info "Step 1/8: Downloading Debian 12 cloud image..."
if [[ -f "$CLOUD_IMG_PATH" ]]; then
    ok "Cloud image already cached"
else
    wget -q --show-progress -O "$CLOUD_IMG_PATH" "$CLOUD_IMG_URL"
    ok "Cloud image downloaded"
fi

###############################################################################
# Step 2/8: Create VM
###############################################################################

info "Step 2/8: Creating VM $VM_ID..."

if qm status "$VM_ID" &>/dev/null; then
    warn "VM $VM_ID exists — destroying"
    qm stop "$VM_ID" --skiplock 2>/dev/null || true
    sleep 3
    qm destroy "$VM_ID" --purge 2>/dev/null || true
    sleep 2
fi

qm create "$VM_ID" \
    --name "openclaw" \
    --ostype l26 \
    --cores 2 \
    --memory "$RAM" \
    --cpu cputype=x86-64-v2-AES \
    --net0 "virtio,bridge=${BRIDGE},firewall=0" \
    --scsihw virtio-scsi-single \
    --vga std \
    --agent enabled=1 \
    --onboot 1

qm importdisk "$VM_ID" "$CLOUD_IMG_PATH" local-lvm --format raw >/dev/null
qm set "$VM_ID" --scsi0 "local-lvm:vm-${VM_ID}-disk-0,discard=on,ssd=1"
qm set "$VM_ID" --boot order=scsi0
qm resize "$VM_ID" scsi0 "${DISK}G"
qm set "$VM_ID" --ide2 "local-lvm:cloudinit"

ok "VM $VM_ID created (${DISK}GB disk, x86-64-v2-AES CPU)"

###############################################################################
# Step 3/8: Proxmox-native cloud-init (NO cicustom!)
###############################################################################

info "Step 3/8: Configuring cloud-init (native Proxmox)..."

qm set "$VM_ID" \
    --ciuser "$USER" \
    --cipassword "$PASSWORD" \
    --sshkeys "$SSH_PUBKEY_FILE" \
    --ipconfig0 "ip=${VM_IP}/24,gw=${GATEWAY}" \
    --nameserver "$GATEWAY" \
    --searchdomain "local"

ok "Cloud-init: user=$USER, IP=$VM_IP, SSH key + password auth"

###############################################################################
# Step 4/8: Proxmox firewall (disabled until setup completes)
###############################################################################

info "Step 4/8: Preparing Proxmox firewall (disabled until setup completes)..."

CLUSTER_FW="/etc/pve/firewall/cluster.fw"
if ! grep -q "^enable: 1" "$CLUSTER_FW" 2>/dev/null; then
    cat > "$CLUSTER_FW" << 'EOF'
[OPTIONS]
enable: 1
policy_in: ACCEPT
policy_out: ACCEPT
EOF
fi

cat > "/etc/pve/firewall/${VM_ID}.fw" << EOF
[OPTIONS]
enable: 0
dhcp: 1
policy_in: DROP
policy_out: DROP

[RULES]
OUT ACCEPT -d ${GATEWAY}/32 -log nolog
OUT ACCEPT -d ${GATEWAY}/32 -p udp -dport 53 -log nolog
OUT ACCEPT -d ${GATEWAY}/32 -p tcp -dport 53 -log nolog
OUT ACCEPT -dest ${HA_IP} -dport ${HA_PORT} -p tcp -log nolog
OUT ACCEPT -dest ${GRAFANA_IP} -dport ${GRAFANA_PORT} -p tcp -log nolog
OUT ACCEPT -dest ${WHISPER_IP} -dport ${WHISPER_PORT} -p tcp -log nolog
OUT DROP -d 10.0.0.0/8 -log nolog
OUT DROP -d 172.16.0.0/12 -log nolog
OUT DROP -d 192.168.0.0/16 -log nolog
OUT DROP -d 169.254.0.0/16 -log nolog
OUT ACCEPT -log nolog
IN ACCEPT -source 192.168.178.0/24 -p tcp -dport 22 -log nolog
IN ACCEPT -p icmp -log nolog
EOF

ok "Firewall rules written (DISABLED until setup completes)"

###############################################################################
# Step 5/8: Start VM (with Docker-on-host detection)
###############################################################################

info "Step 5/8: Starting VM..."

# Detect + remove Docker from Proxmox host (blocks all VM traffic!)
if iptables -L DOCKER-USER -n &>/dev/null; then
    warn "Docker detected on Proxmox host — this blocks ALL VM network traffic!"
    warn "Removing Docker from Proxmox host..."
    systemctl stop docker docker.socket containerd 2>/dev/null || true
    systemctl disable docker docker.socket containerd 2>/dev/null || true
    apt purge -y docker-ce docker-ce-cli docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras containerd.io 2>/dev/null || true
    apt autoremove -y 2>/dev/null || true
    iptables -P FORWARD ACCEPT
    iptables -F FORWARD 2>/dev/null || true
    pve-firewall restart
    ok "Docker removed from Proxmox host, firewall restored"
fi

qm start "$VM_ID"
ok "VM $VM_ID started"

###############################################################################
# Step 6/8: Wait for boot (handle first-boot kernel panic)
###############################################################################

info "Step 6/8: Waiting for VM to boot..."
info "  (First boot may kernel panic — auto-recovery enabled)"

sleep 30

VM_STATUS=$(qm status "$VM_ID" 2>/dev/null | awk '{print $2}')
if [[ "$VM_STATUS" == "stopped" ]]; then
    warn "First-boot kernel panic detected — restarting VM..."
    qm start "$VM_ID"
    sleep 30
fi

ELAPSED=0
RESET_DONE=false
while [[ $ELAPSED -lt 240 ]]; do
    if $SSH_CMD "${USER}@${VM_IP}" "echo SSH_OK" 2>/dev/null | grep -q "SSH_OK"; then
        ok "SSH is ready"
        break
    fi

    if [[ $ELAPSED -ge 90 ]] && [[ "$RESET_DONE" == "false" ]]; then
        VM_STATUS=$(qm status "$VM_ID" 2>/dev/null | awk '{print $2}')
        if [[ "$VM_STATUS" == "stopped" ]]; then
            warn "VM stopped — doing clean start..."
            qm start "$VM_ID"
            RESET_DONE=true
            sleep 30
        elif ! ping -c 1 -W 2 "$VM_IP" &>/dev/null; then
            warn "VM not responding — doing clean stop + start..."
            qm stop "$VM_ID" --timeout 10 2>/dev/null || qm reset "$VM_ID"
            sleep 5
            qm start "$VM_ID"
            RESET_DONE=true
            sleep 30
        fi
    fi

    sleep 10
    ELAPSED=$((ELAPSED + 10))
    printf "."
done
echo ""

if ! $SSH_CMD "${USER}@${VM_IP}" "echo FINAL_OK" 2>/dev/null | grep -q "FINAL_OK"; then
    fail "Cannot reach VM via SSH after 240s. Check Proxmox Console."
fi

# Wait for cloud-init to fully complete
info "  Waiting for cloud-init to finish (apt updates, 3-8 minutes)..."
ELAPSED=0
while [[ $ELAPSED -lt 600 ]]; do
    CI_STATUS=$($SSH_CMD "${USER}@${VM_IP}" "cloud-init status 2>/dev/null | head -1" 2>/dev/null || echo "unknown")
    if echo "$CI_STATUS" | grep -q "done"; then
        ok "Cloud-init completed"
        break
    fi
    sleep 15
    ELAPSED=$((ELAPSED + 15))
    printf "."
done
echo ""

if [[ $ELAPSED -ge 600 ]]; then
    warn "Cloud-init still running after 10min — proceeding anyway"
fi

###############################################################################
# Step 7/8: Phase 2 — Install Docker + OpenClaw via SSH
###############################################################################

info "Step 7/8: Installing Docker + OpenClaw via SSH..."

# --- 7a: Install Docker ---
info "  [1/7] Installing Docker..."
$SSH_CMD "${USER}@${VM_IP}" << 'DOCKER_INSTALL'
set -e
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update -qq
sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin qemu-guest-agent jq curl
sudo systemctl enable --now docker
sudo systemctl enable --now qemu-guest-agent
sudo usermod -aG docker $USER
echo "DOCKER_OK"
DOCKER_INSTALL
ok "  Docker installed"

# --- 7b: Create directories ---
info "  [2/7] Creating directories..."
$SSH_CMD "${USER}@${VM_IP}" "mkdir -p ~/openclaw/workspace ~/.openclaw/agents/main/agent ~/.openclaw/bin ~/.openclaw/workspace/skills"
ok "  Directories created"

# --- 7c: Write docker-compose.yml ---
info "  [3/7] Writing docker-compose.yml..."
$SSH_CMD "${USER}@${VM_IP}" "cat > ~/openclaw/docker-compose.yml" << 'COMPOSE_EOF'
services:
  openclaw-gateway:
    image: ghcr.io/openclaw/openclaw:latest
    container_name: openclaw-gateway
    restart: unless-stopped
    network_mode: host
    cap_drop:
      - NET_RAW
      - NET_ADMIN
      - SYS_ADMIN
    security_opt:
      - no-new-privileges
    volumes:
      - /home/claw/.openclaw:/home/node/.openclaw
      - /home/claw/openclaw/workspace:/workspace
    command: >
      node openclaw.mjs gateway
      --allow-unconfigured
      --bind loopback
      --port 18789
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://127.0.0.1:18789/healthz"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 15s
    environment:
      HOME: /home/node
      TERM: xterm-256color
    env_file:
      - /home/claw/.openclaw/.credentials.env
COMPOSE_EOF
ok "  docker-compose.yml written"

# --- 7d: Write .credentials.env ---
info "  [4/7] Writing credentials..."
$SSH_CMD "${USER}@${VM_IP}" "printf '%s\n' \
  'HA_URL=${HA_URL}' \
  'HA_TOKEN=${HA_TOKEN}' \
  'GRAFANA_URL=${GRAFANA_URL}' \
  > ~/.openclaw/.credentials.env && chmod 644 ~/.openclaw/.credentials.env"
ok "  Credentials written"

# --- 7e: Write openclaw.json ---
info "  [5/7] Writing openclaw.json..."
$SSH_CMD "${USER}@${VM_IP}" "cat > ~/.openclaw/openclaw.json" << OCJSON_EOF
{
  "gateway": {
    "mode": "local",
    "bind": "loopback",
    "auth": {
      "mode": "token",
      "token": "${GATEWAY_TOKEN}"
    },
    "port": 18789
  },
  "session": {
    "dmScope": "per-channel-peer"
  },
  "models": {
    "mode": "merge",
    "providers": {
      "zai": {
        "baseUrl": "https://api.z.ai/api/coding/paas/v4",
        "api": "openai-completions",
        "models": [
          {"id": "glm-4.7", "name": "GLM-4.7", "reasoning": true, "input": ["text"], "cost": {"input": 0.6, "output": 2.2, "cacheRead": 0.11, "cacheWrite": 0}, "contextWindow": 204800, "maxTokens": 131072},
          {"id": "glm-4.7-flash", "name": "GLM-4.7 Flash", "reasoning": true, "input": ["text"], "cost": {"input": 0.07, "output": 0.4, "cacheRead": 0, "cacheWrite": 0}, "contextWindow": 200000, "maxTokens": 131072},
          {"id": "glm-5.1", "name": "GLM-5.1", "reasoning": true, "input": ["text"], "cost": {"input": 1.2, "output": 4, "cacheRead": 0.24, "cacheWrite": 0}, "contextWindow": 202800, "maxTokens": 131100}
        ]
      }
    }
  },
  "tools": {
    "profile": "coding",
    "deny": ["sessions_spawn", "sessions_send"],
    "fs": {"workspaceOnly": true},
    "exec": {"security": "full", "ask": "off"},
    "elevated": {"enabled": false},
    "web": {"search": {"provider": "brave"}},
    "media": {
      "audio": {
        "enabled": true,
        "models": [{
          "type": "cli",
          "command": "curl",
          "args": ["-sf", "-X", "POST", "http://192.168.178.82:8000/v1/audio/transcriptions", "-F", "file=@{{MediaPath}}", "-F", "model=Systran/faster-whisper-small", "-F", "response_format=text", "-F", "language=de"],
          "timeoutSeconds": 60
        }]
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {"primary": "zai/glm-4.7"},
      "workspace": "/home/node/.openclaw/workspace"
    }
  },
  "skills": {
    "install": {"nodeManager": "bun"}
  },
  "hooks": {
    "internal": {
      "enabled": true,
      "entries": {
        "boot-md": {"enabled": true},
        "session-memory": {"enabled": true}
      }
    }
  },
  "channels": {
    "telegram": {
      "enabled": true,
      "groups": {"*": {"requireMention": true}},
      "botToken": "${TELEGRAM_TOKEN}"
    }
  }
}
OCJSON_EOF
ok "  openclaw.json written"

# --- 7f: Write auth-profiles.json ---
info "  [6/7] Writing auth-profiles.json..."
$SSH_CMD "${USER}@${VM_IP}" "cat > ~/.openclaw/agents/main/agent/auth-profiles.json" << AUTHEOF
{
  "version": 1,
  "profiles": {
    "zai:default": {
      "type": "api_key",
      "provider": "zai",
      "key": "${ZAI_KEY}"
    }
  }
}
AUTHEOF
ok "  Auth profiles written"

# --- 7g: Write boot.md + Pull + Start ---
info "  [7/7] Writing boot.md, pulling images, starting containers..."
$SSH_CMD "${USER}@${VM_IP}" "cat > ~/.openclaw/boot.md" << 'BOOTEOF'
## Verfuegbare Integrationen

### Home Assistant (Smart Home)
- URL: $HA_URL (Env-Var im Container verfuegbar)
- Token: $HA_TOKEN (Env-Var im Container verfuegbar)
- Nutze curl mit den Env-Vars $HA_URL und $HA_TOKEN
- jq liegt unter /home/node/.openclaw/bin/jq

### Grafana (Solar-Dashboards)
- URL: $GRAFANA_URL (Env-Var im Container verfuegbar)

### Wichtig
- Du HAST Netzwerkzugriff auf 192.168.178.88 (Home Assistant) und 192.168.178.98 (Grafana)
- Du HAST die Env-Vars HA_URL, HA_TOKEN, GRAFANA_URL im Container
- Nutze exec Tool mit curl/jq fuer API-Zugriffe
BOOTEOF

# Set permissions
$SSH_CMD "${USER}@${VM_IP}" "chmod -R 755 ~/.openclaw && chmod 600 ~/.openclaw/agents/main/agent/auth-profiles.json"

# Install jq binary for container
$SSH_CMD "${USER}@${VM_IP}" "curl -sL -o ~/.openclaw/bin/jq https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64 && chmod +x ~/.openclaw/bin/jq"

# Disable IPv6
$SSH_CMD "${USER}@${VM_IP}" << 'IPV6OFF'
sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null
sudo sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null
echo "net.ipv6.conf.all.disable_ipv6 = 1" | sudo tee -a /etc/sysctl.d/99-disable-ipv6.conf >/dev/null
echo "net.ipv6.conf.default.disable_ipv6 = 1" | sudo tee -a /etc/sysctl.d/99-disable-ipv6.conf >/dev/null
IPV6OFF

# Pull and start
$SSH_CMD "${USER}@${VM_IP}" << 'START_OC'
set -e
cd ~/openclaw
sudo docker compose pull --quiet
sudo docker compose up -d
echo "Waiting 20s for containers to start..."
sleep 20
sudo docker ps --format "table {{.Names}}\t{{.Status}}"
echo "OPENCLAW_SETUP_COMPLETE"
START_OC
ok "OpenClaw deployed"

###############################################################################
# Step 8/8: Enable firewall + verify
###############################################################################

info "Step 8/8: Enabling firewall + finalizing..."

# Enable VM firewall
sed -i 's/^enable: 0/enable: 1/' "/etc/pve/firewall/${VM_ID}.fw"
ok "VM firewall enabled"

# Enable NIC firewall
CURRENT_MAC=$(qm config "$VM_ID" | grep -oP 'virtio=\K[0-9A-Fa-f:]+' | head -1)
if [[ -n "$CURRENT_MAC" ]]; then
    qm set "$VM_ID" --net0 "virtio=${CURRENT_MAC},bridge=${BRIDGE},firewall=1"
    ok "NIC firewall enabled"
fi

# Health check
info "Waiting for health check..."
ELAPSED=0
while [[ $ELAPSED -lt 60 ]]; do
    if $SSH_CMD "${USER}@${VM_IP}" "curl -sf http://127.0.0.1:18789/healthz" 2>/dev/null; then
        echo ""
        ok "OpenClaw is healthy!"
        break
    fi
    sleep 10
    ELAPSED=$((ELAPSED + 10))
done

# Install HA skill
info "Installing Home Assistant skill..."
$SSH_CMD "${USER}@${VM_IP}" "cd ~/openclaw && sudo docker compose exec -T openclaw-gateway node openclaw.mjs skills install home-assistant 2>/dev/null || echo 'HA skill install skipped (rate limit or not available)'"

# Verify connectivity
INET=$($SSH_CMD "${USER}@${VM_IP}" "curl -sf --max-time 5 https://cloud.debian.org >/dev/null && echo OK || echo FAIL" 2>/dev/null || echo "SKIP")
[[ "$INET" == "OK" ]] && ok "Internet: accessible" || warn "Internet: $INET"

###############################################################################
# Summary
###############################################################################

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✅ OpenClaw VM Setup Complete!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""
echo "  VM ID:          $VM_ID"
echo "  VM IP:          $VM_IP"
echo "  User:           $USER"
echo "  Password:       $PASSWORD"
echo "  Disk:           ${DISK}GB"
echo "  SSH:            ssh ${USER}@${VM_IP}"
echo ""
echo "  Gateway:        http://127.0.0.1:18789 (via SSH tunnel)"
echo "  Gateway Token:  $GATEWAY_TOKEN"
echo "  Whisper:        http://192.168.178.82:8000 (shared LXC 102)"
echo ""
echo "  SSH Tunnel (from Windows):"
echo "    ssh -i C:\\Users\\bvogel\\.ssh\\id_ed25519_openclaw \\"
echo "        -L 18789:localhost:18789 ${USER}@${VM_IP}"
echo ""
if [[ -n "$TELEGRAM_TOKEN" ]]; then
    echo "  Telegram:       Configured (bot token in openclaw.json)"
else
    echo "  Telegram:       Not set — add botToken to ~/.openclaw/openclaw.json channels.telegram"
fi
echo ""
echo "  Firewall:"
echo "    ✅ ${HA_IP}:${HA_PORT} (Home Assistant)"
echo "    ✅ ${GRAFANA_IP}:${GRAFANA_PORT} (Grafana)"
echo "    ✅ ${WHISPER_IP}:${WHISPER_PORT} (Whisper LXC)"
echo "    ❌ Rest of 192.168.178.0/24"
echo "    ✅ Internet"
echo ""
echo "  Model:          zai/glm-4.7 (Z.AI)"
echo "  Tools:          coding profile, exec full, elevated disabled"
echo "  Whisper:        shared LXC 102, small model, German"
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}  ⚠️  SAVE the password: ${PASSWORD}${NC}"
echo -e "${YELLOW}  ⚠️  SAVE the gateway token: ${GATEWAY_TOKEN}${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
