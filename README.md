# pve-issue – Login-Screen für Proxmox VE

Dynamischer, kompakter Login-Screen für Proxmox VE. Das Script erzeugt `/etc/issue` (vor dem Login, bewusst minimal) und `/etc/motd` (nach dem Login, mit allen Details) und zeigt Systemzustand, Gäste, Speicher, USV, Wartung und Hardware auf einen Blick. Eine Statuszeile fasst alle Probleme als `OK`, `WARN` oder `ERROR` zusammen.

Ausgabe wahlweise in ANSI/Unicode (farbig, mit Rahmen) oder als reines ASCII (`--mono`).

## Beispielausgabe (`/etc/motd`)

```
╔══════════════════════════════════════════════════════════════════════════════╗
║  PROXMOX VE 8.4.1 | pve01.example.lan                                        ║
╠══════════════════════════════════════════════════════════════════════════════╣
║  Web-UI  : https://192.0.2.10:8006/                                          ║
║  IP      : 192.0.2.10/24(vmbr0), 198.51.100.10/24(vmbr1)                     ║
║  Kernel  : 6.8.12-4-pve [OK]                                                 ║
║  Uptime  : 3d 4h 5m                                                          ║
║  Load    : 0.76 0.99 1.09 | RAM 79% von 63G | / 4%                           ║
║  Status  : OK                                                                ║
╟─ GAESTE / CLUSTER ───────────────────────────────────────────────────────────╢
║  VMs     : 6/8 aktiv                                                         ║
║  LXCs    : 0/1 aktiv                                                         ║
║  Cluster : Standalone                                                        ║
║  Ceph    : nicht konfiguriert                                                ║
╟─ WARTUNG ────────────────────────────────────────────────────────────────────╢
║  Dienste : OK | 0 fehlgeschlagen                                             ║
║  Updates : OK | alles aktuell                                                ║
║  Backup  : OK | 12.10. 11:33 (vor 8h)                                        ║
╟─ USV / NUT ──────────────────────────────────────────────────────────────────╢
║  USV     : NUT nicht installiert                                             ║
╟─ DATASTORES / ZFS ───────────────────────────────────────────────────────────╢
║  DATASTORES (USED)                   ZFS POOLS (USED)                        ║
║  local                  6.07%        rpool        ONLINE      61%            ║
║  local-zfs             52.47%                                                ║
║  pbs-local             49.56%                                                ║
╟─ PHYSICAL DISKS - WEAR USED / YEARS ON ──────────────────────────────────────╢
║  DEVICE   MODEL             SERIAL                  WEAR YEARS  SMART        ║
║  nvme0n1  EXAMPLE NVME 1TB  SN0000000001             13%   1.2     OK        ║
║  nvme1n1  EXAMPLE NVME 1TB  SN0000000002             13%   1.2     OK        ║
╠══════════════════════════════════════════════════════════════════════════════╣
║  Stand: 12.10.2026 19:37 | erzeugt in 1.2s                                   ║
╚══════════════════════════════════════════════════════════════════════════════╝
```

`/etc/issue` enthält standardmäßig nur den oberen Block (Web-UI, IPs, Kernel, Uptime, Load, Status).

## Features

- **System:** FQDN, PVE-Version, Web-UI-URL, IPv4-Adressen, Uptime, Load, RAM, Root-FS
- **Kernel:** Vergleich des laufenden Kernels mit dem neuesten installierten (bzw. gepinnten) Proxmox-Kernel
- **Gäste:** QEMU-VMs und LXC-Container als `aktiv/gesamt` (Auflistung mit `--list-guests`)
- **Cluster:** Name, Knoten, Votes, Quorum
- **Ceph:** Health, OSDs, MON-Quorum
- **Wartung:** fehlgeschlagene systemd-Units, ausstehende Updates (inkl. Sicherheitsupdates), letztes Backup (vzdump/PBS)
- **USV (NUT):** Netz-/Batteriebetrieb, Akkustand, Restlaufzeit, Last
- **Datastores/ZFS:** Belegung und Pool-Health
- **Multipath:** Pfade und Maps, falls installiert
- **Datenträger:** Modell, Seriennummer, SSD-Wearout, Betriebsjahre und SMART-Status (SATA und NVMe)
- **Robust:** alle Abfragen laufen parallel, lesend und mit Timeout; die Dateien werden atomar ersetzt; `flock` verhindert überlappende Läufe

## Installation

Auf dem Proxmox-Host als root:

```bash
git clone https://github.com/db-infra-ops/pve-issue.git
cd pve-issue
./install.sh
```

Der Installer

1. installiert bei Bedarf `python3` und `smartmontools`,
2. kopiert das Script nach `/usr/local/sbin/update-proxmox-issue.sh`,
3. legt `/etc/default/proxmox-issue` an (nur wenn sie fehlt),
4. richtet `proxmox-issue.service` und `proxmox-issue.timer` ein (alle 5 Minuten) und führt das Script einmal aus.

Bei einem Cluster auf jedem Node einzeln ausführen.

Optionen von `install.sh`:

| Option | Beschreibung |
|---|---|
| `--no-deps` | `python3`/`smartmontools` nicht per apt installieren |
| `--no-timer` | nur das Script installieren, keinen Timer einrichten |
| `--issue-full` | `/etc/issue` mit allen Details (siehe Sicherheit) |
| `--mono` | reine ASCII-Ausgabe |
| `--force` | auch ohne Proxmox VE installieren |
| `--uninstall` | Script, Units und Cache entfernen (Config bleibt) |
| `--purge` | mit `--uninstall`: auch die Config entfernen |

`--issue-full` und `--mono` werden in die `ExecStart=`-Zeile des Services geschrieben.

Zum Aktualisieren: `git pull && ./install.sh`.

### Testlauf

```bash
update-proxmox-issue.sh --stdout
```

gibt `issue` und `motd` auf dem Terminal aus, ohne Dateien zu schreiben.

## Konfiguration

`/etc/default/proxmox-issue` (`KEY=WERT`, `#` = Kommentar; wird geparst, nicht als Shell ausgeführt). Eine Vorlage liegt in [`proxmox-issue.conf.example`](proxmox-issue.conf.example).

| Schlüssel | Bedeutung |
|---|---|
| `IGNORE_UNITS` | fehlgeschlagene Units, die ignoriert werden. Namen mit oder ohne `.service`, Wildcards erlaubt, Trennung per Leerzeichen oder Komma. Ignorierte Units werden als `(N ignoriert)` angezeigt. |
| `CRITICAL_UNITS` | Namenspräfixe, bei denen ein Ausfall `ERROR` statt `WARN` ergibt. Default: `pve corosync ceph zfs pbs proxmox multipath nut networking`. Leer = alles nur `WARN`. |
| `BACKUP_CHECK` | `no` blendet die Backup-Zeile aus (z. B. wenn Backups nicht über vzdump dieses Nodes laufen). |

Beispiel:

```bash
IGNORE_UNITS="openipmi.service ugreen-* zfs-import-scan"
BACKUP_CHECK=no
```

## Parameter von `update-proxmox-issue.sh`

| Parameter | Beschreibung |
|---|---|
| *(keiner)* | ANSI/Unicode; kompaktes `/etc/issue`, volles `/etc/motd` |
| `--mono` | reines ASCII ohne Farben und Unicode-Rahmen |
| `--no-issue` | `/etc/issue` nicht verändern |
| `--no-motd` | `/etc/motd` nicht verändern |
| `--issue-full` | `/etc/issue` mit allen Details (vor dem Login sichtbar) |
| `--list-guests` | VMs/LXCs mit VMID:Name auflisten |
| `--smart-ttl SEK` | SMART-Cache in Sekunden (Default 3600, `0` = immer abfragen) |
| `--config DATEI` | andere Konfigurationsdatei |
| `--reload-getty` | nach dem Schreiben `agetty --reload` (Login-Prompt neu zeichnen) |
| `--stdout` | nur ausgeben, keine Dateien schreiben |
| `--help`, `-h` | Hilfe |

`--no-issue` und `--no-motd` lassen sich nicht kombinieren. Mit `--reload-getty` kann ein halb getippter Benutzername auf der Konsole verloren gehen.

## Statuszeile und Schwellenwerte

Die Zeile `Status` nennt nur generische Bereiche (z. B. `WARN | Updates, Backup`), keine Gerätenamen. Die Details stehen im `motd`.

| Bereich | WARN | ERROR |
|---|---|---|
| Kernel | läuft nicht auf dem neuesten/gepinnten Kernel | – |
| Root-FS | ≥ 90 % | ≥ 95 % |
| Storage | ≥ 90 % oder offline | ≥ 95 % |
| ZFS | Pool ≥ 80 % voll | Pool nicht `ONLINE`, `zpool status -x` meldet Probleme, Pool ≥ 90 % |
| Cluster | – | kein Quorum, `pvecm` nicht erreichbar |
| Ceph | `HEALTH_WARN`, CLI fehlt | `HEALTH_ERR`, nicht erreichbar |
| Multipath | – | Dienst/Pfad/Map defekt |
| USV | Batteriebetrieb, Batteriewechsel, nicht erreichbar | niedriger Akkustand, erzwungene Abschaltung |
| Datenträger | Wearout ≥ 80 %, NVMe-Critical-Warning | SMART-Selbsttest fehlgeschlagen |
| Dienste | fehlgeschlagene Unit | fehlgeschlagene Unit mit kritischem Präfix |
| Updates | Sicherheitsupdates oder Paketindex älter als 7 Tage | – |
| Backup | Warnungen, letztes Backup älter als 48 h, Fehler einzelner Gäste in 24 h | letzter Lauf fehlgeschlagen |

## SMART und SSD-Wearout

SMART-Daten werden gecacht (`/var/cache/proxmox-issue/`, Default 1 h). Schlafende HDDs werden mit `-n standby` nicht aufgeweckt. Ohne neue Daten bleibt der letzte bekannte Wert stehen.

| Attribut | Bedeutung |
|---|---|
| 9 | Power-On-Hours |
| 177 | Wear Leveling Count |
| 202 | Lifetime Used / Remaining |
| 231 | SSD Life Left |
| 233 | Media Wearout Indicator |
| NVMe | Percentage Used |

Das Script erkennt die Attribute anhand ihrer IDs und Bezeichnungen. Bei normierten Restlebensdauerwerten wird `100 - VALUE` berechnet, die Betriebsdauer ergibt sich aus Betriebsstunden / 8.766 h pro Jahr. Da die Bedeutung einzelner Attribute herstellerspezifisch ist, wird bei unbekannter Interpretation `-` angezeigt. Der Wearout-Wert ist kein unmittelbarer Ausfallindikator. Virtuelle Blockdevices (`zd*`, `loop*`, `dm-*`, `rbd*` …) werden ausgeschlossen.

## Hinweise

- **Sicherheit:** `/etc/issue` ist vor der Authentifizierung sichtbar. Der Default zeigt dort nur Web-UI-URL, IPs, Kernel, Uptime, Load und den Status, keine VM-Namen und keine Seriennummern. `--issue-full` gibt dort alles aus, das sollte nur auf rein lokal erreichbaren Konsolen genutzt werden. Auf öffentlich erreichbaren Systemen kann `/etc/issue` mit `--no-issue` ganz ausgespart werden.
- **Backups:** Die Zeile wertet die vzdump-Tasks des lokalen Nodes aus (auch Backups auf PBS). Auf Clustern sieht jeder Node nur seine eigenen Backups.
- **Aktualität:** Die Anzeige ist eine Momentaufnahme des letzten Laufs, kein Echtzeit-Monitoring.
- **Kernel-Pin:** Ein Pin wird über `/etc/kernel/proxmox-boot-pin` erkannt.
- **Terminal:** Für die farbige Darstellung ist eine UTF-8-fähige Konsole mit ANSI-Unterstützung nötig, sonst `--mono` verwenden. Die Breite beträgt 80 Spalten.
- **`/etc/motd`:** wird vom Script überschrieben. Eigene Inhalte gehen dabei verloren.

## Deinstallation

```bash
./install.sh --uninstall          # Config bleibt
./install.sh --uninstall --purge  # auch /etc/default/proxmox-issue entfernen
```

Dabei wird `pvebanner.service` neu gestartet, damit Proxmox das Standard-`/etc/issue` wieder schreibt. `/etc/motd` bleibt unverändert; zum Zurücksetzen `: > /etc/motd`.

## Herkunft

Weiterentwicklung des Scripts `update-proxmox-issue.sh` aus [bashclub/trmm-scripts](https://github.com/bashclub/trmm-scripts).
