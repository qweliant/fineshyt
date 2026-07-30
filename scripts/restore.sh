#!/usr/bin/env bash
#
# restore.sh — Restore the SQLite database and uploads from a backup.
#
# Usage:
#   ./scripts/restore.sh                     # restore from "latest"
#   ./scripts/restore.sh 2026-04-12T14:30:00 # restore a specific snapshot
#
# What it does:
#   1. Replaces the SQLite database file with the chosen snapshot
#   2. Rsyncs the uploads back into priv/static/uploads
#   3. Runs mix ecto.migrate to apply any migrations newer than the snapshot
#
# IMPORTANT: stop the app (close the desktop window, or Ctrl-C `make dev`)
# before restoring so nothing is writing to the db file.
# ──────────────────────────────────────────────────────────────

set -euo pipefail

# ── Config ──────────────────────────────────────────────────
BACKUP_DIR="${BACKUP_DIR:-$HOME/.fineshyt-backups}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
UPLOADS_DIR="$PROJECT_DIR/orchestrator/priv/static/uploads"
DB_FILE="${DATABASE_PATH:-$PROJECT_DIR/orchestrator/priv/fineshyt.db}"

# ── Resolve backup to restore ──────────────────────────────
if [ -n "${1:-}" ]; then
  SNAPSHOT="$1"
  RESTORE_DIR="$BACKUP_DIR/$SNAPSHOT"
else
  if [ -L "$BACKUP_DIR/latest" ]; then
    RESTORE_DIR="$(readlink "$BACKUP_DIR/latest")"
    SNAPSHOT="$(basename "$RESTORE_DIR")"
  else
    echo "ERROR: No backup specified and no 'latest' symlink found."
    echo "Usage: $0 [TIMESTAMP]"
    echo ""
    echo "Available backups:"
    ls -1d "$BACKUP_DIR"/????-??-??T??:??:?? 2>/dev/null | xargs -n1 basename || echo "  (none)"
    exit 1
  fi
fi

DUMP_FILE="$RESTORE_DIR/fineshyt.db.gz"

if [ ! -f "$DUMP_FILE" ]; then
  echo "ERROR: Snapshot db not found: $DUMP_FILE"
  echo ""
  echo "Available backups:"
  ls -1d "$BACKUP_DIR"/????-??-??T??:??:?? 2>/dev/null | xargs -n1 basename || echo "  (none)"
  exit 1
fi

echo "Restoring from: $RESTORE_DIR"
echo ""
echo "  This will OVERWRITE the database at $DB_FILE."
echo "  Uploads in priv/static/uploads/ will be overwritten."
echo "  Make sure the app is stopped first."
echo ""
read -r -p "Continue? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

# ── Restore database ────────────────────────────────────────
# Remove any stale WAL/SHM sidecars so the restored db isn't shadowed by a
# leftover write-ahead log from the previous file.
echo ""
echo "Restoring database to $DB_FILE …"
mkdir -p "$(dirname "$DB_FILE")"
rm -f "$DB_FILE" "$DB_FILE-wal" "$DB_FILE-shm"
gunzip -c "$DUMP_FILE" > "$DB_FILE"

ROW_COUNT=$(sqlite3 "$DB_FILE" "SELECT count(*) FROM photos;" 2>/dev/null | tr -d ' ' || echo "?")
echo "  → $ROW_COUNT photo records restored"

# ── Restore uploads ─────────────────────────────────────────
if [ -d "$RESTORE_DIR/uploads" ]; then
  echo "Restoring uploads …"
  mkdir -p "$UPLOADS_DIR"
  rsync -a --delete "$RESTORE_DIR/uploads/" "$UPLOADS_DIR/"
  FILE_COUNT=$(find "$UPLOADS_DIR" -type f | wc -l | tr -d ' ')
  echo "  → $FILE_COUNT files restored to $UPLOADS_DIR"
else
  echo "  ⚠ No uploads directory in backup — skipping"
fi

# ── Run migrations ──────────────────────────────────────────
echo "Running migrations …"
cd "$PROJECT_DIR/orchestrator"
DATABASE_PATH="$DB_FILE" MIX_ENV=dev mix ecto.migrate
echo ""
echo "Restore complete from snapshot: $SNAPSHOT"
