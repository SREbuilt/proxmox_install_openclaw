# OpenClaw Integrationen — Home Assistant, Grafana & Tennis

> Stand: 2026-04-18 — Funktionierendes Setup auf VM 100 (192.168.178.80)

---

## Skills-Übersicht

OpenClaw nutzt ein **Skill-System** zur Integration externer Dienste.
Skills werden automatisch erkannt, wenn sie im Workspace-Verzeichnis
`~/.openclaw/workspace/skills/` liegen und eine `SKILL.md` enthalten.

| Skill | Quelle | Emoji | Funktion |
|-------|--------|-------|----------|
| `home-assistant` | ClawHub (v1.0.0) | 🏠 | Smart Home steuern, Sensoren lesen |
| `tennis-booking` | Lokal erstellt | 🎾 | Tennisplatz-Verfügbarkeit & Buchung |

### Skill-Verzeichnisstruktur

```
~/.openclaw/workspace/skills/
├── home-assistant/          ← ClawHub-installiert
│   ├── SKILL.md             ← Skill-Beschreibung + Anleitung
│   ├── _meta.json           ← ClawHub-Metadaten
│   ├── scripts/
│   │   └── ha.sh            ← CLI-Wrapper für HA REST API
│   └── references/
│       └── api.md           ← HA API-Referenz
│
└── tennis-booking/          ← Lokal erstellt
    ├── SKILL.md             ← Skill-Beschreibung + Anleitung
    └── scripts/
        └── tennis.sh        ← CLI für Verfügbarkeit & Buchung
```

### Skill-Erkennung

OpenClaw scannt `~/.openclaw/workspace/skills/` automatisch beim Start.
Jeder Ordner mit einer `SKILL.md`-Datei wird als Skill erkannt.

**SKILL.md Format:**
```yaml
---
name: mein-skill
description: Beschreibung wann und wofür der Skill genutzt wird.
metadata: {"clawdbot":{"emoji":"🔧","requires":{"bins":["curl"]}}}
---
# Skill-Name
Dokumentation, Beispiele, CLI-Befehle...
```

### Neuen Skill erstellen

```bash
cd ~/.openclaw/workspace/skills
mkdir mein-neuer-skill
# SKILL.md schreiben mit Beschreibung und Beispielen
# Optional: scripts/ Ordner mit Shell-Scripts
# Restart: cd ~/openclaw && docker compose restart openclaw-gateway
```

---

## Architektur-Übersicht

```
┌──────────────────┐     curl/REST API      ┌──────────────────────┐
│  OpenClaw VM     │ ──────────────────────→ │  Home Assistant OS   │
│  192.168.178.80  │     Port 8123 (TCP)     │  192.168.178.88      │
│                  │                         │  User: claw_timbo    │
│  Docker:         │     HTTPS/443           ├──────────────────────┤
│  - openclaw-gw   │ ──────────────────────→ │  Grafana             │
│  - whisper       │                         │  192.168.178.98      │
│                  │                         └──────────────────────┘
│  Skills:         │     HTTPS/443 (Internet)
│  🏠 home-asst.  │ ──────────────────────→  buchen.tc-kleinberghofen.de
│  🎾 tennis      │ ──────────────────────→  tennis-erdweg-online.de
│                  │
│  Credentials:    │
│  .credentials.env│
│  (HA_TOKEN,      │
│   TENNIS_*_EMAIL,│
│   TENNIS_*_PASS) │
└──────────────────┘
        │
        │ Proxmox Firewall (VM 100)
        │ ✅ ACCEPT → 192.168.178.88:8123 (Home Assistant)
        │ ✅ ACCEPT → 192.168.178.98:443  (Grafana)
        │ ❌ DROP   → 192.168.178.0/24    (rest LAN)
        │ ❌ DROP   → 10.0.0.0/8, 172.16.0.0/12
        │ ✅ ACCEPT → Internet (Tennis-Seiten etc.)
```

---

## Komponenten

| Komponente | Details |
|-----------|---------|
| OpenClaw VM | VM 100, IP 192.168.178.80, Debian 12 |
| Home Assistant | HAOS, IP 192.168.178.88:8123 |
| Grafana | IP 192.168.178.98, HTTPS Port 443 |
| HA-Benutzer | `claw_timbo` (kein Admin, eingeschränkte Bereiche) |
| HA-Skill | `home-assistant@1.0.0` via ClawHub |
| Tennis-Skill | `tennis-booking` lokal erstellt |
| Auth-Methode HA | Long-Lived Access Token (JWT) |
| Auth-Methode Tennis | E-Mail + Passwort (ep-3 Session-Cookie) |
| Zugriffsmethode | Skills → `exec`-Tool → `curl` im Container |
| Firewall | Proxmox VM-Firewall: nur HA + Grafana IPs erlaubt, Internet offen |
| Credentials | `~/.openclaw/.credentials.env` (chmod 600) |
| Skill-Erkennung | Automatisch via `~/.openclaw/workspace/skills/*/SKILL.md` |

---

## Einrichtung Schritt für Schritt

### 1. Home Assistant: Eingeschränkten Benutzer erstellen

1. HA → **Einstellungen → Personen → Person hinzufügen**
2. Name: `claw_timbo`
3. Benutzerkonto erlauben: **Ja**
4. Benutzername: `claw_timbo`, Passwort setzen
5. **Administrator: NEIN** (normaler Benutzer!)
6. Speichern

#### Bereiche einschränken

1. **Einstellungen → Personen → `claw_timbo`**
2. **"Im Benutzerbereich verwalten"**
3. Nur die gewünschten Bereiche/Entitäten zuweisen:
   - ✅ Lichter, Sensoren, Klimasteuerung
   - ✅ Solaranlage, Wallbox (über HA-Entitäten)
   - ❌ Türschlösser, Alarmanlagen, Admin-Funktionen

> **Tipp:** Lieber weniger freigeben und bei Bedarf erweitern.

### 2. Home Assistant: Long-Lived Access Token erstellen

1. **Aus HA ausloggen**
2. **Als `claw_timbo` einloggen**
3. **Profil** (links unten) → Runterscrollen
4. **"Langlebiges Zugriffstoken erstellen"**
5. Name: `openclaw`
6. **Token SOFORT KOPIEREN** — wird nur einmal angezeigt!

### 3. OpenClaw VM: Credentials-Datei erstellen

```bash
ssh claw@192.168.178.80

cat > ~/.openclaw/.credentials.env << 'EOF'
# Home Assistant (eingeschränkter User claw_timbo)
HA_URL=http://192.168.178.88:8123
HA_TOKEN=<HIER-TOKEN-EINFÜGEN>

# Grafana
GRAFANA_URL=https://192.168.178.98/proxy/grafana

# Tennis-Buchung (ep-3 System)
TENNIS_KB_EMAIL=deine-email@example.com
TENNIS_KB_PASS=dein-kleinberghofen-passwort
TENNIS_ER_EMAIL=deine-email@example.com
TENNIS_ER_PASS=dein-erdweg-passwort
EOF

chmod 600 ~/.openclaw/.credentials.env
```

### 4. Docker-Compose: Env-File einbinden

In `~/openclaw/docker-compose.yml` beim `openclaw-gateway` Service:

```yaml
services:
  openclaw-gateway:
    image: ghcr.io/openclaw/openclaw:latest
    # ... (restliche Config)
    environment:
      HOME: /home/node
      TERM: xterm-256color
    env_file:
      - /home/claw/.openclaw/.credentials.env
```

### 5. Proxmox-Firewall: HA + Grafana freigeben

Auf dem **Proxmox Host** (192.168.178.108):

```bash
nano /etc/pve/firewall/100.fw
```

ACCEPT-Regeln **VOR** den DROP-Regeln einfügen:

```
[RULES]
# Erlaubte LAN-Ziele für OpenClaw
OUT ACCEPT -dest 192.168.178.88 -dport 8123 -p tcp -log nolog    # Home Assistant
OUT ACCEPT -dest 192.168.178.98 -dport 443 -p tcp -log nolog     # Grafana (HTTPS)

# Block all RFC1918 outbound (LAN isolation) — NACH den ACCEPT-Regeln!
OUT DROP -d 192.168.178.0/24 -log nolog
OUT DROP -d 10.0.0.0/8 -log nolog
OUT DROP -d 172.16.0.0/12 -log nolog
```

> ⚠️ **Reihenfolge ist entscheidend!** ACCEPT muss VOR DROP stehen.

### 6. Home Assistant Skill installieren

```bash
ssh claw@192.168.178.80
cd ~/openclaw

# Skill von ClawHub installieren
docker compose exec openclaw-gateway node openclaw.mjs skills install home-assistant

# Skill-Verzeichnis prüfen
ls ~/.openclaw/workspace/skills/home-assistant/
# → SKILL.md  _meta.json  references  scripts
```

### 7. jq im Container bereitstellen

Das OpenClaw Docker-Image enthält kein `jq`. Binary manuell kopieren:

```bash
# jq herunterladen
curl -sL -o ~/openclaw/workspace/jq-bin \
  https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64
chmod +x ~/openclaw/workspace/jq-bin

# In den Container-PATH legen
mkdir -p ~/.openclaw/bin
cp ~/openclaw/workspace/jq-bin ~/.openclaw/bin/jq
chmod +x ~/.openclaw/bin/jq

# PATH in ha.sh ergänzen (Zeile 2 nach #!/bin/bash)
sed -i '2i export PATH="/home/node/.openclaw/bin:$PATH"' \
  ~/.openclaw/workspace/skills/home-assistant/scripts/ha.sh

# Testen
docker compose exec openclaw-gateway /home/node/.openclaw/bin/jq --version
```

### 8. OpenClaw Tool-Profil konfigurieren

```bash
cd ~/openclaw

# Profil auf "coding" (erlaubt fs + runtime + exec)
docker compose exec openclaw-gateway node openclaw.mjs config set tools.profile "coding"

# Exec-Tool auf "full" (keine Nachfrage bei Telegram)
docker compose exec openclaw-gateway node openclaw.mjs config set tools.exec.security "full"
docker compose exec openclaw-gateway node openclaw.mjs config set tools.exec.ask "off"

# Deny-Liste reduzieren (nur Sessions blockieren)
docker compose exec openclaw-gateway node openclaw.mjs config set tools.deny '["sessions_spawn","sessions_send"]'

# Restart
docker compose restart openclaw-gateway
```

#### Tool-Profile Referenz

| Profil | Enthält | Use Case |
|--------|---------|----------|
| `minimal` | Nur `session_status` | Maximum Lockdown |
| `messaging` | Messaging-Tools, Session-Listen | Chat-only Bot |
| **`coding`** | **fs, runtime, exec, sessions, memory** | **← Unser Setup** |
| `full` | Alles, keine Einschränkungen | Voller Zugriff |

#### Exec-Security Referenz

| Wert | Bedeutung |
|------|-----------|
| `deny` | Exec komplett blockiert |
| `allowlist` | Nur whitelisted Commands (leere Liste = nichts erlaubt) |
| **`full`** | **Alle Befehle erlaubt ← Unser Setup** |

### 9. Boot-Message erstellen

Die `boot.md` wird bei jeder neuen Session gelesen und gibt OpenClaw
Kontext über seine verfügbaren Integrationen:

```bash
cat > ~/.openclaw/boot.md << 'BOOT'
## Verfügbare Integrationen

### Home Assistant (Smart Home)
- URL: $HA_URL (Env-Var im Container verfügbar)
- Token: $HA_TOKEN (Env-Var im Container verfügbar)
- Skill: ~/.openclaw/workspace/skills/home-assistant/
- CLI: Nutze `curl` mit den Env-Vars $HA_URL und $HA_TOKEN
- Beispiel: `curl -s -H "Authorization: Bearer $HA_TOKEN" "$HA_URL/api/states" | jq '.[].entity_id'`
- Script: `/home/node/.openclaw/workspace/skills/home-assistant/scripts/ha.sh`
- PATH enthält jq: `/home/node/.openclaw/bin/jq`

### Grafana (Solar-Dashboards)
- URL: $GRAFANA_URL (Env-Var im Container verfügbar)

### Wichtig
- Du HAST Netzwerkzugriff auf 192.168.178.88 (Home Assistant) und 192.168.178.98 (Grafana)
- Du HAST die Env-Vars HA_URL, HA_TOKEN, GRAFANA_URL im Container
- Nutze `exec` Tool mit curl/jq für API-Zugriffe
- jq liegt unter /home/node/.openclaw/bin/jq
BOOT
```

### 10. Restart & Testen

```bash
cd ~/openclaw
docker compose restart openclaw-gateway
```

Teste via Telegram:
- `"Liste alle Lichter in Home Assistant auf"`
- `"Wie ist die Temperatur im Wohnzimmer?"`
- `"Schalte das Licht im Billardraum an"`

---

## Aktuelle Firewall-Regeln (Referenz)

Datei: `/etc/pve/firewall/100.fw`

```
[OPTIONS]
enable: 1
dhcp: 1
policy_in: DROP
policy_out: DROP

[RULES]
# Allow outbound to gateway/router
OUT ACCEPT -d 192.168.178.1/32 -log nolog
OUT ACCEPT -d 192.168.178.1/32 -p udp -dport 53 -log nolog
OUT ACCEPT -d 192.168.178.1/32 -p tcp -dport 53 -log nolog

# Erlaubte LAN-Ziele für OpenClaw
OUT ACCEPT -dest 192.168.178.88 -dport 8123 -p tcp -log nolog    # Home Assistant
OUT ACCEPT -dest 192.168.178.98 -dport 443 -p tcp -log nolog     # Grafana (HTTPS)

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
```

---

## Aktuelle openclaw.json Tool-Config (Referenz)

```json
{
  "tools": {
    "profile": "coding",
    "deny": ["sessions_spawn", "sessions_send"],
    "fs": { "workspaceOnly": true },
    "exec": { "security": "full", "ask": "off" },
    "elevated": { "enabled": false },
    "web": { "search": { "provider": "brave" } },
    "media": {
      "audio": {
        "enabled": true,
        "models": [{
          "type": "cli",
          "command": "curl",
          "args": [
            "-sf", "-X", "POST",
            "http://127.0.0.1:8000/v1/audio/transcriptions",
            "-F", "file=@{{MediaPath}}",
            "-F", "model=Systran/faster-whisper-small",
            "-F", "response_format=text",
            "-F", "language=de"
          ],
          "timeoutSeconds": 60
        }]
      }
    }
  }
}
```

---

## Sicherheitsmodell

### Dreifache Absicherung

| Schicht | Was | Schutz |
|---------|-----|--------|
| **1. Proxmox Firewall** | VM-Level, host-enforced | OpenClaw kann NUR HA + Grafana im LAN erreichen |
| **2. HA-Benutzerrechte** | `claw_timbo` = kein Admin | Kein Zugriff auf Admin-API, eingeschränkte Entitäten |
| **3. OpenClaw Tools** | `exec: full` aber `elevated: false` | Keine Root-Befehle, kein Schreiben außerhalb Workspace |

### Was OpenClaw KANN

- ✅ HA-Entitäten lesen (Sensoren, Status)
- ✅ HA-Geräte steuern (Lichter, Schalter, Klima — nur freigegebene)
- ✅ HA-Szenen und Scripts aktivieren
- ✅ Grafana-Dashboards abfragen (Solar-Forecast)
- ✅ Befehle im Container ausführen (curl, jq, etc.)
- ✅ Dateien im Workspace lesen/schreiben

### Was OpenClaw NICHT KANN

- ❌ Andere LAN-Geräte erreichen (Firewall blockt)
- ❌ HA-Admin-Funktionen (User ist kein Admin)
- ❌ Root/Elevated-Befehle (disabled)
- ❌ Außerhalb Workspace schreiben (workspaceOnly)
- ❌ Sessions spawnen/senden (deny-Liste)
- ❌ Wallbox direkt steuern (nur über HA-Entitäten)

---

## Troubleshooting

### HA antwortet mit 403 Forbidden

```bash
# Prüfe ob die VM-IP gebannt wurde
# In HA → File Editor → /config/ip_bans.yaml
# Eintrag für 192.168.178.80 löschen → HA neustarten
```

> ⚠️ Fehlgeschlagene Requests (z.B. leerer Token) können einen
> automatischen IP-Ban auslösen!

### Env-Vars nicht im Container

```bash
# Prüfen
docker compose exec openclaw-gateway env | grep -E "HA_|GRAFANA_|TENNIS_"

# Falls leer: docker-compose.yml prüfen
grep -A2 env_file ~/openclaw/docker-compose.yml

# .credentials.env Syntax prüfen (keine Leerzeichen um =)
cat ~/.openclaw/.credentials.env
```

### OpenClaw weigert sich, Befehle auszuführen

```bash
# Exec-Tool Status prüfen
docker compose exec openclaw-gateway node openclaw.mjs config get tools.exec
# Erwartet: {"security":"full","ask":"off"}

# Falls nicht: Nochmal setzen
docker compose exec openclaw-gateway node openclaw.mjs config set tools.exec.security "full"
docker compose exec openclaw-gateway node openclaw.mjs config set tools.exec.ask "off"
docker compose restart openclaw-gateway
```

### jq nicht gefunden

```bash
# Prüfen
docker compose exec openclaw-gateway /home/node/.openclaw/bin/jq --version

# Falls fehlt: Neu installieren
curl -sL -o ~/openclaw/workspace/jq-bin \
  https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64
chmod +x ~/openclaw/workspace/jq-bin
mkdir -p ~/.openclaw/bin
cp ~/openclaw/workspace/jq-bin ~/.openclaw/bin/jq
chmod +x ~/.openclaw/bin/jq
```

### OpenClaw "vergisst" dass es HA-Zugriff hat

Prüfe ob `boot.md` gelesen wird:

```bash
docker compose exec openclaw-gateway cat /home/node/.openclaw/boot.md
```

Falls leer oder nicht vorhanden → Schritt 9 wiederholen.

---

## Weitere Services hinzufügen

### Neuen LAN-Service freigeben

1. **Proxmox Firewall** — ACCEPT-Regel VOR den DROP-Regeln:
   ```
   OUT ACCEPT -dest <IP> -dport <PORT> -p tcp -log nolog
   ```

2. **Credentials** — In `~/.openclaw/.credentials.env` ergänzen

3. **Skill erstellen** — Neuen Skill-Ordner unter `~/.openclaw/workspace/skills/` anlegen:
   ```bash
   mkdir -p ~/.openclaw/workspace/skills/neuer-service/scripts
   # SKILL.md mit Beschreibung + API-Referenz schreiben
   # Optional: Script(s) für CLI-Zugriff
   ```

4. **boot.md** — Integration beschreiben (als Fallback, falls Skill nicht reicht)

5. **Restart** — `cd ~/openclaw && docker compose down && docker compose up -d`

### Neuen Internet-Service hinzufügen

Kein Firewall-Thema — nur Skill + Credentials nötig:

1. **Skill erstellen** mit SKILL.md + Scripts
2. **Credentials** in `.credentials.env` (falls Login nötig)
3. **Restart**

### Aktuell freigegebene Services

| Service | IP | Port | Protokoll |
|---------|-----|------|-----------|
| Home Assistant | 192.168.178.88 | 8123 | HTTP |
| Grafana | 192.168.178.98 | 443 | HTTPS |

### Geplant / Möglich

| Service | IP | Port | Hinweis |
|---------|-----|------|---------|
| openWB Wallbox | 192.168.178.127 | 80 | Besser über HA steuern |

### Internet-Services (kein Firewall-Thema)

| Service | URL | System | Status |
|---------|-----|--------|--------|
| Tennis Kleinberghofen | buchen.tc-kleinberghofen.de | ep-3 | ✅ Eingerichtet |
| Tennis Erdweg | tennis-erdweg-online.de | ep-3 | ✅ Eingerichtet |

---

## Tennis-Platz Integration

### Übersicht

Beide Tennisvereine nutzen das **ep-3 Buchungssystem** (hbsys.de) mit
identischer Web-Oberfläche. OpenClaw greift über `curl` + HTML-Parsing
auf die öffentlichen Kalenderseiten zu.

| Verein | URL | Plätze | Zeiten |
|--------|-----|--------|--------|
| TC Kleinberghofen | buchen.tc-kleinberghofen.de | 2 | 06:00–22:00 |
| TC Erdweg | tennis-erdweg-online.de | 6 | 08:00–21:00 |

### Funktionen

| Feature | Ohne Login | Mit Login |
|---------|-----------|-----------|
| Verfügbarkeit prüfen | ✅ | ✅ |
| Wer hat gebucht | ❌ Nur "Belegt" | ⚠️ Evtl. sichtbar |
| Platz buchen | ❌ | ✅ |
| Buchung stornieren | ❌ | ✅ |

### Einrichtung

Der Tennis-Skill wurde als **lokaler Skill** im Workspace erstellt.

#### 1. Skill-Verzeichnis erstellen (bereits erledigt)

```bash
mkdir -p ~/.openclaw/workspace/skills/tennis-booking/scripts
```

#### 2. SKILL.md und Script wurden direkt im Skill-Ordner erstellt:

```
~/.openclaw/workspace/skills/tennis-booking/
├── SKILL.md             ← Skill-Beschreibung mit ep-3 Referenz
└── scripts/
    └── tennis.sh        ← CLI: check, details, book
```

> **Nicht verwechseln** mit der alten Datei `~/.openclaw/bin/tennis.sh`.
> Der Skill liegt unter `workspace/skills/tennis-booking/scripts/tennis.sh`.

#### 3. Credentials in .credentials.env ergänzen

```bash
cat >> ~/.openclaw/.credentials.env << 'EOF'

# Tennis-Buchung (ep-3 System)
TENNIS_KB_EMAIL=deine-email@example.com
TENNIS_KB_PASS=dein-kleinberghofen-passwort
TENNIS_ER_EMAIL=deine-email@example.com
TENNIS_ER_PASS=dein-erdweg-passwort
EOF

chmod 600 ~/.openclaw/.credentials.env
```

> Gleiche E-Mail für beide Vereine möglich, Passwörter können
> unterschiedlich sein.

#### 4. boot.md aktualisieren

Ergänze in `~/.openclaw/boot.md`:

```markdown
### Tennis-Platzbuchung (ep-3 Skill)
- Skill: ~/.openclaw/workspace/skills/tennis-booking/
- Script: tennis.sh (im Skill scripts/ Ordner)
- Vereine: kb = Kleinberghofen (2 Plätze), er = Erdweg (6 Plätze)
- Env-Vars: TENNIS_KB_EMAIL, TENNIS_KB_PASS, TENNIS_ER_EMAIL, TENNIS_ER_PASS
- Verfügbarkeit: tennis.sh check [kb|er] [YYYY-MM-DD]
- Details: tennis.sh details [kb|er] YYYY-MM-DD HH:MM PLATZ
- Buchen: tennis.sh book [kb|er] YYYY-MM-DD HH:MM PLATZ
- Internet-Seiten, kein Firewall-Thema
```

#### 4. Restart

```bash
cd ~/openclaw && docker compose restart openclaw-gateway
```

### Nutzung via Telegram

Beispiel-Befehle an den Bot:

- `"Zeig mir die freien Tennisplätze morgen in Kleinberghofen"`
- `"Ist am Sonntag um 10 Uhr ein Platz in Erdweg frei?"`
- `"Buche Platz 1 in Kleinberghofen am 20.04. um 18 Uhr"`
- `"Welche Plätze sind heute Abend in Erdweg noch frei?"`

### tennis.sh Referenz

```bash
# Kurzformen: kb = Kleinberghofen, er = Erdweg
tennis.sh check kb                  # Heute
tennis.sh check kb 2026-04-20      # Bestimmtes Datum
tennis.sh check er                  # TC Erdweg, heute

# Slot-Details (wer hat gebucht?)
tennis.sh details er 2026-04-19 15:00 6

# Platz buchen (Login erforderlich)
tennis.sh book kb 2026-04-20 18:00 1
tennis.sh book er 2026-04-20 18:00 3
```

### ep-3 System Details

| Merkmal | Kleinberghofen | Erdweg |
|---------|---------------|--------|
| Basis-URL | buchen.tc-kleinberghofen.de | tennis-erdweg-online.de |
| Platz-IDs (intern) | 1, 2 | 4, 5, 6, 7, 8, 9 |
| Platz-IDs (Display) | 1, 2 | 1, 2, 3, 4, 5, 6 |
| Login-Endpunkt | POST /user/login | POST /user/login |
| Kalender-URL | /?date=YYYY-MM-DD | /?date=YYYY-MM-DD |
| Slot-URL | /square?ds=...&ts=...&te=...&s=... | gleich |
| Frei-CSS-Klasse | `cc-free` | `cc-free` |
| Belegt-CSS-Klasse | `cc-set` | `cc-set` |
| Vorbei-CSS-Klasse | `cc-over` | `cc-over` |

### Troubleshooting Tennis

```bash
# Script direkt im Container testen
docker compose exec openclaw-gateway bash -c \
  'export PATH="/home/node/.openclaw/bin:$PATH" && \
   /home/node/.openclaw/workspace/skills/tennis-booking/scripts/tennis.sh check kb'

# Manuell prüfen ob die Seite erreichbar ist
docker compose exec openclaw-gateway curl -sf \
  https://buchen.tc-kleinberghofen.de/ | head -5

docker compose exec openclaw-gateway curl -sf \
  https://tennis-erdweg-online.de/ | head -5
```
