#!/usr/bin/env bash
#
# restore.sh — Restore the database and uploads from a backup.
#
# Usage:
#   ./scripts/restore.sh                     # restore from "latest"
#   ./scripts/restore.sh 2026-04-12T14:30:00 # restore a specific snapshot
#
# What it does:
#   1. Drops and recreates the photo_curator_dev database
#   2. Restores the pg_dump from the chosen backup
#   3. Rsyncs the uploads back into priv/static/uploads
#   4. Runs mix ecto.migrate to apply any migrations newer than the dump
#
# ──────────────────────────────────────────────────────────────

set -euo pipefail

# ── Config ──────────────────────────────────────────────────
BACKUP_DIR="${BACKUP_DIR:-$HOME/.fineshyt-backups}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
UPLOADS_DIR="$PROJECT_DIR/orchestrator/priv/static/uploads"
DB_NAME="photo_curator_dev"
DB_USER="postgres"
COMPOSE_SERVICE="db"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"

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

DUMP_FILE="$RESTORE_DIR/$DB_NAME.sql.gz"

if [ ! -f "$DUMP_FILE" ]; then
  echo "ERROR: Dump file not found: $DUMP_FILE"
  echo ""
  echo "Available backups:"
  ls -1d "$BACKUP_DIR"/????-??-??T??:??:?? 2>/dev/null | xargs -n1 basename || echo "  (none)"
  exit 1
fi

# ── Preflight ───────────────────────────────────────────────
if ! docker compose -f "$COMPOSE_FILE" ps --status running "$COMPOSE_SERVICE" 2>/dev/null | grep -q "$COMPOSE_SERVICE"; then
  echo "ERROR: Docker service '$COMPOSE_SERVICE' is not running."
  echo "       Start it with: docker compose up -d"
  exit 1
fi

echo "Restoring from: $RESTORE_DIR"
echo ""
echo "  This will DROP and recreate the '$DB_NAME' database."
echo "  Uploads in priv/static/uploads/ will be overwritten."
echo ""
read -r -p "Continue? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

# ── Drop and recreate database ──────────────────────────────
echo ""
echo "Dropping $DB_NAME …"
docker compose -f "$COMPOSE_FILE" exec -T "$COMPOSE_SERVICE" \
  psql -U "$DB_USER" -c "
    SELECT pg_terminate_backend(pid)
    FROM pg_stat_activity
    WHERE datname = '$DB_NAME' AND pid <> pg_backend_pid();
  " > /dev/null 2>&1 || true

docker compose -f "$COMPOSE_FILE" exec -T "$COMPOSE_SERVICE" \
  dropdb -U "$DB_USER" --if-exists "$DB_NAME"

docker compose -f "$COMPOSE_FILE" exec -T "$COMPOSE_SERVICE" \
  createdb -U "$DB_USER" "$DB_NAME"

# ── Restore dump ────────────────────────────────────────────
echo "Restoring database from $DUMP_FILE …"
gunzip -c "$DUMP_FILE" \
  | docker compose -f "$COMPOSE_FILE" exec -T "$COMPOSE_SERVICE" \
      psql -U "$DB_USER" -d "$DB_NAME" --quiet --single-transaction

ROW_COUNT=$(docker compose -f "$COMPOSE_FILE" exec -T "$COMPOSE_SERVICE" \
  psql -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT count(*) FROM photos;" 2>/dev/null | tr -d ' ')
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
mix ecto.migrate
echo ""
echo "Restore complete from snapshot: $SNAPSHOT"
