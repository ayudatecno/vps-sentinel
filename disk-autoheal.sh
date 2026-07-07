#!/bin/bash
# disk-autoheal.sh — safe automatic disk cleanup for Docker hosts.
#
# Part of vps-sentinel: https://github.com/ayudatecno/vps-sentinel
#
# Frees space from the usual suspects WITHOUT touching anything stateful:
#   1. Dangling Docker images (old registry deploy layers — the #1 culprit;
#      first run on a busy CI/CD host freed ~59GB). Tagged images (:latest,
#      :dev, etc.) are never touched; rollback is always possible by re-pulling.
#   2. Docker build cache
#   3. systemd journal (vacuum to 500M / 14 days)
#   4. Rotated logs older than 14 days (/var/log/*.gz, *.1, *.old)
#   5. Oversized container json-logs (>500M → truncate, containers keep running)
#   6. Orphaned backup tmpdirs in /tmp older than 6h
#   7. apt cache
#
# NEVER touches: docker volumes, running containers, app data, uploads, DB data.
#
# Called automatically by infra-monitor.sh check_disk (above the warning
# threshold), or manually / from your own scripts. Sends a Telegram report of
# what was freed, per category.
#
# Cooldown: skips if it already ran in the last 6h (state file), unless --force.
#
# Usage:
#   disk-autoheal.sh [--force] [--trigger "reason shown in the report"]

set -u

ENV_FILE="${SENTINEL_ENV:-/etc/vps-sentinel.env}"
STATE_FILE="${DISK_AUTOHEAL_STATE:-/var/lib/vps-sentinel/disk-autoheal.last}"
LOCK_FILE="/tmp/disk-autoheal.lock"
LOG_FILE="${DISK_AUTOHEAL_LOG:-/var/log/disk-autoheal.log}"
COOLDOWN_SEC=$((6 * 3600))

FORCE=0
TRIGGER="manual"
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    --trigger) shift; TRIGGER="${1:-manual}" ;;
  esac
  shift
done

mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || LOG_FILE=/dev/null
log() { echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*" >> "$LOG_FILE"; }

# ── Telegram creds (shared sentinel env; reporting is optional) ───────────
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
TG_CHATS="${TELEGRAM_ADMIN_CHAT_IDS:-}"
NODE_NAME="${NODE_NAME:-$(hostname)}"

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

# ── Cooldown + lock ───────────────────────────────────────────────────────
if [ "$FORCE" -ne 1 ] && [ -f "$STATE_FILE" ]; then
  last=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
  now=$(date +%s)
  if [ $((now - last)) -lt "$COOLDOWN_SEC" ]; then
    log "skip: ran $(( (now - last) / 60 ))min ago (cooldown 6h). Use --force to override."
    echo "disk-autoheal: skipped (cooldown). Use --force." >&2
    exit 0
  fi
fi
if ! mkdir "$LOCK_FILE" 2>/dev/null; then
  log "skip: already running (lock $LOCK_FILE)"
  exit 0
fi
trap 'rmdir "$LOCK_FILE" 2>/dev/null' EXIT
date +%s > "$STATE_FILE" 2>/dev/null || true

# ── Measurement helpers ───────────────────────────────────────────────────
avail_kb() { df / --output=avail | tail -1 | tr -d ' '; }
pct_used() { df / --output=pcent | tail -1 | tr -d ' %'; }
human() {  # KB → human
  local kb=$1
  if [ "$kb" -ge 1048576 ]; then awk "BEGIN{printf \"%.1fG\", $kb/1048576}";
  elif [ "$kb" -ge 1024 ]; then awk "BEGIN{printf \"%.0fM\", $kb/1024}";
  else echo "${kb}K"; fi
}

PCT_BEFORE=$(pct_used)
KB_BEFORE=$(avail_kb)
log "=== auto-heal start (trigger: $TRIGGER, disk ${PCT_BEFORE}%) ==="

REPORT=""
step() {  # step "label" cmd...
  local label="$1"; shift
  local before; before=$(avail_kb)
  "$@" >> "$LOG_FILE" 2>&1 || log "step '$label' exited non-zero (continuing)"
  sync
  local after; after=$(avail_kb)
  local freed=$((after - before))
  [ "$freed" -lt 0 ] && freed=0
  REPORT="${REPORT}• ${label}: $(human $freed)
"
  log "step '$label' freed $(human $freed)"
}

# Cross-distro helpers: skip cleanly on hosts that don't have the tool, instead
# of emitting a scary "exited non-zero" for every non-Debian / non-systemd box.
clean_journal() {
  command -v journalctl >/dev/null 2>&1 || { echo "journalctl not present — skipping"; return 0; }
  journalctl --vacuum-size=500M --vacuum-time=14d
}
clean_pkg_cache() {
  if   command -v apt-get >/dev/null 2>&1; then apt-get clean
  elif command -v dnf     >/dev/null 2>&1; then dnf clean all
  elif command -v yum     >/dev/null 2>&1; then yum clean all
  elif command -v apk     >/dev/null 2>&1; then rm -rf /var/cache/apk/*
  elif command -v pacman  >/dev/null 2>&1; then pacman -Scc --noconfirm
  else echo "no known package manager — skipping"; fi
}

step "Dangling Docker images"        docker image prune -f
step "Docker build cache"            docker builder prune -af
step "System journal"                clean_journal
step "Rotated logs (>14d)"           find /var/log -type f \( -name "*.gz" -o -name "*.[0-9]" -o -name "*.old" \) -mtime +14 -delete
step "Container logs (>500M)"        bash -c 'find /var/lib/docker/containers -name "*-json.log" -size +500M -exec truncate -s 0 {} \; 2>/dev/null || true'
step "Orphaned backup tmpdirs"       bash -c 'find /tmp -maxdepth 1 -type d -name "backup-*" -mmin +360 -exec rm -rf {} + 2>/dev/null || true'
step "Package cache"                 clean_pkg_cache

PCT_AFTER=$(pct_used)
KB_AFTER=$(avail_kb)
TOTAL_FREED=$((KB_AFTER - KB_BEFORE)); [ "$TOTAL_FREED" -lt 0 ] && TOTAL_FREED=0
FREE_HUMAN=$(df -h / | awk 'NR==2 {print $4}')

log "=== auto-heal done: ${PCT_BEFORE}% → ${PCT_AFTER}% (freed $(human $TOTAL_FREED)) ==="

tg_send "🧹 <b>Disk auto-heal — ${NODE_NAME}</b>
Trigger: ${TRIGGER}

${REPORT}
<b>Disk: ${PCT_BEFORE}% → ${PCT_AFTER}%</b> (${FREE_HUMAN} free, $(human $TOTAL_FREED) freed)"

# Escalate if cleanup wasn't enough
if [ "$PCT_AFTER" -ge 85 ]; then
  tg_send "🚨 <b>Disk still at ${PCT_AFTER}% on ${NODE_NAME} after auto-heal</b>
Automatic cleanup was not enough — manual intervention needed.
Top consumers:
<pre>$(du -xh --max-depth=2 /var/lib 2>/dev/null | sort -rh | head -6)</pre>"
fi

exit 0
