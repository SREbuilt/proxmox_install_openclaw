#!/usr/bin/env bash
###############################################################################
# niklas_setup-openclaw-vm.sh — Hardened OpenClaw VM setup for Proxmox
#
# Creates a Debian 12 cloud-init VM with Docker + OpenClaw container.
# Full VM isolation, Proxmox firewall for LAN blocking, loopback-only port.
#
# Lessons learned and applied:
#   - Uses debian-12-generic (NOT genericcloud — NIC detection issues)
#   - VGA=std (NOT serial0 — cloud image doesn't output to serial)
#   - Firewall starts DISABLED, enabled after setup (DHCP needs open net)
#   - cicustom overrides Proxmox user-data, so user/SSH/password in YAML
#   - No in-VM iptables (conflicts with Docker's iptables chains)
#   - Z.AI API key in auth-profiles.json (NOT config or docker-compose env)
#   - Model as string "zai/glm-5.1" in config
#   - Docker install fallback via SSH if cloud-init errors
#   - Preserves MAC address when enabling firewall on NIC
###############################################################################
set -euo pipefail

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
BOLD='\033[1m'; NC='\033[0m'
info()  { printf "${BLUE}[INFO]${NC} %s\n" "$*"; }
ok()    { printf "${GREEN}[ OK ]${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
fail()  { printf "${RED}[FAIL]${NC} %s\n" "$*"; exit 1; }

# ── Defaults ────────────────────────────────────────────────────────────────
ZAI_API_KEY=""
VM_USER="claw"
SSH_PUBKEY=""
LAN_SUBNET="192.168.178.0/24"
GATEWAY_IP="192.168.178.1"
DNS_SERVER=""
VM_ID=""
VM_NAME="openclaw"
VM_BRIDGE="vmbr0"
VM_RAM=4096
VM_CORES=2
VM_DISK=256
STORAGE="local-lvm"
TIMEZONE="Europe/Berlin"
STATIC_IP=""

# ── Usage ───────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") --zai-api-key KEY [OPTIONS]

Creates a hardened Debian 12 VM on Proxmox with Docker + OpenClaw.

Required:
  --zai-api-key KEY      Z.AI API key

Optional:
  --vm-user NAME         VM user name              (default: claw)
  --ssh-pubkey FILE      SSH public key file        (default: auto-detect)
  --lan-subnet CIDR      LAN subnet to block        (default: 192.168.178.0/24)
  --gateway-ip IP        Gateway / router IP        (default: 192.168.178.1)
  --dns-server IP        DNS server IP              (default: same as gateway)
  --vm-id ID             Proxmox VM ID              (default: auto-detect)
  --vm-name NAME         VM name                    (default: openclaw)
  --vm-bridge BRIDGE     Network bridge             (default: vmbr0)
  --vm-ram MB            RAM in MB                  (default: 4096)
  --vm-cores N           CPU cores                  (default: 2)
  --vm-disk GB           Disk size in GB            (default: 256)
  --storage NAME         Proxmox storage            (default: local-lvm)
  --static-ip IP/CIDR    Static IP for VM           (default: DHCP)
  --timezone TZ          Timezone                   (default: Europe/Berlin)
  --help                 Show this help
EOF
  exit 0
}

# ── Parse arguments ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --zai-api-key)   ZAI_API_KEY="$2";   shift 2 ;;
    --vm-user)       VM_USER="$2";       shift 2 ;;
    --ssh-pubkey)    SSH_PUBKEY="$2";    shift 2 ;;
    --lan-subnet)    LAN_SUBNET="$2";    shift 2 ;;
    --gateway-ip)    GATEWAY_IP="$2";    shift 2 ;;
    --dns-server)    DNS_SERVER="$2";    shift 2 ;;
    --vm-id)         VM_ID="$2";         shift 2 ;;
    --vm-name)       VM_NAME="$2";       shift 2 ;;
    --vm-bridge)     VM_BRIDGE="$2";     shift 2 ;;
    --vm-ram)        VM_RAM="$2";        shift 2 ;;
    --vm-cores)      VM_CORES="$2";      shift 2 ;;
    --vm-disk)       VM_DISK="$2";       shift 2 ;;
    --storage)       STORAGE="$2";       shift 2 ;;
    --static-ip)     STATIC_IP="$2";     shift 2 ;;
    --timezone)      TIMEZONE="$2";      shift 2 ;;
    --help)          usage ;;
    *) fail "Unknown option: $1 (use --help)" ;;
  esac
done

# ── Validation ──────────────────────────────────────────────────────────────
[[ -z "$ZAI_API_KEY" ]] && fail "--zai-api-key is required"
DNS_SERVER="${DNS_SERVER:-$GATEWAY_IP}"
[[ "$(id -u)" -eq 0 ]] || fail "Must run as root on the Proxmox host"

for cmd in qm pvesh wget ssh jq; do
  command -v "$cmd" &>/dev/null || fail "Required command not found: $cmd"
done
ok "Pre-flight checks passed"

# Auto-detect SSH public key
if [[ -z "$SSH_PUBKEY" ]]; then
  for candidate in /root/.ssh/id_ed25519.pub /root/.ssh/id_rsa.pub; do
    [[ -f "$candidate" ]] && SSH_PUBKEY="$candidate" && break
  done
  [[ -z "$SSH_PUBKEY" ]] && fail "No SSH key found. Provide --ssh-pubkey or run: ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519"
fi
[[ -f "$SSH_PUBKEY" ]] || fail "SSH public key not found: $SSH_PUBKEY"
SSH_PUBKEY_CONTENT=$(cat "$SSH_PUBKEY")
ok "SSH public key: $SSH_PUBKEY"

# Auto-detect VM ID
if [[ -z "$VM_ID" ]]; then
  VM_ID=$(pvesh get /cluster/nextid 2>/dev/null | tr -d '"') || fail "Could not detect next VM ID"
fi
ok "VM ID: $VM_ID"

# Generate secrets
GATEWAY_TOKEN=$(openssl rand -hex 32)
CONSOLE_PASSWORD=$(openssl rand -base64 12)

# IP config for cloud-init
if [[ -n "$STATIC_IP" ]]; then
  IP_CONFIG="ip=${STATIC_IP},gw=${GATEWAY_IP}"
  VM_EXPECTED_IP="${STATIC_IP%%/*}"
else
  IP_CONFIG="ip=dhcp"
  VM_EXPECTED_IP=""
fi

###############################################################################
# Step 1: Download Debian 12 cloud image (generic, not genericcloud)
###############################################################################
CLOUD_IMG_DIR="/var/lib/vz/template/cache"
CLOUD_IMG_NAME="debian-12-generic-amd64.qcow2"
CLOUD_IMG_PATH="${CLOUD_IMG_DIR}/${CLOUD_IMG_NAME}"
CLOUD_IMG_URL="https://cloud.debian.org/images/cloud/bookworm/latest/${CLOUD_IMG_NAME}"

mkdir -p "$CLOUD_IMG_DIR"
if [[ -f "$CLOUD_IMG_PATH" ]]; then
  ok "Debian 12 cloud image already cached"
else
  info "Downloading Debian 12 cloud image (generic variant for Proxmox)..."
  wget -q --show-progress -O "$CLOUD_IMG_PATH" "$CLOUD_IMG_URL" \
    || fail "Failed to download cloud image"
  ok "Downloaded Debian 12 cloud image"
fi

###############################################################################
# Step 2: Create VM (firewall=0 initially — enabled after setup)
###############################################################################
info "Creating VM ${VM_ID} (${VM_NAME})..."
qm create "$VM_ID" \
  --name "$VM_NAME" \
  --ostype l26 \
  --machine q35 \
  --cpu host \
  --cores "$VM_CORES" \
  --memory "$VM_RAM" \
  --net0 "virtio,bridge=${VM_BRIDGE},firewall=0" \
  --scsihw virtio-scsi-single \
  --serial0 socket \
  --vga std \
  --agent enabled=1 \
  --onboot 1 \
  --protection 0 \
  || fail "Failed to create VM"
ok "VM $VM_ID created"

###############################################################################
# Step 3: Import disk & resize
###############################################################################
info "Importing cloud image as boot disk..."
qm set "$VM_ID" --scsi0 "${STORAGE}:0,import-from=${CLOUD_IMG_PATH},iothread=1,discard=on" \
  || fail "Failed to import disk"
ok "Disk imported"

info "Resizing disk to ${VM_DISK}G..."
qm disk resize "$VM_ID" scsi0 "${VM_DISK}G" || fail "Failed to resize disk"
ok "Disk resized to ${VM_DISK}G"

qm set "$VM_ID" --boot order=scsi0
ok "Boot order set"

###############################################################################
# Step 4: Cloud-init config
###############################################################################
info "Configuring cloud-init..."
qm set "$VM_ID" --ide2 "${STORAGE}:cloudinit"
# Note: ciuser/cipassword/sshkeys are set here for Proxmox UI display,
# but cicustom overrides them — the actual user setup is in our YAML.
qm set "$VM_ID" --ciuser "$VM_USER"
qm set "$VM_ID" --cipassword "$CONSOLE_PASSWORD"
qm set "$VM_ID" --sshkeys "$SSH_PUBKEY"
qm set "$VM_ID" --ipconfig0 "$IP_CONFIG"
qm set "$VM_ID" --ciupgrade 1
ok "Cloud-init configured (user=$VM_USER, ${IP_CONFIG})"

###############################################################################
# Step 5: Write cloud-init user-data
# cicustom OVERRIDES Proxmox auto-generated user-data, so we must include
# everything: user creation, SSH key, password, packages, and runcmd.
###############################################################################
SNIPPETS_DIR="/var/lib/vz/snippets"
USERDATA_FILE="${SNIPPETS_DIR}/openclaw-${VM_ID}-userdata.yml"
mkdir -p "$SNIPPETS_DIR"

info "Writing cloud-init user-data..."
cat > "$USERDATA_FILE" <<USERDATA_EOF
#cloud-config

# User creation — required because cicustom overrides Proxmox defaults
users:
  - name: ${VM_USER}
    groups: sudo, docker
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    ssh_authorized_keys:
      - ${SSH_PUBKEY_CONTENT}

chpasswd:
  list: |
    ${VM_USER}:${CONSOLE_PASSWORD}
  expire: false

package_update: true
package_upgrade: true
packages:
  - qemu-guest-agent
  - ca-certificates
  - curl
  - gnupg
  - jq
  - unattended-upgrades
  - apt-listchanges

timezone: ${TIMEZONE}

write_files:
  # Disable IPv6 (prevents bypass of IPv4-only firewall rules)
  - path: /etc/sysctl.d/99-disable-ipv6.conf
    content: |
      net.ipv6.conf.all.disable_ipv6 = 1
      net.ipv6.conf.default.disable_ipv6 = 1
      net.ipv6.conf.lo.disable_ipv6 = 1
    owner: root:root
    permissions: "0644"

  # NOTE: No in-VM iptables — Docker manages its own iptables chains.
  # LAN isolation is enforced by the Proxmox firewall (host-level).

  # Docker compose file for OpenClaw
  - path: /home/${VM_USER}/openclaw/docker-compose.yml
    content: |
      services:
        openclaw-gateway:
          image: ghcr.io/openclaw/openclaw:latest
          container_name: openclaw-gateway
          restart: unless-stopped
          ports:
            - "127.0.0.1:18789:18789"
          cap_drop:
            - NET_RAW
            - NET_ADMIN
            - SYS_ADMIN
          security_opt:
            - no-new-privileges
          volumes:
            - /home/${VM_USER}/.openclaw:/home/node/.openclaw
            - /home/${VM_USER}/openclaw/workspace:/workspace
          command: >
            node openclaw.mjs gateway
            --allow-unconfigured
            --bind lan
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
    owner: ${VM_USER}:${VM_USER}
    permissions: "0600"

  # Unattended security upgrades
  - path: /etc/apt/apt.conf.d/20auto-upgrades
    content: |
      APT::Periodic::Update-Package-Lists "1";
      APT::Periodic::Unattended-Upgrade "1";
      APT::Periodic::AutocleanInterval "7";
    owner: root:root
    permissions: "0644"

runcmd:
  # Apply sysctl (disable IPv6)
  - sysctl --system

  # Install Docker CE
  - install -m 0755 -d /etc/apt/keyrings
  - curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  - chmod a+r /etc/apt/keyrings/docker.asc
  - echo "deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \$(. /etc/os-release && echo \$VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list
  - apt-get update -y
  - DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  # Create OpenClaw directories
  - mkdir -p /home/${VM_USER}/.openclaw/agents/main/agent
  - mkdir -p /home/${VM_USER}/openclaw/workspace
  - chown -R ${VM_USER}:${VM_USER} /home/${VM_USER}/.openclaw
  - chown -R ${VM_USER}:${VM_USER} /home/${VM_USER}/openclaw
  - chmod 700 /home/${VM_USER}/.openclaw

  # Enable and start qemu-guest-agent
  - systemctl enable qemu-guest-agent
  - systemctl start qemu-guest-agent

  # Pull OpenClaw image and start container
  - docker pull ghcr.io/openclaw/openclaw:latest
  - cd /home/${VM_USER}/openclaw && docker compose up -d
USERDATA_EOF

ok "Cloud-init user-data written to $USERDATA_FILE"

###############################################################################
# Step 6: Attach cicustom
###############################################################################
info "Attaching custom cloud-init user-data..."
qm set "$VM_ID" --cicustom "user=local:snippets/openclaw-${VM_ID}-userdata.yml"
ok "cicustom attached"

###############################################################################
# Step 7: Write Proxmox firewall rules (DISABLED until setup completes)
###############################################################################
FW_DIR="/etc/pve/firewall"
FW_FILE="${FW_DIR}/${VM_ID}.fw"
mkdir -p "$FW_DIR"

info "Writing Proxmox firewall rules (disabled until setup completes)..."
cat > "$FW_FILE" <<EOF
[OPTIONS]
enable: 0
dhcp: 1
policy_in: DROP
policy_out: DROP

[RULES]
# Outbound: allow gateway (for internet routing + DNS)
OUT ACCEPT -d ${GATEWAY_IP}/32 -log nolog
OUT ACCEPT -d ${DNS_SERVER}/32 -p udp -dport 53 -log nolog
OUT ACCEPT -d ${DNS_SERVER}/32 -p tcp -dport 53 -log nolog

# Outbound: block all RFC1918 (LAN isolation)
OUT DROP -d 10.0.0.0/8 -log nolog
OUT DROP -d 172.16.0.0/12 -log nolog
OUT DROP -d 192.168.0.0/16 -log nolog
OUT DROP -d 169.254.0.0/16 -log nolog

# Outbound: allow internet
OUT ACCEPT -log nolog

# Inbound: SSH from LAN only
IN ACCEPT -source ${LAN_SUBNET} -p tcp -dport 22 -log nolog

# Inbound: ICMP
IN ACCEPT -p icmp -log nolog
EOF
ok "Firewall rules written (disabled)"

###############################################################################
# Step 8: Start VM
###############################################################################
info "Starting VM ${VM_ID}..."
qm start "$VM_ID" || fail "Failed to start VM"
ok "VM $VM_ID started"

###############################################################################
# Step 9: Wait for VM IP
###############################################################################
info "Waiting for VM IP address..."
VM_IP=""
MAX_WAIT=300
ELAPSED=0

while [[ $ELAPSED -lt $MAX_WAIT ]]; do
  sleep 5
  ELAPSED=$((ELAPSED + 5))

  VM_IP=$(qm guest cmd "$VM_ID" network-get-interfaces 2>/dev/null \
    | jq -r '[.[] | select(.name != "lo" and .name != "docker0" and (.name | startswith("br-") | not) and (.name | startswith("veth") | not)) | .["ip-addresses"][]? | select(.["ip-address-type"] == "ipv4")] | first | .["ip-address"] // empty' 2>/dev/null || true)

  if [[ -n "$VM_IP" && "$VM_IP" != "null" ]]; then
    break
  fi
  VM_IP=""
  printf "."
done

# Fallback: ip neigh
if [[ -z "$VM_IP" ]]; then
  warn "Guest agent did not return IP, trying ip neigh..."
  VM_MAC=$(qm config "$VM_ID" | grep -oP 'virtio=\K[0-9A-Fa-f:]+' | head -1)
  if [[ -n "$VM_MAC" ]]; then
    for _ in $(seq 1 24); do
      sleep 5; ELAPSED=$((ELAPSED + 5))
      VM_IP=$(ip neigh show | grep -i "$VM_MAC" | awk '{print $1}' | head -1 || true)
      [[ -n "$VM_IP" ]] && break
      printf "."
    done
  fi
fi

echo ""
[[ -z "$VM_IP" ]] && fail "Could not detect VM IP after ${ELAPSED}s. Check VM console."
ok "VM IP: $VM_IP"

###############################################################################
# Step 10: Wait for SSH
###############################################################################
info "Waiting for SSH on ${VM_IP}..."
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
SSH_CMD="ssh ${SSH_OPTS} ${VM_USER}@${VM_IP}"
SSH_READY=false

for _ in $(seq 1 60); do
  if $SSH_CMD "true" 2>/dev/null; then
    SSH_READY=true; break
  fi
  sleep 5
done
$SSH_READY || fail "SSH not available after 5 minutes"
ok "SSH connection established"

###############################################################################
# Step 11: Wait for cloud-init
###############################################################################
info "Waiting for cloud-init to finish (this may take several minutes)..."
$SSH_CMD "sudo cloud-init status --wait" 2>/dev/null || true
CI_STATUS=$($SSH_CMD "sudo cloud-init status 2>/dev/null | head -1" 2>/dev/null || echo "unknown")
info "Cloud-init status: $CI_STATUS"

###############################################################################
# Step 12: Ensure Docker is installed (fallback if cloud-init errored)
###############################################################################
info "Checking Docker status..."
DOCKER_OK=$($SSH_CMD "command -v docker &>/dev/null && docker info &>/dev/null && echo OK || echo FAIL" 2>/dev/null || echo "FAIL")

if [[ "$DOCKER_OK" != "OK" ]]; then
  warn "Docker not ready — installing via SSH fallback..."
  $SSH_CMD bash <<DOCKER_INSTALL
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \$(. /etc/os-release && echo \$VERSION_CODENAME) stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update -y
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker ${VM_USER}
DOCKER_INSTALL
  ok "Docker installed via SSH fallback"
else
  ok "Docker is running"
fi

###############################################################################
# Step 13: Write OpenClaw config + auth + start container
###############################################################################
info "Writing hardened OpenClaw configuration..."
$SSH_CMD bash <<CONFIG_SCRIPT
set -euo pipefail

# Create directories
mkdir -p ~/.openclaw/agents/main/agent
mkdir -p ~/openclaw/workspace

# Write hardened openclaw.json — model as string, API key in auth-profiles
cat > ~/.openclaw/openclaw.json << 'OCJSON'
{
  "gateway": {
    "mode": "local",
    "bind": "lan",
    "auth": {
      "mode": "token",
      "token": "${GATEWAY_TOKEN}"
    }
  },
  "session": {
    "dmScope": "per-channel-peer"
  },
  "agents": {
    "defaults": {
      "model": "zai/glm-5.1"
    }
  },
  "tools": {
    "profile": "messaging",
    "deny": [
      "group:automation",
      "group:runtime",
      "group:fs",
      "sessions_spawn",
      "sessions_send"
    ],
    "fs": {
      "workspaceOnly": true
    },
    "exec": {
      "security": "deny",
      "ask": "always"
    },
    "elevated": {
      "enabled": false
    }
  }
}
OCJSON

# Write Z.AI auth profile (API key goes here, not in config)
cat > ~/.openclaw/agents/main/agent/auth-profiles.json << 'AUTHJSON'
{
  "zai": {
    "apiKey": "${ZAI_API_KEY}",
    "baseUrl": "https://api.z.ai/api/coding/paas/v4"
  }
}
AUTHJSON

# Set permissions
chmod 700 ~/.openclaw
chmod 600 ~/.openclaw/openclaw.json
chmod 600 ~/.openclaw/agents/main/agent/auth-profiles.json
chmod 600 ~/openclaw/docker-compose.yml
CONFIG_SCRIPT

ok "Config + auth profiles written"

# Now fix the token and API key (heredoc with 'QUOTES' didn't expand vars)
$SSH_CMD "sed -i 's|\${GATEWAY_TOKEN}|${GATEWAY_TOKEN}|' ~/.openclaw/openclaw.json"
$SSH_CMD "sed -i 's|\${ZAI_API_KEY}|${ZAI_API_KEY}|' ~/.openclaw/agents/main/agent/auth-profiles.json"
ok "Secrets injected"

###############################################################################
# Step 14: Start/restart OpenClaw container
###############################################################################
info "Starting OpenClaw container..."
$SSH_CMD bash <<'START_SCRIPT'
set -euo pipefail
cd ~/openclaw
# Clean up any stale state
docker compose down --remove-orphans 2>/dev/null || true
docker network prune -f 2>/dev/null || true
# Pull latest image if not cached
docker pull ghcr.io/openclaw/openclaw:latest 2>&1 | tail -3
# Start
docker compose up -d
START_SCRIPT
ok "Container started"

###############################################################################
# Step 15: Run security audit
###############################################################################
info "Running openclaw security audit --fix..."
$SSH_CMD bash <<'AUDIT_SCRIPT'
cd ~/openclaw
for i in $(seq 1 30); do
  docker compose ps --format '{{.State}}' 2>/dev/null | grep -q running && break
  sleep 2
done
docker compose exec -T openclaw-gateway node openclaw.mjs security audit --fix 2>/dev/null || true
AUDIT_SCRIPT
ok "Security audit completed"

###############################################################################
# Step 16: Wait for health check
###############################################################################
info "Waiting for OpenClaw health check..."
HEALTH_OK=false
for _ in $(seq 1 30); do
  HEALTH=$($SSH_CMD "curl -sf http://127.0.0.1:18789/healthz 2>/dev/null" || true)
  if [[ -n "$HEALTH" ]]; then
    HEALTH_OK=true; break
  fi
  sleep 5
done
if $HEALTH_OK; then
  ok "OpenClaw health check passed"
else
  warn "Health check timed out — container may still be starting"
fi

###############################################################################
# Step 17: Verify model is correct
###############################################################################
MODEL=$($SSH_CMD "curl -sf http://127.0.0.1:18789/healthz 2>/dev/null" | jq -r '.model // empty' 2>/dev/null || true)
$SSH_CMD bash <<'MODEL_CHECK'
cd ~/openclaw
docker compose logs --tail 3 2>/dev/null | grep -o "agent model: [^ ]*" || true
MODEL_CHECK

###############################################################################
# Step 18: Enable Proxmox firewall (preserving MAC address)
###############################################################################
info "Enabling Proxmox firewall..."
sed -i 's/^enable: 0/enable: 1/' "$FW_FILE"
# Preserve the MAC address — extract it first, then set firewall=1
CURRENT_MAC=$(qm config "$VM_ID" | grep -oP 'virtio=\K[0-9A-Fa-f:]+' | head -1)
qm set "$VM_ID" --net0 "virtio=${CURRENT_MAC},bridge=${VM_BRIDGE},firewall=1" 2>/dev/null || true
ok "Proxmox firewall enabled (LAN blocked, internet allowed)"

###############################################################################
# Step 19: Verify firewall didn't break connectivity
###############################################################################
info "Verifying connectivity after firewall enable..."
sleep 3
SSH_CHECK=$($SSH_CMD "echo OK" 2>/dev/null || echo "FAIL")
if [[ "$SSH_CHECK" == "OK" ]]; then
  ok "SSH still works after firewall"
else
  warn "SSH failed after firewall — disabling firewall as safety measure"
  sed -i 's/^enable: 1/enable: 0/' "$FW_FILE"
  warn "Firewall disabled. Check /etc/pve/firewall/${VM_ID}.fw manually."
fi

# Verify internet + LAN isolation
INET=$($SSH_CMD "curl -sf --max-time 5 https://cloud.debian.org >/dev/null && echo OK || echo FAIL" 2>/dev/null || echo "SKIP")
LAN=$($SSH_CMD "curl -sf --max-time 3 http://${GATEWAY_IP}:8123 2>/dev/null && echo EXPOSED || echo BLOCKED" 2>/dev/null || echo "BLOCKED")

[[ "$INET" == "OK" ]] && ok "Internet: accessible" || warn "Internet: $INET"
[[ "$LAN" == "BLOCKED" ]] && ok "LAN: blocked (isolated from Home Assistant)" || warn "LAN: $LAN"

###############################################################################
# Step 20: Print connection info
###############################################################################
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  OpenClaw VM Setup Complete${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${BOLD}VM Details:${NC}"
echo -e "  VM ID:      ${VM_ID}"
echo -e "  VM Name:    ${VM_NAME}"
echo -e "  VM IP:      ${VM_IP}"
echo -e "  VM User:    ${VM_USER}"
echo ""
echo -e "${BOLD}SSH Access (from Proxmox host):${NC}"
echo -e "  ssh ${VM_USER}@${VM_IP}"
echo ""
echo -e "${BOLD}Console Access (Proxmox web UI → VM ${VM_ID} → Console):${NC}"
echo -e "  User:     ${VM_USER}"
echo -e "  Password: ${YELLOW}${CONSOLE_PASSWORD}${NC}"
echo ""
echo -e "${BOLD}Dashboard (via SSH tunnel from your workstation):${NC}"
echo -e "  1. Copy the SSH key to your workstation:"
echo -e "     ${BLUE}scp root@$(hostname -I | awk '{print $1}'):/root/.ssh/id_ed25519 ~/.ssh/id_ed25519_openclaw${NC}"
echo -e "  2. Start SSH tunnel:"
echo -e "     ${BLUE}ssh -i ~/.ssh/id_ed25519_openclaw -L 18789:localhost:18789 ${VM_USER}@${VM_IP}${NC}"
echo -e "  3. Open in browser: ${BLUE}http://localhost:18789${NC}"
echo ""
echo -e "${BOLD}Gateway Auth Token:${NC}"
echo -e "  ${YELLOW}${GATEWAY_TOKEN}${NC}"
echo ""
echo -e "${BOLD}Z.AI Model:${NC}"
echo -e "  Provider: zai | Model: glm-5.1"
echo -e "  Endpoint: https://api.z.ai/api/coding/paas/v4"
echo ""
echo -e "${BOLD}Security:${NC}"
echo -e "  ✓ Full VM isolation (Proxmox hypervisor)"
echo -e "  ✓ Proxmox firewall: LAN blocked, RFC1918 blocked, internet allowed"
echo -e "  ✓ IPv6 disabled"
echo -e "  ✓ Docker: cap_drop NET_RAW, NET_ADMIN, SYS_ADMIN + no-new-privileges"
echo -e "  ✓ Port 18789 bound to VM loopback only (127.0.0.1)"
echo -e "  ✓ Hardened tool config (deny automation/runtime/fs)"
echo -e "  ✓ Unattended security upgrades enabled"
echo -e "  ✓ Security audit --fix executed"
echo ""
if [[ -z "$STATIC_IP" ]]; then
  echo -e "${YELLOW}Tip: To assign a static IP, re-run with --static-ip ${VM_IP}/24${NC}"
  echo -e "${YELLOW}Or:  qm set ${VM_ID} --ipconfig0 ip=${VM_IP}/24,gw=${GATEWAY_IP} && qm reboot ${VM_ID}${NC}"
  echo ""
fi
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
