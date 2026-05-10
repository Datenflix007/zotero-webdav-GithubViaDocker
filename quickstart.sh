#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

DOCKER_CMD=(docker)
FIRST_RUN=0
OS="$(uname -s)"

# ── Helpers ──────────────────────────────────────────────────────────

info()  { printf '[INFO] %s\n' "$1"; }
ok()    { printf '[OK]   %s\n' "$1"; }
warn()  { printf '[WARN] %s\n' "$1"; }
fail()  { printf '[ERROR] %s\n' "$1" >&2; exit 1; }
step()  { printf '\n\033[36m%s\033[0m\n' "$1"; }

# ── Env file ─────────────────────────────────────────────────────────

load_env() {
  [ -f ".env.local" ] || return 0
  while IFS='=' read -r key value; do
    [[ "$key" =~ ^# ]] && continue
    [[ -z "$key" ]] && continue
    case "$key" in
      GITHUB_USERNAME|GITHUB_EMAIL|GITHUB_TOKEN|WEBDAV_USERNAME|WEBDAV_PASSWORD|WEBDAV_URL)
        export "$key=$value" ;;
    esac
  done < .env.local
}

create_env_file() {
  step "[1/7] Projekt einrichten"

  if [ -f ".env.local" ]; then
    ok ".env.local ist vorhanden"
    load_env
    return
  fi

  FIRST_RUN=1
  echo "Erster Start – bitte GitHub-Daten eingeben."
  read -r -p "GitHub Benutzername: "   github_user
  read -r -p "GitHub E-Mail: "         github_email
  read -r -s -p "GitHub Personal Access Token (leer = Git bereits angemeldet): " github_token
  echo ""

  cat > .env.local <<EOF
# GitHub Configuration
GITHUB_USERNAME=$github_user
GITHUB_EMAIL=$github_email
GITHUB_TOKEN=$github_token

# WebDAV Server
WEBDAV_URL=http://localhost:8080
WEBDAV_USERNAME=zotero
WEBDAV_PASSWORD=changeme123
EOF

  chmod 600 .env.local
  git config user.name  "$github_user"
  git config user.email "$github_email"
  export GITHUB_USERNAME="$github_user"
  export GITHUB_EMAIL="$github_email"
  export GITHUB_TOKEN="$github_token"
  ok ".env.local erstellt und Git-Benutzer gesetzt"
}

# ── Git pull ─────────────────────────────────────────────────────────

git_remote() {
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    local b64
    b64="$(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 | tr -d '\n')"
    git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $b64" "$@"
  else
    git "$@"
  fi
}

pull_remote_updates() {
  step "[2/7] GitHub-Stand pruefen"

  if ! git_remote fetch --prune 2>/dev/null; then
    warn "Fetch fehlgeschlagen – arbeite lokal weiter."
    return
  fi

  if [ -n "$(git status --porcelain)" ]; then
    info "Pull uebersprungen (lokale Aenderungen vorhanden)."
    return
  fi

  if git_remote pull --ff-only 2>/dev/null; then
    ok "Repository ist aktuell"
  else
    warn "Fast-forward Pull nicht moeglich – bitte git status pruefen."
  fi
}

# ── Zotero ───────────────────────────────────────────────────────────

find_zotero_cmd() {
  # Native binary
  command -v zotero 2>/dev/null && return
  # Common Linux paths
  for p in /opt/zotero/zotero "$HOME/.local/bin/zotero" /usr/bin/zotero; do
    [ -x "$p" ] && { echo "$p"; return; }
  done
  # Flatpak
  flatpak list 2>/dev/null | grep -qi "org.zotero.Zotero" && echo "flatpak:org.zotero.Zotero" && return
  # macOS app
  [ -d "/Applications/Zotero.app" ] && echo "macos:Zotero" && return
  return 1
}

ensure_zotero_installed() {
  step "[3/7] Zotero pruefen"

  if find_zotero_cmd >/dev/null 2>&1; then
    ok "Zotero ist installiert"
    return
  fi

  case "$OS" in
    Darwin)
      if command -v brew >/dev/null 2>&1; then
        info "Installiere Zotero via Homebrew..."
        brew install --cask zotero && ok "Zotero installiert" && return
      fi
      warn "Bitte Zotero manuell installieren: https://www.zotero.org/download/"
      ;;
    Linux)
      if command -v flatpak >/dev/null 2>&1; then
        info "Installiere Zotero via Flatpak..."
        flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true
        flatpak install -y flathub org.zotero.Zotero && ok "Zotero installiert (Flatpak)" && return
      fi
      warn "Flatpak nicht gefunden. Zotero manuell installieren: https://www.zotero.org/download/"
      info "Flatpak installieren: https://flatpak.org/setup/"
      ;;
  esac
}

start_zotero() {
  local cmd
  cmd="$(find_zotero_cmd 2>/dev/null)" || { warn "Zotero nicht gefunden – bitte manuell starten."; return; }

  # Check if already running
  pgrep -x zotero >/dev/null 2>&1 && { ok "Zotero laeuft bereits"; return; }

  info "Starte Zotero..."
  case "$cmd" in
    flatpak:*)
      flatpak run "${cmd#flatpak:}" >/dev/null 2>&1 & ;;
    macos:*)
      open -a "${cmd#macos:}" >/dev/null 2>&1 || true ;;
    *)
      nohup "$cmd" >/dev/null 2>&1 & ;;
  esac
}

# ── PowerShell 7 (fuer vault-ui.ps1) ─────────────────────────────────

ensure_pwsh_installed() {
  step "[3b] PowerShell 7 pruefen (fuer Browser-UI)"

  if command -v pwsh >/dev/null 2>&1; then
    ok "PowerShell 7 ist installiert ($(pwsh --version 2>/dev/null))"
    return
  fi

  case "$OS" in
    Darwin)
      if command -v brew >/dev/null 2>&1; then
        info "Installiere PowerShell via Homebrew..."
        brew install powershell/tap/powershell && ok "PowerShell 7 installiert" && return
      fi
      ;;
    Linux)
      if command -v snap >/dev/null 2>&1; then
        info "Installiere PowerShell via Snap..."
        sudo snap install powershell --classic && ok "PowerShell 7 installiert" && return
      elif command -v apt-get >/dev/null 2>&1; then
        info "Installiere PowerShell via apt..."
        # Microsoft-Paketquelle
        local vid
        vid="$(. /etc/os-release 2>/dev/null && echo "${VERSION_ID:-22.04}")"
        local pkg_url="https://packages.microsoft.com/config/ubuntu/${vid}/packages-microsoft-prod.deb"
        if wget -q "$pkg_url" -O /tmp/_ms_prod.deb 2>/dev/null; then
          sudo dpkg -i /tmp/_ms_prod.deb 2>/dev/null && \
          sudo apt-get update -qq && \
          sudo apt-get install -y powershell && \
          ok "PowerShell 7 installiert" && return
        fi
      fi
      ;;
  esac

  warn "PowerShell 7 konnte nicht automatisch installiert werden."
  warn "Browser-UI nicht verfuegbar. Manuell: https://learn.microsoft.com/de-de/powershell/scripting/install/installing-powershell"
  info "Auto-Sync laeuft trotzdem (bash-Version)."
}

# ── Docker install ────────────────────────────────────────────────────

install_docker_linux() {
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -qq
    sudo apt-get install -y docker.io docker-compose-plugin
    sudo systemctl enable --now docker || true
    sudo usermod -aG docker "$USER" || true
    return
  fi
  if command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y docker docker-compose-plugin
    sudo systemctl enable --now docker || true
    return
  fi
  if command -v pacman >/dev/null 2>&1; then
    sudo pacman -S --noconfirm docker docker-compose
    sudo systemctl enable --now docker || true
    return
  fi
  fail "Kein unterstuetzter Paketmanager. Bitte Docker manuell installieren: https://docs.docker.com/engine/install/"
}

ensure_docker_installed() {
  step "[4/7] Docker pruefen"

  if command -v docker >/dev/null 2>&1; then
    ok "Docker CLI ist vorhanden"
    return
  fi

  case "$OS" in
    Darwin)
      if command -v brew >/dev/null 2>&1; then
        info "Installiere Docker Desktop via Homebrew..."
        brew install --cask docker
      else
        fail "Docker nicht installiert. Bitte installieren: https://www.docker.com/products/docker-desktop/"
      fi
      ;;
    Linux)
      info "Installiere Docker via Paketmanager..."
      install_docker_linux
      ;;
    *)
      fail "Betriebssystem nicht unterstuetzt."
      ;;
  esac
}

# ── Docker start ──────────────────────────────────────────────────────

docker_ready() {
  "${DOCKER_CMD[@]}" info >/dev/null 2>&1
}

start_docker() {
  step "[5/7] Docker starten"

  # Check with and without sudo
  if docker_ready; then
    ok "Docker Engine laeuft bereits"
    return
  fi
  if sudo docker info >/dev/null 2>&1; then
    DOCKER_CMD=(sudo docker)
    ok "Docker Engine laeuft (sudo erforderlich)"
    return
  fi

  case "$OS" in
    Darwin)
      info "Starte Docker Desktop..."
      open -a Docker 2>/dev/null || true
      ;;
    Linux)
      info "Starte Docker Daemon..."
      sudo systemctl start docker 2>/dev/null || sudo service docker start 2>/dev/null || true
      ;;
  esac

  printf 'Warte auf Docker Engine'
  local deadline=$(( $(date +%s) + 180 ))
  local attempt=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    sleep 3
    printf '.'
    attempt=$(( attempt + 1 ))
    if docker_ready; then
      echo " bereit"
      ok "Docker Engine ist bereit"
      return
    fi
    # Try sudo fallback on Linux
    if [ "$OS" = "Linux" ] && sudo docker info >/dev/null 2>&1; then
      DOCKER_CMD=(sudo docker)
      echo " bereit (sudo)"
      ok "Docker Engine ist bereit"
      return
    fi
  done
  echo ""
  fail "Docker Engine war nach 3 Minuten nicht bereit. Docker manuell starten und quickstart.sh erneut ausfuehren."
}

# ── WebDAV ────────────────────────────────────────────────────────────

webdav_ready() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://localhost:8080" 2>/dev/null)"
  case "$code" in 200|401|207) return 0 ;; esac
  return 1
}

start_webdav() {
  step "[6/7] WebDAV Container starten"

  mkdir -p data

  # Load WebDAV credentials for docker-compose env substitution
  if [ -f ".env.local" ]; then
    while IFS='=' read -r key value; do
      case "$key" in WEBDAV_USERNAME|WEBDAV_PASSWORD) export "$key=$value" ;; esac
    done < .env.local
  fi

  # Already healthy?
  if webdav_ready; then
    ok "WebDAV antwortet bereits auf http://localhost:8080"
    return
  fi

  info "Starte WebDAV Container..."
  if ! "${DOCKER_CMD[@]}" compose up -d 2>&1; then
    # Show logs for diagnosis
    "${DOCKER_CMD[@]}" compose logs --tail 20 2>&1 || true
    fail "docker compose up -d fehlgeschlagen. Siehe Logs oben."
  fi

  # Wait up to 30s for WebDAV to respond
  printf 'Warte auf WebDAV'
  local deadline=$(( $(date +%s) + 30 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if webdav_ready; then
      echo " OK"
      break
    fi
    sleep 2
    printf '.'
  done
  echo ""

  "${DOCKER_CMD[@]}" ps --filter "name=zotero-webdav" --format "  {{.Names}} | {{.Status}} | {{.Ports}}" 2>/dev/null || true
  ok "WebDAV laeuft auf http://localhost:8080"
}

# ── Auto-Sync ─────────────────────────────────────────────────────────

start_auto_sync() {
  step "[7/7] Auto-Sync und UI starten"

  if pgrep -f "auto-sync\.(ps1|sh)" >/dev/null 2>&1; then
    ok "Auto-Sync laeuft bereits"
  else
    if command -v pwsh >/dev/null 2>&1; then
      nohup pwsh -NoProfile -File "$SCRIPT_DIR/auto-sync.ps1" \
        -WatchPath "$SCRIPT_DIR/data" -Push \
        > "$SCRIPT_DIR/auto-sync.log" 2>&1 &
      ok "Auto-Sync gestartet via pwsh (PID: $!)"
    else
      chmod +x "$SCRIPT_DIR/auto-sync.sh"
      PUSH=1 nohup "$SCRIPT_DIR/auto-sync.sh" data \
        > "$SCRIPT_DIR/auto-sync.log" 2>&1 &
      ok "Auto-Sync gestartet via bash (PID: $!)"
    fi
    info "Log: $SCRIPT_DIR/auto-sync.log"
  fi
}

# ── UI ────────────────────────────────────────────────────────────────

start_ui() {
  if ! command -v pwsh >/dev/null 2>&1; then
    warn "Browser-UI benoetigt PowerShell 7. Auto-Sync laeuft trotzdem."
    warn "pwsh installieren: https://learn.microsoft.com/de-de/powershell/scripting/install/installing-powershell"
    return
  fi

  if pgrep -f "vault-ui\.ps1" >/dev/null 2>&1; then
    ok "UI laeuft bereits auf http://localhost:8765"
  else
    nohup pwsh -NoProfile -File "$SCRIPT_DIR/vault-ui.ps1" \
      > "$SCRIPT_DIR/vault-ui.log" 2>&1 &
    ok "UI gestartet: http://localhost:8765 (PID: $!)"
    sleep 2
  fi

  # Open browser
  if command -v open     >/dev/null 2>&1; then open     "http://localhost:8765" 2>/dev/null || true; fi
  if command -v xdg-open >/dev/null 2>&1; then xdg-open "http://localhost:8765" >/dev/null 2>&1 || true; fi
}

# ── Main ──────────────────────────────────────────────────────────────

echo "=========================================="
echo " MyLiteratureVault Quickstart"
echo "=========================================="

create_env_file
pull_remote_updates
ensure_zotero_installed
ensure_pwsh_installed
ensure_docker_installed
start_docker
start_webdav
start_auto_sync
start_ui
start_zotero

echo ""
echo "Fertig! Alle Dienste laufen."
echo ""
echo "  WebDAV:  http://localhost:8080   Benutzer: zotero   Passwort: changeme123"
echo "  UI:      http://localhost:8765"
echo ""

if [ "$FIRST_RUN" = "1" ]; then
  echo "ZOTERO EINRICHTEN (Erster Start):"
  echo "  1. Zotero wurde gestartet – anmelden oder registrieren:"
  echo "     https://www.zotero.org/user/login"
  echo ""
  echo "  2. In Zotero: Bearbeiten -> Einstellungen -> Sync -> Datei-Sync"
  echo "     Methode:   WebDAV"
  echo "     URL:       http://localhost:8080"
  echo "     Benutzer:  zotero"
  echo "     Passwort:  changeme123"
  echo "     -> 'Server pruefen' klicken"
  echo ""
  read -r -p "Enter druecken wenn Zotero eingerichtet ist..."
else
  echo "In Zotero: Einstellungen -> Sync -> Datei-Sync -> WebDAV -> Server pruefen."
fi
