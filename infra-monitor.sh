#!/bin/bash
# infra-monitor.sh — host-level Telegram health monitor for VPS / Docker Swarm nodes.
#
# Part of vps-sentinel: https://github.com/ayudatecno/vps-sentinel
#
# Runs on each node. Modes:
#   * check    — cron every 15min. Real-time critical alerts with cooldown.
#                Triggers: disk critical, swarm down, service below desired replicas,
#                backup stale (manager only), peer node SSH unreachable (manager only).
#   * digest   — cron daily. Full per-node health digest (disk/RAM/load/swarm/
#                services/backup freshness) sent to your Telegram DM.
#   * appwatch — cron every 5min (manager only). Detects a hung-but-alive app
#                (process running, health endpoint dead — the failure mode Swarm
#                cannot see) and performs ONE forced service restart, then
#                escalates to a human if that didn't help.
#   * test     — send a hello message and exit.
#
# Why a host-level shell script (vs. an in-app worker):
#   - Still alerts when your app is dead (the most important time).
#   - Zero dependencies beyond bash + curl + cron. Nothing to deploy or babysit.
#   - Each node observes itself and posts directly to Telegram.
#
# Env source: /etc/vps-sentinel.env (see sentinel.env.example).
#   Required: TELEGRAM_BOT_TOKEN, TELEGRAM_ADMIN_CHAT_IDS (CSV).
#   Optional: NODE_ROLE (manager|worker), NODE_NAME, PEER_HOST,
#             APP_SERVICE + APP_HEALTH_HOST (enables appwatch),
#             BACKUP_LOG (enables backup-freshness check),
#             DEPLOY_LOG (suppresses false alerts during rolling deploys).
#
# Usage:
#   infra-monitor.sh check
#   infra-monitor.sh digest
#   infra-monitor.sh appwatch
#   infra-monitor.sh test

set -u  # no -e: a single check failing must not abort the script

ENV_FILE="${SENTINEL_ENV:-/etc/vps-sentinel.env}"
STATE_DIR="${SENTINEL_STATE:-/var/lib/vps-sentinel/state}"
COOLDOWN_SEC="${SENTINEL_COOLDOWN:-3600}"  # 1h between repeats of the same alert
LOG_FILE="${SENTINEL_LOG:-/var/log/vps-sentinel.log}"
DISK_WARN_PCT="${SENTINEL_DISK_WARN:-85}"
DISK_CRIT_PCT="${SENTINEL_DISK_CRIT:-92}"

mkdir -p "$STATE_DIR"
touch "$LOG_FILE" 2>/dev/null || LOG_FILE=/dev/null

log() { echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*" >> "$LOG_FILE"; }

if [ ! -f "$ENV_FILE" ]; then
  log "FATAL: env file $ENV_FILE not found"
  echo "[vps-sentinel] missing $ENV_FILE — run install.sh first" >&2
  exit 2
fi

# shellcheck disable=SC1090
. "$ENV_FILE"

: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN missing}"
: "${TELEGRAM_ADMIN_CHAT_IDS:?TELEGRAM_ADMIN_CHAT_IDS missing}"
: "${NODE_NAME:=$(hostname)}"
: "${NODE_ROLE:=manager}"
: "${PEER_HOST:=}"
: "${APP_SERVICE:=}"
: "${APP_HEALTH_HOST:=}"
: "${APP_HEALTH_PATH:=/api/health}"
: "${BACKUP_LOG:=}"
: "${BACKUP_MAX_AGE_SEC:=28800}"   # 8h default (6h cron + 2h grace)
: "${BACKUP_OK_PATTERN:= Backup complete}"
: "${DEPLOY_LOG:=}"
: "${DEPLOY_GRACE_SEC:=300}"       # 5 min after last deploy log write

# ── Telegram send ─────────────────────────────────────────────────────────
tg_send() {
  local text="$1"
  local IFS=','
  for chat_id in $TELEGRAM_ADMIN_CHAT_IDS; do
    chat_id=$(echo "$chat_id" | tr -d ' ')
    [ -z "$chat_id" ] && continue
    curl -fsS --max-time 10 \
      "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${chat_id}" \
      --data-urlencode "text=${text}" \
      --data-urlencode "parse_mode=HTML" \
      --data-urlencode "disable_web_page_preview=true" \
      > /dev/null 2>>"$LOG_FILE" \
      || log "telegram send failed for chat_id=$chat_id"
  done
}

# ── Cooldown (real-time alerts only) ──────────────────────────────────────
should_alert() {
  local key="$1"
  local f="$STATE_DIR/$key"
  local now; now=$(date +%s)
  if [ -f "$f" ]; then
    local last; last=$(cat "$f")
    local diff=$((now - last))
    [ "$diff" -lt "$COOLDOWN_SEC" ] && return 1
  fi
  echo "$now" > "$f"
  return 0
}

clear_alert() { rm -f "$STATE_DIR/$1"; }

# True if a deploy started/finished within the grace window (rolling restart in
# progress). Your CI/CD should append a line to $DEPLOY_LOG at deploy start and
# finish — the file's mtime then tracks the last deploy activity. Returns false
# if unset/missing, so the checks behave normally except during an actual deploy.
recent_deploy() {
  [ -n "$DEPLOY_LOG" ] && [ -f "$DEPLOY_LOG" ] || return 1
  local mtime; mtime=$(stat -c %Y "$DEPLOY_LOG" 2>/dev/null || echo 0)
  [ "$mtime" -eq 0 ] && return 1
  [ $(( $(date +%s) - mtime )) -lt "$DEPLOY_GRACE_SEC" ]
}

alert() {
  local key="$1"
  local subject="$2"
  local body="$3"
  if should_alert "$key"; then
    tg_send "🚨 <b>${subject}</b>
<i>${NODE_NAME}</i> · $(date -u +'%Y-%m-%d %H:%M UTC')

${body}"
    log "ALERT $key: $subject"
  else
    log "ALERT $key suppressed (cooldown)"
  fi
}

# ── Per-check helpers ─────────────────────────────────────────────────────
check_disk() {
  local pct; pct=$(df / --output=pcent | tail -1 | tr -d ' %')
  # Auto-healing first: safe cleanup (old docker images, journal, rotated logs).
  # disk-autoheal.sh has its own 6h cooldown + lock and sends its own TG report,
  # so calling it on every tick is harmless. Re-measure before alerting.
  local autoheal; autoheal=$(dirname "$(readlink -f "$0")")/disk-autoheal.sh
  if [ "$pct" -gt "$DISK_WARN_PCT" ] && [ -x "$autoheal" ]; then
    "$autoheal" --trigger "infra-monitor: disk at ${pct}% on ${NODE_NAME}" >>"$LOG_FILE" 2>&1 || true
    pct=$(df / --output=pcent | tail -1 | tr -d ' %')
  fi
  if [ "$pct" -gt "$DISK_CRIT_PCT" ]; then
    alert "disk_critical_${NODE_NAME}" "Disk CRITICAL on ${NODE_NAME} (${pct}%)" \
      "Top consumers:
$(du -h --max-depth=2 / 2>/dev/null | sort -rh | head -8)

Docker df:
$(docker system df 2>/dev/null)"
  elif [ "$pct" -gt "$DISK_WARN_PCT" ]; then
    alert "disk_warning_${NODE_NAME}" "Disk WARNING on ${NODE_NAME} (${pct}%)" \
      "Currently at ${pct}%. Consider docker system prune -af."
  else
    clear_alert "disk_critical_${NODE_NAME}"
    clear_alert "disk_warning_${NODE_NAME}"
  fi
}

check_swarm_self() {
  local state; state=$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)
  [ "$state" = "inactive" ] && return 0  # not a swarm host — nothing to check
  if [ "$state" != "active" ]; then
    alert "swarm_local_down_${NODE_NAME}" "Swarm DOWN on ${NODE_NAME} (state=${state})" \
      "Local docker daemon reports swarm state '${state}', expected 'active'.

$(docker ps --format 'table {{.Names}}\t{{.Status}}' 2>/dev/null | head -20)"
  else
    clear_alert "swarm_local_down_${NODE_NAME}"
  fi
}

# Manager-only: validate every node is Ready, every service at desired replicas.
check_swarm_cluster() {
  [ "$NODE_ROLE" != "manager" ] && return 0
  docker node ls > /dev/null 2>&1 || return 0  # not a swarm manager
  # Any node not Ready
  local bad_nodes; bad_nodes=$(docker node ls --format '{{.Hostname}} {{.Status}} {{.Availability}}' 2>/dev/null | awk '$2!="Ready" || $3!="Active" {print}')
  if [ -n "$bad_nodes" ]; then
    alert "swarm_node_not_ready" "Swarm node not Ready" "$bad_nodes"
  else
    clear_alert "swarm_node_not_ready"
  fi
  # Any service below desired replicas
  local bad_svcs; bad_svcs=$(docker service ls --format '{{.Name}} {{.Mode}} {{.Replicas}}' 2>/dev/null \
    | awk '{ split($3,a,"/"); if (a[1]+0 < a[2]+0) print }')
  if [ -n "$bad_svcs" ]; then
    if recent_deploy; then
      log "service_replicas_short suppressed (deploy in progress, within ${DEPLOY_GRACE_SEC}s grace): $bad_svcs"
    else
      alert "service_replicas_short" "Service replicas below desired" "$bad_svcs"
    fi
  else
    clear_alert "service_replicas_short"
  fi
}

# Manager-only: backup ran recently. Enabled by setting BACKUP_LOG.
# A successful run must log a line containing $BACKUP_OK_PATTERN, prefixed with
# a [YYYY-MM-DD HH:MM:SS] timestamp.
check_backup() {
  [ "$NODE_ROLE" != "manager" ] && return 0
  [ -z "$BACKUP_LOG" ] && return 0
  if [ ! -f "$BACKUP_LOG" ]; then
    alert "backup_log_missing" "Backup log missing ($BACKUP_LOG)" "Expected your backup job to write to $BACKUP_LOG"
    return
  fi
  local last_complete; last_complete=$(grep -F "$BACKUP_OK_PATTERN" "$BACKUP_LOG" | tail -1)
  if [ -z "$last_complete" ]; then
    alert "backup_no_success" "No successful backup found in $BACKUP_LOG" "Last 5 lines:
$(tail -5 "$BACKUP_LOG")"
    return
  fi
  # Lines look like: [2026-05-06 00:02:19]  Backup complete
  local ts_str; ts_str=$(echo "$last_complete" | sed -E 's/^\[([0-9-]+ [0-9:]+)\].*/\1/')
  local ts; ts=$(date -d "$ts_str" +%s 2>/dev/null || echo 0)
  local age=$(( $(date +%s) - ts ))
  if [ "$age" -gt "$BACKUP_MAX_AGE_SEC" ]; then
    local hours=$(( age / 3600 ))
    alert "backup_stale" "Backup stale (${hours}h old)" "Last successful run: $ts_str"
  else
    clear_alert "backup_stale"
    clear_alert "backup_log_missing"
    clear_alert "backup_no_success"
  fi
}

# Manager-only: peer node ssh-reachable
check_peer() {
  [ "$NODE_ROLE" != "manager" ] && return 0
  [ -z "$PEER_HOST" ] && return 0
  if ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
       "root@${PEER_HOST}" "echo ok" > /dev/null 2>&1; then
    clear_alert "peer_unreachable"
  else
    alert "peer_unreachable" "Peer node ${PEER_HOST} unreachable via SSH" \
      "Tried: ssh -o ConnectTimeout=8 root@${PEER_HOST} echo ok — failed."
  fi
}

# ── App watchdog (manager only, own cron every 5min) ─────────────────────
# Swarm only restarts your app if the PROCESS dies. The common Node/Python/etc
# failure mode is a hung-but-alive app (blocked event loop, exhausted DB pool):
# the health endpoint times out while the container stays "running". This
# watchdog detects that and does ONE forced service restart, then escalates to
# a human if it didn't help.
#
#   - Local check via your reverse proxy (127.0.0.1 + --resolve, bypasses any
#     CDN) so an edge/CDN outage never triggers a restart that can't fix it.
#   - 3 consecutive failures before acting — one blip never restarts.
#   - Max 1 restart per 6h (state file). Still failing after restart → critical
#     alert with cooldown, no more restarts.
#   - If local is OK but the public URL fails → alert only (edge problem).
APPWATCH_FAILS="$STATE_DIR/appwatch_consecutive_fails"
APPWATCH_LAST_RESTART="$STATE_DIR/appwatch_last_restart"

health_local()  { curl -fsS --max-time 10 --resolve "${APP_HEALTH_HOST}:443:127.0.0.1" "https://${APP_HEALTH_HOST}${APP_HEALTH_PATH}" > /dev/null 2>&1; }
health_public() { curl -fsS --max-time 15 "https://${APP_HEALTH_HOST}${APP_HEALTH_PATH}" > /dev/null 2>&1; }

run_appwatch() {
  [ "$NODE_ROLE" != "manager" ] && return 0
  if [ -z "$APP_SERVICE" ] || [ -z "$APP_HEALTH_HOST" ]; then
    log "appwatch: APP_SERVICE / APP_HEALTH_HOST not configured — skipping"
    return 0
  fi

  if health_local; then
    rm -f "$APPWATCH_FAILS"
    clear_alert "app_hung"
    clear_alert "app_restart_failed"
    if ! health_public; then
      alert "app_edge_down" "App healthy locally but UNREACHABLE publicly" \
        "The app answers via the local reverse proxy but https://${APP_HEALTH_HOST}${APP_HEALTH_PATH} fails from outside. Likely CDN/DNS/network — a restart won't fix it, investigate manually."
    else
      clear_alert "app_edge_down"
    fi
    return 0
  fi

  # Don't count health failures that happen during a rolling deploy — the new
  # task is just still booting. Leave the fail counter untouched so a real hang
  # right after a deploy still needs its own 3 consecutive ticks to act.
  if recent_deploy; then
    log "appwatch: local health failed but deploy in progress (within ${DEPLOY_GRACE_SEC}s grace) — ignoring"
    return 0
  fi

  local fails; fails=$(( $(cat "$APPWATCH_FAILS" 2>/dev/null || echo 0) + 1 ))
  echo "$fails" > "$APPWATCH_FAILS"
  log "appwatch: local health FAILED (consecutive: $fails)"
  [ "$fails" -lt 3 ] && return 0

  # 3+ consecutive failures — restart if we haven't in the last 6h
  local now; now=$(date +%s)
  local last_restart; last_restart=$(cat "$APPWATCH_LAST_RESTART" 2>/dev/null || echo 0)
  if [ $(( now - last_restart )) -lt 21600 ]; then
    alert "app_restart_failed" "App still down after the auto-restart" \
      "The watchdog already restarted ${APP_SERVICE} $(( (now - last_restart) / 60 ))min ago and the health endpoint is still not answering after ${fails} checks. Manual intervention required:
<pre>docker service ps ${APP_SERVICE}
docker service logs ${APP_SERVICE} --tail 50</pre>"
    return 0
  fi

  echo "$now" > "$APPWATCH_LAST_RESTART"
  tg_send "🤖 <b>Watchdog: app unresponsive — restarting</b>
<i>${NODE_NAME}</i> · $(date -u +'%Y-%m-%d %H:%M UTC')

${APP_HEALTH_PATH} has not answered for $(( fails * 5 )) min (${fails} consecutive checks, via local reverse proxy).
Running a clean restart: <code>docker service update --force ${APP_SERVICE}</code>"
  log "appwatch: forcing service restart of ${APP_SERVICE}"
  docker service update --force "$APP_SERVICE" >> "$LOG_FILE" 2>&1

  # Give it up to 2 minutes to come back, then report the outcome
  local recovered=0
  for i in $(seq 1 12); do
    sleep 10
    health_local && { recovered=1; break; }
  done
  if [ "$recovered" -eq 1 ]; then
    rm -f "$APPWATCH_FAILS"
    tg_send "✅ <b>Watchdog: app recovered after restart</b>
<i>${NODE_NAME}</i> · health endpoint answering again. If this keeps happening there is an underlying problem to investigate (docker service logs ${APP_SERVICE})."
  else
    tg_send "🚨 <b>Watchdog: restart did NOT recover the app</b>
<i>${NODE_NAME}</i> · health endpoint still not answering 2 min after the restart. URGENT manual intervention needed.
<pre>docker service ps ${APP_SERVICE}
docker service logs ${APP_SERVICE} --tail 50</pre>"
  fi
}

# ── Real-time check mode ──────────────────────────────────────────────────
run_check() {
  log "check start"
  check_disk
  check_swarm_self
  check_swarm_cluster
  check_backup
  check_peer
  log "check end"
}

# ── Daily digest mode ─────────────────────────────────────────────────────
build_digest() {
  local disk_pct; disk_pct=$(df / --output=pcent | tail -1 | tr -d ' %')
  local disk_human; disk_human=$(df -h / | tail -1 | awk '{print $3 " of " $2}')
  local mem_used; mem_used=$(free -h | awk '/^Mem:/ {print $3 " / " $2}')
  local swap_used; swap_used=$(free -h | awk '/^Swap:/ {print $3 " / " $2}')
  local load_avg; load_avg=$(uptime | sed 's/.*load average: //')
  local up_since; up_since=$(uptime -p)

  local apt_count; apt_count=$(apt list --upgradable 2>/dev/null | grep -cv '^Listing' || echo 0)
  local reboot_req="no"
  [ -f /var/run/reboot-required ] && reboot_req="<b>YES</b>"

  local docker_reclaim; docker_reclaim=$(docker system df 2>/dev/null | awk '/^Images/ {print $5}' | head -1)

  local swarm_state; swarm_state=$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)

  local body
  body="📊 <b>Infra digest — ${NODE_NAME}</b>
<i>$(date -u +'%Y-%m-%d %H:%M UTC')</i>

<b>Host</b>
• Disk: ${disk_pct}% (${disk_human})
• RAM: ${mem_used}
• Swap: ${swap_used}
• Load: ${load_avg}
• Uptime: ${up_since}

<b>Docker</b>
• Swarm: ${swarm_state:-none} (${NODE_ROLE})
• Reclaimable images: ${docker_reclaim:-?}

<b>OS</b>
• APT updates pending: ${apt_count}
• Reboot required: ${reboot_req}"

  if [ "$NODE_ROLE" = "manager" ] && docker node ls > /dev/null 2>&1; then
    local nodes_summary; nodes_summary=$(docker node ls --format '• {{.Hostname}} — {{.Status}}/{{.Availability}}/{{.ManagerStatus}}' 2>/dev/null)
    local svcs_summary; svcs_summary=$(docker service ls --format '• {{.Name}} — {{.Replicas}}' 2>/dev/null \
      | awk '{ if ($0 ~ /[0-9]+\/[0-9]+/) {n=split($0,a,"—"); split(a[2],b,"/"); gsub(/ /,"",b[1]); gsub(/ /,"",b[2]); ok=(b[1]+0 == b[2]+0)?"✅":"⚠️"; print $0 " " ok} else print }')

    body="${body}

<b>Swarm cluster</b>
${nodes_summary}

<b>Services</b>
${svcs_summary}"
  fi

  # Backup freshness (if configured)
  if [ -n "$BACKUP_LOG" ] && [ -f "$BACKUP_LOG" ]; then
    local last_line; last_line=$(grep -F "$BACKUP_OK_PATTERN" "$BACKUP_LOG" | tail -1)
    if [ -n "$last_line" ]; then
      local ts_str; ts_str=$(echo "$last_line" | sed -E 's/^\[([0-9-]+ [0-9:]+)\].*/\1/')
      local ts; ts=$(date -d "$ts_str" +%s 2>/dev/null || echo 0)
      local age_h=$(( ( $(date +%s) - ts ) / 3600 ))
      body="${body}

<b>Backups</b>
• Last successful run: ${ts_str} (${age_h}h ago)"
    else
      body="${body}

<b>Backups</b>
• ⚠️ no successful run found in ${BACKUP_LOG}"
    fi
  fi

  echo "$body"
}

run_digest() {
  log "digest start"
  local text; text=$(build_digest)
  tg_send "$text"
  log "digest sent"
}

# ── Test mode ─────────────────────────────────────────────────────────────
run_test() {
  tg_send "✅ <b>vps-sentinel test</b>
<i>${NODE_NAME}</i> · $(date -u +'%Y-%m-%d %H:%M UTC')
Telegram delivery from this host is working."
  echo "test sent"
}

# ── Entrypoint ────────────────────────────────────────────────────────────
case "${1:-}" in
  check)    run_check ;;
  digest)   run_digest ;;
  appwatch) run_appwatch ;;
  test)     run_test ;;
  *) echo "Usage: $0 {check|digest|appwatch|test}" >&2; exit 1 ;;
esac
