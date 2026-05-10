#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

WATCH_PATH="${1:-data}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-5}"
DEBOUNCE_SECONDS="${DEBOUNCE_SECONDS:-10}"
PUSH="${PUSH:-1}"
LOG_FILE="$SCRIPT_DIR/.sync-log.json"

# ── Logging ──────────────────────────────────────────────────────────

_log() {
  printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$1"
}

# Append entry to .sync-log.json using Python3 (matches auto-sync.ps1 format)
_append_json_log() {
  local level="$1"
  local text="$2"
  command -v python3 >/dev/null 2>&1 || return 0
  local ts
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  local existing="[]"
  [ -f "$LOG_FILE" ] && existing="$(cat "$LOG_FILE" 2>/dev/null || echo '[]')"
  python3 - "$existing" "$ts" "$level" "$text" <<'PYEOF' > "$LOG_FILE" 2>/dev/null || true
import json, sys
try:    entries = json.loads(sys.argv[1])
except Exception:
    entries = []
entries.append({"ts": sys.argv[2], "level": sys.argv[3], "text": sys.argv[4]})
if len(entries) > 300:
    entries = entries[-300:]
print(json.dumps(entries, ensure_ascii=False))
PYEOF
}

log_ok()   { _log "$1"; _append_json_log "ok"    "$1"; }
log_info() { _log "$1"; _append_json_log "info"  "$1"; }
log_warn() { _log "$1"; _append_json_log "warn"  "$1"; }
log_err()  { _log "$1"; _append_json_log "error" "$1"; }

# ── Env + Git ────────────────────────────────────────────────────────

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

ensure_git_identity() {
  if ! git config user.name >/dev/null 2>&1 && [ -n "${GITHUB_USERNAME:-}" ]; then
    git config user.name "$GITHUB_USERNAME"
  fi
  if ! git config user.email >/dev/null 2>&1 && [ -n "${GITHUB_EMAIL:-}" ]; then
    git config user.email "$GITHUB_EMAIL"
  fi
}

git_remote() {
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    local b64
    b64="$(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 | tr -d '\n')"
    git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $b64" "$@"
  else
    git "$@"
  fi
}

branch_has_unpushed_commits() {
  git status -sb 2>/dev/null | grep -Eq '\[ahead [0-9]+'
}

# ── Push ─────────────────────────────────────────────────────────────

push_current_branch() {
  [ "$PUSH" = "1" ] || return 0
  if git_remote push 2>/dev/null || git_remote push -u origin HEAD 2>/dev/null; then
    log_ok "Push zu GitHub erfolgreich."
  else
    log_warn "Push fehlgeschlagen. GitHub-Anmeldung oder Remote pruefen."
  fi
}

# ── Pull ─────────────────────────────────────────────────────────────

pull_remote_updates() {
  log_info "Pruefe GitHub auf neuere Commits..."
  if ! git_remote fetch --prune 2>/dev/null; then
    log_warn "Fetch fehlgeschlagen. Arbeite lokal weiter."
    return 0
  fi

  if [ -n "$(git status --porcelain)" ]; then
    log_info "Pull uebersprungen (lokale Aenderungen vorhanden)."
    return 0
  fi

  if git_remote pull --ff-only 2>/dev/null; then
    log_ok "Remote-Stand ist aktuell oder wurde gepulled."
  else
    log_warn "Pull fehlgeschlagen. Bitte git status pruefen."
  fi
}

# ── Sync ─────────────────────────────────────────────────────────────

sync_changes() {
  if [ -z "$(git status --porcelain -- "$WATCH_PATH")" ]; then
    return 0
  fi

  log_info "Aenderungen gefunden. Commit wird vorbereitet..."
  git add -A -- "$WATCH_PATH"

  if git diff --cached --quiet -- "$WATCH_PATH"; then
    log_info "Keine commitbaren Aenderungen nach git add."
    return 0
  fi

  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  if git commit -m "Auto-sync Zotero WebDAV data [$ts]" 2>/dev/null; then
    log_ok "Commit erstellt."
    push_current_branch
  else
    log_err "Commit fehlgeschlagen. Bitte Git-Konfiguration pruefen."
  fi
}

# ── Main loop ────────────────────────────────────────────────────────

mkdir -p "$WATCH_PATH"
load_env
ensure_git_identity
pull_remote_updates

log_ok  "Auto-Sync startet."
log_info "Ueberwache: $WATCH_PATH"
log_info "Intervall: ${INTERVAL_SECONDS}s, Ruhezeit vor Commit: ${DEBOUNCE_SECONDS}s"
log_info "Push nach GitHub: $PUSH"

last_status=""
last_change_at="$(date +%s)"
last_push_attempt=0

while true; do
  current_status="$(git status --porcelain -- "$WATCH_PATH" 2>/dev/null)"
  now="$(date +%s)"

  if [ "$current_status" != "$last_status" ]; then
    last_status="$current_status"
    last_change_at="$now"
    if [ -n "$current_status" ]; then
      log_info "Zotero-Daten wurden geaendert. Warte auf weitere Schreibvorgaenge..."
    fi
  fi

  idle=$(( now - last_change_at ))
  if [ -n "$current_status" ] && [ "$idle" -ge "$DEBOUNCE_SECONDS" ]; then
    sync_changes
    last_status="$(git status --porcelain -- "$WATCH_PATH" 2>/dev/null)"
    last_change_at="$(date +%s)"
  elif [ -z "$current_status" ] && \
       [ "$PUSH" = "1" ] && \
       [ $(( now - last_push_attempt )) -ge 60 ] && \
       branch_has_unpushed_commits; then
    log_info "Lokale Commits noch nicht auf GitHub. Push wird erneut versucht..."
    last_push_attempt="$now"
    push_current_branch
    last_change_at="$(date +%s)"
  fi

  sleep "$INTERVAL_SECONDS"
done
