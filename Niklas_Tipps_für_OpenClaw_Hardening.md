# Niklas' Tipps für OpenClaw Hardening

> Zusammengestellt aus zwei Videos von **Niklas Steenfatt** (@NiklasSteenfatt):
>
> 1. **„100 Stunden OpenClaw in 19 Minuten"**
>    https://www.youtube.com/watch?v=yfFARCwwKtQ
>
> 2. **„Mein n8n Server wurde EXPOSED"**
>    https://www.youtube.com/watch?v=I2BWbK5bkAM
>
> **Kontext**: Niklas hostet seine Dienste (OpenClaw, n8n) auf einem **Hetzner
> VPS** im Internet. Viele Tipps gelten 1:1 auch für selbst gehostete Proxmox
> VMs/LXCs — manche sind VPS-spezifisch (z.B. öffentliche IP, Let's Encrypt).

---

## Teil 1: Tipps aus „100 Stunden OpenClaw in 19 Minuten"

### Server & Infrastruktur

| # | Tipp | Details |
|---|------|---------|
| 1 | **SSH-Keys nutzen, Passwort-Login deaktivieren** | Einen dedizierten User anlegen, root-Login über SSH deaktivieren (`PermitRootLogin no`, `PasswordAuthentication no` in `/etc/ssh/sshd_config`) |
| 2 | **Firewall aktivieren (ufw)** | Nur benötigte Ports öffnen (22/SSH, 80/443 für Web). Alles andere blocken |
| 3 | **Docker für Isolation** | Alles in Containern laufen lassen — saubere Trennung der Dienste |
| 4 | **Reverse Proxy mit SSL** | nginx oder Traefik vor OpenClaw schalten, Let's Encrypt für TLS-Zertifikate |
| 5 | **Regelmässige Updates** | `apt update && apt upgrade` regelmässig ausführen, alle Abhängigkeiten aktuell halten |
| 6 | **Fail2Ban installieren** | Brute-Force-Attacken auf SSH und Web-Dienste automatisch blockieren |
| 7 | **Monitoring** | `htop` und `docker stats` nutzen, um Ressourcenverbrauch im Blick zu behalten |
| 8 | **Umgebungsvariablen in .env** | Alle Secrets (API-Keys, Tokens, Passwörter) in `.env`-Datei mit restriktiven Berechtigungen speichern |
| 9 | **Regelmässige Backups** | Konfigurationsdateien und Daten regelmässig sichern |
| 10 | **Ubuntu LTS als Basis** | Stabile, langfristig unterstützte Basis mit Security-Updates |

### OpenClaw-spezifisch

| # | Tipp | Details |
|---|------|---------|
| 11 | **Ports korrekt weiterleiten** | Nur die tatsächlich benötigten Ports freigeben, nicht pauschal alles öffnen |
| 12 | **Kosten im Blick behalten** | Bei Cloud/VPS Abrechnung pro Stunde — ungewollte Ressourcen zeitnah abschalten |

---

## Teil 2: Tipps aus „Mein n8n Server wurde EXPOSED"

> **Hintergrund**: Niklas' selbst gehosteter n8n-Server war öffentlich ohne
> Authentifizierung erreichbar. Unbefugte konnten seinen Server missbrauchen
> (z.B. Spam versenden). Kernaussage: *„Mache Dienste nie ohne Authentifizierung
> und Verschlüsselung im Internet zugänglich."*

### VPS/Server Hardening

| # | Tipp | Details |
|---|------|---------|
| 13 | **Authentifizierung IMMER aktivieren** | Starkes Passwort oder Token für alle Admin-Oberflächen. Nie einen Dienst ohne Auth im Internet betreiben |
| 14 | **2-Faktor-Authentifizierung (2FA)** | Wo möglich aktivieren, insbesondere für Admin-Zugänge |
| 15 | **Dienste nur lokal binden (127.0.0.1)** | Serverprozesse auf `127.0.0.1` binden, NICHT auf `0.0.0.0`. Zugriff nur über Reverse Proxy oder SSH-Tunnel |
| 16 | **SSL/TLS erzwingen** | Verschlüsselten Zugang mit Let's Encrypt oder eigenen Zertifikaten sicherstellen |
| 17 | **Starke, einzigartige Passwörter** | Für jeden Dienst separate, starke Passwörter/Tokens verwenden |
| 18 | **Unnötige Software entfernen** | Weniger installiert = weniger Angriffsfläche |
| 19 | **Zugriff beschränken** | Admin-Bereiche auf bestimmte IPs oder VPN/Tailscale beschränken |
| 20 | **Shodan-Check** | Regelmässig mit shodan.io prüfen, wie der Server von aussen erreichbar ist |
| 21 | **Keine Standard-/Test-Konfigurationen produktiv nutzen** | Default-Configs sind fast immer unsicher. Jede Einstellung bewusst setzen |

---

## Teil 3: Zusammengefasste Hardening-Checkliste

Aus beiden Videos ergibt sich folgende priorisierte Checkliste:

### Kritisch (sofort umsetzen)
1. ✅ **Authentifizierung für ALLE Dienste** — kein Dienst ohne Auth
2. ✅ **SSH-Keys statt Passwörter** — Root-Login deaktivieren
3. ✅ **Dienste lokal binden** (127.0.0.1) — Zugriff nur via Tunnel/Proxy
4. ✅ **Firewall** — Default-Deny, nur benötigte Ports
5. ✅ **TLS/HTTPS** — Verschlüsselung erzwingen

### Wichtig (zeitnah umsetzen)
6. ✅ Fail2Ban oder ähnliches IDS
7. ✅ Regelmässige OS- und Software-Updates
8. ✅ Secrets in .env mit restriktiven Dateiberechtigungen
9. ✅ Docker/Container-Isolation
10. ✅ Separate, starke Passwörter pro Dienst

### Empfohlen (Best Practice)
11. ✅ 2FA für Admin-Zugänge
12. ✅ Regelmässige Backups
13. ✅ Monitoring (htop, docker stats)
14. ✅ Unnötige Software entfernen
15. ✅ Shodan-Check / externe Sicherheitsprüfung

---

## Teil 4: Vergleich mit unseren Setup-Skripten

### Legende
- ✅ = Umgesetzt
- ⚠️ = Teilweise umgesetzt / anders gelöst
- ❌ = Nicht umgesetzt (ggfs. nicht anwendbar)
- n/a = Nicht anwendbar (VPS-spezifisch, bei lokalem Proxmox nicht relevant)

### Video-Tipp vs. `niklas_setup-openclaw-vm.sh` (VM)

| # | Niklas' Tipp | VM-Skript | Status | Anmerkung |
|---|-------------|-----------|--------|-----------|
| 1 | SSH-Keys, kein Passwort-Login | Cloud-init mit SSH-Key, kein Passwort | ✅ | |
| 2 | Firewall (ufw) | Proxmox Firewall + iptables (defense in depth) | ✅ | Stärker als ufw: zwei Ebenen |
| 3 | Docker für Isolation | OpenClaw läuft in Docker mit cap_drop + no-new-privileges | ✅ | |
| 4 | Reverse Proxy mit SSL | Nicht umgesetzt — Gateway bindet auf loopback, Zugriff via SSH-Tunnel | ⚠️ | SSL nicht nötig, da kein Netzwerk-Exposure. SSH-Tunnel ist verschlüsselt |
| 5 | Regelmässige Updates | unattended-upgrades in cloud-init konfiguriert | ✅ | |
| 6 | Fail2Ban | Nicht installiert | ❌ | Geringes Risiko: SSH nur via Key, Gateway auf loopback. Optional nachrüstbar |
| 7 | Monitoring | Nicht konfiguriert | ❌ | Manuell via `docker stats` möglich |
| 8 | Secrets in .env | API-Key via SSH injiziert, chmod 600 auf Config | ✅ | Nicht in cloud-init, nicht in Shell-History |
| 9 | Regelmässige Backups | Nicht automatisiert | ❌ | Proxmox-Backups manuell konfigurierbar (`vzdump`) |
| 10 | Ubuntu LTS als Basis | Debian 12 (Bookworm) — gleichwertig stabil | ✅ | |
| 11 | Ports korrekt weiterleiten | Docker published auf 127.0.0.1 only | ✅ | |
| 12 | Kosten im Blick | n/a | n/a | Lokaler Proxmox, keine Cloud-Kosten |
| 13 | Auth IMMER aktivieren | 256-bit Token generiert, hardened baseline | ✅ | |
| 14 | 2FA | Nicht umgesetzt | ❌ | OpenClaw unterstützt Token-Auth, kein 2FA. SSH-Key ist Äquivalent |
| 15 | Lokal binden (127.0.0.1) | Docker published auf 127.0.0.1, Gateway intern auf lan (für Docker-Forward) | ✅ | |
| 16 | SSL/TLS erzwingen | SSH-Tunnel statt TLS | ⚠️ | Gleiche Sicherheit, anderer Mechanismus |
| 17 | Starke, einzigartige Passwörter | Zufällig generierter 256-bit Token | ✅ | |
| 18 | Unnötige Software entfernen | Minimales cloud-init, nur Docker + Abhängigkeiten | ✅ | |
| 19 | Zugriff beschränken | Loopback-only + Proxmox FW blockiert LAN | ✅ | |
| 20 | Shodan-Check | n/a | n/a | Kein öffentliches Internet-Exposure |
| 21 | Keine Default-Configs | Hardened baseline aus offizieller Doku angewendet | ✅ | tools deny, exec deny, elevated disabled |

**Zusammenfassung VM**: 14× ✅, 2× ⚠️, 3× ❌, 2× n/a

---

### Video-Tipp vs. `niklas_setup-openclaw-lxc.sh` (LXC)

| # | Niklas' Tipp | LXC-Skript | Status | Anmerkung |
|---|-------------|------------|--------|-----------|
| 1 | SSH-Keys, kein Passwort-Login | Root-Passwort gesetzt (für pct/VNC), SSH-Key nicht automatisch | ⚠️ | SSH-Key kann manuell nachgerüstet werden. Passwort nötig für LXC-Konsole |
| 2 | Firewall (ufw) | Proxmox Firewall + iptables (defense in depth) | ✅ | Stärker als ufw: zwei Ebenen |
| 3 | Docker für Isolation | Kein Docker — OpenClaw direkt installiert (npm), aber unprivilegierter LXC | ⚠️ | LXC-Isolation statt Docker-Isolation. Unprivileged = sicherer als privileged |
| 4 | Reverse Proxy mit SSL | Gateway auf loopback, noVNC auf localhost, Zugriff via SSH-Tunnel | ⚠️ | SSL nicht nötig, da kein Netzwerk-Exposure |
| 5 | Regelmässige Updates | unattended-upgrades konfiguriert | ✅ | |
| 6 | Fail2Ban | Nicht installiert | ❌ | SSH von LAN, Gateway auf loopback — geringes Risiko |
| 7 | Monitoring | Nicht konfiguriert | ❌ | Manuell via `htop`/`systemctl status` möglich |
| 8 | Secrets in .env | API-Key nach Setup injiziert, chmod 600 | ✅ | |
| 9 | Regelmässige Backups | Nicht automatisiert | ❌ | Proxmox `vzdump` manuell konfigurierbar |
| 10 | Ubuntu LTS als Basis | Debian 13 (Trixie) — gleichwertige Basis | ✅ | |
| 11 | Ports korrekt weiterleiten | Gateway loopback, noVNC localhost-only | ✅ | |
| 12 | Kosten im Blick | n/a | n/a | Lokaler Proxmox |
| 13 | Auth IMMER aktivieren | 256-bit Token, VNC separates Passwort | ✅ | |
| 14 | 2FA | Nicht umgesetzt | ❌ | SSH-Key nachrüstbar, kein 2FA-Support in OpenClaw |
| 15 | Lokal binden (127.0.0.1) | Gateway loopback, noVNC localhost | ✅ | |
| 16 | SSL/TLS erzwingen | SSH-Tunnel statt TLS | ⚠️ | Äquivalente Sicherheit |
| 17 | Starke, einzigartige Passwörter | Zufälliger Token + separates VNC-Passwort | ✅ | |
| 18 | Unnötige Software entfernen | Desktop-Umgebung installiert (LXQt, Chrome) | ⚠️ | Gewollt für Browser-basiertes Onboarding. Vergrössert Angriffsfläche |
| 19 | Zugriff beschränken | Loopback + Proxmox FW + iptables | ✅ | |
| 20 | Shodan-Check | n/a | n/a | Kein öffentliches Internet-Exposure |
| 21 | Keine Default-Configs | Hardened baseline angewendet | ✅ | |

**Zusammenfassung LXC**: 11× ✅, 5× ⚠️, 3× ❌, 2× n/a

---

## Teil 5: Was fehlt — Empfehlungen zur Nachrüstung

### Für beide Varianten (VM + LXC)

| Massnahme | Aufwand | Befehl / Anleitung |
|-----------|---------|---------------------|
| **Fail2Ban nachrüsten** | Niedrig | `apt install fail2ban` + Standard-Config reicht für SSH-Schutz |
| **Proxmox-Backups einrichten** | Niedrig | Proxmox UI → Datacenter → Backup → Schedule für den Container/VM erstellen |
| **Monitoring einrichten** | Mittel | `apt install htop` ist schon vorhanden. Für Alerting: Proxmox Mail-Notifications oder Uptime Kuma |

### Nur LXC

| Massnahme | Aufwand | Anleitung |
|-----------|---------|-----------|
| **SSH-Key für root nachrüsten** | Niedrig | `pct exec <VMID> -- mkdir -p /root/.ssh && pct exec <VMID> -- tee /root/.ssh/authorized_keys < ~/.ssh/id_ed25519.pub` und dann `PasswordAuthentication no` in sshd_config |
| **Chrome/Desktop-Angriffsfläche minimieren** | Mittel | Nach Abschluss des Onboardings optional Desktop-Pakete entfernen: `apt remove --purge lxqt tigervnc-standalone-server novnc google-chrome-stable` |

### Nicht anwendbar bei lokalem Proxmox (VPS-spezifisch)

| Video-Tipp | Warum nicht relevant |
|-----------|---------------------|
| Let's Encrypt / TLS-Zertifikate | Kein öffentliches Internet-Exposure. SSH-Tunnel bietet Ende-zu-Ende-Verschlüsselung |
| Shodan-Check | Server ist nicht aus dem Internet erreichbar |
| Cloud-Kosten überwachen | Eigene Hardware, keine laufenden Kosten |
| 2FA | OpenClaw unterstützt kein natives 2FA. Token-Auth + SSH-Key bieten äquivalente Sicherheit im LAN |

---

## Fazit

Niklas' Videos decken die **klassischen VPS-Hardening-Grundlagen** ab, die für
jedes Internet-exponierte System gelten. Da unsere Proxmox-Skripte auf einem
**lokalen Server ohne Internet-Exposure** laufen und alle Dienste auf
**loopback binden**, sind viele VPS-spezifische Massnahmen (TLS, Shodan,
2FA) weniger kritisch.

Die **grössten Lücken** in beiden Skripten sind:
1. **Fail2Ban** — einfach nachrüstbar
2. **Automatische Backups** — über Proxmox UI konfigurierbar
3. **Monitoring/Alerting** — optional, aber empfehlenswert

Die **Kern-Sicherheitsmassnahmen** aus den Videos — Authentifizierung, lokales
Binding, Firewall, Updates, starke Passwörter, Isolation — sind in beiden
Skripten **vollständig umgesetzt**, teils sogar stärker (Proxmox Firewall +
iptables = defense in depth, RFC1918-Block, IPv6 deaktiviert, hardened
OpenClaw-Baseline).
