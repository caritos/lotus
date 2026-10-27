# Deploying goweb

One static Linux binary, run as a systemd **user** service by a non-root user, behind
a reverse proxy that terminates HTTPS (see [https.md](https.md)). `deploy/deploy.sh`
builds on your machine, uploads over SSH and switches releases; nothing is built on
the server.

## Layout on the server

Everything is under the deploy user's home (the base directory is `REMOTE_BASE`, default `goweb`):

```
~/goweb/
  releases/<version>/goweb   one directory per release
  current -> releases/<version>   the active release (a symlink)
  data/                      DATA_DIR: db/, logs/, storage/, backups/
  .env                       runtime configuration (never uploaded, never printed)
  restore.sh                 copied there by every deploy
```

## 1. Prepare the server (once)

Use a normal user with a real login shell (not an SFTP-only user), key authentication
and no root access. Check it first: `ssh deploy@host.example.com 'whoami; echo $SHELL'`
must print output.

```sh
# on the server
loginctl enable-linger                       # user services must survive logout
loginctl show-user "$(id -un)" --property=Linger   # must print Linger=yes
mkdir -p ~/goweb/releases ~/goweb/data ~/.config/systemd/user
chmod 700 ~/goweb ~/goweb/data
```

Linger is required: without it the user's systemd instance stops when the last SSH
session ends and the site goes down. `deploy.sh` checks this and fails with the fix; it
never enables linger by itself.

## 2. Configure `.env`

Copy `.env.example` to `~/goweb/.env` on the server and edit it. Production needs:

```
APP_ENV=production
ADDR=0.0.0.0:8080
PUBLIC_ORIGIN=https://app.example.com
SECURE_COOKIES=true
TRUSTED_PROXY=127.0.0.1/32
SESSION_SECRET=<output of: openssl rand -hex 32>
```

Pick a free port; on a shared host check `ss -tln` first, because ports are not private
to your user. Listen on `0.0.0.0`, not `127.0.0.1`, when a panel proxy reaches the app
through the host's public address. Write values without quotes or spaces (systemd and
`deploy.sh` both read the file line by line). Keep it private: `chmod 600 ~/goweb/.env`.
`deploy.sh` never uploads this file.

## 3. Install the units

Copy from `deploy/` to `~/.config/systemd/user/` on the server (the first deploy does
not install them):

```sh
scp deploy/goweb.service deploy/goweb-backup.service deploy/goweb-backup.timer deploy@host.example.com:.config/systemd/user/
ssh deploy@host.example.com 'systemctl --user daemon-reload && systemctl --user enable goweb && systemctl --user enable --now goweb-backup.timer'
```

The units assume the layout above. If your host rejects the sandboxing lines in a user
unit (`status=226/NAMESPACE`), delete `NoNewPrivileges`, `ProtectSystem`,
`ReadWritePaths` and `PrivateTmp` from the units, as the comment in `goweb.service` says.
The service is enabled but not started yet: it starts on the first deploy.

## 4. Check, then deploy

```sh
deploy/deploy.sh deploy@host.example.com --check   # preflight only, changes nothing
PUBLIC_URL=https://app.example.com deploy/deploy.sh deploy@host.example.com
```

`--check` verifies the SSH login, linger, local tools, that `~/goweb/data`, `.env` and the
service unit exist, and that the server has `curl` or `wget` and a sha256 tool.

Environment knobs: `SSH_KEY`, `REMOTE_BASE`, `SERVICE`, `HEALTH_PORT` (the app port,
default 8080), `HEALTH_TIMEOUT` (default 20 s), `VERSION` (default
`git describe --tags --always --dirty`; a dirty tree is allowed and shows in the version),
`SKIP_WEB_BUILD=1`, `KEEP_OLD`.

What a deploy does, in order:

1. Preflight (as `--check`). Every ssh and rsync call uses `BatchMode=yes`, so it fails
   instead of prompting for a password.
2. `pnpm build`, then a static `GOOS=linux GOARCH=amd64 CGO_ENABLED=0` build with the version and
   commit injected.
3. If a release is active, runs `goweb backup` on the server with the running binary
   (the pre-deploy snapshot) and remembers its directory.
4. Uploads to `releases/<version>.uploading`, compares the sha256 on the server with the
   local one (a mismatch aborts with nothing changed), then renames into place.
5. Repoints `current` (an atomic rename when the server's `mv` supports `-T`, else
   `ln -sfn`, and it says so), restarts the unit and polls `/healthz` on the server's
   loopback until it reports the new version.
6. Keeps the active release, the previous one and up to three older ones; deletes the
   rest inside `releases/`.
7. When `PUBLIC_URL` is set, runs `deploy/smoke.sh` against it from your machine. A failing smoke
   check makes the deploy exit 1 but does not roll back.

## Rollback and restore

If the new release is not healthy within the timeout:

- **No migration in this release** (the highest migration file, as printed by
  `goweb schema-version`, equals the previous release's): `current` is switched back,
  the service restarted and health-checked, and the deploy exits non-zero saying
  "rolled back automatically".
- **The release carries a migration**: the binary is **not** rolled back, because the
  previous binary may not work against the migrated schema. The deploy prints the exact
  commands to put the previous release back and restore the pre-deploy backup with
  `restore.sh` (run on the server). `restore.sh` verifies the backup, stops the
  service, saves the live data as `pre-restore-*`, swaps the backup in, restarts and
  health-checks. See [backups.md](backups.md).
- **First deploy**: there is no previous release; the deploy says so and exits non-zero.
  Read the service log (`journalctl --user -u goweb`, and `~/goweb/data/logs/`).

### Release notes convention

Every release that adds a migration states in its notes, in one line, whether **the
previous binary still works against the new schema**. Prefer expand-then-contract
migrations (add compatible schema, ship code that handles both, drop the old schema in a
later release) so the answer is "yes" and a binary rollback is always safe. Never edit a
migration that has been released.

## Backups

The timer from step 3 runs `goweb backup --keep 14` daily at 03:15 on the server.
Pulling copies to another machine is covered in [backups.md](backups.md).

### Off-site pull with a restricted key

Create a key used only for pulling, on the machine that will hold the copies:

```sh
ssh-keygen -t ed25519 -f ~/.ssh/goweb-pull -N '' -C goweb-pull
```

`pull-backups.sh` does two things over SSH: `ls -1 <dir>` to list the sets and `rsync` to copy
one. A forced `rrsync -ro` command alone permits only the second, so use a tiny gate script
that allows exactly the listing and hands every rsync request to `rrsync` in read-only mode.
On the server, save this as `~/goweb/pull-gate.sh` (`chmod 700`), adjusting the home path:

```sh
#!/bin/sh
# Forced command for the pull key: list the backups directory, or read it with rsync. Nothing else.
DIR=/home/deploy/goweb/data/backups
case "$SSH_ORIGINAL_COMMAND" in
  "ls -1 '/'") exec ls -1 "$DIR" ;;
  "rsync --server --sender "*) exec rrsync -ro "$DIR" ;;
  *) echo "denied" >&2; exit 1 ;;
esac
```

Then add the public key to `~/.ssh/authorized_keys` on the server:

```
restrict,command="/home/deploy/goweb/pull-gate.sh" ssh-ed25519 AAAA... goweb-pull
```

`rrsync` ships with rsync (usually `/usr/bin/rrsync`; on some distributions it is under
the rsync package's documentation or scripts directory). With this key the backups
directory is the root, so run the pull with `REMOTE_DIR=/`:

```sh
REMOTE=deploy@host.example.com REMOTE_DIR=/ SSH_KEY=~/.ssh/goweb-pull deploy/pull-backups.sh
```

Verify the restriction by hand: `ssh -i ~/.ssh/goweb-pull deploy@host.example.com whoami`
must print `denied`, and the pull command above must still pull a set.

Schedule the pull from the other machine with launchd or cron, and read
[backups.md](backups.md) for the exit codes and the freshness alert.

## Monitoring

- Point an external uptime monitor at `https://app.example.com/healthz` (it returns
  `status`, `version` and `commit`), and alert on a non-200 or on an unexpected version.
- Alert when disk usage on the data volume passes 80 percent.
- Check after install that the monitor is really running (look at its log), and only
  monitor URLs you have fetched with `curl` yourself.
- Keep an eye on `systemctl --user list-timers` for the backup timer and on the age of
  the newest local copy (the pull script alerts on that).
