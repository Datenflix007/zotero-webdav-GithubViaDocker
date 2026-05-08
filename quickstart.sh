#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
DOCKER_CMD=(docker)

info() { printf '[INFO] %s\n' "$1"; }
ok() { printf '[OK] %s\n' "$1"; }
fail() { printf '[ERROR] %s\n' "$1" >&2; exit 1; }

load_env() {
  [ -f ".env.local" ] || return 0
  while IFS='=' read -r key value; do
    case "$key" in
      GITHUB_USERNAME|GITHUB_EMAIL|GITHUB_TOKEN|WEBDAV_USERNAME|WEBDAV_PASSWORD|WEBDAV_URL) export "$key=$value" ;;
    esac
  done < .env.local
}

git_remote() {
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    basic_auth="$(printf '%s:%s' "x-access-token" "$GITHUB_TOKEN" | base64 | tr -d '\n')"
    git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $basic_auth" "$@"
  else
    git "$@"
  fi
}

create_env_file() {
  echo ""
  echo "[1/5] Projekt einrichten"

  if [ -f ".env.local" ]; then
    ok ".env.local ist vorhanden"
    return
  fi

  echo "Beim ersten Start brauche ich deine GitHub-Daten fuer automatische Commits und Pushes."
  read -r -p "GitHub Benutzername: " github_user
  read -r -p "GitHub E-Mail: " github_email
  read -r -s -p "GitHub Personal Access Token (optional, Enter wenn Git bereits angemeldet ist): " github_token
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
  git config user.name "$github_user"
  git config user.email "$github_email"
  ok ".env.local erstellt und Git-Benutzer gesetzt"
}

install_docker_linux() {
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y docker.io docker-compose-plugin
    sudo usermod -aG docker "$USER" || true
    return
  fi

  if command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y docker docker-compose-plugin
    return
  fi

  if command -v pacman >/dev/null 2>&1; then
    sudo pacman -S --noconfirm docker docker-compose
    return
  fi

  fail "Docker ist nicht installiert. Bitte Docker installieren: https://docs.docker.com/engine/install/"
}

ensure_docker_installed() {
  echo ""
  echo "[3/6] Docker pruefen"

  if command -v docker >/dev/null 2>&1; then
    ok "Docker ist installiert"
    return
  fi

  case "$(uname -s)" in
    Darwin)
      if command -v brew >/dev/null 2>&1; then
        info "Docker Desktop wird mit Homebrew installiert."
        brew install --cask docker
      else
        fail "Docker ist nicht installiert. Bitte Docker Desktop installieren: https://www.docker.com/products/docker-desktop/"
      fi
      ;;
    Linux)
      info "Docker wird ueber den Paketmanager installiert."
      install_docker_linux
      ;;
    *)
      fail "Dieses System wird von quickstart.sh nicht automatisch unterstuetzt."
      ;;
  esac
}

pull_remote_updates() {
  echo ""
  echo "[2/6] GitHub-Stand pruefen"

  load_env
  if ! git_remote fetch --prune; then
    info "Fetch fehlgeschlagen. Quickstart arbeitet lokal weiter."
    return
  fi

  if [ -n "$(git status --porcelain)" ]; then
    info "Pull uebersprungen, weil lokale Aenderungen vorhanden sind."
    return
  fi

  if git_remote pull --ff-only; then
    ok "Repository ist aktuell"
  else
    info "Pull nicht moeglich. Bitte Git-Status pruefen."
  fi
}

start_docker() {
  echo ""
  echo "[4/6] Docker starten"

  if "${DOCKER_CMD[@]}" info >/dev/null 2>&1; then
    ok "Docker Engine ist bereit"
    return
  fi

  case "$(uname -s)" in
    Darwin)
      open -a Docker || true
      ;;
    Linux)
      sudo systemctl enable --now docker || sudo service docker start || true
      ;;
  esac

  info "Warte auf Docker Engine..."
  for _ in $(seq 1 60); do
    if "${DOCKER_CMD[@]}" info >/dev/null 2>&1; then
      ok "Docker Engine ist bereit"
      return
    fi
    if command -v sudo >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
      DOCKER_CMD=(sudo docker)
      ok "Docker Engine ist bereit"
      return
    fi
    sleep 3
    printf '.'
  done
  echo ""
  fail "Docker Engine wurde nicht rechtzeitig bereit. Bitte Docker starten und quickstart.sh erneut ausfuehren."
}

start_webdav() {
  echo ""
  echo "[5/6] WebDAV Container starten"

  mkdir -p data
  if [ -f ".env.local" ]; then
    while IFS='=' read -r key value; do
      case "$key" in
        WEBDAV_USERNAME|WEBDAV_PASSWORD) export "$key=$value" ;;
      esac
    done < .env.local
  fi
  "${DOCKER_CMD[@]}" compose up -d
  sleep 3
  "${DOCKER_CMD[@]}" ps --filter "name=zotero-webdav" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
  ok "WebDAV laeuft auf http://localhost:8080"
}

start_auto_sync() {
  echo ""
  echo "[6/6] Auto-Sync starten"

  if pgrep -f "auto-sync.ps1|auto-sync.sh" >/dev/null 2>&1; then
    ok "Auto-Sync laeuft bereits"
    return
  fi

  if command -v pwsh >/dev/null 2>&1; then
    nohup pwsh -NoProfile -File "$SCRIPT_DIR/auto-sync.ps1" -WatchPath "$SCRIPT_DIR/data" -Push > "$SCRIPT_DIR/auto-sync.log" 2>&1 &
  else
    chmod +x "$SCRIPT_DIR/auto-sync.sh"
    PUSH=1 nohup "$SCRIPT_DIR/auto-sync.sh" data > "$SCRIPT_DIR/auto-sync.log" 2>&1 &
  fi

  ok "Auto-Sync wurde gestartet (PID: $!)"
  info "Logdatei: $SCRIPT_DIR/auto-sync.log"
}

start_ui() {
  if ! command -v pwsh >/dev/null 2>&1; then
    info "UI braucht PowerShell 7 auf macOS/Linux. Auto-Sync laeuft trotzdem."
    return
  fi

  if pgrep -f "vault-ui.ps1" >/dev/null 2>&1; then
    ok "UI laeuft bereits auf http://localhost:8765"
  else
    nohup pwsh -NoProfile -File "$SCRIPT_DIR/vault-ui.ps1" > "$SCRIPT_DIR/vault-ui.log" 2>&1 &
    ok "UI gestartet: http://localhost:8765"
  fi

  if command -v open >/dev/null 2>&1; then open "http://localhost:8765"; fi
  if command -v xdg-open >/dev/null 2>&1; then xdg-open "http://localhost:8765" >/dev/null 2>&1 || true; fi
}

echo "========================================"
echo "MyLiteratureVault Quickstart"
echo "========================================"

create_env_file
pull_remote_updates
ensure_docker_installed
start_docker
start_webdav
start_auto_sync
start_ui

echo ""
echo "Fertig. Zotero kann jetzt WebDAV verwenden:"
echo "  URL:      http://localhost:8080"
echo "  Benutzer: zotero"
echo "  Passwort: changeme123"
echo ""
echo "In Zotero: Einstellungen -> Sync -> Datei-Sync -> WebDAV -> Server pruefen."
echo "Alle Aenderungen unter ./data werden automatisch committed und gepusht."
echo "UI: http://localhost:8765"
