#!/bin/bash
# install.sh — provisions vps-sentinel on the current node. Idempotent.
#
# What it does:
#   1. Copies the scripts to /opt/vps-sentinel/ + chmod +x
#   2. Creates /etc/vps-sentinel.env from sentinel.env.example if absent
#      (or keeps your existing one untouched)
#   3. Installs cron entries: 15-min check, daily digest, 5-min appwatch
#   4. Sends a one-off test message so you can confirm Telegram delivery
#
# Usage:
#   sudo bash install.sh [manager|worker] [node-display-name] [peer-host]
# Examples:
#   sudo bash install.sh manager vps-1 203.0.113.7
#   sudo bash install.sh worker  vps-2

set -euo pipefail

NODE_ROLE="${1:-manager}"
NODE_NAME="${2:-$(hostname)}"
PEER_HOST="${3:-}"

SRC_DIR="$(dirname "$(readlink -f "$0")")"
DEST_DIR="/opt/vps-sentinel"
ENV_FILE="/etc/vps-sentinel.env"
DIGEST_HOUR="${SENTINEL_DIGEST_HOUR:-8}"   # local server time

mkdir -p "$DEST_DIR" /var/lib/vps-sentinel/state
for f in infra-monitor.sh disk-autoheal.sh restore-drill.sh; do
  install -m 0750 "$SRC_DIR/$f" "$DEST_DIR/$f"
  echo "✓ installed $DEST_DIR/$f"
done

# ── Env file ──────────────────────────────────────────────────────────────
if [ -f "$ENV_FILE" ]; then
  echo "✓ $ENV_FILE already exists — keeping it (edit it to change settings)"
  # Refresh role/name/peer only if provided explicitly
  if [ $# -ge 1 ]; then
    sed -i -E "s|^NODE_ROLE=.*|NODE_ROLE=\"${NODE_ROLE}\"|; s|^NODE_NAME=.*|NODE_NAME=\"${NODE_NAME}\"|; s|^PEER_HOST=.*|PEER_HOST=\"${PEER_HOST}\"|" "$ENV_FILE" || true
  fi
else
  install -m 0600 "$SRC_DIR/sentinel.env.example" "$ENV_FILE"
  sed -i -E "s|^NODE_ROLE=.*|NODE_ROLE=\"${NODE_ROLE}\"|; s|^NODE_NAME=.*|NODE_NAME=\"${NODE_NAME}\"|; s|^PEER_HOST=.*|PEER_HOST=\"${PEER_HOST}\"|" "$ENV_FILE"
  echo "⚠ wrote $ENV_FILE from the example — EDIT IT NOW and set TELEGRAM_BOT_TOKEN + TELEGRAM_ADMIN_CHAT_IDS"
fi

# ── Cron ──────────────────────────────────────────────────────────────────
CRON_TAG="# vps-sentinel"
TMP=$(mktemp)
crontab -l 2>/dev/null | grep -v "$CRON_TAG" > "$TMP" || true
cat >> "$TMP" <<EOF
*/15 * * * * ${DEST_DIR}/infra-monitor.sh check ${CRON_TAG}
0 ${DIGEST_HOUR} * * * ${DEST_DIR}/infra-monitor.sh digest ${CRON_TAG}
*/5 * * * * ${DEST_DIR}/infra-monitor.sh appwatch ${CRON_TAG}
EOF
crontab "$TMP"
rm -f "$TMP"
echo "✓ cron installed (check every 15min, digest daily at ${DIGEST_HOUR}:00, appwatch every 5min)"
echo "  (restore-drill is opt-in — add your own entry, e.g.: 0 4 1 * * ${DEST_DIR}/restore-drill.sh >> /var/log/restore-drill.log 2>&1)"

# ── Test ──────────────────────────────────────────────────────────────────
echo
echo "→ sending test message via Telegram…"
"$DEST_DIR/infra-monitor.sh" test || echo "WARN: test send failed; check $ENV_FILE and bot token"
echo
echo "Done. Manual triggers:"
echo "  $DEST_DIR/infra-monitor.sh check     # real-time critical scan"
echo "  $DEST_DIR/infra-monitor.sh digest    # daily health digest"
echo "  $DEST_DIR/infra-monitor.sh appwatch  # hung-app watchdog tick"
echo "  $DEST_DIR/disk-autoheal.sh --force   # safe disk cleanup now"
echo "  $DEST_DIR/restore-drill.sh           # DR restore drill now"
