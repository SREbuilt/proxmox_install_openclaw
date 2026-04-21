# Lessons Learned — Proxmox AI Infrastructure

> Gesammelt aus 8+ Iterationen, mehrstündigem Debugging und vielen Fehlschlägen.
> Stand: 2026-04-21

---

## Inhaltsverzeichnis

- [1. Proxmox VM Setup — Das Zwei-Phasen-Pattern](#1-proxmox-vm-setup--das-zwei-phasen-pattern)
- [2. Cloud-Init — Die 7 Todsünden](#2-cloud-init--die-7-todsünden)
- [3. Docker auf dem Proxmox Host — FATAL](#3-docker-auf-dem-proxmox-host--fatal)
- [4. Intel N150 CPU Eigenheiten](#4-intel-n150-cpu-eigenheiten)
- [5. Proxmox Firewall — Reihenfolge und Timing](#5-proxmox-firewall--reihenfolge-und-timing)
- [6. Docker in VMs — UID, Netzwerk, iptables](#6-docker-in-vms--uid-netzwerk-iptables)
- [7. OpenClaw Konfiguration](#7-openclaw-konfiguration)
- [8. Hermes Agent Konfiguration](#8-hermes-agent-konfiguration)
- [9. NFS in unprivilegierten LXCs](#9-nfs-in-unprivilegierten-lxcs)
- [10. Boot-Loader und Kernel](#10-boot-loader-und-kernel)
- [11. Netzwerk und DHCP](#11-netzwerk-und-dhcp)
- [12. Allgemeine Shell-Script-Patterns](#12-allgemeine-shell-script-patterns)
- [13. Credentials und Secrets](#13-credentials-und-secrets)
- [14. Anti-Patterns (Was NICHT funktioniert)](#14-anti-patterns-was-nicht-funktioniert)

---

## 1. Proxmox VM Setup — Das Zwei-Phasen-Pattern

### Das Pattern (bewährt nach 8+ Iterationen)

```
Phase 1: VM-Erstellung mit nativen Proxmox cloud-init Parametern
  └─ qm create ... --ciuser --cipassword --sshkeys --ipconfig0
  └─ KEIN cicustom!

Phase 2: SSH in die VM → Software installieren
  └─ Warte auf cloud-init completion
  └─ Dann: apt-get, Docker, App-Deployment
```

### Warum dieses Pattern?

- **Phase 1** nutzt Proxmox' eigene cloud-init-Integration, die User, Passwort
  und SSH-Keys direkt in die NoCloud-ISO schreibt
- **Phase 2** wartet bis `cloud-init status` "done" meldet, dann installiert
  per SSH (apt-get upgrade hält oft 3-8 Minuten den apt-Lock)

### Typische Phase-2-Wartelogik

```bash
ELAPSED=0
while [[ $ELAPSED -lt 600 ]]; do
    STATUS=$($SSH_CMD "user@${VM_IP}" "cloud-init status 2>/dev/null" || echo "pending")
    if echo "$STATUS" | grep -q "done"; then
        break
    fi
    sleep 15
    ELAPSED=$((ELAPSED + 15))
done
```

### Dateien

- `niklas_setup-openclaw-vm.sh` — OpenClaw VM (v2, Komplettrewrite)
- `setup-hermes-vm.sh` — Hermes Agent VM (v8, meistgetestetes Script)
- `setup-whisper-lxc.sh` — Whisper LXC (LXC-Variante des Patterns)

---

## 2. Cloud-Init — Die 7 Todsünden

| # | Fehler | Symptom | Lösung |
|---|--------|---------|--------|
| 1 | `--cicustom` verwenden | SSH-Login, Passwort, Permissions kaputt | **Native** `--ciuser`, `--cipassword`, `--sshkeys` nutzen |
| 2 | Phase 2 starten bevor cloud-init fertig | `apt-get` blockiert (dpkg lock) | `cloud-init status: done` abwarten |
| 3 | `cpu: host` auf N150 | Kernel Panic beim ersten Boot | `cpu: x86-64-v2-AES` verwenden |
| 4 | Firewall vor Phase 2 aktivieren | SSH wird blockiert | `enable: 0` beim Setup, `enable: 1` nach Abschluss |
| 5 | Feste IP im selben DHCP-Range | IP-Konflikte mit Fritz!Box | Statische IPs außerhalb des DHCP-Bereichs |
| 6 | SSH known_hosts nicht bereinigen | `Host key verification failed` | `ssh-keygen -R $IP` am Script-Anfang |
| 7 | `arp` Befehl für IP-Erkennung | `arp: command not found` auf modernem Debian | `ip neigh` oder QEMU Guest Agent verwenden |

### cicustom vs. native Cloud-Init — Der kritischste Fehler

```bash
# ❌ FALSCH — überschreibt alle Proxmox cloud-init Settings
qm set $VMID --cicustom "user=local:snippets/userdata.yaml"

# ✅ RICHTIG — Proxmox integriert alles sauber in die NoCloud-ISO
qm set $VMID --ciuser "myuser" --cipassword "mypass" \
    --sshkeys /root/.ssh/id_ed25519.pub \
    --ipconfig0 "ip=$IP/24,gw=$GW"
```

**Warum**: `cicustom` ersetzt den kompletten `user-data`-Abschnitt der
cloud-init NoCloud-ISO. Damit werden `ciuser`, `cipassword` und `sshkeys`
ignoriert — sie stehen nur im Proxmox-Config aber nicht in der ISO.

---

## 3. Docker auf dem Proxmox Host — FATAL

> **Entdeckt nach mehrstündigem Ausfall (2026-04-20)**

### Problem

Docker installiert iptables-Regeln mit `FORWARD DROP` und einer
`DOCKER-USER`-Chain, die **allen Bridge-Traffic blockiert**. Da Proxmox
VMs über eine Bridge (`vmbr0`) kommunizieren, verlieren alle VMs ihre
Netzwerkverbindung.

### Symptome

- VMs können den Gateway (192.168.178.1) nicht pingen
- Kein Internet in VMs
- Telegram-Bots verbinden nicht
- Home Assistant unerreichbar von OpenClaw
- Proxmox Web-UI funktioniert noch (läuft direkt auf dem Host)

### Erkennung

```bash
# Schnelltest
iptables -L DOCKER-USER -n 2>/dev/null && echo "⚠️ DOCKER AUF HOST!" || echo "✅ OK"
```

### Entfernung

```bash
systemctl stop docker docker.socket containerd
systemctl disable docker docker.socket containerd
apt purge -y docker-ce docker-ce-cli docker-buildx-plugin \
    docker-compose-plugin docker-ce-rootless-extras containerd.io
apt autoremove -y
iptables -P FORWARD ACCEPT
iptables -F FORWARD
pve-firewall restart
```

### In Setup-Scripts

```bash
# Am Anfang jedes Scripts prüfen
if iptables -L DOCKER-USER -n &>/dev/null; then
    fail "Docker on Proxmox host detected! This blocks ALL VM traffic."
fi
```

---

## 4. Intel N150 CPU Eigenheiten

### Kernel Panic beim ersten Boot

Debian 12 Cloud-Images haben einen bekannten Bug: Der **erste Boot**
nach VM-Erstellung endet häufig in einem Kernel Panic.

**Lösung im Script:**

```bash
# VM starten
qm start $VMID

# 60s warten, dann prüfen ob VM noch läuft
sleep 60
VM_STATUS=$(qm status $VMID 2>/dev/null | awk '{print $2}')
if [[ "$VM_STATUS" == "stopped" ]]; then
    warn "First-boot kernel panic (expected on N150) — restarting..."
    qm start $VMID
fi
```

### CPU-Typ

```bash
# ❌ FALSCH — verursacht Kernel Panics auf N150
--cpu host

# ✅ RICHTIG — stabil auf N150
--cpu x86-64-v2-AES
```

### C-State Freeze (60-80h Uptime)

Intel N150 geht in tiefe C-States (C6/C7+), aus denen er nicht aufwacht.

**Fix in `/etc/kernel/cmdline`:**

```
intel_idle.max_cstate=1 processor.max_cstate=1
```

Dann: `proxmox-boot-tool refresh` (NICHT `update-grub` — siehe Abschnitt 10).

### BIOS-Einstellungen (BK-1264NP-N150 v41.5)

| Setting | Ort | Wert | Warum |
|---------|-----|------|-------|
| C6DRAM | CPU Configuration | **Disabled** | Verhindert Deep C-States |
| MonitorMWait | CPU Configuration | **Disabled** | Verhindert C-State Wechsel |
| ASPM | PCI Subsystem Settings | **Disabled** | Verhindert PCIe Power Saving |
| ACPI Sleep State | ACPI Settings | **Disabled** | Verhindert System Suspend |
| Resume By LAN | Power Configuration | **Enabled** | Wake-on-LAN für Remote Recovery |
| PWRON After Loss | Power Configuration | **Always On** | Auto-Start nach Stromausfall |

---

## 5. Proxmox Firewall — Reihenfolge und Timing

### Timing

```bash
# Phase 1: Firewall DEAKTIVIERT
cat > "/etc/pve/firewall/${VMID}.fw" << EOF
[OPTIONS]
enable: 0          # ← Aus während Setup
policy_in: DROP
policy_out: ACCEPT
...
EOF

# Phase 2: SSH + Software-Installation
...

# Phase 3: Firewall AKTIVIEREN (erst ganz am Ende!)
sed -i 's/^enable: 0/enable: 1/' "/etc/pve/firewall/${VMID}.fw"
```

### Reihenfolge der Regeln

```
[RULES]
# 1. ZUERST: Spezifische ACCEPT-Regeln
OUT ACCEPT -dest 192.168.178.88 -dport 8123 -p tcp    # HA
OUT ACCEPT -dest 192.168.178.82 -dport 8000 -p tcp    # Whisper

# 2. DANN: Block-Regeln (RFC1918)
OUT DROP -dest 192.168.178.0/24 -p tcp                  # LAN
OUT DROP -dest 10.0.0.0/8 -p tcp                        # RFC1918
OUT DROP -dest 172.16.0.0/12 -p tcp                     # RFC1918

# 3. ZULETZT: Default-Allow für Internet
OUT ACCEPT                                               # Internet
```

**ACCEPT vor DROP!** Regeln werden top-down evaluiert.

### NIC Firewall und MAC-Adresse

```bash
# ❌ FALSCH — überschreibt MAC-Adresse
qm set $VMID --net0 "virtio,bridge=vmbr0,firewall=1"

# ✅ RICHTIG — MAC-Adresse zuerst extrahieren und beibehalten
CURRENT_MAC=$(qm config $VMID | grep "^net0:" | grep -oP 'virtio=\K[0-9A-Fa-f:]+')
qm set $VMID --net0 "virtio=${CURRENT_MAC},bridge=vmbr0,ip=${IP}/24,gw=${GW},firewall=1"
```

### IPv6 deaktivieren (Firewall-Bypass verhindern)

```bash
# In der VM via SSH:
sysctl -w net.ipv6.conf.all.disable_ipv6=1
sysctl -w net.ipv6.conf.default.disable_ipv6=1
echo "net.ipv6.conf.all.disable_ipv6=1" >> /etc/sysctl.conf
echo "net.ipv6.conf.default.disable_ipv6=1" >> /etc/sysctl.conf
```

---

## 6. Docker in VMs — UID, Netzwerk, iptables

### UID-Mismatch

Docker-Container laufen als anderer UID als der Host-User. Config-Dateien
müssen daher lesbar sein:

```bash
# ❌ FALSCH — Container kann .env nicht lesen
chmod 600 ~/.hermes/.env

# ✅ RICHTIG — Docker-Container als anderer UID
chmod 644 ~/.hermes/.env
chmod 644 ~/.hermes/config.yaml
```

### In-VM iptables vs. Docker

Docker verwaltet eigene iptables-Chains (`DOCKER`, `DOCKER-USER`, etc.).
Wenn man in der VM zusätzlich iptables-Regeln setzt, entstehen Konflikte.

**Empfehlung**: Keine in-VM iptables. Proxmox Firewall ist ausreichend.

### network_mode

| Mode | Vorteil | Nachteil | Empfohlen für |
|------|---------|----------|---------------|
| `host` | Einfach, localhost-Zugriff | Kein Port-Isolation | OpenClaw (braucht loopback) |
| `bridge` | Port-Isolation, sauberer | Kein localhost-Zugriff | Hermes |

---

## 7. OpenClaw Konfiguration

### Model-Format

```
"zai/glm-4.7"    ← Mit Provider-Prefix
```

### Gateway Bind

```
--bind loopback   ← Korrekt (nicht "lan", nicht "127.0.0.1")
```

### SSRF-Schutz

OpenClaw blockiert **alle privaten IPs** für Audio-Transcription (auch 127.0.0.1).

```json
// ❌ FALSCH — wird von SSRF blockiert
"audio": { "type": "http", "url": "http://127.0.0.1:8000/..." }

// ✅ RICHTIG — CLI-basierte Transcription umgeht SSRF
"audio": {
  "type": "cli",
  "command": "curl",
  "args": ["-sf", "-X", "POST", "http://192.168.178.82:8000/v1/audio/transcriptions",
           "-F", "file=@{file}", "-F", "model=Systran/faster-whisper-small",
           "-F", "response_format=text", "-F", "language=de"]
}
```

### Auth-Profiles

Datei: `~/.openclaw/agents/main/agent/auth-profiles.json`

```json
{
  "version": 1,
  "profiles": {
    "zai:default": {
      "type": "api_key",
      "provider": "zai",
      "key": "your-api-key-here"
    }
  }
}
```

### Tool Profile

| Profil | exec.security | exec.ask | Skills | Empfohlen für |
|--------|--------------|----------|--------|---------------|
| `messaging` | `sandboxed` | `always` | ❌ Eingeschränkt | Ersteinrichtung |
| `coding` | `full` | `off` | ✅ Voll | Telegram + Skills |

Wechsel:
```bash
docker compose exec openclaw-gateway node openclaw.mjs config set tools.profile "coding"
docker compose exec openclaw-gateway node openclaw.mjs config set exec.security "full"
docker compose exec openclaw-gateway node openclaw.mjs config set exec.ask "off"
```

### jq in OpenClaw

OpenClaw's Docker-Image enthält kein `jq`. Manuell installieren:

```bash
mkdir -p ~/.openclaw/bin
curl -sL https://github.com/jqlang/jq/releases/latest/download/jq-linux-amd64 -o ~/.openclaw/bin/jq
chmod +x ~/.openclaw/bin/jq
```

In Skills referenzieren: `export PATH="/home/node/.openclaw/bin:$PATH"`

### boot.md (Session-Kontext)

`~/.openclaw/boot.md` wird bei jedem Session-Start geladen:

```markdown
# Environment
- Home Assistant: http://192.168.178.88:8123 (Token in $HA_TOKEN)
- Grafana: https://192.168.178.98:443
- jq: /home/node/.openclaw/bin/jq
- Whisper: http://192.168.178.82:8000 (shared LXC)
```

---

## 8. Hermes Agent Konfiguration

### Model-Format (ANDERS als OpenClaw!)

```yaml
# ❌ FALSCH
model:
  default: "zai/glm-4.7"    # Provider-Prefix funktioniert NICHT

# ✅ RICHTIG
model:
  default: "glm-4.7"         # Kein Prefix!
  provider: "zai"             # Provider separat
```

### Z.AI Konfiguration

```yaml
# In ~/.hermes/config.yaml
providers:
  zai:
    base_url: "https://api.z.ai/api/coding/paas/v4"
```

```bash
# In ~/.hermes/.env
GLM_API_KEY=your-api-key      # NICHT OPENAI_API_KEY
```

### Config wird beim ersten Start generiert

Hermes generiert `config.yaml` beim allerersten Container-Start.
**Das bedeutet**: Man kann die Config nicht VOR dem ersten Start schreiben.

```bash
# Richtige Reihenfolge:
docker compose up -d           # Erster Start → generiert config.yaml
sleep 10
docker compose stop            # Stoppen
sed -i '...' config.yaml       # Jetzt patchen
docker compose up -d           # Neustart mit gepatchter Config
```

### GATEWAY_ALLOW_ALL_USERS

```bash
# In .env — damit Telegram ohne User-Allowlist funktioniert
GATEWAY_ALLOW_ALL_USERS=true
```

⚠️ Für Produktion: Durch explizite User-Allowlists ersetzen.

---

## 9. NFS in unprivilegierten LXCs

### Problem

Unprivilegierte LXCs können kein NFS direkt mounten (fehlende Kernel-Capabilities).

### Lösung: Host-Mount + Bind-Mount

```bash
# 1. NFS auf dem Proxmox HOST mounten
mount -t nfs brain:/volume1/praxis /mnt/nas-praxis -o rw,hard,timeo=600

# 2. In /etc/fstab persistieren
echo 'brain:/volume1/praxis  /mnt/nas-praxis  nfs  rw,hard,timeo=600,retrans=3,_netdev  0  0' >> /etc/fstab

# 3. Bind-Mount in LXC konfigurieren
pct set 103 -mp0 /mnt/nas-praxis,mp=/nas/praxis
```

### Wichtige Details

| Thema | Empfehlung | Warum |
|-------|-----------|-------|
| Mount-Typ | `hard` (nicht `soft`) | `soft` kann bei Netzwerkproblemen zu stillem Datenverlust führen |
| UID-Mapping | "Map all users to admin" im NAS | Unprivilegierte LXCs mappen root auf hohe UIDs (100000+) |
| Schreibtest | Immer nach Mount durchführen | UID-Mapping-Probleme sind erst beim Schreiben sichtbar |
| onboot | LXC `onboot: 0` oder Host-Mount zuerst sicherstellen | LXC startet vor NFS → leerer Mount |

### Schreibtest

```bash
ssh root@$LXC_IP "touch /nas/praxis/.write-test && rm -f /nas/praxis/.write-test && echo OK"
```

---

## 10. Boot-Loader und Kernel

### systemd-boot vs. GRUB

Proxmox mit **ZFS-Root** nutzt **systemd-boot**, NICHT GRUB!

| Merkmal | systemd-boot (ZFS) | GRUB (ext4/LVM) |
|---------|-------------------|------------------|
| Config | `/etc/kernel/cmdline` | `/etc/default/grub` |
| Refresh | `proxmox-boot-tool refresh` | `update-grub` |
| Boot-Einträge | `/etc/kernel/install.d/` | `/boot/grub/grub.cfg` |

### Kernel-Parameter ändern

```bash
# 1. Datei editieren
nano /etc/kernel/cmdline
# Inhalt: root=ZFS=rpool/ROOT/pve-1 boot=zfs intel_idle.max_cstate=1 processor.max_cstate=1

# 2. Boot-Entries aktualisieren
proxmox-boot-tool refresh

# 3. Reboot
reboot
```

⚠️ `update-grub` tut auf ZFS-Installationen **nichts** (kein Fehler, aber keine Wirkung).

### Kernel pinnen

```bash
# Bestimmten Kernel setzen
proxmox-boot-tool kernel pin 6.8.12-16-pve

# Pin aufheben
proxmox-boot-tool kernel unpin
```

---

## 11. Netzwerk und DHCP

### Fritz!Box DHCP-Bereich

Statische VM-IPs (80-89) müssen **außerhalb** des Fritz!Box DHCP-Bereichs liegen.

```
Fritz!Box DHCP:  192.168.178.100 – 192.168.178.129  (angepasst!)
Statische IPs:   192.168.178.80 – 192.168.178.89    (VMs/LXCs)
Proxmox Host:    192.168.178.108                      (statisch)
```

### NIC-Wechsel (USB → Built-in)

Der Proxmox-Host hat 4x Intel I226-V NICs (`enp1s0`–`enp4s0`).
Wechsel des Bridge-Ports:

1. **Am physischen Monitor** arbeiten (SSH wird unterbrochen!)
2. Backup: `cp /etc/network/interfaces /root/interfaces.backup`
3. Neues NIC hochfahren: `ip link set enp1s0 up`
4. Link prüfen: `ethtool enp1s0 | grep "Link detected"`
5. Bridge-Port ändern: `sed -i 's/old_nic/enp1s0/g' /etc/network/interfaces`
6. Reboot

---

## 12. Allgemeine Shell-Script-Patterns

### SSH-Kommando-Template

```bash
SSH_CMD="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes"
```

### known_hosts bereinigen (am Script-Anfang)

```bash
ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$VM_IP" 2>/dev/null || true
```

### Zufälliges Passwort generieren

```bash
PASSWORD=$(openssl rand -base64 12)
```

### CRLF-Problem (Windows → Linux)

Scripts die auf Windows erstellt/bearbeitet werden, haben CRLF-Zeilenenden:

```bash
sed -i 's/\r$//' /root/setup-script.sh
```

### Fehlerhafte Pipe maskiert Fehler

```bash
# ❌ FALSCH — docker compose build Fehler wird verschluckt
docker compose build 2>&1 | tail -5
echo "BUILD_OK"    # ← Wird auch bei Build-Fehler ausgegeben!

# ✅ RICHTIG
set -euo pipefail
docker compose build
echo "BUILD_OK"
```

---

## 13. Credentials und Secrets

### OpenClaw

| Datei | Zweck | Permissions |
|-------|-------|-------------|
| `~/.openclaw/agents/main/agent/auth-profiles.json` | Z.AI API Key | 644 (Docker UID) |
| `~/.openclaw/.credentials.env` | HA, Tennis, Grafana | 644 (Docker UID) |
| `~/openclaw/docker-compose.yml` | env_file Referenz | 644 |

### Hermes

| Datei | Zweck | Permissions |
|-------|-------|-------------|
| `~/.hermes/.env` | GLM_API_KEY, HA_TOKEN, TELEGRAM_BOT_TOKEN | 644 (Docker UID) |
| `~/.hermes/config.yaml` | Model, Provider, base_url | 644 |

### e-Invoice

| Datei | Zweck | Permissions |
|-------|-------|-------------|
| `/opt/e-invoice/e-Invoice/.env` | KEEPASSXC_MASTER_PASSWORD | 600 (root) |

### Spezialzeichen in Passwörtern

Tennis-Passwörter enthalten Sonderzeichen (`$`, `^`, `'`, `!`).

```bash
# ❌ FALSCH — Shell interpretiert Sonderzeichen
cat > .env << EOF
TENNIS_KB_PASS=Pa$$w0rd!
EOF

# ✅ RICHTIG — printf oder SCP
printf 'TENNIS_KB_PASS=Pa$$w0rd!\n' >> .env
# oder
scp credentials.env user@host:~/.hermes/.env
```

### GitHub PAT Handling

```bash
# Clone mit PAT (temporär im URL)
git clone "https://${PAT}@github.com/org/repo.git" /opt/app

# Sofort danach: PAT aus Remote entfernen
git remote set-url origin https://github.com/org/repo.git

# Shell-History löschen
history -c && rm -f ~/.bash_history
```

---

## 14. Anti-Patterns (Was NICHT funktioniert)

### VM-Setup

| Anti-Pattern | Warum es scheitert |
|-------------|-------------------|
| `--cicustom` für cloud-init | Überschreibt ciuser/cipassword/sshkeys |
| `--cpu host` auf N150 | Kernel Panic |
| Firewall vor Phase 2 | SSH blockiert |
| `arp` für IP-Erkennung | Nicht auf modernem Debian installiert |
| In-VM iptables + Docker | Konflikte mit Docker iptables-Chains |
| Docker auf Proxmox Host | Blockiert allen VM Bridge-Traffic |

### OpenClaw

| Anti-Pattern | Warum es scheitert |
|-------------|-------------------|
| `--bind lan` | Größere Angriffsfläche als nötig |
| `type: http` für lokalen Whisper | SSRF blockiert private IPs |
| `chmod 600` auf Config | Docker-Container (anderer UID) kann nicht lesen |
| Model `glm-4.7` (ohne Prefix) | OpenClaw erwartet `zai/glm-4.7` |

### Hermes

| Anti-Pattern | Warum es scheitert |
|-------------|-------------------|
| Model `zai/glm-4.7` (mit Prefix) | Hermes erwartet nur `glm-4.7` |
| `OPENAI_API_KEY` Env-Variable | Z.AI braucht `GLM_API_KEY` |
| Config VOR erstem Start schreiben | Wird von Hermes überschrieben |
| `base_url` auf openrouter | Z.AI hat eigene URL |

### NFS/LXC

| Anti-Pattern | Warum es scheitert |
|-------------|-------------------|
| NFS direkt in unprivilegierten LXC | Fehlende Kernel-Capabilities |
| `soft` NFS-Mount für Geschäftsdaten | Stiller Datenverlust bei Netzwerkproblemen |
| Nur Lesetest nach NFS-Mount | UID-Mapping-Probleme erst beim Schreiben sichtbar |
| NFS-Regel nur für LXC-IP | PVE-Host mountet NFS, nicht die LXC — beide IPs nötig |
| `/volume1/praxis` annehmen | Synology-Volume kann anders sein — `showmount -e` nutzen |

### Dockerfile/Docker Compose

| Anti-Pattern | Warum es scheitert |
|-------------|-------------------|
| `COPY ... 2>/dev/null \|\| true` | COPY ist kein Shell-Befehl, `\|\|` wird als Dateiname interpretiert |
| `import tkinter` in headless Container | libtk nicht installiert → ImportError beim Modulstart |
| `ping` ohne `cap_add: [NET_RAW]` | Docker-Default entfernt NET_RAW → ping scheitert |
| `iputils-ping` nicht im Image | `python:slim` enthält kein ping |
| Docker iptables-Chains nach Deinstallation | Chains bleiben in Kernel — manuell `iptables -F/-X` nötig |

### Boot/Kernel

| Anti-Pattern | Warum es scheitert |
|-------------|-------------------|
| `update-grub` auf ZFS | Tut nichts (kein Fehler, keine Wirkung) |
| Kernel 6.14+ auf N150 ohne C-State Fix | System-Freeze nach 60-80h |
| C6DRAM enabled im BIOS | Deep C-States → Freeze |

---

## Chronologie der Entdeckungen

| # | Was | Wie entdeckt | Dauer bis Fix |
|---|-----|-------------|---------------|
| 1 | CRLF-Problem | Script-Syntaxfehler | 10 min |
| 2 | cicustom zerstört cloud-init | SSH "Permission denied" | 3 Iterationen |
| 3 | CPU type `host` → Kernel Panic | VM startet, stoppt sofort | 2 Iterationen |
| 4 | Firewall blockiert Phase 2 | SSH timeout nach VM-Start | 1 Iteration |
| 5 | `arp` nicht vorhanden | Endlosschleife bei IP-Erkennung | 1 Iteration |
| 6 | Docker auf PVE Host blockiert alles | VMs ohne Netzwerk | 4+ Stunden |
| 7 | Hermes config wird überschrieben | Model immer auf Default | 2 Iterationen |
| 8 | .env chmod 600 → Container Permission denied | Container startet nicht | 1 Iteration |
| 9 | OpenClaw SSRF blockiert Whisper | Audio-Transcription fehlschlägt | 2 Iterationen |
| 10 | NFS soft mount → Datenverlust-Risiko | Code Review | Sofort behoben |
| 11 | NFS Export-Pfad /volume1 vs /volume8 | `mount.nfs: access denied` | `showmount -e` zeigt richtigen Pfad |
| 12 | NFS-Regel nur für LXC-IP, nicht PVE-Host | `mount.nfs: access denied` | Host (.108) mountet, nicht LXC (.83) |
| 13 | Dockerfile `COPY ... 2>/dev/null \|\| true` | `"/\|\|": not found` | COPY ist kein Shell-Befehl |
| 14 | `import tkinter` in headless Docker | `ImportError: libtk8.6.so` | Lazy import mit `try/except` |
| 15 | Docker `ping` ohne NET_RAW | `Operation not permitted` | `cap_add: [NET_RAW]` in compose |
| 16 | Docker iptables-Chains als Host-Überbleibsel | DOCKER-USER Chain blockiert FORWARD | `iptables -F/-X DOCKER*` manuell |
