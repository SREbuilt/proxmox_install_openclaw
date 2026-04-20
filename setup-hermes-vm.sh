#!/bin/bash
###############################################################################
# setup-hermes-vm.sh — Fire-and-forget Hermes Agent VM on Proxmox
#
# Strategy (proven through 5 iterations):
#   Phase 1: Proxmox-native cloud-init (user, SSH key, password, IP)
#            NO cicustom — avoids all YAML/heredoc/permission issues
#   Phase 2: Wait for boot (handle first-boot kernel panic automatically)
#   Phase 3: SSH into VM → install Docker → deploy Hermes → patch config
#
# Known issues addressed:
#   - First boot kernel panic on N150 (auto-reset)
#   - cicustom breaks password auth (use native ciuser/cipassword instead)
#   - .env newline issues (write via SSH cat, not heredoc)
#   - Docker changes file ownership (chmod 777 on .hermes/)
#   - Model format: "glm-4.7" not "zai/glm-4.7" or "openai/glm-4.7"
#   - CPU type: x86-64-v2-AES (host causes kernel panic on N150)
#
# Usage:
#   ./setup-hermes-vm.sh \
#       --zai-api-key "KEY" --ssh-pubkey ~/.ssh/id_ed25519.pub
#
# Optional:
#       --vm-id 101  --vm-ip 192.168.178.81  --gateway 192.168.178.1
#       --ram 3072   --disk 100  --bridge vmbr0  --user hermes
#       --telegram-token "TOKEN"  --ha-token "TOKEN"  --password "PASS"
#
# Prerequisites: Proxmox VE 8.x+, jq, SSH key pair
###############################################################################

set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────

VM_ID=101
VM_IP="192.168.178.81"
GATEWAY="192.168.178.1"
RAM=3072
DISK=100
BRIDGE="vmbr0"
USER="hermes"
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

# Remove old known_hosts entry
ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$VM_IP" 2>/dev/null || true

SSH_CMD="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes"

info "═══════════════════════════════════════════════════"
info "  Hermes Agent VM Setup — Fire & Forget"
info "═══════════════════════════════════════════════════"
info "  VM ID:     $VM_ID"
info "  VM IP:     $VM_IP"
info "  RAM:       ${RAM}MB  Disk: ${DISK}GB"
info "  User:      $USER  Password: $PASSWORD"
info "  CPU:       x86-64-v2-AES"
info "  Z.AI:      ${ZAI_KEY:0:8}..."
info "  Telegram:  ${TELEGRAM_TOKEN:+configured}${TELEGRAM_TOKEN:-(not set)}"
info "  HA Token:  ${HA_TOKEN:+configured}${HA_TOKEN:-(not set)}"
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
    --name "hermes-agent" \
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
# Step 4/8: Proxmox firewall
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

# Write firewall rules but keep DISABLED — enable after Phase 2
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
# Step 5/8: Start VM
###############################################################################

info "Step 5/8: Starting VM..."

# Fix Docker iptables FORWARD DROP that blocks VM bridge traffic
# Docker on Proxmox host sets FORWARD policy to DROP — must be removed!
if iptables -L DOCKER-USER -n &>/dev/null; then
    warn "Docker detected on Proxmox host — this blocks ALL VM network traffic!"
    warn "Removing Docker from Proxmox host..."
    systemctl stop docker docker.socket containerd 2>/dev/null || true
    systemctl disable docker docker.socket containerd 2>/dev/null || true
    apt purge -y docker-ce docker-ce-cli docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras containerd.io 2>/dev/null || true
    apt autoremove -y 2>/dev/null || true
    # Restore FORWARD chain
    iptables -P FORWARD ACCEPT
    iptables -F FORWARD 2>/dev/null || true
    # Restart PVE firewall to restore proper rules
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

# Check if VM crashed on first boot
VM_STATUS=$(qm status "$VM_ID" 2>/dev/null | awk '{print $2}')
if [[ "$VM_STATUS" == "stopped" ]]; then
    warn "First-boot kernel panic detected — restarting VM..."
    qm start "$VM_ID"
    sleep 30
fi

# Poll for SSH with auto-reset
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
            warn "VM stopped — doing clean shutdown + start..."
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

# Final SSH check
if ! $SSH_CMD "${USER}@${VM_IP}" "echo FINAL_OK" 2>/dev/null | grep -q "FINAL_OK"; then
    fail "Cannot reach VM via SSH after 240s. Check Proxmox Console."
fi

# Wait for cloud-init to fully complete (including apt-get update/upgrade)
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
# Step 7/8: Phase 2 — Install Docker + Hermes via SSH
###############################################################################

info "Step 7/8: Installing Docker + Hermes via SSH..."

# --- 7a: Install Docker ---
info "  [1/6] Installing Docker..."
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
info "  [2/6] Creating directories..."
$SSH_CMD "${USER}@${VM_IP}" "mkdir -p ~/hermes ~/workspace ~/.hermes/{sessions,memories,skills,cron,hooks,logs}"
ok "  Directories created"

# --- 7c: Write docker-compose.yml ---
info "  [3/6] Writing docker-compose.yml..."
$SSH_CMD "${USER}@${VM_IP}" "cat > ~/hermes/docker-compose.yml" << 'COMPOSE_EOF'
services:
  hermes:
    image: nousresearch/hermes-agent:latest
    container_name: hermes
    restart: unless-stopped
    command: gateway run
    ports:
      - "127.0.0.1:8642:8642"
    cap_drop:
      - NET_RAW
      - NET_ADMIN
      - SYS_ADMIN
    security_opt:
      - no-new-privileges
    volumes:
      - /home/hermes/.hermes:/opt/data
    env_file:
      - /home/hermes/.hermes/.env
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://127.0.0.1:8642/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    networks:
      - hermes-net

  dashboard:
    image: nousresearch/hermes-agent:latest
    container_name: hermes-dashboard
    restart: unless-stopped
    command: dashboard --host 0.0.0.0
    ports:
      - "127.0.0.1:9119:9119"
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges
    volumes:
      - /home/hermes/.hermes:/opt/data
    environment:
      GATEWAY_HEALTH_URL: "http://hermes:8642"
    depends_on:
      - hermes
    networks:
      - hermes-net

networks:
  hermes-net:
    driver: bridge
COMPOSE_EOF
ok "  docker-compose.yml written"

# --- 7d: Write .env ---
info "  [4/6] Writing .env..."
# Use printf over SSH to guarantee correct newlines (no heredoc expansion issues)
$SSH_CMD "${USER}@${VM_IP}" "printf '%s\n' \
  'GLM_API_KEY=${ZAI_KEY}' \
  'HA_URL=${HA_URL}' \
  'HA_TOKEN=${HA_TOKEN}' \
  'GRAFANA_URL=${GRAFANA_URL}' \
  'TELEGRAM_BOT_TOKEN=${TELEGRAM_TOKEN}' \
  'GATEWAY_ALLOW_ALL_USERS=true' \
  > ~/.hermes/.env && chmod 644 ~/.hermes/.env"
ok "  .env written"

# --- 7e: Write SOUL.md ---
info "  [5/6] Writing SOUL.md..."
$SSH_CMD "${USER}@${VM_IP}" "cat > ~/.hermes/SOUL.md" << 'SOUL_EOF'
# Hermes — Personal AI Assistant

Du bist Hermes, ein hilfreicher persoenlicher AI-Assistent.
Du sprichst Deutsch und Englisch.

## Capabilities
- Smart Home control via Home Assistant (use $HA_URL and $HA_TOKEN env vars)
- Grafana Solar Dashboard queries
- Tennis court booking (TC Kleinberghofen, TC Erdweg)
- General questions and tasks

## Important
- You HAVE network access to Home Assistant (192.168.178.88:8123) and Grafana (192.168.178.98:443)
- Use curl with $HA_URL and $HA_TOKEN env vars for HA API calls
- You run on a secured Proxmox VM with restricted LAN access
SOUL_EOF
ok "  SOUL.md written"

# --- 7f: Pull, start, patch config ---
info "  [6/6] Pulling and starting Hermes (2-3 minutes)..."
$SSH_CMD "${USER}@${VM_IP}" << 'START_HERMES'
set -e

# Make .hermes writable by Docker container
chmod -R 777 ~/.hermes

# Pull and start
sudo docker compose -f ~/hermes/docker-compose.yml pull --quiet
sudo docker compose -f ~/hermes/docker-compose.yml up -d

echo "Waiting 30s for Hermes to generate default config..."
sleep 30

# Patch config.yaml: set Z.AI provider + correct model name
if [ -f ~/.hermes/config.yaml ]; then
    # Fix model: must be plain "glm-4.7" (not "zai/glm-4.7" or "openai/...")
    sed -i 's/default:.*"anthropic\/[^"]*"/default: "glm-4.7"/' ~/.hermes/config.yaml
    sed -i 's/default:.*"openai\/[^"]*"/default: "glm-4.7"/' ~/.hermes/config.yaml
    # Set provider to zai
    sed -i '0,/^  provider:/s/^  provider:.*/  provider: "zai"/' ~/.hermes/config.yaml 2>/dev/null || true
    grep -q '^  provider:' ~/.hermes/config.yaml || sed -i '/^model:/a\  provider: "zai"' ~/.hermes/config.yaml
    # Set base_url to Z.AI endpoint
    sed -i 's|base_url: "https://openrouter.ai/api/v1"|base_url: "https://api.z.ai/api/coding/paas/v4"|' ~/.hermes/config.yaml
    echo "Config patched: model=glm-4.7, provider=zai, base_url=z.ai"
else
    echo "WARNING: config.yaml not yet generated"
fi

# Ensure permissions are wide open for Docker
chmod -R 777 ~/.hermes

# Restart with patched config
sudo docker compose -f ~/hermes/docker-compose.yml restart hermes
sleep 15

# Verify
echo "=== Container Status ==="
sudo docker ps --format "table {{.Names}}\t{{.Status}}"
echo ""
echo "=== Config Check ==="
grep -A3 "^model:" ~/.hermes/config.yaml 2>/dev/null | head -4
echo ""
echo "=== .env Check ==="
head -2 ~/.hermes/.env
echo ""
echo "HERMES_SETUP_COMPLETE"
START_HERMES
ok "Hermes Agent deployed and configured"

###############################################################################
# Step 8/8: Enable NIC firewall + disable IPv6
###############################################################################

info "Step 8/8: Enabling firewall + finalizing security..."

# Enable VM firewall now that setup is complete
sed -i 's/^enable: 0/enable: 1/' "/etc/pve/firewall/${VM_ID}.fw"
ok "VM firewall enabled"

# Enable Proxmox NIC firewall
CURRENT_MAC=$(qm config "$VM_ID" | grep -oP 'virtio=\K[0-9A-Fa-f:]+' | head -1)
if [[ -n "$CURRENT_MAC" ]]; then
    qm set "$VM_ID" --net0 "virtio=${CURRENT_MAC},bridge=${BRIDGE},firewall=1"
    ok "Proxmox NIC firewall enabled"
fi

# Disable IPv6 inside VM
$SSH_CMD "${USER}@${VM_IP}" << 'IPV6_DISABLE'
sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null
sudo sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null
echo "net.ipv6.conf.all.disable_ipv6 = 1" | sudo tee -a /etc/sysctl.d/99-disable-ipv6.conf >/dev/null
echo "net.ipv6.conf.default.disable_ipv6 = 1" | sudo tee -a /etc/sysctl.d/99-disable-ipv6.conf >/dev/null
echo "IPv6 disabled"
IPV6_DISABLE
ok "IPv6 disabled"

# Final health check
info "Final health check..."
ELAPSED=0
while [[ $ELAPSED -lt 60 ]]; do
    if $SSH_CMD "${USER}@${VM_IP}" "curl -sf http://127.0.0.1:8642/health" 2>/dev/null; then
        echo ""
        ok "Hermes Agent is healthy!"
        break
    fi
    sleep 10
    ELAPSED=$((ELAPSED + 10))
done

GW_TOKEN=$($SSH_CMD "${USER}@${VM_IP}" "grep auth_token ~/.hermes/config.yaml 2>/dev/null | head -1 | awk '{print \$2}' | tr -d '\"'" 2>/dev/null || echo "check config.yaml")

###############################################################################
# Summary
###############################################################################

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✅ Hermes Agent VM Setup Complete!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""
echo "  VM ID:          $VM_ID"
echo "  VM IP:          $VM_IP"
echo "  User:           $USER"
echo "  Password:       $PASSWORD"
echo "  Disk:           ${DISK}GB"
echo "  SSH:            ssh ${USER}@${VM_IP}"
echo ""
echo "  Gateway API:    http://127.0.0.1:8642 (via SSH tunnel)"
echo "  Dashboard:      http://127.0.0.1:9119 (via SSH tunnel)"
echo "  Gateway Token:  $GW_TOKEN"
echo ""
echo "  SSH Tunnel (from Windows):"
echo "    ssh -i C:\\Users\\bvogel\\.ssh\\id_ed25519_openclaw \\"
echo "        -L 8642:localhost:8642 -L 9119:localhost:9119 \\"
echo "        ${USER}@${VM_IP}"
echo ""
if [[ -n "$TELEGRAM_TOKEN" ]]; then
    echo "  Telegram:       Configured"
else
    echo "  Telegram:       Not set — add TELEGRAM_BOT_TOKEN to ~/.hermes/.env"
fi
echo ""
echo "  Firewall:"
echo "    ✅ ${HA_IP}:${HA_PORT} (Home Assistant)"
echo "    ✅ ${GRAFANA_IP}:${GRAFANA_PORT} (Grafana)"
echo "    ❌ Rest of 192.168.178.0/24"
echo "    ✅ Internet"
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}  ⚠️  SAVE the password: ${PASSWORD}${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
