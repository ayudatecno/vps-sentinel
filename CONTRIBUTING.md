# Contributing to vps-sentinel

Thanks for taking a look. This project stays deliberately small — bash + curl + cron, no runtime dependencies — so contributions are held to that bar.

## Ground rules

- **No new runtime dependencies.** If it needs more than bash, curl and coreutils to run, it probably belongs in a different tool. (Docker, rclone and systemd are optional and already feature-detected.)
- **Fail safe, never destructive.** Anything that deletes must be scoped, reversible where possible, and never touch volumes, running containers, backups or app data. When in doubt, alert instead of act.
- **Feature-detect, don't assume.** Different distros, init systems and Docker setups are the norm — probe for a tool (`command -v`) and skip cleanly if it's missing.

## Before you open a PR

```bash
shellcheck -S warning *.sh   # must pass (CI runs this)
for f in *.sh; do bash -n "$f"; done
```

The `lint` workflow runs both on every push and PR.

## Good first contributions

- Package-manager / init-system paths for distros beyond Debian, Alpine, Fedora and Arch
- A non-PostgreSQL variant of the restore drill (MySQL/MariaDB, SQLite)
- Alerting sinks beyond Telegram (ntfy, Slack webhook, Discord) — same "works when the app is dead" constraint
- Docs, real-world examples, and "this assumption broke on my setup" bug reports

## Reporting a bug

Open an issue with your distro, whether you run swarm or plain Docker, and the relevant lines from `/var/log/vps-sentinel.log`. Redact tokens and chat IDs.
