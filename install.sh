#!/usr/bin/env bash
# Installer fuer pve-issue (Proxmox VE Login-Screen)
#   - installiert /usr/local/sbin/update-proxmox-issue.sh
#   - legt /etc/default/proxmox-issue an (nur wenn sie fehlt)
#   - richtet systemd-Service + Timer ein (alle 5 Minuten)
set -euo pipefail

REPO_RAW="${PVE_ISSUE_RAW:-https://raw.githubusercontent.com/db-infra-ops/pve-issue/main}"
DESTDIR="${DESTDIR:-}"          # nur fuer Tests/Pakete: Installation in ein Zielverzeichnis
BIN="/usr/local/sbin/update-proxmox-issue.sh"
CONF="/etc/default/proxmox-issue"
UNIT_DIR="/etc/systemd/system"
CACHE_DIR="/var/cache/proxmox-issue"

DEPS=1
TIMER=1
FORCE=0
UNINSTALL=0
PURGE=0
EXEC_ARGS=()

usage() {
    cat <<'EOF'
Usage: ./install.sh [Optionen]

  (ohne Option)   installieren bzw. aktualisieren
  --no-deps       python3/smartmontools nicht per apt installieren
  --no-timer      nur Script installieren, keinen systemd-Timer einrichten
  --issue-full    /etc/issue mit allen Details (vor dem Login sichtbar!)
  --mono          reine ASCII-Ausgabe ohne Farben
  --force         auch auf Systemen ohne Proxmox VE installieren
  --uninstall     Script, Units und Cache entfernen (Config bleibt)
  --purge         mit --uninstall: auch /etc/default/proxmox-issue entfernen
  -h, --help      diese Hilfe

Umgebungsvariable PVE_ISSUE_RAW ueberschreibt die Download-URL, falls das
Script ohne lokalen Repo-Checkout gestartet wird (z. B. per curl | bash).
EOF
}

for arg in "$@"; do
    case "$arg" in
        --no-deps)     DEPS=0 ;;
        --no-timer)    TIMER=0 ;;
        --issue-full)  EXEC_ARGS+=(--issue-full) ;;
        --mono)        EXEC_ARGS+=(--mono) ;;
        --force)       FORCE=1 ;;
        --uninstall)   UNINSTALL=1 ;;
        --purge)       PURGE=1 ;;
        -h|--help)     usage; exit 0 ;;
        *) printf 'Unbekannte Option: %s\n\n' "$arg" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ -z "$DESTDIR" ]] && (( EUID != 0 )); then
    echo "Bitte als root ausfuehren." >&2
    exit 1
fi

info() { printf '==> %s\n' "$*"; }
warn() { printf 'WARNUNG: %s\n' "$*" >&2; }
have_systemd() { [[ -z "$DESTDIR" ]] && command -v systemctl >/dev/null 2>&1; }

# ---------------------------------------------------------------- Deinstallation
if (( UNINSTALL )); then
    info "Deinstallation"
    if have_systemd; then
        systemctl disable --now proxmox-issue.timer 2>/dev/null || true
        systemctl stop proxmox-issue.service 2>/dev/null || true
    fi
    rm -f "$DESTDIR$UNIT_DIR/proxmox-issue.service" "$DESTDIR$UNIT_DIR/proxmox-issue.timer" \
          "$DESTDIR$BIN" "$DESTDIR/run/proxmox-issue.lock"
    rm -rf "$DESTDIR$CACHE_DIR"
    (( PURGE )) && rm -f "$DESTDIR$CONF"
    if have_systemd; then
        systemctl daemon-reload
        # Proxmox schreibt das Standard-/etc/issue neu
        systemctl restart pvebanner.service 2>/dev/null || true
    fi
    info "Fertig."
    echo "Hinweis: /etc/motd wurde vom Script ueberschrieben und bleibt unveraendert bestehen."
    echo "         Zum Zuruecksetzen: : > /etc/motd"
    (( PURGE )) || [[ ! -f "$DESTDIR$CONF" ]] || echo "Config $CONF wurde behalten (--purge zum Entfernen)."
    exit 0
fi

# ---------------------------------------------------------------- Voraussetzungen
if ! command -v pveversion >/dev/null 2>&1 && (( ! FORCE )) && [[ -z "$DESTDIR" ]]; then
    echo "pveversion nicht gefunden - das ist kein Proxmox VE. Mit --force trotzdem installieren." >&2
    exit 1
fi

# Quelle: lokaler Checkout, sonst von GitHub nachladen
SRC="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fetch() {   # fetch <Pfad im Repo> -> gibt lokalen Dateipfad aus
    local rel="$1"
    if [[ -n "$SRC" && -f "$SRC/$rel" ]]; then
        printf '%s\n' "$SRC/$rel"
        return
    fi
    mkdir -p "$TMP/$(dirname "$rel")"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$REPO_RAW/$rel" -o "$TMP/$rel"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$TMP/$rel" "$REPO_RAW/$rel"
    else
        echo "Weder lokale Datei $rel noch curl/wget gefunden." >&2
        exit 1
    fi
    printf '%s\n' "$TMP/$rel"
}

if (( DEPS )) && [[ -z "$DESTDIR" ]]; then
    missing=()
    command -v python3  >/dev/null 2>&1 || missing+=(python3)
    command -v smartctl >/dev/null 2>&1 || missing+=(smartmontools)
    if (( ${#missing[@]} )); then
        info "Installiere Abhaengigkeiten: ${missing[*]}"
        apt-get update -qq
        apt-get install -y "${missing[@]}"
    fi
fi

# ---------------------------------------------------------------- Installation
info "Installiere $BIN"
install -D -m 755 "$(fetch update-proxmox-issue.sh)" "$DESTDIR$BIN"

if [[ -f "$DESTDIR$CONF" ]]; then
    info "Config $CONF existiert bereits - bleibt unveraendert"
else
    info "Lege $CONF an (Beispiel, alles auskommentiert)"
    install -D -m 644 "$(fetch proxmox-issue.conf.example)" "$DESTDIR$CONF"
fi

if (( TIMER )); then
    info "Richte systemd-Service und Timer ein"
    install -D -m 644 "$(fetch systemd/proxmox-issue.timer)" "$DESTDIR$UNIT_DIR/proxmox-issue.timer"
    install -D -m 644 "$(fetch systemd/proxmox-issue.service)" "$DESTDIR$UNIT_DIR/proxmox-issue.service"
    if (( ${#EXEC_ARGS[@]} )); then
        sed -i "s|^ExecStart=.*|ExecStart=$BIN ${EXEC_ARGS[*]}|" "$DESTDIR$UNIT_DIR/proxmox-issue.service"
    fi
    if have_systemd; then
        systemctl daemon-reload
        systemctl enable --now proxmox-issue.timer
        systemctl start proxmox-issue.service || warn "Erster Lauf fehlgeschlagen: journalctl -u proxmox-issue.service"
    else
        warn "systemd nicht aktiv bzw. DESTDIR gesetzt - Timer nicht aktiviert"
    fi
else
    info "Timer uebersprungen. Manuell ausfuehren: $BIN"
fi

info "Fertig."
cat <<EOF

Testlauf ohne Dateien zu schreiben:  update-proxmox-issue.sh --stdout
Timer pruefen:                       systemctl list-timers proxmox-issue.timer
Log:                                 journalctl -u proxmox-issue.service -n 20 --no-pager
Konfiguration:                       $CONF
Deinstallation:                      ./install.sh --uninstall
EOF
