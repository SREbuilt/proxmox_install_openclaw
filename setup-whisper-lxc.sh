#!/bin/bash
###############################################################################
# setup-whisper-lxc.sh — Shared Whisper STT service in Proxmox LXC
#
# Creates an unprivileged Debian 12 LXC with faster-whisper-server.
# Shared by OpenClaw (VM 100) and Hermes (VM 101) for voice transcription.
#
# Strategy:
#   Phase 1: Create LXC with Proxmox native config
#   Phase 2: SSH in → install Docker → deploy Whisper container
#
# Usage:
#   ./setup-whisper-lxc.sh --ssh-pubkey ~/.ssh/id_ed25519.pub
#
# Optional:
#       --ct-id 102  --ct-ip 192.168.178.82  --gateway 192.168.178.1
#       --ram 1024   --disk 8  --bridge vmbr0  --password "PASS"
#       --whisper-model small  --language de
#
# Prerequisites: Proxmox VE 8.x+
###############################################################################

set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────

CT_ID=102
CT_IP="192.168.178.82"
GATEWAY="192.168.178.1"
RAM=1024
DISK=8
BRIDGE="vmbr0"
USER="whisper"
PASSWORD=""
SSH_PUBKEY_FILE=""
WHISPER_MODEL="small"
LANGUAGE="de"
WHISPER_PORT=8000

# Allowed clients (OpenClaw + Hermes)
OPENCLAW_IP="192.168.178.80"
HERMES_IP="192.168.178.81"

TEMPLATE_URL="http://download.proxmox.com/images/system/debian-12-standard_12.7-1_amd64.tar.zst"
TEMPLATE_NAME="debian-12-standard_12.7-1_amd64.tar.zst"
TEMPLATE_PATH="/var/lib/vz/template/cache/${TEMPLATE_NAME}"

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
        --ct-id)          CT_ID="$2";          shift 2 ;;
        --ct-ip)          CT_IP="$2";          shift 2 ;;
        --gateway)        GATEWAY="$2";        shift 2 ;;
        --ram)            RAM="$2";            shift 2 ;;
        --disk)           DISK="$2";           shift 2 ;;
        --bridge)         BRIDGE="$2";         shift 2 ;;
        --password)       PASSWORD="$2";       shift 2 ;;
        --ssh-pubkey)     SSH_PUBKEY_FILE="$2"; shift 2 ;;
        --whisper-model)  WHISPER_MODEL="$2";  shift 2 ;;
        --language)       LANGUAGE="$2";       shift 2 ;;
        *)                fail "Unknown argument: $1" ;;
    esac
done

# ─── Validate ────────────────────────────────────────────────────────────────

[[ -z "$SSH_PUBKEY_FILE" ]] && fail "Missing --ssh-pubkey"
[[ ! -f "$SSH_PUBKEY_FILE" ]] && fail "SSH pubkey not found: $SSH_PUBKEY_FILE"
command -v pct &>/dev/null || fail "Must run on a Proxmox host"

[[ -z "$PASSWORD" ]] && PASSWORD=$(openssl rand -base64 12)

ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$CT_IP" 2>/dev/null || true

SSH_CMD="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes"

info "═══════════════════════════════════════════════════"
info "  Whisper LXC Setup — Shared STT Service"
info "═══════════════════════════════════════════════════"
info "  CT ID:     $CT_ID"
info "  CT IP:     $CT_IP"
info "  RAM:       ${RAM}MB  Disk: ${DISK}GB"
info "  User:      root (LXC)  Password: $PASSWORD"
info "  Model:     $WHISPER_MODEL  Language: $LANGUAGE"
info "  Port:      $WHISPER_PORT"
info "  Clients:   $OPENCLAW_IP (OpenClaw), $HERMES_IP (Hermes)"
info "═══════════════════════════════════════════════════"

###############################################################################
# Step 1/6: Download LXC template
###############################################################################

info "Step 1/6: Downloading Debian 12 LXC template..."
if [[ -f "$TEMPLATE_PATH" ]]; then
    ok "Template already cached"
else
    wget -q --show-progress -O "$TEMPLATE_PATH" "$TEMPLATE_URL"
    ok "Template downloaded"
fi

###############################################################################
# Step 2/6: Create LXC
###############################################################################

info "Step 2/6: Creating LXC $CT_ID..."

if pct status "$CT_ID" &>/dev/null; then
    warn "LXC $CT_ID exists — destroying"
    pct stop "$CT_ID" 2>/dev/null || true
    sleep 2
    pct destroy "$CT_ID" --purge 2>/dev/null || true
    sleep 2
fi

pct create "$CT_ID" "$TEMPLATE_PATH" \
    --hostname whisper \
    --ostype debian \
    --cores 2 \
    --memory "$RAM" \
    --swap 512 \
    --rootfs "local-lvm:${DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=${CT_IP}/24,gw=${GATEWAY},firewall=0" \
    --nameserver "$GATEWAY" \
    --searchdomain "local" \
    --password "$PASSWORD" \
    --ssh-public-keys "$SSH_PUBKEY_FILE" \
    --unprivileged 1 \
    --features nesting=1,keyctl=1 \
    --onboot 1 \
    --start 0

ok "LXC $CT_ID created (${DISK}GB disk, unprivileged)"

###############################################################################
# Step 3/6: Proxmox firewall (restrict access to OpenClaw + Hermes only)
###############################################################################

info "Step 3/6: Configuring Proxmox firewall..."

cat > "/etc/pve/firewall/${CT_ID}.fw" << EOF
[OPTIONS]
enable: 0
policy_in: DROP
policy_out: ACCEPT

[RULES]
# Only OpenClaw and Hermes can access Whisper
IN ACCEPT -source ${OPENCLAW_IP}/32 -p tcp -dport ${WHISPER_PORT} -log nolog
IN ACCEPT -source ${HERMES_IP}/32 -p tcp -dport ${WHISPER_PORT} -log nolog

# SSH from LAN
IN ACCEPT -source 192.168.178.0/24 -p tcp -dport 22 -log nolog

# ICMP
IN ACCEPT -p icmp -log nolog
EOF

ok "Firewall: Whisper port restricted to OpenClaw + Hermes only"

###############################################################################
# Step 4/6: Start LXC + wait for SSH
###############################################################################

info "Step 4/6: Starting LXC..."
pct start "$CT_ID"
ok "LXC $CT_ID started"

info "  Waiting for SSH..."
ELAPSED=0
while [[ $ELAPSED -lt 120 ]]; do
    if $SSH_CMD "root@${CT_IP}" "echo SSH_OK" 2>/dev/null | grep -q "SSH_OK"; then
        ok "SSH is ready"
        break
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    printf "."
done
echo ""

if ! $SSH_CMD "root@${CT_IP}" "echo OK" 2>/dev/null | grep -q "OK"; then
    fail "Cannot reach LXC via SSH after 120s."
fi

###############################################################################
# Step 5/6: Install Docker + Whisper via SSH
###############################################################################

info "Step 5/6: Installing Docker + Whisper..."

$SSH_CMD "root@${CT_IP}" << 'INSTALL_DOCKER'
set -e
echo "[1/3] Installing Docker..."
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable --now docker
echo "DOCKER_OK"
INSTALL_DOCKER
ok "  Docker installed"

# Write docker-compose.yml
info "  Writing docker-compose.yml..."
$SSH_CMD "root@${CT_IP}" "mkdir -p /root/whisper && cat > /root/whisper/docker-compose.yml" << COMPOSE_EOF
services:
  whisper:
    image: fedirz/faster-whisper-server:latest-cpu
    container_name: whisper
    restart: unless-stopped
    ports:
      - "${CT_IP}:${WHISPER_PORT}:8000"
    environment:
      - WHISPER__MODEL=${WHISPER_MODEL}
      - WHISPER__INFERENCE_DEVICE=cpu
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://127.0.0.1:8000/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    deploy:
      resources:
        limits:
          memory: 900M
          cpus: "2.0"
COMPOSE_EOF
ok "  docker-compose.yml written"

# Pull and start
info "  Pulling Whisper image (this may take 1-2 minutes)..."
$SSH_CMD "root@${CT_IP}" << 'START_WHISPER'
set -e
cd /root/whisper
docker compose pull --quiet
docker compose up -d
echo "Waiting 30s for model download..."
sleep 30
docker ps --format "table {{.Names}}\t{{.Status}}"
echo "WHISPER_OK"
START_WHISPER
ok "  Whisper deployed"

# Health check
info "  Waiting for Whisper health..."
ELAPSED=0
while [[ $ELAPSED -lt 120 ]]; do
    if $SSH_CMD "root@${CT_IP}" "curl -sf http://127.0.0.1:${WHISPER_PORT}/health" 2>/dev/null | grep -qi "ok\|OK"; then
        ok "  Whisper is healthy!"
        break
    fi
    sleep 10
    ELAPSED=$((ELAPSED + 10))
done

###############################################################################
# Step 6/6: Enable firewall + update OpenClaw & Hermes
###############################################################################

info "Step 6/6: Enabling firewall + configuring clients..."

# Enable LXC firewall
sed -i 's/^enable: 0/enable: 1/' "/etc/pve/firewall/${CT_ID}.fw"

# Enable NIC firewall
pct set "$CT_ID" --net0 "name=eth0,bridge=${BRIDGE},ip=${CT_IP}/24,gw=${GATEWAY},firewall=1"
ok "LXC firewall enabled"

# Update OpenClaw Whisper config to point to shared LXC
info "  Updating OpenClaw to use shared Whisper..."
$SSH_CMD "claw@${OPENCLAW_IP}" << PATCH_OPENCLAW
set -e
# Update audio args in openclaw.json to point to Whisper LXC
cd ~/openclaw

# Replace localhost Whisper URL with LXC IP
sed -i 's|http://127.0.0.1:8000/v1/audio/transcriptions|http://${CT_IP}:${WHISPER_PORT}/v1/audio/transcriptions|' ~/.openclaw/openclaw.json

# Remove Whisper container from docker-compose (now external)
# Create new compose without whisper service
python3 -c "
import re
with open('docker-compose.yml','r') as f: content = f.read()
# Remove whisper service block
content = re.sub(r'  whisper:.*?(?=\n[a-z]|\Z)', '', content, flags=re.DOTALL)
with open('docker-compose.yml','w') as f: f.write(content)
print('Whisper removed from docker-compose')
" 2>/dev/null || echo "Manual compose edit needed"

# Restart OpenClaw (without Whisper container)
sudo docker compose down --remove-orphans 2>/dev/null || true
sudo docker compose up -d
echo "OpenClaw updated"
PATCH_OPENCLAW
ok "  OpenClaw updated"

# Add Whisper firewall rule to OpenClaw VM (allow outbound to Whisper LXC)
OPENCLAW_FW="/etc/pve/firewall/100.fw"
if ! grep -q "${CT_IP}" "$OPENCLAW_FW" 2>/dev/null; then
    # Insert before the DROP rules
    sed -i "/OUT DROP -d 10.0.0.0/i OUT ACCEPT -dest ${CT_IP} -dport ${WHISPER_PORT} -p tcp -log nolog    # Whisper LXC" "$OPENCLAW_FW"
    ok "  OpenClaw firewall: Whisper LXC access added"
fi

# Add Whisper firewall rule to Hermes VM
HERMES_FW="/etc/pve/firewall/101.fw"
if [[ -f "$HERMES_FW" ]] && ! grep -q "${CT_IP}" "$HERMES_FW" 2>/dev/null; then
    sed -i "/OUT DROP -d 10.0.0.0/i OUT ACCEPT -dest ${CT_IP} -dport ${WHISPER_PORT} -p tcp -log nolog    # Whisper LXC" "$HERMES_FW"
    ok "  Hermes firewall: Whisper LXC access added"
fi

# Verify from OpenClaw
info "  Verifying Whisper access from OpenClaw..."
WHISPER_CHECK=$($SSH_CMD "claw@${OPENCLAW_IP}" "curl -sf --max-time 5 http://${CT_IP}:${WHISPER_PORT}/health" 2>/dev/null || echo "BLOCKED")
if echo "$WHISPER_CHECK" | grep -qi "ok\|OK"; then
    ok "  OpenClaw → Whisper: accessible"
else
    warn "  OpenClaw → Whisper: $WHISPER_CHECK (may need firewall restart)"
fi

###############################################################################
# Summary
###############################################################################

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✅ Whisper LXC Setup Complete!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""
echo "  LXC ID:         $CT_ID"
echo "  LXC IP:         $CT_IP"
echo "  Password:       $PASSWORD"
echo "  SSH:            ssh root@${CT_IP}"
echo ""
echo "  Whisper API:    http://${CT_IP}:${WHISPER_PORT}"
echo "  Model:          ${WHISPER_MODEL}"
echo "  Language:       ${LANGUAGE}"
echo ""
echo "  Access Control:"
echo "    ✅ ${OPENCLAW_IP} (OpenClaw) → port ${WHISPER_PORT}"
echo "    ✅ ${HERMES_IP} (Hermes) → port ${WHISPER_PORT}"
echo "    ❌ All other IPs blocked"
echo ""
echo "  Test transcription:"
echo "    curl -X POST http://${CT_IP}:${WHISPER_PORT}/v1/audio/transcriptions \\"
echo "      -F 'file=@audio.ogg' -F 'model=Systran/faster-whisper-${WHISPER_MODEL}' \\"
echo "      -F 'response_format=text' -F 'language=${LANGUAGE}'"
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}  ⚠️  SAVE the password: ${PASSWORD}${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
