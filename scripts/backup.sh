#!/usr/bin/env bash
#
# backup.sh — Snapshot the SQLite database and mirror uploaded photos.
#
# Usage:
#   ./scripts/backup.sh              # uses defaults
#   BACKUP_DIR=~/my-backups KEEP=10 ./scripts/backup.sh
#   DATABASE_PATH=/path/to/fineshyt.db ./scripts/backup.sh
#
# Backups land in ~/.fineshyt-backups/<timestamp>/:
#   fineshyt.db.gz   — online sqlite3 .backup (WAL-safe), gzipped
#   uploads/         — rsync mirror of priv/static/uploads
#
# A "latest" symlink always points to the most recent backup.
# Older backups beyond $KEEP (default 5) are pruned automatically.
#
# Automated daily runs: see scripts/com.fineshyt.backup.plist
# ──────────────────────────────────────────────────────────────

set -euo pipefail

# ── Config ──────────────────────────────────────────────────
BACKUP_DIR="${BACKUP_DIR:-$HOME/.fineshyt-backups}"
KEEP="${KEEP:-5}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
UPLOADS_DIR="$PROJECT_DIR/orchestrator/priv/static/uploads"
# Matches the path the Makefile c2 target and the Tauri shell pass as
# DATABASE_PATH. Override DATABASE_PATH to back up a db elsewhere (e.g. the
# packaged build's per-user data dir).
DB_FILE="${DATABASE_PATH:-$PROJECT_DIR/orchestrator/priv/fineshyt.db}"
TIMESTAMP="$(date +%Y-%m-%dT%H:%M:%S)"
DEST="$BACKUP_DIR/$TIMESTAMP"

# ── Preflight ───────────────────────────────────────────────
if [ ! -f "$DB_FILE" ]; then
  echo "ERROR: SQLite database not found at $DB_FILE"
  echo "       Set DATABASE_PATH or run the app once to create it."
  exit 1
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "ERROR: sqlite3 CLI not found. Install it (macOS: it's preinstalled; apt: sqlite3)."
  exit 1
fi

mkdir -p "$DEST"

# ── Database snapshot ───────────────────────────────────────
# `.backup` takes a consistent online copy even while the app holds the db
# open in WAL mode, so we don't have to stop the server to back up.
echo "[$TIMESTAMP] Snapshotting $(basename "$DB_FILE") …"
sqlite3 "$DB_FILE" ".backup '$DEST/fineshyt.db'"
gzip "$DEST/fineshyt.db"

DUMP_SIZE=$(du -h "$DEST/fineshyt.db.gz" | cut -f1)
echo "  → $DEST/fineshyt.db.gz ($DUMP_SIZE)"

# ── Uploads mirror ──────────────────────────────────────────
if [ -d "$UPLOADS_DIR" ]; then
  echo "[$TIMESTAMP] Syncing uploads …"
  rsync -a --delete "$UPLOADS_DIR/" "$DEST/uploads/"
  UPLOAD_COUNT=$(find "$DEST/uploads" -type f | wc -l | tr -d ' ')
  echo "  → $DEST/uploads/ ($UPLOAD_COUNT files)"
else
  echo "  ⚠ Uploads directory not found at $UPLOADS_DIR — skipping"
fi

# ── Update "latest" symlink ─────────────────────────────────
ln -sfn "$DEST" "$BACKUP_DIR/latest"

# ── Prune old backups ───────────────────────────────────────
# List timestamp dirs (YYYY-MM-DDTHH:MM:SS), sorted oldest-first, skip the
# newest $KEEP entries, and remove the rest.
PRUNED=0
ALL_BACKUPS=()
while IFS= read -r d; do
  ALL_BACKUPS+=("$(basename "$d")")
done < <(ls -1d "$BACKUP_DIR"/????-??-??T??:??:?? 2>/dev/null | sort)

TOTAL=${#ALL_BACKUPS[@]}
if [ "$TOTAL" -gt "$KEEP" ]; then
  TO_PRUNE=$((TOTAL - KEEP))
  for (( i=0; i<TO_PRUNE; i++ )); do
    rm -rf "$BACKUP_DIR/${ALL_BACKUPS[$i]}"
    PRUNED=$((PRUNED + 1))
  done
fi

# ── Summary ─────────────────────────────────────────────────
echo ""
echo "Backup complete: $DEST"
[ "$PRUNED" -gt 0 ] && echo "Pruned $PRUNED old backup(s) (keeping $KEEP)."
echo "Restore with:    ./scripts/restore.sh $TIMESTAMP"
