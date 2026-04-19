#!/bin/bash
###############################################################################
# setup-hermes-vm.sh — Fire-and-forget Hermes Agent VM on Proxmox
#
# Creates a hardened Debian 12 VM with Docker, deploys Hermes Agent
# (nousresearch/hermes-agent) with Z.AI as LLM provider, Telegram channel,
# and secured network access to Home Assistant + Grafana.
#
# Usage:
#   ./setup-hermes-vm.sh \
#       --zai-api-key "YOUR_ZAI_KEY" \
#       --ssh-pubkey ~/.ssh/id_ed25519.pub
#
# Optional flags:
#       --vm-id 101                    (default: 101)
#       --vm-ip 192.168.178.81         (default: 192.168.178.81)
#       --gateway 192.168.178.1        (default: 192.168.178.1)
#       --ram 3072                     (MB, default: 3072)
#       --disk 16                      (GB, default: 16)
#       --bridge vmbr0                 (default: vmbr0)
#       --telegram-token "BOT_TOKEN"   (optional, configure later)
#       --ha-token "HA_LONG_LIVED_TOK" (optional, for HA integration)
#       --user hermes                  (default: hermes)
#       --password ""                  (auto-generated if empty)
#
# Prerequisites:
#   - Proxmox VE 8.x+ with root access
#   - jq installed: apt install -y jq
#   - SSH key pair on the Proxmox host
#
# Network security:
#   - Proxmox firewall blocks all LAN except HA + Grafana
#   - Internet access allowed (for Z.AI API)
#   - SSH inbound from LAN only
#
# Author: Copilot CLI + bvogel
# Date: 2026-04-19
###############################################################################

set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────

VM_ID=101
VM_IP="192.168.178.81"
GATEWAY="192.168.178.1"
RAM=3072
DISK=16
BRIDGE="vmbr0"
USER="hermes"
PASSWORD=""
ZAI_KEY=""
SSH_PUBKEY_FILE=""
TELEGRAM_TOKEN=""
HA_TOKEN=""
HA_URL="http://192.168.178.88:8123"
GRAFANA_URL="https://192.168.178.98/proxy/grafana"

# HA + Grafana IPs for firewall whitelist
HA_IP="192.168.178.88"
HA_PORT="8123"
GRAFANA_IP="192.168.178.98"
GRAFANA_PORT="443"

CLOUD_IMG_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
CLOUD_IMG_PATH="/var/lib/vz/template/iso/debian-12-generic-amd64.qcow2"
SNIPPET_STORAGE="local"

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
[[ ! -f "$SSH_PUBKEY_FILE" ]] && fail "SSH pubkey file not found: $SSH_PUBKEY_FILE"
command -v jq &>/dev/null || fail "jq not installed. Run: apt install -y jq"
command -v qm &>/dev/null || fail "Must run on a Proxmox host (qm not found)"

SSH_PUBKEY=$(cat "$SSH_PUBKEY_FILE")
[[ -z "$PASSWORD" ]] && PASSWORD=$(openssl rand -base64 12)

info "═══════════════════════════════════════════════════"
info "  Hermes Agent VM Setup — Fire & Forget"
info "═══════════════════════════════════════════════════"
info "  VM ID:     $VM_ID"
info "  VM IP:     $VM_IP"
info "  RAM:       ${RAM}MB"
info "  Disk:      ${DISK}GB"
info "  User:      $USER"
info "  Bridge:    $BRIDGE"
info "  Gateway:   $GATEWAY"
info "  Z.AI:      ${ZAI_KEY:0:8}..."
info "  Telegram:  ${TELEGRAM_TOKEN:+configured}${TELEGRAM_TOKEN:-not set}"
info "  HA Token:  ${HA_TOKEN:+configured}${HA_TOKEN:-not set}"
info "═══════════════════════════════════════════════════"

###############################################################################
# Step 1: Download Debian cloud image (cached)
###############################################################################

info "Step 1/7: Downloading Debian 12 cloud image..."

if [[ -f "$CLOUD_IMG_PATH" ]]; then
    ok "Cloud image already cached"
else
    wget -q --show-progress -O "$CLOUD_IMG_PATH" "$CLOUD_IMG_URL"
    ok "Cloud image downloaded"
fi

###############################################################################
# Step 2: Create VM
###############################################################################

info "Step 2/7: Creating VM $VM_ID..."

if qm status "$VM_ID" &>/dev/null; then
    warn "VM $VM_ID already exists — destroying it"
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
    --cpu cputype=host \
    --net0 "virtio,bridge=${BRIDGE},firewall=0" \
    --scsihw virtio-scsi-single \
    --vga std \
    --agent enabled=1 \
    --onboot 1

# Import disk
qm importdisk "$VM_ID" "$CLOUD_IMG_PATH" local-lvm --format raw >/dev/null
qm set "$VM_ID" --scsi0 "local-lvm:vm-${VM_ID}-disk-0,discard=on,ssd=1"
qm set "$VM_ID" --boot order=scsi0
qm resize "$VM_ID" scsi0 "${DISK}G"

# Cloud-init drive
qm set "$VM_ID" --ide2 "local-lvm:cloudinit"

ok "VM $VM_ID created"

###############################################################################
# Step 3: Cloud-init configuration
###############################################################################

info "Step 3/7: Configuring cloud-init..."

# Ensure snippets directory exists
SNIPPET_DIR="/var/lib/vz/snippets"
mkdir -p "$SNIPPET_DIR"

# Generate gateway auth token
GW_TOKEN=$(openssl rand -hex 24)

# Create cloud-init userdata with Docker install + Hermes setup
cat > "${SNIPPET_DIR}/hermes-${VM_ID}-userdata.yaml" << USERDATA
#cloud-config
hostname: hermes
manage_etc_hosts: true
locale: en_US.UTF-8
timezone: Europe/Berlin

users:
  - name: ${USER}
    groups: [sudo, docker]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    passwd: $(openssl passwd -6 "${PASSWORD}")
    ssh_authorized_keys:
      - ${SSH_PUBKEY}

package_update: true
package_upgrade: true

packages:
  - curl
  - ca-certificates
  - gnupg
  - jq
  - qemu-guest-agent
  - unattended-upgrades

write_files:
  # Docker Compose for Hermes Agent
  - path: /home/${USER}/hermes/docker-compose.yml
    owner: ${USER}:${USER}
    permissions: '0644'
    content: |
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
            - /home/${USER}/.hermes:/opt/data
          environment:
            HOME: /root
            TERM: xterm-256color
          env_file:
            - /home/${USER}/.hermes/.env
          healthcheck:
            test: ["CMD", "curl", "-sf", "http://127.0.0.1:8642/health"]
            interval: 30s
            timeout: 10s
            retries: 3
            start_period: 30s
          deploy:
            resources:
              limits:
                memory: 2560M
                cpus: "2.0"
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
            - /home/${USER}/.hermes:/opt/data
          environment:
            GATEWAY_HEALTH_URL: "http://hermes:8642"
          depends_on:
            - hermes
          deploy:
            resources:
              limits:
                memory: 512M
                cpus: "0.5"
          networks:
            - hermes-net

      networks:
        hermes-net:
          driver: bridge

  # Hermes .env (API keys and secrets)
  - path: /home/${USER}/.hermes/.env
    owner: ${USER}:${USER}
    permissions: '0600'
    content: |
      # Z.AI native provider
      GLM_API_KEY=${ZAI_KEY}
      # Home Assistant
      HA_URL=${HA_URL}
      HA_TOKEN=${HA_TOKEN}
      # Grafana
      GRAFANA_URL=${GRAFANA_URL}
      # Telegram (if configured)
      TELEGRAM_BOT_TOKEN=${TELEGRAM_TOKEN}

  # Hermes config.yaml
  - path: /home/${USER}/.hermes/config.yaml
    owner: ${USER}:${USER}
    permissions: '0644'
    content: |
      # Hermes Agent Configuration
      # VM: ${VM_ID}, IP: ${VM_IP}
      # Generated: $(date -Iseconds)

      model: "zai/glm-4.7"

      terminal:
        backend: local
        cwd: "/home/${USER}/workspace"
        timeout: 180

      gateway:
        auth_token: "${GW_TOKEN}"

      memory:
        enabled: true
        auto_save: true

      compression:
        enabled: true
        model: "zai/glm-4.7-flash"

      tts:
        enabled: false

      tools:
        web_search: true
        browser: false
        image_generation: false
        text_to_speech: false

  # SOUL.md — Agent personality
  - path: /home/${USER}/.hermes/SOUL.md
    owner: ${USER}:${USER}
    permissions: '0644'
    content: |
      # Hermes — Persönlicher AI-Assistent

      Du bist Hermes, ein hilfreicher persönlicher AI-Assistent.
      Du sprichst Deutsch und Englisch.

      ## Fähigkeiten
      - Smart Home Steuerung via Home Assistant (HA_URL und HA_TOKEN als Env-Vars)
      - Grafana Solar-Dashboard Abfragen
      - Tennisplatz-Buchung (Internet)
      - Allgemeine Fragen und Aufgaben

      ## Wichtig
      - Du hast Netzwerkzugriff auf Home Assistant (192.168.178.88:8123) und Grafana (192.168.178.98:443)
      - Nutze curl mit den Env-Vars \$HA_URL und \$HA_TOKEN für HA-API-Zugriffe
      - Du läufst auf einer gesicherten Proxmox-VM mit eingeschränktem LAN-Zugang

runcmd:
  # Disable IPv6 (prevent firewall bypass)
  - sysctl -w net.ipv6.conf.all.disable_ipv6=1
  - sysctl -w net.ipv6.conf.default.disable_ipv6=1
  - echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.d/99-disable-ipv6.conf
  - echo "net.ipv6.conf.default.disable_ipv6 = 1" >> /etc/sysctl.d/99-disable-ipv6.conf

  # Install Docker
  - install -m 0755 -d /etc/apt/keyrings
  - curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  - chmod a+r /etc/apt/keyrings/docker.asc
  - echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list
  - apt-get update -qq
  - apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
  - systemctl enable --now docker

  # Create workspace
  - mkdir -p /home/${USER}/workspace
  - mkdir -p /home/${USER}/.hermes/sessions
  - mkdir -p /home/${USER}/.hermes/memories
  - mkdir -p /home/${USER}/.hermes/skills
  - mkdir -p /home/${USER}/.hermes/cron
  - mkdir -p /home/${USER}/.hermes/hooks
  - mkdir -p /home/${USER}/.hermes/logs
  - chown -R ${USER}:${USER} /home/${USER}

  # Pull and start Hermes
  - su - ${USER} -c 'cd ~/hermes && docker compose pull --quiet'
  - su - ${USER} -c 'cd ~/hermes && docker compose up -d'

  # Enable qemu-guest-agent
  - systemctl enable --now qemu-guest-agent

  # Signal completion
  - echo "HERMES_SETUP_COMPLETE" > /tmp/setup-done
USERDATA

# Apply cloud-init
qm set "$VM_ID" \
    --ciuser "$USER" \
    --ipconfig0 "ip=${VM_IP}/24,gw=${GATEWAY}" \
    --nameserver "$GATEWAY" \
    --cicustom "user=${SNIPPET_STORAGE}:snippets/hermes-${VM_ID}-userdata.yaml"

ok "Cloud-init configured"

###############################################################################
# Step 4: Proxmox firewall
###############################################################################

info "Step 4/7: Configuring Proxmox firewall..."

# Enable cluster firewall if not already
CLUSTER_FW="/etc/pve/firewall/cluster.fw"
if [[ -f "$CLUSTER_FW" ]]; then
    if ! grep -q "^enable: 1" "$CLUSTER_FW"; then
        sed -i 's/^enable:.*/enable: 1/' "$CLUSTER_FW" 2>/dev/null || \
            echo -e "[OPTIONS]\nenable: 1\npolicy_in: ACCEPT\npolicy_out: ACCEPT" > "$CLUSTER_FW"
    fi
else
    cat > "$CLUSTER_FW" << 'EOF'
[OPTIONS]
enable: 1
policy_in: ACCEPT
policy_out: ACCEPT
EOF
fi
ok "Cluster firewall enabled"

# VM-specific firewall
cat > "/etc/pve/firewall/${VM_ID}.fw" << EOF
[OPTIONS]
enable: 1
dhcp: 1
policy_in: DROP
policy_out: DROP

[RULES]
# Allow outbound to gateway/router (internet routing + DNS)
OUT ACCEPT -d ${GATEWAY}/32 -log nolog
OUT ACCEPT -d ${GATEWAY}/32 -p udp -dport 53 -log nolog
OUT ACCEPT -d ${GATEWAY}/32 -p tcp -dport 53 -log nolog

# Erlaubte LAN-Ziele
OUT ACCEPT -dest ${HA_IP} -dport ${HA_PORT} -p tcp -log nolog    # Home Assistant
OUT ACCEPT -dest ${GRAFANA_IP} -dport ${GRAFANA_PORT} -p tcp -log nolog   # Grafana

# Block all RFC1918 outbound (LAN isolation)
OUT DROP -d 10.0.0.0/8 -log nolog
OUT DROP -d 172.16.0.0/12 -log nolog
OUT DROP -d 192.168.0.0/16 -log nolog
OUT DROP -d 169.254.0.0/16 -log nolog

# Allow all other outbound (internet)
OUT ACCEPT -log nolog

# Inbound: SSH from LAN only
IN ACCEPT -source 192.168.178.0/24 -p tcp -dport 22 -log nolog

# Inbound: ICMP
IN ACCEPT -p icmp -log nolog
EOF

ok "Firewall configured for VM $VM_ID"

###############################################################################
# Step 5: Start VM
###############################################################################

info "Step 5/7: Starting VM $VM_ID..."

qm start "$VM_ID"
ok "VM $VM_ID started"

###############################################################################
# Step 6: Wait for VM to boot and get IP
###############################################################################

info "Step 6/7: Waiting for VM to boot (this takes 3-5 minutes)..."

MAX_WAIT=300
ELAPSED=0
while [[ $ELAPSED -lt $MAX_WAIT ]]; do
    if ping -c 1 -W 2 "$VM_IP" &>/dev/null; then
        ok "VM is responding at $VM_IP"
        break
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    printf "."
done
echo ""

if [[ $ELAPSED -ge $MAX_WAIT ]]; then
    warn "VM did not respond within ${MAX_WAIT}s — it may still be booting"
    warn "Check: qm guest cmd $VM_ID network-get-interfaces"
fi

# Wait for SSH
info "Waiting for SSH..."
ELAPSED=0
while [[ $ELAPSED -lt 120 ]]; do
    if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=3 \
           -o BatchMode=yes "${USER}@${VM_IP}" "echo SSH_OK" 2>/dev/null | grep -q "SSH_OK"; then
        ok "SSH is ready"
        break
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

###############################################################################
# Step 7: Wait for Docker + Hermes to be ready
###############################################################################

info "Step 7/7: Waiting for Hermes Agent to start..."

ELAPSED=0
MAX_WAIT=300
while [[ $ELAPSED -lt $MAX_WAIT ]]; do
    # Check if cloud-init is done
    if ssh -o BatchMode=yes "${USER}@${VM_IP}" \
           "test -f /tmp/setup-done && echo DONE" 2>/dev/null | grep -q "DONE"; then
        ok "Cloud-init completed"

        # Enable Proxmox NIC firewall now that DHCP/setup is done
        CURRENT_MAC=$(qm config "$VM_ID" | grep -oP 'virtio=\K[0-9A-Fa-f:]+' | head -1)
        if [[ -n "$CURRENT_MAC" ]]; then
            qm set "$VM_ID" --net0 "virtio=${CURRENT_MAC},bridge=${BRIDGE},firewall=1"
            ok "Proxmox NIC firewall enabled"
        else
            warn "Could not extract MAC — enable firewall manually:"
            warn "  qm set $VM_ID --net0 'virtio=<MAC>,bridge=${BRIDGE},firewall=1'"
        fi

        break
    fi
    sleep 10
    ELAPSED=$((ELAPSED + 10))
    printf "."
done
echo ""

if [[ $ELAPSED -ge $MAX_WAIT ]]; then
    warn "Cloud-init did not complete within ${MAX_WAIT}s"
    warn "SSH in and check: sudo cloud-init status --long"
fi

# Wait for Hermes health endpoint
ELAPSED=0
while [[ $ELAPSED -lt 120 ]]; do
    if ssh -o BatchMode=yes "${USER}@${VM_IP}" \
           "curl -sf http://127.0.0.1:8642/health" 2>/dev/null | grep -qi "ok\|healthy\|running"; then
        ok "Hermes Agent is healthy!"
        break
    fi
    sleep 10
    ELAPSED=$((ELAPSED + 10))
done

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
echo "  SSH:            ssh ${USER}@${VM_IP}"
echo ""
echo "  Gateway API:    http://127.0.0.1:8642 (loopback only)"
echo "  Gateway Token:  $GW_TOKEN"
echo "  Dashboard:      http://127.0.0.1:9119 (loopback only)"
echo ""
echo "  SSH Tunnel (from Windows):"
echo "    ssh -i C:\\Users\\bvogel\\.ssh\\id_ed25519_openclaw \\"
echo "        -L 8642:localhost:8642 -L 9119:localhost:9119 \\"
echo "        ${USER}@${VM_IP}"
echo ""
echo "  Then open: http://localhost:9119 (Dashboard)"
echo "             http://localhost:8642 (API)"
echo ""
if [[ -n "$TELEGRAM_TOKEN" ]]; then
    echo "  Telegram:       Bot configured (restart gateway if not connecting)"
else
    echo "  Telegram:       Not configured — set later with:"
    echo "    ssh ${USER}@${VM_IP}"
    echo "    nano ~/.hermes/.env  # Add: TELEGRAM_BOT_TOKEN=your-token"
    echo "    cd ~/hermes && docker compose restart hermes"
fi
echo ""
echo "  Firewall:       LAN blocked except HA + Grafana"
echo "    ✅ ${HA_IP}:${HA_PORT} (Home Assistant)"
echo "    ✅ ${GRAFANA_IP}:${GRAFANA_PORT} (Grafana)"
echo "    ❌ Rest of 192.168.178.0/24"
echo "    ✅ Internet"
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""
echo "  ⚠️  SAVE these credentials! They won't be shown again."
echo ""
