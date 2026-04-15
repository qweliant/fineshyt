#!/usr/bin/env bash
#
# backup.sh — Dump the Postgres database and mirror uploaded photos.
#
# Usage:
#   ./scripts/backup.sh              # uses defaults
#   BACKUP_DIR=~/my-backups KEEP=10 ./scripts/backup.sh
#
# Backups land in ~/.fineshyt-backups/<timestamp>/:
#   photo_curator_dev.sql.gz   — full pg_dump (custom format, compressed)
#   uploads/                   — rsync mirror of priv/static/uploads
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
DB_NAME="photo_curator_dev"
DB_USER="postgres"
COMPOSE_SERVICE="db"
TIMESTAMP="$(date +%Y-%m-%dT%H:%M:%S)"
DEST="$BACKUP_DIR/$TIMESTAMP"

# ── Preflight ───────────────────────────────────────────────
if ! docker compose -f "$PROJECT_DIR/docker-compose.yml" ps --status running "$COMPOSE_SERVICE" 2>/dev/null | grep -q "$COMPOSE_SERVICE"; then
  echo "ERROR: Docker service '$COMPOSE_SERVICE' is not running."
  echo "       Start it with: docker compose up -d"
  exit 1
fi

mkdir -p "$DEST"

# ── Database dump ───────────────────────────────────────────
echo "[$TIMESTAMP] Dumping $DB_NAME …"
docker compose -f "$PROJECT_DIR/docker-compose.yml" exec -T "$COMPOSE_SERVICE" \
  pg_dump -U "$DB_USER" -d "$DB_NAME" --no-owner --no-acl \
  | gzip > "$DEST/$DB_NAME.sql.gz"

DUMP_SIZE=$(du -h "$DEST/$DB_NAME.sql.gz" | cut -f1)
echo "  → $DEST/$DB_NAME.sql.gz ($DUMP_SIZE)"

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
