#!/bin/sh
# boot.sh — keep Hermes' home (/data/.hermes: chat sessions, memory, learned
# skills, config, cron jobs, kanban, state DBs) across Render Free resets.
#
# Render Free wipes the filesystem on every restart / spin-down / redeploy.
# This script:
#   1. restores /data/.hermes from a PRIVATE GitHub repo before hermes starts
#   2. pushes a fresh backup every HERMES_STATE_BACKUP_INTERVAL seconds (default 600)
#
# Required env:  GH_STATE_REPO=owner/repo   GH_TOKEN=<fine-grained PAT, Contents R/W>
# Optional env:  GH_STATE_CLONE_URL=<full clone url (overrides GH_STATE_REPO)>
#                HERMES_STATE_BACKUP_INTERVAL=<seconds, default 600>
set -u

STATE_REPO="${GH_STATE_REPO:-}"
STATE_TOKEN="${GH_TOKEN:-}"
CLONE_URL="${GH_STATE_CLONE_URL:-}"
INTERVAL="${HERMES_STATE_BACKUP_INTERVAL:-600}"
STATE_DIR="${STATE_DIR:-/tmp/hermes-state}"
HERMES_HOME_DIR="${HERMES_HOME:-/data/.hermes}"
ENTRYPOINT_CMD="${ENTRYPOINT_CMD:-/app/scripts/entrypoint.sh}"

export GIT_TERMINAL_PROMPT=0

log() { echo "[hermes-state] $*"; }

[ -n "$STATE_REPO" ] && [ -z "$CLONE_URL" ] \
  && CLONE_URL="https://x-access-token:*** $STATE_REPO}.git"

# Make sure $STATE_DIR is a git clone of the state repo (retried every cycle,
# so a transient network failure on boot never disables backups permanently).
ensure_repo() {
  [ -d "$STATE_DIR/.git" ] && return 0
  rm -rf "$STATE_DIR"
  mkdir -p "$STATE_DIR"
  git -C "$STATE_DIR" init -q || return 1
  git -C "$STATE_DIR" remote add origin "$CLONE_URL" || return 1
  git -C "$STATE_DIR" fetch -q --depth 1 origin 2>/dev/null || true
  git -C "$STATE_DIR" checkout -q -B main FETCH_HEAD 2>/dev/null \
    || git -C "$STATE_DIR" checkout -q -B main 2>/dev/null \
    || true
  return 0
}

# Consistent snapshot of every live SQLite file (never tar a file SQLite is
# writing — a torn copy fails the integrity check and is discarded on restore).
snapshot_dbs() {
  find "$HERMES_HOME_DIR" -type f -name '*.db' 2>/dev/null | while IFS= read -r db; do
    python3 -c 'import sqlite3,sys; s=sqlite3.connect(sys.argv[1]); d=sqlite3.connect(sys.argv[2]); s.backup(d); d.close()' \
      "$db" "$db.snap" >/dev/null 2>&1 || rm -f "$db.snap"
  done
}

restore_dbs() {
  find "$HERMES_HOME_DIR" -type f -name '*.db.snap' 2>/dev/null | while IFS= read -r snap; do
    base=$(printf '%s' "$snap" | sed 's/\.snap$//')
    rm -f "$base-wal" "$base-shm"
    mv -f "$snap" "$base"
  done
}

restore_state() {
  if [ -z "$CLONE_URL" ]; then
    log "GH_STATE_REPO/GH_TOKEN not set — running WITHOUT persistence"
    return 0
  fi
  if ! ensure_repo; then
    log "could not reach state repo — starting fresh (backup will retry)"
    return 0
  fi
  if [ ! -f "$STATE_DIR/data.tar.gz" ]; then
    log "no backup in state repo yet — starting fresh"
    return 0
  fi
  # relative -f path: avoids GNU tar treating a "drive:" prefix as a remote host
  mkdir -p "$HERMES_HOME_DIR"
  if ! ( cd "$STATE_DIR" && tar -xzf data.tar.gz -C "$HERMES_HOME_DIR" ) 2>/dev/null; then
    log "restore failed — starting fresh"
    return 0
  fi
  restore_dbs
  log "hermes state restored — sessions, memory and skills kept"
}

backup_cycle() {
  [ -n "$CLONE_URL" ] || return 0
  ensure_repo || return 0

  snapshot_dbs

  # archive written INSIDE $STATE_DIR via relative path (see restore note above)
  ( cd "$STATE_DIR" && tar -czf data.tar.gz \
      --exclude='logs' --exclude='cache' --exclude='__pycache__' \
      --exclude='*.sock' --exclude='*.log' --exclude='browser' \
      --exclude='*.db' --exclude='*.db-wal' --exclude='*.db-shm' \
      --exclude='*/*.db' --exclude='*/*.db-wal' --exclude='*/*.db-shm' \
      --exclude='*/*/*.db' --exclude='*/*/*.db-wal' --exclude='*/*/*.db-shm' \
      -C "$HERMES_HOME_DIR" . ) 2>/dev/null || return 0

  git -C "$STATE_DIR" add -A 2>/dev/null || return 0
  if git -C "$STATE_DIR" diff --cached --quiet 2>/dev/null; then
    return 0
  fi
  TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  git -C "$STATE_DIR" -c user.email=boot@hermes.local -c user.name=hermes-boot \
    commit -qm "state $TS" || return 0
  if git -C "$STATE_DIR" push -q origin HEAD:main 2>/dev/null; then
    log "backup pushed ($TS)"
    return 0
  fi
  git -C "$STATE_DIR" pull --rebase -q origin main 2>/dev/null || true
  if git -C "$STATE_DIR" push -q origin HEAD:main 2>/dev/null; then
    log "backup pushed after rebase ($TS)"
  else
    log "push failed — will retry next cycle"
  fi
}

# ---- boot ------------------------------------------------------------------
restore_state

(
  while sleep "$INTERVAL"; do
    backup_cycle
  done
) &

exec sh -c "$ENTRYPOINT_CMD"
