#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

WATCH_PATH="${1:-data}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-5}"
DEBOUNCE_SECONDS="${DEBOUNCE_SECONDS:-10}"
PUSH="${PUSH:-1}"

log() {
  printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$1"
}

load_env() {
  [ -f ".env.local" ] || return 0
  while IFS='=' read -r key value; do
    case "$key" in
      ''|\#*) continue ;;
      *) export "$key=$value" ;;
    esac
  done < .env.local
}

ensure_git_identity() {
  if ! git config user.name >/dev/null && [ -n "${GITHUB_USERNAME:-}" ]; then
    git config user.name "$GITHUB_USERNAME"
  fi
  if ! git config user.email >/dev/null && [ -n "${GITHUB_EMAIL:-}" ]; then
    git config user.email "$GITHUB_EMAIL"
  fi
}

push_current_branch() {
  [ "$PUSH" = "1" ] || return 0
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    basic_auth="$(printf '%s:%s' "x-access-token" "$GITHUB_TOKEN" | base64 | tr -d '\n')"
    git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $basic_auth" push ||
      git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $basic_auth" push -u origin HEAD
  else
    git push || git push -u origin HEAD
  fi
  if [ "$?" -eq 0 ]; then
    log "Push zu GitHub erfolgreich."
  else
    log "Push fehlgeschlagen. GitHub-Anmeldung oder Remote pruefen."
  fi
}

git_remote() {
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    basic_auth="$(printf '%s:%s' "x-access-token" "$GITHUB_TOKEN" | base64 | tr -d '\n')"
    git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $basic_auth" "$@"
  else
    git "$@"
  fi
}

branch_has_unpushed_commits() {
  git status -sb | grep -Eq '\[ahead [0-9]+'
}

pull_remote_updates() {
  log "Pruefe GitHub auf neuere Commits..."
  if ! git_remote fetch --prune; then
    log "Fetch fehlgeschlagen. Arbeite lokal weiter."
    return 0
  fi

  if [ -n "$(git status --porcelain)" ]; then
    log "Pull uebersprungen, weil lokale Aenderungen vorhanden sind."
    return 0
  fi

  if git_remote pull --ff-only; then
    log "Remote-Stand ist aktuell oder wurde gepulled."
  else
    log "Pull fehlgeschlagen. Bitte Git-Status pruefen."
  fi
}

sync_changes() {
  if [ -z "$(git status --porcelain -- "$WATCH_PATH")" ]; then
    return 0
  fi

  log "Aenderungen gefunden. Commit wird vorbereitet..."
  git add -A -- "$WATCH_PATH"

  if git diff --cached --quiet -- "$WATCH_PATH"; then
    log "Keine commitbaren Aenderungen nach git add."
    return 0
  fi

  git commit -m "Auto-sync Zotero WebDAV data [$(date '+%Y-%m-%d %H:%M:%S')]"
  if [ "$?" -ne 0 ]; then
    log "Commit fehlgeschlagen. Bitte Git-Konfiguration pruefen."
    return 1
  fi

  push_current_branch
}

mkdir -p "$WATCH_PATH"
load_env
ensure_git_identity
pull_remote_updates

log "Auto-Sync startet."
log "Ueberwache: $WATCH_PATH"
log "Intervall: ${INTERVAL_SECONDS}s, Ruhezeit vor Commit: ${DEBOUNCE_SECONDS}s"

last_status=""
last_change_at="$(date +%s)"
last_push_attempt=0

while true; do
  current_status="$(git status --porcelain -- "$WATCH_PATH")"
  now="$(date +%s)"

  if [ "$current_status" != "$last_status" ]; then
    last_status="$current_status"
    last_change_at="$now"
    if [ -n "$current_status" ]; then
      log "Zotero-Daten wurden geaendert. Warte auf weitere Schreibvorgaenge..."
    fi
  fi

  if [ -n "$current_status" ] && [ $((now - last_change_at)) -ge "$DEBOUNCE_SECONDS" ]; then
    sync_changes
    last_status="$(git status --porcelain -- "$WATCH_PATH")"
    last_change_at="$(date +%s)"
  elif [ -z "$current_status" ] && [ "$PUSH" = "1" ] && [ $((now - last_push_attempt)) -ge 60 ] && branch_has_unpushed_commits; then
    log "Lokale Commits sind noch nicht auf GitHub. Push wird erneut versucht..."
    last_push_attempt="$now"
    push_current_branch
    last_change_at="$(date +%s)"
  fi

  sleep "$INTERVAL_SECONDS"
done
