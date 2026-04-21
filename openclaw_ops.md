# OpenClaw Operations Guide
## VM 100 on Proxmox (192.168.178.108)

> All `docker compose exec` commands must be run from **inside the VM**
> in the `~/openclaw` directory. OpenClaw is installed inside the Docker
> container, not on the VM host.

### Proxmox VM/LXC-Übersicht

| ID | Typ | Name | IP | RAM | Funktion | Setup-Script |
|----|-----|------|----|-----|----------|-------------|
| 100 | VM | openclaw | 192.168.178.80 | 4 GB | OpenClaw AI Assistant | `niklas_setup-openclaw-vm.sh` |
| 101 | VM | hermes-agent | 192.168.178.81 | 3 GB | Hermes AI Agent | `setup-hermes-vm.sh` |
| 102 | LXC | whisper | 192.168.178.82 | 1 GB | Shared Whisper STT | `setup-whisper-lxc.sh` |
| 103 | LXC | invoicing | 192.168.178.83 | 2 GB | e-Invoice (Batch) | `setup-einvoice-lxc.sh` |
| 108 | VM | haos151 | 192.168.178.88 | 6.5 GB | Home Assistant OS (prod) | `setup-haos-vm.sh` |

> Für Hermes-spezifische Dokumentation: siehe `SETUP-GUIDE.md`, Option 3.
> container, not on the VM host.

---

## Quick Reference

| Task | Where to run |
|------|-------------|
| Backup/restore VM | Proxmox host |
| Docker container management | VM SSH session (`~/openclaw`) |
| OpenClaw CLI commands | Inside the container via `docker compose exec` |
| Dashboard access | SSH tunnel from workstation |
| Skills verwalten | VM SSH session (`~/.openclaw/workspace/skills/`) |
| Credentials bearbeiten | VM SSH session (`~/.openclaw/.credentials.env`) |
| Integrationen (HA, Tennis) | Siehe `openclaw-home-assistant-integration.md` |

---

## Connecting to the VM

### From Proxmox host
```bash
ssh claw@192.168.178.80
cd ~/openclaw
```

### From Windows workstation (with SSH tunnel for dashboard)
```powershell
ssh -i C:\Users\bvogel\.ssh\id_ed25519_openclaw -L 18789:localhost:18789 claw@192.168.178.80
```
Then open `http://localhost:18789` in your browser.

---

## OpenClaw CLI Commands

All OpenClaw commands run **inside the Docker container**. Prefix every
command with:

```bash
docker compose exec openclaw-gateway node openclaw.mjs <command>
```

### Onboarding
```bash
docker compose exec -it openclaw-gateway node openclaw.mjs onboard
```

### Pairing (approve a messaging channel)
```bash
# Approve a pairing code from Telegram, WhatsApp, etc.
docker compose exec openclaw-gateway node openclaw.mjs pairing approve telegram <CODE>
docker compose exec openclaw-gateway node openclaw.mjs pairing approve whatsapp <CODE>
docker compose exec openclaw-gateway node openclaw.mjs pairing approve discord <CODE>
```

### Configuration
```bash
# View a config value
docker compose exec openclaw-gateway node openclaw.mjs config get gateway.auth.token
docker compose exec openclaw-gateway node openclaw.mjs config get agents.defaults.model

# Set a config value
docker compose exec openclaw-gateway node openclaw.mjs config set <key> <value>
```

### Agent Management
```bash
# List agents
docker compose exec openclaw-gateway node openclaw.mjs agents list

# Add a new agent
docker compose exec -it openclaw-gateway node openclaw.mjs agents add
```

### Security Audit
```bash
# Run security audit
docker compose exec openclaw-gateway node openclaw.mjs security audit

# Deep audit
docker compose exec openclaw-gateway node openclaw.mjs security audit --deep

# Auto-fix common issues
docker compose exec openclaw-gateway node openclaw.mjs security audit --fix
```

### Doctor (diagnostics)
```bash
docker compose exec openclaw-gateway node openclaw.mjs doctor
docker compose exec openclaw-gateway node openclaw.mjs doctor --fix
```

### Health Check
```bash
# From inside the VM
curl -sf http://127.0.0.1:18789/healthz

# Or via the container
docker compose exec openclaw-gateway node openclaw.mjs health
```

### View Logs
```bash
# Docker container logs (last 50 lines, follow)
docker compose logs --tail 50 -f

# OpenClaw's own log file inside the container
docker compose exec openclaw-gateway cat /tmp/openclaw/openclaw-$(date +%Y-%m-%d).log
```

### Send a Message
```bash
docker compose exec openclaw-gateway node openclaw.mjs message send --to <recipient> --message "Hello"
```

### Agent Chat
```bash
docker compose exec -it openclaw-gateway node openclaw.mjs agent --message "Hello, what can you do?"
```

---

## Model & Whisper Configuration

### Change the AI model (Z.AI)

```bash
# Switch to a different Z.AI model (e.g. glm-4.7 instead of glm-5.1)
docker compose exec openclaw-gateway node openclaw.mjs config set agents.defaults.model "zai/glm-4.7"
docker compose restart openclaw-gateway
```

Available Z.AI models: `glm-5.1`, `glm-5`, `glm-5-turbo`, `glm-4.7`, `glm-4.7-flash`, `glm-4.6`, `glm-4.5`

### Whisper voice transcription (Shared LXC 102)

Voice messages from Telegram are transcribed by a **shared Whisper LXC**
(LXC 102, IP 192.168.178.82) running faster-whisper-server. Both OpenClaw
and Hermes access this LXC via the Proxmox firewall whitelist.

OpenClaw uses CLI-based transcription (`type: "cli"` with curl) to bypass
its built-in SSRF protection that blocks private IP addresses.

#### Test Whisper

```bash
# From Proxmox host or any whitelisted VM
curl -sf http://192.168.178.82:8000/health

# Test transcription
curl -X POST http://192.168.178.82:8000/v1/audio/transcriptions \
  -F "file=@/path/to/audio.ogg" \
  -F "model=Systran/faster-whisper-small" \
  -F "response_format=text" \
  -F "language=de"
```

#### Whisper LXC Management

```bash
# SSH into Whisper LXC
ssh root@192.168.178.82

# Check container
cd /root/whisper && docker compose ps

# Restart
docker compose restart whisper

# View logs
docker compose logs --tail 50 whisper

# Update
docker compose pull && docker compose up -d
```

---

## Docker Container Management

Run these from the VM (`~/openclaw`):

### Status
```bash
docker compose ps
```

### Restart
```bash
docker compose restart
```

### Stop / Start
```bash
docker compose stop
docker compose start
```

### View resource usage
```bash
docker stats openclaw-gateway --no-stream
```

### Update OpenClaw to latest version
```bash
docker compose pull
docker compose up -d
docker compose logs --tail 10
```

### Full rebuild (if something is broken)
```bash
docker compose down --remove-orphans
docker network prune -f
docker compose pull
docker compose up -d
```

---

## Backup & Restore

### Manual Backup (from Proxmox host)

```bash
# Snapshot backup while VM is running (no downtime)
vzdump 100 --storage local --compress zstd --mode snapshot
```

Backups are stored in `/var/lib/vz/dump/`.

### List Backups
```bash
ls -lh /var/lib/vz/dump/vzdump-qemu-100-*
```

### Restore a Backup
```bash
# Stop the VM first
qm stop 100

# Restore (overwrites existing VM 100)
qmrestore /var/lib/vz/dump/vzdump-qemu-100-<DATE>.vma.zst 100 --force

# Start the restored VM
qm start 100
```

### Restore to a Different VM ID
```bash
qmrestore /var/lib/vz/dump/vzdump-qemu-100-<DATE>.vma.zst 200
```

### Automatic Weekly Backups

**Via Proxmox Web UI:**
1. Go to `Datacenter → Backup → Add`
2. Storage: `local`
3. Schedule: `sun 02:00` (or your preference)
4. Selection mode: `Include` → select VM 100
5. Compression: `ZSTD`
6. Mode: `Snapshot`
7. Click `Create`

**Via command line:**
```bash
# Add a cron job for weekly Sunday 2am backup
cat > /etc/cron.d/openclaw-backup << 'EOF'
0 2 * * 0 root vzdump 100 --storage local --compress zstd --mode snapshot --quiet
EOF
```

### Backup Retention (clean up old backups)

```bash
# Keep only the last 3 backups, remove older ones
ls -t /var/lib/vz/dump/vzdump-qemu-100-*.vma.zst | tail -n +4 | xargs rm -f
```

---

## Proxmox Firewall Management

### Check firewall status
```bash
cat /etc/pve/firewall/100.fw | head -5
```

### Temporarily disable firewall (for debugging)
```bash
sed -i 's/^enable: 1/enable: 0/' /etc/pve/firewall/100.fw
```

### Re-enable firewall
```bash
sed -i 's/^enable: 0/enable: 1/' /etc/pve/firewall/100.fw
```

### Verify isolation is working
```bash
# Internet should work
ssh claw@192.168.178.80 "curl -sf --max-time 5 https://cloud.debian.org > /dev/null && echo INTERNET_OK"

# LAN should be blocked
ssh claw@192.168.178.80 "curl -sf --max-time 3 http://192.168.178.108:8123 2>/dev/null && echo LAN_EXPOSED || echo LAN_BLOCKED"
```

---

## VM Management (from Proxmox host)

```bash
# Status
qm status 100

# Start / Stop / Reboot
qm start 100
qm stop 100
qm reboot 100

# Open console
qm terminal 100    # serial (Ctrl+O to exit)
# Or use Proxmox web UI → VM 100 → Console

# Check VM IP
qm guest cmd 100 network-get-interfaces | jq -r '.[] | select(.name == "eth0") | .["ip-addresses"][]? | select(.["ip-address-type"] == "ipv4") | .["ip-address"]'
```

---

## Network Interface (NIC) Management (from Proxmox host)

### Hardware Info

| Component | Details |
|-----------|---------|
| Built-in NICs | 4x Intel I226-V (`enp1s0`–`enp4s0`) |
| USB NIC (removed) | Microsoft Surface Ethernet Adapter (`enxc0335eee4ac3`) |
| Active bridge port | `enp1s0` (switched 2026-04-17) |

### Query all interfaces

```bash
# List all interfaces with state
ip link show

# Show only physical NICs (no bridges, taps, loopback)
ip link show | grep -E "^[0-9]+: en"

# Show which PCI NICs are installed
lspci | grep -i ethernet

# Show USB NICs
lsusb | grep -i net
```

### Check link status (cable connected?)

NICs in `DOWN` state don't report link — bring them up first:

```bash
# Bring all built-in NICs up (needed to detect cable)
for iface in enp1s0 enp2s0 enp3s0 enp4s0; do
  ip link set $iface up
done
sleep 3

# Check which port has a cable plugged in (1 = yes, 0 = no)
for iface in enp1s0 enp2s0 enp3s0 enp4s0; do
  echo "$iface: carrier=$(cat /sys/class/net/$iface/carrier 2>/dev/null || echo 'N/A')"
done

# Detailed link info for a specific NIC
ethtool enp1s0 | grep -E "Speed|Duplex|Link detected"
```

### Check which NIC is used by the bridge

```bash
# Show bridge members
bridge link show
# or
cat /etc/network/interfaces | grep bridge-ports
```

### Switch bridge to a different NIC

> ⚠️ **Do this at the physical console (monitor + keyboard), not SSH!**
> Changing the bridge port will drop network connectivity.

```bash
# 1. Backup current config
cp /etc/network/interfaces /root/interfaces.backup

# 2. Bring up the target NIC and verify link
ip link set enp2s0 up
sleep 2
ethtool enp2s0 | grep "Link detected"  # Must say "yes"

# 3. Switch bridge port (replace enp1s0 with new NIC)
sed -i 's/enp1s0/enp2s0/g' /etc/network/interfaces

# 4. Verify the change
cat /etc/network/interfaces | grep -A5 vmbr0

# 5. Reboot (safest method)
reboot
```

### Rollback if network is broken

At the physical console:

```bash
cp /root/interfaces.backup /etc/network/interfaces
reboot
```

### Current network config (`/etc/network/interfaces`)

```
auto lo
iface lo inet loopback

iface enp1s0 inet manual

auto vmbr0
iface vmbr0 inet static
        address 192.168.178.108/24
        gateway 192.168.178.1
        bridge-ports enp1s0
        bridge-stp off
        bridge-fd 0
```

---

## Skills (Integrationen)

OpenClaw nutzt **Skills** zur Integration externer Dienste. Skills sind
Ordner mit einer `SKILL.md`-Datei im Workspace-Verzeichnis.

> Vollständige Dokumentation: siehe `openclaw-home-assistant-integration.md`

### Installierte Skills

| Skill | Verzeichnis | Funktion |
|-------|-------------|----------|
| 🏠 `home-assistant` | `~/.openclaw/workspace/skills/home-assistant/` | Smart Home steuern |
| 🎾 `tennis-booking` | `~/.openclaw/workspace/skills/tennis-booking/` | Tennisplatz-Buchung |

### Skills auflisten

```bash
ls ~/.openclaw/workspace/skills/
```

### Skill von ClawHub installieren

```bash
docker compose exec openclaw-gateway node openclaw.mjs skills install <SKILL_NAME>
docker compose restart openclaw-gateway
```

### Eigenen Skill erstellen

```bash
# 1. Ordner anlegen
mkdir -p ~/.openclaw/workspace/skills/mein-skill/scripts

# 2. SKILL.md erstellen (Frontmatter + Doku)
cat > ~/.openclaw/workspace/skills/mein-skill/SKILL.md << 'EOF'
---
name: mein-skill
description: Beschreibung wann der Skill genutzt werden soll.
metadata: {"clawdbot":{"emoji":"🔧","requires":{"bins":["curl"]}}}
---
# Mein Skill
Dokumentation, Beispiele, CLI-Referenz...
EOF

# 3. Optional: Script(s) erstellen
cat > ~/.openclaw/workspace/skills/mein-skill/scripts/mein-script.sh << 'SCRIPT'
#!/usr/bin/env bash
export PATH="/home/node/.openclaw/bin:$PATH"
set -euo pipefail
echo "Hello from mein-skill!"
SCRIPT
chmod +x ~/.openclaw/workspace/skills/mein-skill/scripts/mein-script.sh

# 4. Gateway neustarten
cd ~/openclaw && docker compose restart openclaw-gateway
```

> **Wichtig:** Die `description` im SKILL.md-Frontmatter bestimmt, wann
> OpenClaw den Skill erkennt und nutzt. Formuliere sie so, dass die
> relevanten Schlüsselwörter enthalten sind.

### Skill löschen

```bash
rm -rf ~/.openclaw/workspace/skills/<SKILL_NAME>
docker compose restart openclaw-gateway
```

---

## Credentials-Management

Alle Zugangsdaten liegen in einer einzigen Datei:

```bash
# Datei anzeigen
cat ~/.openclaw/.credentials.env

# Datei bearbeiten
nano ~/.openclaw/.credentials.env

# Nach Änderungen: Container MÜSSEN neu starten
cd ~/openclaw && docker compose down && docker compose up -d
```

### Aktuelle Variablen

| Variable | Dienst | Beschreibung |
|----------|--------|-------------|
| `HA_URL` | Home Assistant | API-URL (http://192.168.178.88:8123) |
| `HA_TOKEN` | Home Assistant | Long-Lived Access Token (JWT) |
| `GRAFANA_URL` | Grafana | Dashboard-URL |
| `TENNIS_KB_EMAIL` | TC Kleinberghofen | Login E-Mail |
| `TENNIS_KB_PASS` | TC Kleinberghofen | Login Passwort |
| `TENNIS_ER_EMAIL` | TC Erdweg | Login E-Mail |
| `TENNIS_ER_PASS` | TC Erdweg | Login Passwort |

### Prüfen ob Variablen im Container ankommen

```bash
docker compose exec openclaw-gateway env | grep -E "HA_|GRAFANA_|TENNIS_"
```

> ⚠️ `source ~/.openclaw/.credentials.env` lädt die Vars nur in die
> Shell, nicht in den Docker-Container! Für den Container zählt nur
> das `env_file` in `docker-compose.yml` + Restart.

---

## Troubleshooting

### Container won't start
```bash
ssh claw@192.168.178.80
cd ~/openclaw
docker compose logs --tail 30
docker compose down --remove-orphans
docker network prune -f
docker compose up -d
```

### Config validation error
```bash
# Check config
docker compose exec openclaw-gateway cat /home/node/.openclaw/openclaw.json | python3 -m json.tool

# Reset to known-good config via doctor
docker compose exec openclaw-gateway node openclaw.mjs doctor --fix
docker compose restart
```

### API key not working
```bash
# Check auth profiles inside the container
docker compose exec openclaw-gateway cat /home/node/.openclaw/agents/main/agent/auth-profiles.json

# Edit auth profiles (from VM host, mounted volume)
nano ~/.openclaw/agents/main/agent/auth-profiles.json
docker compose restart
```

### SSH key issues from Windows
```powershell
# Re-copy the key from Proxmox
scp root@192.168.178.108:/root/.ssh/id_ed25519 C:\Users\bvogel\.ssh\id_ed25519_openclaw

# Fix permissions
icacls "C:\Users\bvogel\.ssh\id_ed25519_openclaw" /inheritance:r /grant:r "bvogel:(R)"

# Test connection
ssh -i C:\Users\bvogel\.ssh\id_ed25519_openclaw claw@192.168.178.80
```

### VM has no IP after reboot
```bash
# From Proxmox host
qm guest cmd 100 network-get-interfaces | jq '.'

# If no IP, check cloud-init inside VM console (Proxmox web UI)
# Login with user: claw, password from setup output
sudo cloud-init status
ip addr show
```

---

## e-Invoice LXC Management (LXC 103)

### Access

```bash
# From Proxmox host (preferred — SSH key may not be configured)
pct enter 103

# Working directory
cd /opt/e-invoice/e-Invoice
```

### Running Invoices

```bash
# Draft mode (preview, no emails sent)
docker compose run --rm e-invoice \
    --journal /data/praxis/Rechnungen/2026/Rechnungsliste_2026.xlsx \
    --session SaaS_LXC --config config \
    --year 2026 --month 4 -dr -u

# Production run (sends emails)
docker compose run --rm e-invoice \
    --journal /data/praxis/Rechnungen/2026/Rechnungsliste_2026.xlsx \
    --session SaaS_LXC --config config \
    --year 2026 --month 4 --fireforget --prodrun
```

### Update Code + Rebuild

```bash
cd /opt/e-invoice && git pull && cd e-Invoice && docker compose build
```

> **Hinweis:** `git pull` benötigt GitHub-Credentials (PAT wurde aus
> Sicherheitsgründen vom Remote entfernt). Entweder PAT temporär setzen:
> ```bash
> git remote set-url origin https://TOKEN@github.com/SREbuilt/Python.git
> git pull
> git remote set-url origin https://github.com/SREbuilt/Python.git
> ```

### NAS Mount prüfen

```bash
# Vom Proxmox host
mount | grep nas-praxis

# Innerhalb der LXC
ls /nas/praxis/Rechnungen/
touch /nas/praxis/.write-test && rm /nas/praxis/.write-test && echo "WRITE_OK"
```

### Docker Management

```bash
# Container-Status
docker compose ps

# Logs anzeigen
docker compose logs e-invoice

# Image neubauen (nach Code-Änderungen)
docker compose build

# Alle Images aufräumen
docker image prune -f
```

### .env verwalten

```bash
# Anzeigen
cat /opt/e-invoice/e-Invoice/.env

# Bearbeiten
nano /opt/e-invoice/e-Invoice/.env

# Variablen:
# KEEPASSXC_MASTER_PASSWORD=...   (Pflicht)
# OTEL_EXPORTER_OTLP_ENDPOINT=... (Optional, für SigNoz)
# NAS_MOUNT=/nas/praxis            (Standard)
```
