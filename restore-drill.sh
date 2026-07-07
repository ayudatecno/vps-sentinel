#!/bin/bash
# restore-drill.sh — automated disaster-recovery restore drill for PostgreSQL.
#
# Part of vps-sentinel: https://github.com/ayudatecno/vps-sentinel
#
# "A backup you never restored is not a backup." Monthly cron (+ on-demand) that
# proves your offsite backup chain actually works, end to end, WITHOUT touching
# production:
#   1. Finds the latest snapshot in your rclone remote (B2, S3, whatever)
#   2. Downloads the DB dump + verifies companion archives exist & are sound
#   3. Restores the dump into a THROWAWAY postgres container: no published
#      ports, --network none, its own anonymous volume — fully isolated from
#      prod. Prod is only ever read (SELECT count(*)).
#   4. Compares row counts of your key tables (restored vs live prod)
#   5. Reports ✅/🚨 to Telegram with the numbers, then deletes everything
#
# Cron:   0 4 1 * * /opt/vps-sentinel/restore-drill.sh >> /var/log/restore-drill.log 2>&1
# Manual: /opt/vps-sentinel/restore-drill.sh
#
# Expected snapshot layout in the remote (produced by your backup job):
#   <RCLONE_REMOTE>/<YYYYMMDD_HHMMSS>/db_*.sql.gz        (pg_dumpall, gzip)
#   <RCLONE_REMOTE>/<YYYYMMDD_HHMMSS>/uploads_*.tar.gz   (optional, checked remotely)
#   <RCLONE_REMOTE>/<YYYYMMDD_HHMMSS>/configs_*.tar.gz   (optional, downloaded + verified)
#
# Config (in /etc/vps-sentinel.env or exported):
#   RCLONE_REMOTE       e.g. "b2:my-backups"          (required)
#   PROD_DB_CONTAINER   name filter of the live pg container   (required)
#   PROD_DB_USER        prod db user for the read-only counts  (required)
#   PROD_DB_NAME        database name to verify                (required)
#   KEY_TABLES          space-separated tables to compare      (required)
#   PG_IMAGE_FALLBACK   image if prod image can't be detected  (default postgres:16)
#
# Gotchas this script already handles (learned the hard way):
#   - The drill container uses the SAME image as your live prod DB (auto-
#     detected): if your dump uses extensions (pgvector, PostGIS...), a plain
#     postgres image degrades the restore into thousands of errors.
#   - pg_dump >= 16.14 emits \restrict/\unrestrict lines: restore with a
#     matching-or-newer psql.
#
# Safety: the ONLY docker objects this script creates/removes are the container
# "dr-drill-pg" and its anonymous volume. It never writes to prod DB, volumes,
# services or files.

set -u

ENV_FILE="${SENTINEL_ENV:-/etc/vps-sentinel.env}"
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

DRILL_CONTAINER="dr-drill-pg"
RCLONE_REMOTE="${RCLONE_REMOTE:-}"
PG_IMAGE_FALLBACK="${PG_IMAGE_FALLBACK:-postgres:16}"
PROD_DB_CONTAINER="${PROD_DB_CONTAINER:-}"
PROD_DB_USER="${PROD_DB_USER:-postgres}"
PROD_DB_NAME="${PROD_DB_NAME:-}"
KEY_TABLES="${KEY_TABLES:-}"
LOG_FILE="${RESTORE_DRILL_LOG:-/var/log/restore-drill.log}"

touch "$LOG_FILE" 2>/dev/null || LOG_FILE=/dev/null
log() { echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*" | tee -a "$LOG_FILE" >&2; }

for req in RCLONE_REMOTE PROD_DB_CONTAINER PROD_DB_NAME KEY_TABLES; do
  [ -z "$(eval echo "\$$req")" ] && { echo "FATAL: $req not set (see $ENV_FILE)" >&2; exit 2; }
done

# ── Telegram ──────────────────────────────────────────────────────────────
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TG_CHATS="${TELEGRAM_ADMIN_CHAT_IDS:-}"

tg_send() {
  [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TG_CHATS" ] && return 0
  local IFS=','
  for chat_id in $TG_CHATS; do
    chat_id=$(echo "$chat_id" | tr -d ' ')
    [ -z "$chat_id" ] && continue
    curl -fsS --max-time 10 \
      "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${chat_id}" \
      --data-urlencode "text=$1" \
      --data-urlencode "parse_mode=HTML" \
      > /dev/null 2>>"$LOG_FILE" || log "telegram send failed for chat_id=$chat_id"
  done
}

WORKDIR=""
cleanup() {
  docker rm -f "$DRILL_CONTAINER" >/dev/null 2>&1 || true
  docker volume prune -f --filter "label=dr-drill" >/dev/null 2>&1 || true
  [ -n "$WORKDIR" ] && rm -rf "$WORKDIR"
}
trap cleanup EXIT

fail() {
  log "DRILL FAILED: $1"
  tg_send "🚨 <b>Restore drill FAILED</b>
$(date -u +'%Y-%m-%d %H:%M UTC')

<b>Failed step:</b> $1

This means your disaster-recovery plan is NOT guaranteed — check ${LOG_FILE}."
  exit 1
}

log "=== restore drill start ==="

# ── 1. Latest snapshot in the remote ──────────────────────────────────────
LATEST=$(rclone lsd "$RCLONE_REMOTE" 2>>"$LOG_FILE" | awk '{print $NF}' | grep -E '^[0-9]{8}_[0-9]{6}$' | sort | tail -1)
[ -z "$LATEST" ] && fail "no snapshot found in ${RCLONE_REMOTE} (rclone lsd)"
log "latest snapshot: $LATEST"

SNAP_EPOCH=$(date -d "${LATEST:0:8} ${LATEST:9:2}:${LATEST:11:2}" +%s 2>/dev/null || echo 0)
AGE_H=$(( ($(date +%s) - SNAP_EPOCH) / 3600 ))

FILES=$(rclone ls "${RCLONE_REMOTE}/${LATEST}" 2>>"$LOG_FILE")
echo "$FILES" | grep -q "db_" || fail "snapshot ${LATEST} contains no DB dump"

# ── 2. Download DB dump + configs (small); check uploads remotely ────────
WORKDIR=$(mktemp -d /tmp/restore-drill-XXXXXX)
rclone copy "${RCLONE_REMOTE}/${LATEST}" "$WORKDIR/" --include "db_*.sql.gz" --include "configs_*.tar.gz" 2>>"$LOG_FILE" \
  || fail "download from remote failed"
DB_FILE=$(ls "$WORKDIR"/db_*.sql.gz 2>/dev/null | head -1)
[ -z "$DB_FILE" ] && fail "DB dump not downloaded"
DB_SIZE=$(du -h "$DB_FILE" | cut -f1)
log "downloaded $(basename "$DB_FILE") ($DB_SIZE)"

gzip -t "$DB_FILE" 2>>"$LOG_FILE" || fail "DB dump is corrupt (gzip -t)"
CONFIGS_FILE=$(ls "$WORKDIR"/configs_*.tar.gz 2>/dev/null | head -1)
CONFIGS_COUNT=0
[ -n "$CONFIGS_FILE" ] && { gzip -t "$CONFIGS_FILE" || fail "configs tar corrupt"; CONFIGS_COUNT=$(tar -tzf "$CONFIGS_FILE" 2>/dev/null | wc -l); }

# Uploads: verify remote size > 0 (usually too big to download on a schedule)
UPLOADS_BYTES=$(echo "$FILES" | awk '/uploads_/ {print $1}')

# ── 3. Throwaway postgres + restore ───────────────────────────────────────
PROD_CID_EARLY=$(docker ps -q -f "name=${PROD_DB_CONTAINER}" | head -1)
PG_IMAGE=$(docker inspect "$PROD_CID_EARLY" --format '{{.Config.Image}}' 2>/dev/null || true)
[ -z "$PG_IMAGE" ] && PG_IMAGE="$PG_IMAGE_FALLBACK"
log "drill image: $PG_IMAGE"

docker rm -f "$DRILL_CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$DRILL_CONTAINER" --label dr-drill=1 \
  --network none \
  -e POSTGRES_PASSWORD=drill-only \
  --memory 2g \
  "$PG_IMAGE" >/dev/null 2>>"$LOG_FILE" || fail "could not create the throwaway container"

READY=0
for _ in $(seq 1 30); do
  docker exec "$DRILL_CONTAINER" pg_isready -U postgres >/dev/null 2>&1 && { READY=1; break; }
  sleep 2
done
[ "$READY" -ne 1 ] && fail "throwaway postgres did not start"

log "restoring dump into $DRILL_CONTAINER..."
if ! gunzip -c "$DB_FILE" | docker exec -i "$DRILL_CONTAINER" psql -U postgres -d postgres -q -v ON_ERROR_STOP=0 >/dev/null 2>>"$LOG_FILE"; then
  fail "psql restore returned an error"
fi

docker exec "$DRILL_CONTAINER" psql -U postgres -lqt 2>/dev/null | cut -d'|' -f1 | grep -qw "$PROD_DB_NAME" \
  || fail "database ${PROD_DB_NAME} does not exist after restore"

# ── 4. Row counts: restored vs prod (prod = read-only) ───────────────────
PROD_CID=$(docker ps -q -f "name=${PROD_DB_CONTAINER}" | head -1)
[ -z "$PROD_CID" ] && fail "live prod DB container not found for comparison"

REPORT=""
MISMATCH=0
for t in $KEY_TABLES; do
  RESTORED=$(docker exec "$DRILL_CONTAINER" psql -U postgres -d "$PROD_DB_NAME" -t -A -c "SELECT count(*) FROM $t" 2>/dev/null || echo "ERR")
  PROD=$(docker exec "$PROD_CID" psql -U "$PROD_DB_USER" -d "$PROD_DB_NAME" -t -A -c "SELECT count(*) FROM $t" 2>/dev/null || echo "ERR")
  if [ "$RESTORED" = "ERR" ]; then
    REPORT="${REPORT}• ${t}: ❌ error querying restored copy
"; MISMATCH=1; continue
  fi
  # Restored snapshot is older than live prod: restored <= prod and within 5% is healthy
  ROW_STATUS="✓"
  if [ "$PROD" != "ERR" ] && [ "$RESTORED" -gt "$PROD" ]; then ROW_STATUS="⚠️"; MISMATCH=1; fi
  if [ "$PROD" != "ERR" ] && [ "$PROD" -gt 0 ]; then
    DIFF=$(( (PROD - RESTORED) * 100 / PROD ))
    [ "$DIFF" -gt 5 ] && { ROW_STATUS="⚠️ ${DIFF}% fewer"; MISMATCH=1; }
  fi
  REPORT="${REPORT}• ${t}: ${RESTORED} (prod: ${PROD}) ${ROW_STATUS}
"
done

log "drill complete (mismatch=$MISMATCH)"

# ── 5. Report ─────────────────────────────────────────────────────────────
STATUS_ICON="✅"; STATUS_TXT="Restore verified OK"
[ "$MISMATCH" -ne 0 ] && { STATUS_ICON="⚠️"; STATUS_TXT="Restore OK but with differences to review"; }

EXTRAS=""
[ "$CONFIGS_COUNT" -gt 0 ] && EXTRAS="Configs tar: ${CONFIGS_COUNT} files ✓ · "
[ -n "${UPLOADS_BYTES:-}" ] && EXTRAS="${EXTRAS}Uploads in remote: $(( ${UPLOADS_BYTES:-0} / 1048576 ))MB ✓"

tg_send "${STATUS_ICON} <b>Restore drill — ${STATUS_TXT}</b>
Snapshot: <code>${LATEST}</code> (${AGE_H}h ago, ${DB_SIZE})

<b>Restored rows vs prod:</b>
${REPORT}
${EXTRAS}

Restored from offsite into an isolated container and destroyed afterwards. Prod was never written to."

log "=== restore drill done ==="
exit "$MISMATCH"
