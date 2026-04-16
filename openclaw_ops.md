# OpenClaw Operations Guide
## VM 100 on Proxmox (192.168.178.108)

> All `docker compose exec` commands must be run from **inside the VM**
> in the `~/openclaw` directory. OpenClaw is installed inside the Docker
> container, not on the VM host.

---

## Quick Reference

| Task | Where to run |
|------|-------------|
| Backup/restore VM | Proxmox host |
| Docker container management | VM SSH session (`~/openclaw`) |
| OpenClaw CLI commands | Inside the container via `docker compose exec` |
| Dashboard access | SSH tunnel from workstation |

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
