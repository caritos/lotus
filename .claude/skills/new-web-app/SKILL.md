---
name: new-web-app
description: Use when starting a new Go + React + SQLite web app or backend (JSON API, public pages, /healthz, backups) for the DreamHost VPS, or when an app needs its server deployed there; it turns ~/src/goweb into the app and applies Eladio's hosting specifics.
---

# New Web App (wrapper around goweb)

## Overview

`~/src/goweb` is the single source for the Go + SQLite + React app (API, public pages, session auth, backups, deploy and smoke scripts). This skill does not duplicate it: it copies goweb's committed `HEAD` into a repo, renames it, and adds only what is specific to Eladio's VPS. Read the new app's `CLAUDE.md` and `docs/` for how the app itself works. Hosting specifics live here, never in goweb.

## Scaffold

```bash
bash ~/.claude/skills/new-web-app/scripts/scaffold.sh <repo-dir> <slug> "<Display Name>" "<one-line description>" [--port N] [--allow-dirty]
```

- Exit 0 done; 1 refusal (goweb missing or dirty, a file would be overwritten, goweb's fast tier failed in the copy); 2 bad input (slug not `^[a-z][a-z0-9]*$`, `| % \ "` or a newline in the text, port outside 1024-65535). Refusals leave `<repo-dir>` untouched. It does not commit.
- `GOWEB_DIR` overrides `~/src/goweb`. A dirty goweb is refused because only its `HEAD` is used (`--allow-dirty` to ignore the rest). `.goweb-origin` records the commit the app started from.
- The slug may not contain hyphens (`scripts/rename.sh` needs `^[a-z][a-z0-9]*$`) even if the iOS app name has one (`busy-hive`).
- Known limit (goweb L3): if the target already had `ios/` or a root `CLAUDE.md` (e.g. from `new-ios-app`), `make test` in the app fails at `scripts/layout.test.sh` until goweb's guard is host-aware; the scaffold warns. Other tiers are unaffected.
- Collisions: root `.gitignore` gets missing lines appended; an existing root `CLAUDE.md` gets one pointer line and goweb's goes to `web/CLAUDE.md`; existing `README.md` and `AGENTS.md` are skipped (printed); goweb's `ios/` placeholder is skipped when `ios/` exists (run `new-ios-app` before or after).
- Applies: `scripts/rename.sh github.com/caritos/<slug> <slug>`, the display name (HTML-escaped) and description in the public pages, `web/index.html` and the README title, `support@caritos.com`, `.env.example` (`ADDR=0.0.0.0:<port>`, `PUBLIC_ORIGIN=https://<slug>.caritos.com`), and `scripts/backup-pull.env.example` (`MIRROR_DIR="/Volumes/Treasure Chest/backups/<slug>"`).
- Without `--port`, `ADDR` carries a non-numeric placeholder and `scripts/deploy-app.sh` refuses to run until it is set. Only Eladio can pick the port, after `ss -tln` on the server.
- The privacy, terms, FAQ, support and home copy still describes goweb's example notes app: rewrite it for the real app before release (the scaffold prints this).

## Deploying: `scripts/deploy-app.sh`

Generated; exports `PUBLIC_URL=https://<slug>.caritos.com` (so goweb's deploy runs the smoke check), `EXPECT_PUBLIC_LISTENER=1` (panel proxy), `REQUIRE_BACKUP_TIMER=1` (deploy is refused unless `<slug>-backup.timer` is enabled on the server) and `APP_NAME` (the display name as it appears in the page HTML, which the smoke check looks for), then runs goweb's `scripts/deploy.sh`.

| Command | Does |
|---|---|
| `scripts/deploy-app.sh <user>@<host> --check` | Preflight only: SSH login, linger, server layout, timer |
| `scripts/deploy-app.sh <user>@<host>` | Test gate, build, upload, switch release, restart, public smoke check |
| `make test-fast` / `make test` | Fast and full tier (in the app) |

## One-time setup per app

| Step | Where |
|---|---|
| Add the domain `<slug>.caritos.com` | DreamHost panel |
| SSH key login | `ssh-copy-id -i ~/.ssh/id_ed25519.pub <user>@<host>`; a FULL shell user, not SFTP-only |
| Free port | `ss -tln`, then `ps aux` to see who owns a taken one (ports are shared VPS-wide) |
| Proxy Server | Panel -> VPS Management -> Proxy Server -> that port. Never add `~/nginx/domain/proxy.conf` |
| Backup timer | Install and enable `<slug>-backup.timer` on the server (`docs/deploy.md` step 3) BEFORE the first deploy, or it is refused |
| Server `.env` | From `.env.example` (docs/deploy.md); never uploaded by deploy |
| Check | `scripts/deploy-app.sh <user>@<host> --check` |
| Mac backups | `mkdir -p ~/.config/<slug>`, copy `scripts/backup-pull.env.example` to `~/.config/<slug>/backup-pull.env`, set `REMOTE`, run `scripts/install-backup-agent.sh`. A backup counts only after a restore drill (`docs/backups.md`) |

## Failure signatures

- SFTP-only user: SSH works but commands exit 0 with no output, or `rsync` / `ssh -tt` hang. Switch the user to a shell user in the panel.
- "Index of /" on the domain while the service is healthy: the Proxy Server step is missing or points at the wrong port.
- A `200` on the port from someone else's app: shared ports. The smoke check requires the display name on the home page.
- Local checks pass but the domain 502s: the app listens on `127.0.0.1`. Keep `ADDR=0.0.0.0:<port>`.
- HTTP/1.0 trap: the panel's nginx speaks HTTP/1.0 and corrupts chunked or streamed static files. Serve a known `Content-Length`; compare CSS and icon bytes through the public URL.
- Services stop when SSH ends: `loginctl enable-linger` was not set (the preflight checks it).

## After the first real app

Follow "Retro before closing out an app" in `~/.claude/CLAUDE.md`: fold workarounds back into goweb (if generic) or into this skill (if hosting-specific) with tests.

## Not covered

Android and iOS clients (`new-ios-app`), legacy Bun/Hono apps, per-user roles beyond goweb's session auth, hosting other than the DreamHost VPS.
