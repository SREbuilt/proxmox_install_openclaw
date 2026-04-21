#!/bin/bash
###############################################################################
# setup-einvoice-lxc.sh — e-Invoice batch processing in Proxmox LXC
#
# Creates an unprivileged Debian 12 LXC with Docker.
# Clones the private e-Invoice repo, builds the Docker image, and configures
# NAS access via NFS bind-mount from the Proxmox host.
#
# Architecture:
#   Proxmox host mounts NAS via NFS → bind-mount into unprivileged LXC
#   LXC runs Docker → container sees /data/praxis
#
#   ┌─────────────┐  NFS   ┌──────────────┐  bind-mount  ┌──────────────┐
#   │ NAS "brain"  │───────►│ PVE host     │─────────────►│ LXC 103      │
#   │ /volume8/... │        │ /mnt/nas-... │              │ /nas/praxis  │
#   └─────────────┘        └──────────────┘              │  └─ Docker   │
#                                                         │    /data/... │
#                                                         └──────────────┘
#
# Usage:
#   ./setup-einvoice-lxc.sh \
#       --ssh-pubkey ~/.ssh/id_ed25519.pub \
#       --keepass-pw "YourMasterPassword" \
#       --github-pat "ghp_xxxx" \
#       --nas-ip 192.168.178.74
#
# Optional:
#       --ct-id 103  --ct-ip 192.168.178.83  --gateway 192.168.178.1
#       --ram 2048   --disk 16  --bridge vmbr0  --password "PASS"
#       --nas-export /volume8/praxis  --otel-endpoint http://host:4317
#
# Prerequisites: Proxmox VE 8.x+, NAS reachable via NFS
###############################################################################

set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────

CT_ID=103
CT_IP="192.168.178.83"
GATEWAY="192.168.178.1"
RAM=2048
DISK=16
BRIDGE="vmbr0"
PASSWORD=""
SSH_PUBKEY_FILE=""

NAS_IP="192.168.178.74"
NAS_HOSTNAME="brain"
NAS_EXPORT="/volume8/praxis"
HOST_NFS_MOUNT="/mnt/nas-praxis"

KEEPASS_PW=""
GITHUB_PAT=""
OTEL_ENDPOINT=""

REPO_URL="https://github.com/SREbuilt/Python.git"
REPO_BRANCH="migration_to_lxc_docker"

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
        --keepass-pw)     KEEPASS_PW="$2";     shift 2 ;;
        --github-pat)     GITHUB_PAT="$2";     shift 2 ;;
        --nas-ip)         NAS_IP="$2";         shift 2 ;;
        --nas-hostname)   NAS_HOSTNAME="$2";   shift 2 ;;
        --nas-export)     NAS_EXPORT="$2";     shift 2 ;;
        --otel-endpoint)  OTEL_ENDPOINT="$2";  shift 2 ;;
        *)                fail "Unknown argument: $1" ;;
    esac
done

# ─── Validate ────────────────────────────────────────────────────────────────

[[ -z "$SSH_PUBKEY_FILE" ]] && fail "Missing --ssh-pubkey <path>"
[[ ! -f "$SSH_PUBKEY_FILE" ]] && fail "SSH pubkey not found: $SSH_PUBKEY_FILE"
[[ -z "$KEEPASS_PW" ]] && fail "Missing --keepass-pw <password>"
[[ -z "$GITHUB_PAT" ]] && fail "Missing --github-pat <token>"
command -v pct &>/dev/null || fail "Must run on a Proxmox host"

[[ -z "$PASSWORD" ]] && PASSWORD=$(openssl rand -base64 12)

ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$CT_IP" 2>/dev/null || true

SSH_CMD="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes"

info "═══════════════════════════════════════════════════"
info "  e-Invoice LXC Setup — Batch Invoicing Service"
info "═══════════════════════════════════════════════════"
info "  CT ID:        $CT_ID"
info "  CT IP:        $CT_IP"
info "  RAM:          ${RAM}MB  Disk: ${DISK}GB"
info "  NAS:          ${NAS_HOSTNAME} (${NAS_IP})"
info "  NAS Export:   ${NAS_EXPORT}"
info "  Repo:         ${REPO_URL} @ ${REPO_BRANCH}"
info "  OTel:         ${OTEL_ENDPOINT:-disabled}"
info "═══════════════════════════════════════════════════"

###############################################################################
# Step 1/8: Download LXC template
###############################################################################

info "Step 1/8: Downloading Debian 12 LXC template..."
if [[ -f "$TEMPLATE_PATH" ]]; then
    ok "Template already cached"
else
    wget -q --show-progress -O "$TEMPLATE_PATH" "$TEMPLATE_URL"
    ok "Template downloaded"
fi

###############################################################################
# Step 2/8: Mount NAS via NFS on Proxmox host
###############################################################################

info "Step 2/8: Mounting NAS via NFS on Proxmox host..."

# Ensure nfs-common is available on the host
if ! command -v mount.nfs &>/dev/null; then
    apt-get update -qq && apt-get install -y -qq nfs-common
    ok "Installed nfs-common on Proxmox host"
fi

# Add /etc/hosts entry for NAS hostname (idempotent)
if ! grep -q "$NAS_HOSTNAME" /etc/hosts; then
    echo "${NAS_IP}  ${NAS_HOSTNAME}" >> /etc/hosts
    ok "Added ${NAS_HOSTNAME} → ${NAS_IP} to /etc/hosts"
else
    ok "${NAS_HOSTNAME} already in /etc/hosts"
fi

# Create host mount point
mkdir -p "$HOST_NFS_MOUNT"

# Mount NFS if not already mounted
if mountpoint -q "$HOST_NFS_MOUNT" 2>/dev/null; then
    ok "NFS already mounted at ${HOST_NFS_MOUNT}"
else
    mount -t nfs "${NAS_HOSTNAME}:${NAS_EXPORT}" "$HOST_NFS_MOUNT" \
        -o rw,hard,timeo=600,retrans=3,_netdev || fail "NFS mount failed — is the NAS reachable and NFS enabled?"
    ok "NFS mounted: ${NAS_HOSTNAME}:${NAS_EXPORT} → ${HOST_NFS_MOUNT}"
fi

# Verify NFS mount has expected content
if [[ ! -d "${HOST_NFS_MOUNT}/Rechnungen" ]] && [[ ! -d "${HOST_NFS_MOUNT}/assets" ]]; then
    warn "NFS mount exists but 'Rechnungen/' and 'assets/' not found — verify NAS share content"
fi

# Persist in /etc/fstab (idempotent)
FSTAB_ENTRY="${NAS_HOSTNAME}:${NAS_EXPORT}  ${HOST_NFS_MOUNT}  nfs  rw,hard,timeo=600,retrans=3,_netdev  0  0"
if ! grep -qF "$HOST_NFS_MOUNT" /etc/fstab; then
    echo "$FSTAB_ENTRY" >> /etc/fstab
    ok "Added NFS mount to /etc/fstab"
else
    ok "NFS mount already in /etc/fstab"
fi

###############################################################################
# Step 3/8: Create LXC
###############################################################################

info "Step 3/8: Creating LXC $CT_ID..."

if pct status "$CT_ID" &>/dev/null; then
    warn "LXC $CT_ID exists — destroying"
    pct stop "$CT_ID" 2>/dev/null || true
    sleep 2
    pct destroy "$CT_ID" --purge 2>/dev/null || true
    sleep 2
fi

pct create "$CT_ID" "$TEMPLATE_PATH" \
    --hostname invoicing \
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
    --onboot 0 \
    --start 0

ok "LXC $CT_ID created (${DISK}GB disk, unprivileged)"

# Bind-mount NAS into LXC (/nas/praxis inside LXC)
pct set "$CT_ID" -mp0 "${HOST_NFS_MOUNT},mp=/nas/praxis"
ok "NAS bind-mount configured: ${HOST_NFS_MOUNT} → /nas/praxis (inside LXC)"

###############################################################################
# Step 4/8: Proxmox firewall
###############################################################################

info "Step 4/8: Configuring Proxmox firewall..."

cat > "/etc/pve/firewall/${CT_ID}.fw" << EOF
[OPTIONS]
enable: 0
policy_in: DROP
policy_out: ACCEPT

[RULES]
# SSH from LAN
IN ACCEPT -source 192.168.178.0/24 -p tcp -dport 22 -log nolog

# ICMP (ping)
IN ACCEPT -p icmp -log nolog

# No inbound service ports — this is a batch job, not a daemon
EOF

ok "Firewall configured (batch job — no inbound service ports)"

###############################################################################
# Step 5/8: Start LXC + wait for SSH
###############################################################################

info "Step 5/8: Starting LXC..."
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
# Step 6/8: Install Docker via SSH
###############################################################################

info "Step 6/8: Installing Docker..."

$SSH_CMD "root@${CT_IP}" << 'INSTALL_DOCKER'
set -e
echo "[1/4] Installing prerequisites..."
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg git

echo "[2/4] Adding Docker repository..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list

echo "[3/4] Installing Docker Engine..."
apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable --now docker

echo "[4/4] Verifying Docker..."
docker run --rm hello-world | head -1
echo "DOCKER_OK"
INSTALL_DOCKER
ok "Docker installed"

###############################################################################
# Step 7/8: Clone repo, copy fonts, create .env, build image
###############################################################################

info "Step 7/8: Deploying e-Invoice application..."

# Clone the private repo using PAT (token is not stored permanently)
info "  Cloning repository..."
CLONE_URL="https://${GITHUB_PAT}@github.com/SREbuilt/Python.git"
$SSH_CMD "root@${CT_IP}" "git clone -b ${REPO_BRANCH} '${CLONE_URL}' /opt/e-invoice 2>&1 | tail -1"
ok "  Repository cloned"

# Remove PAT from git remote (security: don't leave token in .git/config)
$SSH_CMD "root@${CT_IP}" "cd /opt/e-invoice && git remote set-url origin ${REPO_URL}"
# Clear shell history to remove any trace of the PAT
$SSH_CMD "root@${CT_IP}" "history -c 2>/dev/null; rm -f ~/.bash_history" 2>/dev/null || true
ok "  PAT removed from git remote and shell history"

# Copy Century Gothic fonts from NAS if available
info "  Copying fonts from NAS..."
$SSH_CMD "root@${CT_IP}" << 'COPY_FONTS'
set -e
mkdir -p /opt/e-invoice/e-Invoice/fonts
# Try common font locations on NAS
for dir in /nas/praxis/assets/Vorlagen /nas/praxis/assets/fonts /nas/praxis/assets; do
    if ls "$dir"/GOTHIC*.TTF 2>/dev/null || ls "$dir"/gothic*.ttf 2>/dev/null; then
        cp "$dir"/GOTHIC*.TTF /opt/e-invoice/e-Invoice/fonts/ 2>/dev/null || true
        cp "$dir"/gothic*.ttf /opt/e-invoice/e-Invoice/fonts/ 2>/dev/null || true
        echo "FONTS_COPIED"
        break
    fi
done
# Create empty placeholder if no fonts found (build won't fail)
ls /opt/e-invoice/e-Invoice/fonts/*.TTF 2>/dev/null \
    || ls /opt/e-invoice/e-Invoice/fonts/*.ttf 2>/dev/null \
    || echo "NO_FONTS_FOUND — Century Gothic not on NAS (PDF will use fallback font)"
COPY_FONTS
ok "  Fonts step done"

# Create .env file with secrets
info "  Creating .env file..."
$SSH_CMD "root@${CT_IP}" "cat > /opt/e-invoice/e-Invoice/.env" << ENV_EOF
KEEPASSXC_MASTER_PASSWORD=${KEEPASS_PW}
OTEL_EXPORTER_OTLP_ENDPOINT=${OTEL_ENDPOINT:-http://host.docker.internal:4317}
NAS_MOUNT=/nas/praxis
ENV_EOF
$SSH_CMD "root@${CT_IP}" "chmod 600 /opt/e-invoice/e-Invoice/.env"
ok "  .env created (permissions 600)"

# Build Docker image
info "  Building Docker image (this may take 3-5 minutes)..."
$SSH_CMD "root@${CT_IP}" << 'BUILD_IMAGE'
set -euo pipefail
cd /opt/e-invoice/e-Invoice
docker compose build
echo "BUILD_OK"
BUILD_IMAGE
ok "  Docker image built"

# Verify image exists
$SSH_CMD "root@${CT_IP}" "docker images e-invoice --format '{{.Repository}}:{{.Tag}}  {{.Size}}'" 2>/dev/null || true

###############################################################################
# Step 8/8: Enable firewall + create convenience script
###############################################################################

info "Step 8/8: Finalizing..."

# Enable LXC firewall
sed -i 's/^enable: 0/enable: 1/' "/etc/pve/firewall/${CT_ID}.fw"
pct set "$CT_ID" --net0 "name=eth0,bridge=${BRIDGE},ip=${CT_IP}/24,gw=${GATEWAY},firewall=1"
ok "Firewall enabled"

# Create convenience invoicing script in LXC
$SSH_CMD "root@${CT_IP}" << 'CREATE_SCRIPT'
cat > /usr/local/bin/invoice << 'SCRIPT'
#!/bin/bash
# Convenience wrapper for e-Invoice Docker container
# Usage:
#   invoice --year 2026 --month 4
#   invoice --year 2026 --month 4 --fireforget --prodrun
#   invoice --help

set -e
cd /opt/e-invoice/e-Invoice

# Default: find the current year's Excel
YEAR=$(date +%Y)
EXCEL="/data/praxis/Rechnungen/${YEAR}/Rechnungsliste_${YEAR}.xlsx"

echo "═══════════════════════════════════════════"
echo "  e-Invoice Generator"
echo "═══════════════════════════════════════════"
echo "  Excel: ${EXCEL}"
echo "  Args:  $@"
echo "═══════════════════════════════════════════"

docker compose run --rm e-invoice \
    --journal "${EXCEL}" \
    --session Journal --config Config \
    "$@"

echo ""
echo "✅ Done. Check output in /nas/praxis/Rechnungen/${YEAR}/"
SCRIPT
chmod +x /usr/local/bin/invoice
echo "SCRIPT_OK"
CREATE_SCRIPT
ok "Convenience script created: 'invoice' command"

# Create update script
$SSH_CMD "root@${CT_IP}" << 'CREATE_UPDATE'
cat > /usr/local/bin/invoice-update << 'SCRIPT'
#!/bin/bash
# Pull latest code and rebuild Docker image
set -e
echo "Pulling latest code..."
cd /opt/e-invoice
git pull
echo "Rebuilding Docker image..."
cd e-Invoice
docker compose build
echo "✅ Update complete"
SCRIPT
chmod +x /usr/local/bin/invoice-update
echo "UPDATE_SCRIPT_OK"
CREATE_UPDATE
ok "Update script created: 'invoice-update' command"

# Verify NAS mount is accessible from inside LXC (read + write test)
info "  Verifying NAS access..."
NAS_CHECK=$($SSH_CMD "root@${CT_IP}" "ls /nas/praxis/ 2>/dev/null | head -5" 2>/dev/null || echo "MOUNT_FAILED")
if [[ "$NAS_CHECK" != "MOUNT_FAILED" ]] && [[ -n "$NAS_CHECK" ]]; then
    ok "NAS readable from LXC: $(echo "$NAS_CHECK" | tr '\n' ' ')"
    # Write test — unprivileged LXC UID mapping can break writes
    WRITE_TEST=$($SSH_CMD "root@${CT_IP}" "touch /nas/praxis/.lxc-write-test && rm -f /nas/praxis/.lxc-write-test && echo WRITE_OK" 2>/dev/null || echo "WRITE_FAILED")
    if [[ "$WRITE_TEST" == "WRITE_OK" ]]; then
        ok "NAS writable from LXC (UID mapping OK)"
    else
        warn "NAS readable but NOT writable — check NFS squash settings on NAS"
        warn "  Fix: NAS → NFS Permissions → Squash: 'Map all users to admin'"
    fi
else
    warn "NAS mount empty or inaccessible — check NFS permissions on NAS"
fi

###############################################################################
# Summary
###############################################################################

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✅ e-Invoice LXC Setup Complete!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""
echo "  LXC ID:         $CT_ID"
echo "  LXC IP:         $CT_IP"
echo "  Password:       $PASSWORD"
echo "  SSH:            ssh root@${CT_IP}"
echo ""
echo "  NAS Mount:      ${NAS_HOSTNAME}:${NAS_EXPORT} → /nas/praxis"
echo "  App Dir:        /opt/e-invoice/e-Invoice"
echo "  Docker Image:   e-invoice (batch job)"
echo ""
echo "  Usage:"
echo "    # Generate April 2026 invoices (draft mode)"
echo "    ssh root@${CT_IP} invoice --year 2026 --month 4"
echo ""
echo "    # Fire & forget (sends emails directly)"
echo "    ssh root@${CT_IP} invoice --year 2026 --month 4 --fireforget --prodrun"
echo ""
echo "    # Update code + rebuild image"
echo "    ssh root@${CT_IP} invoice-update"
echo ""
echo "  NAS Data Flow:"
echo "    Input:  \\\\brain\\praxis\\Rechnungen\\2026\\Rechnungsliste_2026.xlsx"
echo "    Output: \\\\brain\\praxis\\Rechnungen\\2026\\Praxis Rechnungen 2026-04\\"
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}  ⚠️  SAVE the password: ${PASSWORD}${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
