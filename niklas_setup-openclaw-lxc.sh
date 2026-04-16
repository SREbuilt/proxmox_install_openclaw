#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# setup-openclaw-lxc.sh
#
# Creates an unprivileged Debian 13 LXC container on Proxmox with:
#   - OpenClaw + hardened baseline config (loopback bind, token auth)
#   - LXQt desktop + TigerVNC + noVNC (localhost only, SSH tunnel access)
#   - Chrome with sandbox (non-root)
#   - Proxmox firewall (default DROP, internet-only egress)
#   - In-container iptables + IPv6 disabled
#   - Non-root service user for all daemons
#   - Unattended security upgrades
#
# Usage:
#   ./setup-openclaw-lxc.sh --password <root-pw> [options]
###############################################################################

# ── Colour helpers ───────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

# ── Defaults ─────────────────────────────────────────────────────────────────
PASSWORD=""
ZAI_API_KEY=""
LAN_SUBNET="192.168.178.0/24"
GATEWAY_IP="192.168.178.1"
DNS_SERVER=""
DISK=16
MEMORY=3072
CORES=2
VNC_RESOLUTION="1920x1080"
VMID=""
TIMEZONE="Europe/Berlin"

# ── Parse arguments ──────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") --password PASS [OPTIONS]

Required:
  --password PASS        Container root password

Optional:
  --zai-api-key KEY      Z.AI API key (or use onboard wizard later)
  --lan-subnet CIDR      LAN subnet to block (default: 192.168.178.0/24)
  --gateway-ip IP        Default gateway   (default: 192.168.178.1)
  --dns-server IP        DNS server         (default: same as gateway)
  --disk GB              Root disk size     (default: 16)
  --memory MB            RAM                (default: 3072)
  --cores N              CPU cores          (default: 2)
  --vnc-resolution WxH   VNC resolution     (default: 1920x1080)
  --vm-id ID             Container VMID     (default: auto-detect)
  --timezone TZ          Timezone           (default: Europe/Berlin)
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --password)       PASSWORD="$2";       shift 2 ;;
        --zai-api-key)    ZAI_API_KEY="$2";    shift 2 ;;
        --lan-subnet)     LAN_SUBNET="$2";     shift 2 ;;
        --gateway-ip)     GATEWAY_IP="$2";     shift 2 ;;
        --dns-server)     DNS_SERVER="$2";     shift 2 ;;
        --disk)           DISK="$2";           shift 2 ;;
        --memory)         MEMORY="$2";         shift 2 ;;
        --cores)          CORES="$2";          shift 2 ;;
        --vnc-resolution) VNC_RESOLUTION="$2"; shift 2 ;;
        --vm-id)          VMID="$2";           shift 2 ;;
        --timezone)       TIMEZONE="$2";       shift 2 ;;
        -h|--help)        usage ;;
        *)                fail "Unknown option: $1" ;;
    esac
done

[[ -z "$PASSWORD" ]] && fail "Missing required --password argument"
DNS_SERVER="${DNS_SERVER:-$GATEWAY_IP}"

# ── Pre-flight checks ───────────────────────────────────────────────────────
info "Running pre-flight checks …"
[[ $(id -u) -eq 0 ]] || fail "Must run as root on the Proxmox host"
command -v pct   >/dev/null 2>&1 || fail "pct not found – is this a Proxmox host?"
command -v pvesh >/dev/null 2>&1 || fail "pvesh not found"
command -v pveam >/dev/null 2>&1 || fail "pveam not found"
ok "Proxmox tooling present"

# ── Auto-detect next VMID ────────────────────────────────────────────────────
if [[ -z "$VMID" ]]; then
    info "Auto-detecting next available VMID …"
    USED_IDS=$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null \
        | python3 -c "import sys,json; print(' '.join(str(r['vmid']) for r in json.load(sys.stdin)))" 2>/dev/null || echo "")
    VMID=100
    while echo " $USED_IDS " | grep -q " $VMID "; do
        VMID=$((VMID + 1))
    done
fi
ok "Using VMID ${VMID}"

# ── Auto-detect storage ─────────────────────────────────────────────────────
info "Detecting storage backends …"
detect_storage() {
    local content_type="$1"
    pvesh get /storage --output-format json 2>/dev/null \
        | python3 -c "
import sys, json
for s in json.load(sys.stdin):
    if '${content_type}' in s.get('content',''):
        print(s['storage']); break
" 2>/dev/null || echo ""
}

TEMPLATE_STORAGE=$(detect_storage "vztmpl")
[[ -n "$TEMPLATE_STORAGE" ]] || fail "No storage with 'vztmpl' content found"
ok "Template storage: ${TEMPLATE_STORAGE}"

ROOTFS_STORAGE=$(detect_storage "rootdir")
if [[ -z "$ROOTFS_STORAGE" ]]; then
    ROOTFS_STORAGE=$(detect_storage "images")
fi
[[ -n "$ROOTFS_STORAGE" ]] || ROOTFS_STORAGE="$TEMPLATE_STORAGE"
ok "Root-FS storage: ${ROOTFS_STORAGE}"

# ── Generate tokens / passwords ─────────────────────────────────────────────
AUTH_TOKEN=$(openssl rand -hex 32)
VNC_PASSWORD=$(openssl rand -base64 12 | tr -dc 'A-Za-z0-9' | head -c 12)
ok "Auth token and VNC password generated"

# ── Helper: execute inside container ─────────────────────────────────────────
ct_exec() {
    pct exec "$VMID" -- bash -c "$1"
}

###############################################################################
# STEP 1 – Download Debian 13 template
###############################################################################
info "Downloading Debian 13 (trixie) template …"
pveam update >/dev/null 2>&1 || true
TEMPLATE=$(pveam available --section system 2>/dev/null \
    | awk '/debian-13/ { print $2; exit }')
if [[ -z "$TEMPLATE" ]]; then
    TEMPLATE=$(pveam available --section system 2>/dev/null \
        | awk '/debian-13\|trixie/ { print $2; exit }')
fi
[[ -n "$TEMPLATE" ]] || fail "Debian 13 template not found in repository"
pveam download "$TEMPLATE_STORAGE" "$TEMPLATE" >/dev/null 2>&1 || true
ok "Template ready: ${TEMPLATE}"

###############################################################################
# STEP 2 – Create unprivileged LXC container
###############################################################################
info "Creating unprivileged LXC container ${VMID} …"
pct create "$VMID" \
    "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
    --hostname openclaw \
    --password "$PASSWORD" \
    --unprivileged 1 \
    --features nesting=1 \
    --ostype debian \
    --arch amd64 \
    --cores "$CORES" \
    --memory "$MEMORY" \
    --swap 512 \
    --rootfs "${ROOTFS_STORAGE}:${DISK}" \
    --net0 "name=eth0,bridge=vmbr0,firewall=1,ip=dhcp" \
    --nameserver "$DNS_SERVER" \
    --timezone "$TIMEZONE" \
    --start 0 \
    --onboot 1
ok "Container ${VMID} created (unprivileged, nesting=1, firewall=1)"

###############################################################################
# STEP 3 – Configure Proxmox firewall
###############################################################################
info "Configuring Proxmox firewall for CT ${VMID} …"

# Cluster-level: ensure firewall is enabled
CLUSTER_FW="/etc/pve/firewall/cluster.fw"
if ! grep -q "^\[OPTIONS\]" "$CLUSTER_FW" 2>/dev/null; then
    mkdir -p "$(dirname "$CLUSTER_FW")"
    cat >> "$CLUSTER_FW" <<'CLUSTERFW'

[OPTIONS]
enable: 1
CLUSTERFW
fi

# Per-container firewall
CT_FW="/etc/pve/firewall/${VMID}.fw"
cat > "$CT_FW" <<CTFW
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: DROP
log_level_in: nolog
log_level_out: nolog

[RULES]
# --- INBOUND ---
# Allow SSH from LAN only
IN ACCEPT -source ${LAN_SUBNET} -p tcp -dport 22 -log nolog
# Allow ICMP
IN ACCEPT -p icmp -log nolog
# Allow established/related return traffic
IN ACCEPT -m state --state ESTABLISHED,RELATED -log nolog

# --- OUTBOUND ---
# Allow DNS (UDP+TCP)
OUT ACCEPT -p udp -dport 53 -log nolog
OUT ACCEPT -p tcp -dport 53 -log nolog
# Allow HTTP/HTTPS (internet access for npm, apt, etc.)
OUT ACCEPT -p tcp -dport 80 -log nolog
OUT ACCEPT -p tcp -dport 443 -log nolog
# Allow NTP
OUT ACCEPT -p udp -dport 123 -log nolog
# Allow gateway for routing
OUT ACCEPT -dest ${GATEWAY_IP}/32 -log nolog
# Block LAN subnet
OUT DROP -dest ${LAN_SUBNET} -log nolog
# Block all RFC1918 ranges
OUT DROP -dest 10.0.0.0/8 -log nolog
OUT DROP -dest 172.16.0.0/12 -log nolog
OUT DROP -dest 192.168.0.0/16 -log nolog
# Allow everything else outbound (internet)
OUT ACCEPT -log nolog
CTFW
ok "Proxmox firewall configured (default DROP, internet-only egress)"

###############################################################################
# STEP 4 – Start container, wait for network
###############################################################################
info "Starting container ${VMID} …"
pct start "$VMID"
sleep 3

info "Waiting for network (DHCP) …"
for i in $(seq 1 30); do
    if ct_exec "ip -4 addr show eth0 2>/dev/null | grep -q 'inet '" 2>/dev/null; then
        break
    fi
    sleep 2
done
CT_IP=$(ct_exec "ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}'" 2>/dev/null || echo "unknown")
ok "Container started – IP: ${CT_IP}"

###############################################################################
# STEP 5 – Base packages + hardening
###############################################################################
info "Installing base packages and hardening …"

ct_exec "export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
    curl wget gnupg2 ca-certificates apt-transport-https \
    sudo iptables procps dbus-x11 \
    unattended-upgrades apt-listchanges \
    xdg-utils
"

# Disable IPv6
ct_exec "
cat > /etc/sysctl.d/99-disable-ipv6.conf <<'SYSCTL'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
SYSCTL
sysctl --system >/dev/null 2>&1 || true
"

# In-container iptables (defense in depth)
ct_exec "
cat > /etc/network/if-up.d/openclaw-firewall <<'IPTABLES'
#!/bin/sh
# Defense-in-depth: container-level firewall
iptables -F OUTPUT 2>/dev/null || true
# Allow loopback
iptables -A OUTPUT -o lo -j ACCEPT
# Allow established
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
# Allow DNS
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
# Allow HTTP/HTTPS
iptables -A OUTPUT -p tcp --dport 80 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 443 -j ACCEPT
# Allow NTP
iptables -A OUTPUT -p udp --dport 123 -j ACCEPT
# Allow gateway
iptables -A OUTPUT -d ${GATEWAY_IP}/32 -j ACCEPT
# Block RFC1918
iptables -A OUTPUT -d 10.0.0.0/8 -j DROP
iptables -A OUTPUT -d 172.16.0.0/12 -j DROP
iptables -A OUTPUT -d 192.168.0.0/16 -j DROP
# Allow remaining (internet)
iptables -A OUTPUT -j ACCEPT
IPTABLES
chmod +x /etc/network/if-up.d/openclaw-firewall
/etc/network/if-up.d/openclaw-firewall || true
"

# Unattended security upgrades
ct_exec "
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'UUCONF'
APT::Periodic::Update-Package-Lists \"1\";
APT::Periodic::Unattended-Upgrade \"1\";
APT::Periodic::AutocleanInterval \"7\";
UUCONF
cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'UUCONF2'
Unattended-Upgrade::Origins-Pattern {
    \"origin=Debian,codename=\${distro_codename},label=Debian-Security\";
    \"origin=Debian,codename=\${distro_codename}-security,label=Debian-Security\";
};
Unattended-Upgrade::AutoFixInterruptedDpkg \"true\";
Unattended-Upgrade::Remove-Unused-Dependencies \"true\";
UUCONF2
"
ok "Base packages installed, IPv6 disabled, iptables + unattended-upgrades configured"

###############################################################################
# STEP 6 – Create non-root service user
###############################################################################
info "Creating non-root user 'openclaw' …"
ct_exec "
useradd -m -s /bin/bash -G audio,video openclaw
echo 'openclaw ALL=(ALL) ALL' > /etc/sudoers.d/openclaw
chmod 440 /etc/sudoers.d/openclaw
"
ok "User 'openclaw' created (sudo with password, no NOPASSWD)"

###############################################################################
# STEP 7 – Install Node.js 24
###############################################################################
info "Installing Node.js 24 …"
ct_exec "
curl -fsSL https://deb.nodesource.com/setup_24.x | bash - >/dev/null 2>&1
apt-get install -y -qq nodejs
"
NODE_VER=$(ct_exec "node --version" 2>/dev/null || echo "unknown")
ok "Node.js installed: ${NODE_VER}"

###############################################################################
# STEP 8 – Install OpenClaw via npm
###############################################################################
info "Installing OpenClaw globally …"
ct_exec "npm install -g openclaw 2>&1 | tail -1"
OPENCLAW_VER=$(ct_exec "openclaw --version" 2>/dev/null || echo "unknown")
ok "OpenClaw installed: ${OPENCLAW_VER}"

###############################################################################
# STEP 9 – Install LXQt + TigerVNC + noVNC + Chrome
###############################################################################
info "Installing desktop environment (LXQt + TigerVNC + noVNC + Chrome) …"
ct_exec "export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq \
    lxqt-core lxqt-about lxqt-config lxqt-globalkeys lxqt-notificationd \
    lxqt-openssh-askpass lxqt-panel lxqt-qtplugin lxqt-runner lxqt-session \
    lxqt-sudo lxqt-themes openbox pcmanfm-qt qterminal \
    tigervnc-standalone-server tigervnc-common \
    novnc websockify \
    xfonts-base xfonts-75dpi xfonts-100dpi fonts-liberation \
    dbus-x11 at-spi2-core
"

# Install Google Chrome
ct_exec "
curl -fsSL https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb -o /tmp/chrome.deb
apt-get install -y -qq /tmp/chrome.deb || apt-get install -y -f -qq
rm -f /tmp/chrome.deb
"
ok "Desktop environment + Chrome installed"

###############################################################################
# STEP 10 – Configure OpenClaw with hardened baseline
###############################################################################
info "Configuring OpenClaw with hardened baseline …"
ct_exec "
mkdir -p /home/openclaw/.openclaw
cat > /home/openclaw/.openclaw/openclaw.json <<'OCCONFIG'
{
  \"gateway\": {
    \"mode\": \"local\",
    \"bind\": \"loopback\",
    \"auth\": {
      \"mode\": \"token\",
      \"token\": \"${AUTH_TOKEN}\"
    }
  },
  \"session\": {
    \"dmScope\": \"per-channel-peer\"
  },
  \"tools\": {
    \"profile\": \"messaging\",
    \"deny\": [\"group:automation\", \"group:runtime\", \"group:fs\", \"sessions_spawn\", \"sessions_send\"],
    \"fs\": {
      \"workspaceOnly\": true
    },
    \"exec\": {
      \"security\": \"deny\",
      \"ask\": \"always\"
    },
    \"elevated\": {
      \"enabled\": false
    }
  }
}
OCCONFIG
chown -R openclaw:openclaw /home/openclaw/.openclaw
"
ok "OpenClaw hardened config written"

###############################################################################
# STEP 11 – Configure VNC (non-root, separate password, localhost)
###############################################################################
info "Configuring TigerVNC for user 'openclaw' …"
VNC_W="${VNC_RESOLUTION%%x*}"
VNC_H="${VNC_RESOLUTION##*x}"

ct_exec "
mkdir -p /home/openclaw/.vnc
cat > /home/openclaw/.vnc/xstartup <<'VNCSTART'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
export XDG_SESSION_TYPE=x11
exec startlxqt
VNCSTART
chmod +x /home/openclaw/.vnc/xstartup

# Set VNC password (separate from root password)
echo '${VNC_PASSWORD}' | vncpasswd -f > /home/openclaw/.vnc/passwd
chmod 600 /home/openclaw/.vnc/passwd

cat > /home/openclaw/.vnc/config <<VNCCONF
geometry=${VNC_RESOLUTION}
localhost
depth=24
VNCCONF

chown -R openclaw:openclaw /home/openclaw/.vnc
"
ok "VNC configured (localhost only, separate password)"

###############################################################################
# STEP 12 – Configure Chrome for non-root user WITH sandbox
###############################################################################
info "Configuring Chrome with sandbox for non-root user …"
ct_exec "
mkdir -p /home/openclaw/.config/google-chrome
cat > /home/openclaw/.config/google-chrome/Local\ State <<'CHROMESTATE'
{
  \"browser\": {
    \"enabled_labs_experiments\": []
  }
}
CHROMESTATE

# Chrome wrapper that runs as non-root with sandbox enabled
cat > /usr/local/bin/openclaw-chrome <<'CHROMEWRAP'
#!/bin/sh
exec google-chrome-stable \
    --disable-gpu \
    --disable-dev-shm-usage \
    --start-maximized \
    \"\$@\"
CHROMEWRAP
chmod +x /usr/local/bin/openclaw-chrome
chown -R openclaw:openclaw /home/openclaw/.config/google-chrome
"
ok "Chrome configured (sandbox enabled, non-root user)"

###############################################################################
# STEP 13 – Desktop shortcuts
###############################################################################
info "Creating desktop shortcuts …"
ct_exec "
mkdir -p /home/openclaw/Desktop

# Terminal shortcut
cat > /home/openclaw/Desktop/terminal.desktop <<'SHORTCUT'
[Desktop Entry]
Type=Application
Name=Terminal
Exec=qterminal
Icon=utilities-terminal
Terminal=false
Categories=System;TerminalEmulator;
SHORTCUT

# OpenClaw Onboard Wizard
cat > /home/openclaw/Desktop/openclaw-wizard.desktop <<'SHORTCUT'
[Desktop Entry]
Type=Application
Name=OpenClaw Onboard Wizard
Exec=qterminal -e openclaw onboard
Icon=system-run
Terminal=false
Categories=Utility;
SHORTCUT

# OpenClaw Dashboard
cat > /home/openclaw/Desktop/openclaw-dashboard.desktop <<'SHORTCUT'
[Desktop Entry]
Type=Application
Name=OpenClaw Dashboard
Exec=openclaw-chrome http://127.0.0.1:18789
Icon=internet-web-browser
Terminal=false
Categories=Network;WebBrowser;
SHORTCUT

chmod +x /home/openclaw/Desktop/*.desktop
chown -R openclaw:openclaw /home/openclaw/Desktop
"
ok "Desktop shortcuts created"

###############################################################################
# STEP 14 – Disable LXC-incompatible LXQt components
###############################################################################
info "Disabling LXC-incompatible LXQt components …"
ct_exec "
mkdir -p /home/openclaw/.config/lxqt

# Disable power management
cat > /home/openclaw/.config/lxqt/lxqt-powermanagement.conf <<'PWRCONF'
[General]
__userfile__=true
enableBatteryWatcher=false
enableIdlenessWatcher=false
enableLidWatcher=false
PWRCONF

# Disable screen saver
cat > /home/openclaw/.config/lxqt/lxqt-config-session.conf <<'SESSCONF'
[General]
__userfile__=true

[Screensaver]
lock_command=
SESSCONF

# Minimal autostart – exclude problematic modules
mkdir -p /home/openclaw/.config/autostart
cat > /home/openclaw/.config/autostart/lxqt-powermanagement.desktop <<'NOAUTO'
[Desktop Entry]
Type=Application
Name=LXQt Power Management
Hidden=true
NOAUTO

chown -R openclaw:openclaw /home/openclaw/.config
"
ok "LXC-incompatible LXQt components disabled"

###############################################################################
# STEP 15 – Systemd services (all as non-root user)
###############################################################################
info "Creating systemd services …"

# OpenClaw gateway service
ct_exec "
cat > /etc/systemd/system/openclaw-gateway.service <<'SVCOC'
[Unit]
Description=OpenClaw Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=openclaw
Group=openclaw
Environment=HOME=/home/openclaw
WorkingDirectory=/home/openclaw
ExecStart=/usr/bin/openclaw gateway run --auth token
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCOC
"

# TigerVNC service
ct_exec "
cat > /etc/systemd/system/openclaw-vnc.service <<'SVCVNC'
[Unit]
Description=TigerVNC Server for OpenClaw
After=network.target

[Service]
Type=simple
User=openclaw
Group=openclaw
Environment=HOME=/home/openclaw
WorkingDirectory=/home/openclaw
ExecStartPre=/bin/sh -c 'rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 || true'
ExecStart=/usr/bin/vncserver :1 -fg -localhost yes -geometry ${VNC_RESOLUTION} -depth 24
ExecStop=/usr/bin/vncserver -kill :1
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
SVCVNC
"

# noVNC service (localhost only)
ct_exec "
cat > /etc/systemd/system/openclaw-novnc.service <<'SVCNOVNC'
[Unit]
Description=noVNC Web Client for OpenClaw
After=openclaw-vnc.service
Requires=openclaw-vnc.service

[Service]
Type=simple
User=openclaw
Group=openclaw
Environment=HOME=/home/openclaw
ExecStart=/usr/bin/websockify --web /usr/share/novnc 127.0.0.1:6080 localhost:5901
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
SVCNOVNC
"

# noVNC auto-scaling patch
ct_exec "
if [ -f /usr/share/novnc/app/ui.js ]; then
    sed -i \"s/UI.initSetting('resize', 'off')/UI.initSetting('resize', 'scale')/\" /usr/share/novnc/app/ui.js
fi
"

# Enable and start services
ct_exec "
systemctl daemon-reload
systemctl enable openclaw-gateway openclaw-vnc openclaw-novnc
systemctl start openclaw-gateway
sleep 2
systemctl start openclaw-vnc
sleep 2
systemctl start openclaw-novnc
"
ok "Systemd services created and started"

###############################################################################
# STEP 16 – Inject Z.AI API key if provided
###############################################################################
if [[ -n "$ZAI_API_KEY" ]]; then
    info "Injecting Z.AI API key …"
    ct_exec "
python3 -c \"
import json, sys
with open('/home/openclaw/.openclaw/openclaw.json', 'r') as f:
    cfg = json.load(f)
cfg.setdefault('providers', {})['zai'] = {'apiKey': '${ZAI_API_KEY}'}
with open('/home/openclaw/.openclaw/openclaw.json', 'w') as f:
    json.dump(cfg, f, indent=2)
\"
chown openclaw:openclaw /home/openclaw/.openclaw/openclaw.json
chmod 600 /home/openclaw/.openclaw/openclaw.json
"
    ok "Z.AI API key injected"
else
    warn "No Z.AI API key provided – use onboard wizard or add later"
fi

###############################################################################
# STEP 17 – File permissions (700 state dir, 600 config)
###############################################################################
info "Setting file permissions …"
ct_exec "
chmod 700 /home/openclaw/.openclaw
chmod 600 /home/openclaw/.openclaw/openclaw.json
chown -R openclaw:openclaw /home/openclaw/.openclaw
chown -R openclaw:openclaw /home/openclaw/.vnc
chmod 700 /home/openclaw/.vnc
chmod 600 /home/openclaw/.vnc/passwd
"
ok "File permissions hardened (state dir 700, config 600)"

###############################################################################
# STEP 18 – Run openclaw security audit --fix
###############################################################################
info "Running OpenClaw security audit …"
ct_exec "su - openclaw -c 'openclaw security audit --fix'" 2>&1 || warn "Security audit returned warnings (review manually)"
ok "Security audit complete"

###############################################################################
# STEP 19 – Verify services
###############################################################################
info "Verifying services …"
FAILED=0
for svc in openclaw-gateway openclaw-vnc openclaw-novnc; do
    STATUS=$(ct_exec "systemctl is-active ${svc}" 2>/dev/null || echo "inactive")
    if [[ "$STATUS" == "active" ]]; then
        ok "  ${svc}: active"
    else
        warn "  ${svc}: ${STATUS}"
        FAILED=$((FAILED + 1))
    fi
done

if [[ $FAILED -gt 0 ]]; then
    warn "${FAILED} service(s) not yet active – they may need a moment to start"
fi

###############################################################################
# DONE – Connection info
###############################################################################
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  OpenClaw LXC Container Ready!${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${CYAN}Container:${NC}   VMID ${VMID} | IP ${CT_IP}"
echo -e "  ${CYAN}Node.js:${NC}     ${NODE_VER}"
echo -e "  ${CYAN}OpenClaw:${NC}    ${OPENCLAW_VER}"
echo ""
echo -e "  ${BOLD}SSH Access:${NC}"
echo -e "    ssh root@${CT_IP}"
echo ""
echo -e "  ${BOLD}noVNC Access (via SSH tunnel):${NC}"
echo -e "    ${YELLOW}ssh -L 6080:localhost:6080 root@${CT_IP}${NC}"
echo -e "    Then open: ${CYAN}http://localhost:6080/vnc.html${NC}"
echo -e "    VNC Password: ${YELLOW}${VNC_PASSWORD}${NC}"
echo ""
echo -e "  ${BOLD}Dashboard:${NC}"
echo -e "    Accessible inside container desktop (via noVNC) at:"
echo -e "    ${CYAN}http://127.0.0.1:18789${NC}"
echo ""
echo -e "  ${BOLD}Auth Token:${NC}"
echo -e "    ${YELLOW}${AUTH_TOKEN}${NC}"
echo ""
if [[ -z "$ZAI_API_KEY" ]]; then
echo -e "  ${BOLD}Next Step:${NC}"
echo -e "    Run the onboard wizard via the desktop shortcut or:"
echo -e "    ${CYAN}pct exec ${VMID} -- su - openclaw -c 'openclaw onboard'${NC}"
echo ""
fi
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo ""
ok "Setup complete!"
