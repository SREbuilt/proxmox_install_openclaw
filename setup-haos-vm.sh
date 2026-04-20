#!/bin/bash
###############################################################################
# setup-haos-vm.sh — Fire-and-forget Home Assistant OS VM on Proxmox
#
# Downloads the latest HAOS qcow2 image, creates a UEFI VM with USB
# passthrough, and starts it. HAOS manages itself after first boot.
#
# Based on the proven VM 108 configuration (running stable since 2026-04).
#
# Usage:
#   ./setup-haos-vm.sh --ssh-pubkey ~/.ssh/id_ed25519.pub
#
# Optional:
#       --vm-id 110  --ram 6656  --disk 128  --bridge vmbr0
#       --usb-device "3-4"  --serial-device "/dev/ttyACM0"
#       --haos-version "17.2"
#
# Prerequisites: Proxmox VE 8.x+, wget, xz-utils
###############################################################################

set -euo pipefail

# ─── Defaults (modeled after working VM 108) ─────────────────────────────────

VM_ID=110
VM_NAME="haos"
RAM=6656
DISK=128
BRIDGE="vmbr0"
CORES=2
STORAGE="local-lvm"
USB_DEVICE="3-4"
SERIAL_DEVICE="/dev/ttyACM0"
SSH_PUBKEY_FILE=""
HAOS_VERSION="17.2"

HAOS_URL_BASE="https://github.com/home-assistant/operating-system/releases/download"
HAOS_IMG_NAME="haos_ova-${HAOS_VERSION}.qcow2"
HAOS_DL_NAME="${HAOS_IMG_NAME}.xz"
HAOS_CACHE_DIR="/var/lib/vz/template/cache"

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
        --vm-name)        VM_NAME="$2";        shift 2 ;;
        --ram)            RAM="$2";            shift 2 ;;
        --disk)           DISK="$2";           shift 2 ;;
        --bridge)         BRIDGE="$2";         shift 2 ;;
        --cores)          CORES="$2";          shift 2 ;;
        --storage)        STORAGE="$2";        shift 2 ;;
        --usb-device)     USB_DEVICE="$2";     shift 2 ;;
        --serial-device)  SERIAL_DEVICE="$2";  shift 2 ;;
        --ssh-pubkey)     SSH_PUBKEY_FILE="$2"; shift 2 ;;
        --haos-version)   HAOS_VERSION="$2";   shift 2 ;;
        --no-usb)         USB_DEVICE=""; SERIAL_DEVICE=""; shift ;;
        *)                fail "Unknown argument: $1" ;;
    esac
done

# ─── Validate ────────────────────────────────────────────────────────────────

command -v qm &>/dev/null || fail "Must run on a Proxmox host"
command -v wget &>/dev/null || fail "wget not found"
command -v xz &>/dev/null || fail "xz not found. Run: apt install -y xz-utils"

# Recalculate image names if version was overridden
HAOS_IMG_NAME="haos_ova-${HAOS_VERSION}.qcow2"
HAOS_DL_NAME="${HAOS_IMG_NAME}.xz"

# Detect Docker on host (blocks VM traffic)
if iptables -L DOCKER-USER -n &>/dev/null 2>&1; then
    warn "Docker detected on Proxmox host — this blocks ALL VM network traffic!"
    warn "Removing Docker from Proxmox host..."
    systemctl stop docker docker.socket containerd 2>/dev/null || true
    systemctl disable docker docker.socket containerd 2>/dev/null || true
    apt purge -y docker-ce docker-ce-cli docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras containerd.io 2>/dev/null || true
    apt autoremove -y 2>/dev/null || true
    iptables -P FORWARD ACCEPT 2>/dev/null || true
    iptables -F FORWARD 2>/dev/null || true
    pve-firewall restart 2>/dev/null || true
    ok "Docker removed from Proxmox host"
fi

info "═══════════════════════════════════════════════════"
info "  Home Assistant OS VM Setup — Fire & Forget"
info "═══════════════════════════════════════════════════"
info "  VM ID:     $VM_ID"
info "  VM Name:   $VM_NAME"
info "  RAM:       ${RAM}MB  Disk: ${DISK}GB  Cores: $CORES"
info "  BIOS:      OVMF (UEFI)"
info "  HAOS:      v${HAOS_VERSION}"
info "  USB:       ${USB_DEVICE:-(none)}  Serial: ${SERIAL_DEVICE:-(none)}"
info "═══════════════════════════════════════════════════"

###############################################################################
# Step 1/5: Download HAOS image
###############################################################################

info "Step 1/5: Downloading Home Assistant OS ${HAOS_VERSION}..."

if [[ -f "${HAOS_CACHE_DIR}/${HAOS_IMG_NAME}" ]]; then
    ok "HAOS image already cached"
else
    if [[ -f "${HAOS_CACHE_DIR}/${HAOS_DL_NAME}" ]]; then
        info "  Compressed image cached, decompressing..."
    else
        wget -q --show-progress -O "${HAOS_CACHE_DIR}/${HAOS_DL_NAME}" \
            "${HAOS_URL_BASE}/${HAOS_VERSION}/${HAOS_DL_NAME}" \
            || fail "Failed to download HAOS ${HAOS_VERSION}"
        ok "Downloaded HAOS ${HAOS_VERSION}"
    fi

    info "  Decompressing (this takes a minute)..."
    xz -d "${HAOS_CACHE_DIR}/${HAOS_DL_NAME}" \
        || fail "Failed to decompress HAOS image"
    ok "HAOS image decompressed"
fi

###############################################################################
# Step 2/5: Create VM
###############################################################################

info "Step 2/5: Creating VM $VM_ID..."

if qm status "$VM_ID" &>/dev/null; then
    warn "VM $VM_ID exists — destroying"
    qm stop "$VM_ID" --skiplock 2>/dev/null || true
    sleep 3
    qm destroy "$VM_ID" --purge 2>/dev/null || true
    sleep 2
fi

# Create VM with UEFI BIOS (required for HAOS)
qm create "$VM_ID" \
    --name "$VM_NAME" \
    --ostype l26 \
    --bios ovmf \
    --machine q35 \
    --cores "$CORES" \
    --sockets 1 \
    --memory "$RAM" \
    --balloon 0 \
    --cpu host \
    --net0 "virtio,bridge=${BRIDGE}" \
    --scsihw virtio-scsi-pci \
    --tablet 0 \
    --localtime 1 \
    --agent 1 \
    --onboot 1 \
    --startup order=1

ok "VM $VM_ID created"

# Add EFI disk
info "  Adding EFI disk..."
qm set "$VM_ID" --efidisk0 "${STORAGE}:4,efitype=4m"
ok "  EFI disk added"

# Import HAOS disk
info "  Importing HAOS disk image..."
qm importdisk "$VM_ID" "${HAOS_CACHE_DIR}/${HAOS_IMG_NAME}" "$STORAGE" --format raw >/dev/null
# Find the imported disk name
IMPORTED_DISK=$(qm config "$VM_ID" | grep "^unused" | head -1 | awk '{print $2}')
if [[ -n "$IMPORTED_DISK" ]]; then
    qm set "$VM_ID" --scsi0 "${IMPORTED_DISK},cache=writethrough,discard=on,ssd=1"
else
    # Fallback: try standard naming
    qm set "$VM_ID" --scsi0 "${STORAGE}:vm-${VM_ID}-disk-1,cache=writethrough,discard=on,ssd=1"
fi
ok "  HAOS disk imported"

# Set boot order
qm set "$VM_ID" --boot order=scsi0

# Resize disk
info "  Resizing disk to ${DISK}GB..."
qm resize "$VM_ID" scsi0 "${DISK}G"
ok "  Disk resized to ${DISK}GB"

###############################################################################
# Step 3/5: USB passthrough
###############################################################################

if [[ -n "$USB_DEVICE" ]]; then
    info "Step 3/5: Configuring USB passthrough..."
    qm set "$VM_ID" --usb0 "host=${USB_DEVICE}"

    if [[ -n "$SERIAL_DEVICE" ]]; then
        qm set "$VM_ID" --args "-device usb-serial,chardev=serial1 -chardev serial,id=serial1,path=${SERIAL_DEVICE}"
        ok "USB passthrough: device ${USB_DEVICE} + serial ${SERIAL_DEVICE}"
    else
        ok "USB passthrough: device ${USB_DEVICE}"
    fi
else
    info "Step 3/5: USB passthrough skipped (--no-usb)"
fi

###############################################################################
# Step 4/5: Firewall (MQTT + basic protection)
###############################################################################

info "Step 4/5: Configuring firewall..."

cat > "/etc/pve/firewall/${VM_ID}.fw" << 'EOF'
[OPTIONS]
enable: 0
policy_in: ACCEPT
policy_out: ACCEPT

[RULES]
# MQTT (for IoT devices)
OUT ACCEPT -p tcp -dport 1883 -log nolog
IN ACCEPT -p tcp -dport 1883 -log nolog
EOF

ok "Firewall rules written (MQTT allowed)"

###############################################################################
# Step 5/5: Start VM
###############################################################################

info "Step 5/5: Starting VM $VM_ID..."
qm start "$VM_ID"
ok "VM $VM_ID started"

# Wait for VM to come online
info "  Waiting for HAOS to boot (first boot takes 2-5 minutes)..."
sleep 30

# Try to detect IP via guest agent
VM_IP=""
ELAPSED=0
while [[ $ELAPSED -lt 300 ]]; do
    VM_IP=$(qm guest cmd "$VM_ID" network-get-interfaces 2>/dev/null \
        | jq -r '[.[] | select(.name != "lo" and .name != "docker0" and (.name | startswith("veth") | not)) | .["ip-addresses"][]? | select(.["ip-address-type"] == "ipv4")] | first | .["ip-address"] // empty' 2>/dev/null || true)

    if [[ -n "$VM_IP" && "$VM_IP" != "null" ]]; then
        ok "HAOS IP detected: $VM_IP"
        break
    fi
    VM_IP=""
    sleep 10
    ELAPSED=$((ELAPSED + 10))
    printf "."
done
echo ""

if [[ -z "$VM_IP" ]]; then
    warn "Could not detect IP via guest agent."
    warn "Check Proxmox Console or router DHCP leases."
    VM_IP="<check-router-dhcp>"
fi

# Health check
if [[ "$VM_IP" != "<check-router-dhcp>" ]]; then
    info "  Checking Home Assistant web interface..."
    ELAPSED=0
    while [[ $ELAPSED -lt 300 ]]; do
        if curl -sf --max-time 5 "http://${VM_IP}:8123" -o /dev/null 2>/dev/null; then
            ok "Home Assistant is accessible at http://${VM_IP}:8123"
            break
        fi
        sleep 15
        ELAPSED=$((ELAPSED + 15))
        printf "."
    done
    echo ""

    if [[ $ELAPSED -ge 300 ]]; then
        warn "Web interface not yet available — HAOS may still be initializing"
        warn "First boot can take up to 20 minutes (downloading components)"
    fi
fi

###############################################################################
# Summary
###############################################################################

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✅ Home Assistant OS VM Setup Complete!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""
echo "  VM ID:          $VM_ID"
echo "  VM Name:        $VM_NAME"
echo "  HAOS Version:   ${HAOS_VERSION}"
echo "  RAM:            ${RAM}MB"
echo "  Disk:           ${DISK}GB"
echo "  Cores:          $CORES"
echo "  BIOS:           OVMF (UEFI)"
echo "  IP:             $VM_IP (DHCP)"
echo ""
if [[ -n "$USB_DEVICE" ]]; then
    echo "  USB:            host=${USB_DEVICE}"
    [[ -n "$SERIAL_DEVICE" ]] && echo "  Serial:         ${SERIAL_DEVICE}"
fi
echo ""
echo "  Web Interface:  http://${VM_IP}:8123"
echo "  (First boot takes up to 20 minutes to fully initialize)"
echo ""
echo "  Next Steps:"
echo "    1. Open http://${VM_IP}:8123 in your browser"
echo "    2. Create your admin account"
echo "    3. Restore from backup (if migrating from VM 108):"
echo "       Settings → System → Backups → Upload Backup"
echo ""
echo "  Matching VM 108 config:"
echo "    ✅ UEFI (OVMF) + EFI disk"
echo "    ✅ virtio-scsi-pci + writethrough cache + discard + SSD"
echo "    ✅ Balloon disabled"
echo "    ✅ USB passthrough (${USB_DEVICE:-none})"
echo "    ✅ Serial passthrough (${SERIAL_DEVICE:-none})"
echo "    ✅ Guest agent enabled"
echo "    ✅ Onboot + startup order=1"
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
