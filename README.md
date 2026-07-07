# vps-sentinel

[![lint](https://github.com/ayudatecno/vps-sentinel/actions/workflows/lint.yml/badge.svg)](https://github.com/ayudatecno/vps-sentinel/actions/workflows/lint.yml) [![license: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE) ![bash](https://img.shields.io/badge/dependencies-bash%20%2B%20curl%20%2B%20cron-blue)

**Zero-dependency ops safety net for a VPS or small Docker Swarm — bash + curl + cron, alerts to your Telegram DM.**

If you run production on one or two VPS (a SaaS, a client stack, a side project), you have the same four problems every managed platform solves with a team you don't have:

1. **You find out the app is down from a customer.** Swarm restarts a *dead* process, but the common failure mode is a *hung-but-alive* app — blocked event loop, exhausted DB pool — where the container stays "running" and the health endpoint times out forever.
2. **The disk silently fills** with old deploy images and container logs until Postgres stops writing.
3. **Backups run… you think.** Nobody notices the cron that's been failing for three weeks.
4. **You've never actually restored a backup.** A backup you never restored is not a backup.

vps-sentinel is the battle-tested set of shell scripts we run in production at [AyudaTecno](https://ayudatecno.com.ar) (an MSP running a multi-tenant helpdesk platform for clinics, schools and factories on a 2-node Swarm). No agents, no Prometheus stack, no SaaS bill — each node observes itself and posts straight to Telegram. Everything still works **when your app is dead**, which is exactly when in-app monitoring can't help you.

## What's in the box

| Script | What it does |
|---|---|
| [`infra-monitor.sh`](infra-monitor.sh) | `check` (15-min cron): disk / swarm state / service replicas / backup freshness / peer-node reachability, with per-alert 1h cooldown. `digest` (daily): full host + cluster health summary. `appwatch` (5-min cron): the hung-app watchdog. |
| [`disk-autoheal.sh`](disk-autoheal.sh) | Safe, categorized disk cleanup (dangling images, build cache, journal, rotated logs, oversized container json-logs, apt cache). Never touches volumes, running containers or app data. Reports what each category freed. First run on a busy CI/CD host freed ~59 GB. |
| [`restore-drill.sh`](restore-drill.sh) | Monthly disaster-recovery drill: pulls the latest offsite snapshot (any rclone remote), restores it into a throwaway `--network none` postgres container, compares row counts of your key tables against live prod (read-only), reports ✅/🚨, destroys everything. |
| [`install.sh`](install.sh) | Idempotent installer: copies scripts, seeds the env file, installs the cron entries, sends a test message. |

## The appwatch logic (the part that saves you at 3 AM)

- Health check goes through the **local reverse proxy** (`curl --resolve host:443:127.0.0.1`), bypassing your CDN — so a Cloudflare outage never triggers a restart that can't fix anything. If local is fine but the public URL is down, you get an "edge problem" alert instead.
- **3 consecutive failures** (15 min) before acting — one blip never restarts anything.
- Then exactly **one** `docker service update --force`, with a before/after report to Telegram, and a **max of 1 restart per 6 h**. Still down after that → critical alert and a human takes over. No restart loops, ever.
- A deploy-grace window (touch a log file from your CI/CD) suppresses false alarms during rolling deploys.

## Install

```bash
git clone https://github.com/ayudatecno/vps-sentinel.git
cd vps-sentinel
sudo bash install.sh manager my-vps-1        # or: worker my-vps-2 [peer-host]
sudo nano /etc/vps-sentinel.env               # set TELEGRAM_BOT_TOKEN + TELEGRAM_ADMIN_CHAT_IDS
sudo /opt/vps-sentinel/infra-monitor.sh test  # confirm delivery
```

Create the bot with [@BotFather](https://t.me/BotFather); get your chat id from [@userinfobot](https://t.me/userinfobot). Everything is configured in [`/etc/vps-sentinel.env`](sentinel.env.example) — the two Telegram vars are the only required ones; each extra var enables an extra check (app watchdog, backup freshness, peer ping, restore drills).

Works on plain Docker hosts too — the swarm checks self-disable when the node isn't part of a swarm.

## Requirements

- Linux with bash, curl, cron
- Docker (for the docker checks, auto-heal categories and restore drill)
- `rclone` configured with your offsite remote (restore drill only)

Distro-agnostic: package-cache cleanup and the "updates pending" digest line auto-detect apt / dnf / yum / apk / pacman, and the journal-vacuum step is skipped cleanly on non-systemd hosts. Tested on Debian/Ubuntu; Alpine, Fedora and Arch paths are best-effort — issues/PRs from those welcome.

## Hard-won gotchas baked in

- Drill restores use the **same image as your live prod DB** (auto-detected) — dumps with extensions (pgvector, PostGIS) degrade into thousands of errors on a plain `postgres` image.
- `pg_dump` ≥ 16.14 emits `\restrict`/`\unrestrict` — restore with a matching-or-newer psql.
- Alert cooldowns are per-alert-key state files, and every alert **clears its own state on recovery**, so you get exactly one "it broke" and the next occurrence alerts again.
- `docker image prune --filter until=Xh` reclaims 0 B on containerd image stores — the plain dangling prune is what actually works.

## License

MIT
