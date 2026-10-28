---
name: new-web-app
description: Use when starting a new Go + React + SQLite web app or backend (JSON API, public pages, /healthz, backups) for the DreamHost VPS, or when an app needs its server deployed there; it turns the starter repo this skill lives in into the app and applies Eladio's hosting specifics.
---

# New Web App (wrapper around the starter)

## Overview

The repo this skill lives in (the goweb starter) is the single source for the Go + SQLite + React app (API, public pages, session auth, backups, deploy and smoke scripts). This skill does not duplicate it: it copies the starter's committed `HEAD` (without `.claude/skills/`) into a repo, renames it, and adds only what is specific to Eladio's VPS. Read the new app's `CLAUDE.md` and `web/docs/` for how the app itself works. Hosting specifics live here, never in the app.

## Scaffold

```bash
bash <starter-repo>/.claude/skills/new-web-app/scripts/scaffold.sh <repo-dir> <slug> "<Display Name>" "<one-line description>" [--port N] [--allow-dirty]
```

Once linked it also works as `bash ~/.claude/skills/new-web-app/scripts/scaffold.sh ...`.

- Exit 0 done; 1 refusal (starter missing or dirty, a file would be overwritten, the starter's fast tier failed in the copy); 2 bad input (slug not `^[a-z][a-z0-9]*$`, a slug the starter's `web/scripts/rename.sh --check` refuses, `| % \ "` or a newline in the text, port outside 1024-65535). Refusals leave `<repo-dir>` untouched. It does not commit.
- `GOWEB_DIR` overrides the starter: the default is the repo the script lives in (the real path, symlinks followed). A dirty starter is refused because only its `HEAD` is used (`--allow-dirty` to ignore the rest). The marker file `.goweb-origin` records the commit the app started from; the starter's layout guard keys on it.
- The slug is checked up front by the starter's own `web/scripts/rename.sh --check github.com/caritos/<slug> <slug>` (reserved words, names it could not undo, no hyphens even if the iOS app name has one such as `busy-hive`). The slug `app` is allowed (module-only rename).
- Collisions: root `.gitignore` gets missing lines appended; an existing root `CLAUDE.md` gets one pointer line and the starter's goes to `web/CLAUDE.md`; existing `README.md` and `AGENTS.md` are skipped (printed); the starter's `ios/` placeholder is skipped when `ios/` exists (run `new-ios-app` before or after). The starter's layout guard has a host mode keyed on the marker, so `make -C web test` passes next to `ios/` and a root `CLAUDE.md`.
- Applies: `web/scripts/rename.sh github.com/caritos/<slug> <slug>`, the display name (HTML-escaped) and description in the pages' `<title>`, brand link, first `<h1>` and "What is ...?" heading, `web/index.html` and the README title (every other bare word "app" in the pages is protected through the rename), `support@caritos.com`, `web/deploy/.env.example` (`ADDR=0.0.0.0:<port>`, `PUBLIC_ORIGIN=https://<slug>.caritos.com`), and `web/scripts/backup-pull.env.example` (`MIRROR_DIR="/Volumes/Treasure Chest/backups/<slug>"`).
- Without `--port`, `ADDR` carries a non-numeric placeholder and `web/scripts/deploy-app.sh` refuses to run until it is set. Only Eladio can pick the port, after `ss -tln` on the server.
- The privacy, terms, FAQ, support and home copy still describes the starter's example notes app: rewrite it for the real app before release (the scaffold prints this).
- Tests: `bash <starter-repo>/.claude/skills/new-web-app/tests/run.sh` (`--fast` skips the full tier, which needs a clean committed starter, Node, pnpm and Go; `make -C web test-skills` runs the fast tier).

## Deploying: `web/scripts/deploy-app.sh`

Generated; exports `PUBLIC_URL=https://<slug>.caritos.com` (so the deploy runs the smoke check), `EXPECT_PUBLIC_LISTENER=1` (panel proxy), `REQUIRE_BACKUP_TIMER=1` (deploy is refused unless `<slug>-backup.timer` is enabled on the server) and `APP_NAME` (the display name as it appears in the page HTML, matched as a whole word in the home page `<title>` or first `<h1>` by the smoke check), then runs the starter's `web/scripts/deploy.sh`.

| Command | Does |
|---|---|
| `web/scripts/deploy-app.sh <user>@<host> --check` | Preflight only: SSH login, linger, server layout, timer |
| `web/scripts/deploy-app.sh <user>@<host>` | Test gate, build, upload, switch release, restart, public smoke check |
| `make -C web test-fast` / `make -C web test` | Fast and full tier (in the app) |

## One-time setup per app

| Step | Where |
|---|---|
| Add the domain `<slug>.caritos.com` | DreamHost panel |
| SSH key login | `ssh-copy-id -i ~/.ssh/id_ed25519.pub <user>@<host>`; a FULL shell user, not SFTP-only |
| Free port | `ss -tln`, then `ps aux` to see who owns a taken one (ports are shared VPS-wide) |
| Proxy Server | Panel -> VPS Management -> Proxy Server -> that port. Never add `~/nginx/domain/proxy.conf` |
| Backup timer | Install and enable `<slug>-backup.timer` on the server (`web/docs/deploy.md` step 3) BEFORE the first deploy, or it is refused |
| Server `.env` | From `web/deploy/.env.example` (web/docs/deploy.md); never uploaded by deploy |
| Check | `web/scripts/deploy-app.sh <user>@<host> --check` |
| Mac backups | `mkdir -p ~/.config/<slug>`, copy `web/scripts/backup-pull.env.example` to `~/.config/<slug>/backup-pull.env`, set `REMOTE`, run `web/scripts/install-backup-agent.sh`. A backup counts only after a restore drill (`web/docs/backups.md`) |

## Failure signatures

- SFTP-only user: SSH works but commands exit 0 with no output, or `rsync` / `ssh -tt` hang. Switch the user to a shell user in the panel.
- "Index of /" on the domain while the service is healthy: the Proxy Server step is missing or points at the wrong port.
- A `200` on the port from someone else's app: shared ports. The smoke check requires the display name on the home page.
- Local checks pass but the domain 502s: the app listens on `127.0.0.1`. Keep `ADDR=0.0.0.0:<port>`.
- HTTP/1.0 trap: the panel's nginx speaks HTTP/1.0 and corrupts chunked or streamed static files. Serve a known `Content-Length`; compare CSS and icon bytes through the public URL.
- Services stop when SSH ends: `loginctl enable-linger` was not set (the preflight checks it).

## After the first real app

Follow "Retro before closing out an app" in `~/.claude/CLAUDE.md`: fold workarounds back into the starter (if generic) or into this skill (if hosting-specific) with tests; both live in the same repo.

## Not covered

Android and iOS clients (`new-ios-app`), legacy Bun/Hono apps, per-user roles beyond the starter's session auth, hosting other than the DreamHost VPS.
