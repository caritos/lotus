# Deploying goweb

One static Linux binary, run as a systemd **user** service by a non-root user, behind
a reverse proxy that terminates HTTPS (see [https.md](https.md)). `scripts/deploy.sh`
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
  restore.sh                 copied there by every deploy (from scripts/restore.sh in the repository)
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

Copy `.env.example` to `~/goweb/.env` on the server and edit it. It is the server template: it already
says `APP_ENV=production` and leaves the two required values empty, so the app refuses to start until you
fill them in. The common part:

```
APP_ENV=production
PUBLIC_ORIGIN=https://app.example.com
SESSION_SECRET=<output of: openssl rand -hex 32>
```

`SECURE_COOKIES` follows `APP_ENV` (on in production), so it needs no line. `deploy.sh` reads `APP_ENV`
from this file and stops, with nothing changed, unless it is `production`; set `ALLOW_DEV_DEPLOY=1` in
your local environment only if you really mean to deploy a development-mode server (it prints a warning).

Then pick the case that matches how traffic reaches the app. Pick a free port; on a shared host
check `ss -tln` first, because ports are not private to your user.

**(a) Your own NGINX on the same host** (see [https.md](https.md)). Keep the app on loopback so plain HTTP
is never exposed and TLS/HSTS cannot be bypassed (the proxy sets HSTS; the app never sends it):

```
ADDR=127.0.0.1:8080
TRUSTED_PROXY=127.0.0.1/32
```

**(b) A hosting panel proxy** that connects to the app through the machine's public address. Loopback-only
would give 502, so listen on all interfaces and trust that proxy's address:

```
ADDR=0.0.0.0:8080
TRUSTED_PROXY=<the proxy's address, as /32>
```

To find the proxy's address, make a request through the public site and look at the `remote` address in
the app log (`~/goweb/data/logs/`), or at the source of connections in `ss -tn` on the server. Leave
`TRUSTED_PROXY` empty if you cannot tell, but then every request appears to come from the proxy, so
per-IP limits (for example on sign-in attempts) are shared by all visitors. Restrict who can reach the port
with the host's firewall if it offers one.

Two optional deploy checks guard this setup. They are separate from `EXPECT_PUBLIC_LISTENER`: the first
always runs, the second is off by default.

- Port owner (always on): `deploy.sh` (also with `--check`) refuses to continue when something is already
  listening on the app port and `systemctl --user is-active <unit>` does not say `active`, because that
  listener belongs to someone else. Pick a free port.
- `EXPECT_PUBLIC_LISTENER=1`: refuses a loopback `ADDR` (`127.0.0.1`, `::1`, `localhost`) in the server
  `.env` before anything changes, and after the restart requires a listener on `0.0.0.0`, `*` or `[::]` on
  the app port (`ss -H -ltn`). Otherwise the deploy exits 1 and tells you to set `ADDR=0.0.0.0:<port>`;
  the release is not rolled back because the previous one has the same `.env`.

**Health check address.** `deploy.sh` probes `http://127.0.0.1:<port>/healthz` on the server (the port is
taken from `ADDR`). `127.0.0.1:<port>`, `0.0.0.0:<port>` and `:<port>` all answer there; an `ADDR` bound to a
single non-loopback address (for example `203.0.113.5:8080`) does not, so every deploy would fail its health
check and roll back. Use one of the first three forms.

**Sign-in lockout (a denial-of-service property).** Failed sign-ins are throttled in memory for 15 minutes:
5 failures per email and client address, 20 per email from anywhere, and 50 per client address. So anyone
who knows an email can lock that account out for 15 minutes with 20 wrong passwords, and with
`TRUSTED_PROXY` empty behind a proxy every visitor shares the proxy's address, so 50 failures from anyone
lock out every user for 15 minutes. Set `TRUSTED_PROXY` correctly; a restart clears the counters.

Write values without quotes, spaces or a trailing carriage return (systemd and `deploy.sh` read the file
line by line; `deploy.sh` refuses `APP_ENV`, `DATA_DIR` and `ADDR` lines that contain them). Keep it private:
`chmod 600 ~/goweb/.env`. `deploy.sh` never uploads this file.

**DATA_DIR.** Leave it out of `.env`. If you set it, remember that systemd lets `EnvironmentFile=` values
override the unit's `Environment=DATA_DIR=...`, so the `.env` value is what the service uses (a relative
value is relative to `~/goweb/data`). `deploy.sh` resolves it the same way for the pre-deploy backup and the
printed restore command, and refuses to continue if that directory has no `db/goweb.db`.

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
scripts/deploy.sh deploy@host.example.com --check   # preflight only, changes nothing
PUBLIC_URL=https://app.example.com scripts/deploy.sh deploy@host.example.com
```

`--check` verifies the SSH login, linger, local tools, that `~/goweb/data`, `.env` and the
service unit exist, that the server has `curl` or `wget` and a sha256 tool, that the daily backup
timer `goweb-backup.timer` is enabled (section 3; a warning, or a refusal with `REQUIRE_BACKUP_TIMER=1`), and that the server
`.env` says `APP_ENV=production` and has readable `DATA_DIR` and `ADDR` lines.

Environment knobs: `SSH_KEY`, `REMOTE_BASE`, `SERVICE`, `HEALTH_PORT` (the app port,
default 8080), `HEALTH_TIMEOUT` (default 20 s), `VERSION` (default
`git describe --tags --always --dirty`; a dirty tree is allowed and shows in the version),
`SKIP_WEB_BUILD=1`, `KEEP_OLD`, `HEALTH_RECHECK_DELAY`, `ALLOW_DEV_DEPLOY=1`, `SKIP_TESTS=1` (skip the
test gate below), `REQUIRE_BACKUP_TIMER=1` (refuse to deploy when `${SERVICE}-backup.timer` is not enabled
on the server; otherwise that only warns). When `HEALTH_PORT` is not set the port is read
from `ADDR` in the server's `.env` (default 8080).

What a deploy does, in order:

1. Preflight (as `--check`). Every ssh and rsync call uses `BatchMode=yes`, so it fails
   instead of prompting for a password. This includes resolving `APP_ENV`, `DATA_DIR` and the app port
   from the server's `.env` as described above, and refusing a non-production `APP_ENV`.
2. The test gate, before anything changes on the server (not part of `--check`; `SKIP_TESTS=1` skips it):
   `go vet ./...` and `go test -short ./...` in `web/api`, then `pnpm test` and `pnpm typecheck` in `web/`.
   The first failure stops the deploy. Unless `SKIP_WEB_BUILD=1`, the deploy also stops early when the
   major version in `.nvmrc` (`web/.nvmrc` if present) differs from `node -v`.
3. `pnpm build`, then a static `GOOS=linux GOARCH=amd64 CGO_ENABLED=0` build with the version,
   commit and build id injected. The build id (`YYYYMMDD-<short commit>`, UTC date, `-dirty` for
   uncommitted changes to tracked files) comes from `scripts/build-id.sh`, is computed once, and is
   printed in the progress output and in the final "done" line.
4. Takes a deploy lock on the server (`~/goweb/.deploy.lock`, holding who and when). A second deploy
   fails at once with exit 1 and changes nothing; a lock older than 30 minutes is reported and taken
   over. The lock is released on exit, also after a failure or Ctrl-C.
5. Checks that the resolved `DATA_DIR` holds `db/goweb.db` (when a release is active).
6. If a release is active, runs `goweb backup --label predeploy --keep 5` on the server with the running
   binary (the pre-deploy snapshot, `<timestamp>-predeploy`) and remembers its directory. Pre-deploy sets have
   their own retention (the 5 newest), never push the daily sets out, and stay on the server (the pull script
   ignores them); see [backups.md](backups.md).
7. Uploads to `releases/<version>.uploading`, compares the sha256 on the server with the
   local one (a mismatch aborts with nothing changed), then renames into place.
8. Repoints `current` (an atomic rename when the server's `mv` supports `-T`, else
   `ln -sfn`, and it says so), restarts the unit and polls `/healthz` on the server's
   loopback until it reports exactly the new version (up to `HEALTH_TIMEOUT` seconds on the clock),
   then probes once more after 3 seconds: a service that comes up and falls over again counts as failed.
9. Keeps the active release, the previous one and up to three older ones; deletes the
   rest inside `releases/` (never the active or previous release, and never an `*.uploading` directory
   younger than 30 minutes).
10. When `PUBLIC_URL` is set, runs `scripts/smoke.sh` against it from your machine with
   `EXPECTED_BUILD_ID` set to the id it just built. A failing smoke check makes the deploy exit 1 but
   does not roll back.

**Which build is live?** Every page footer shows `Build <id>` and `/healthz` reports the same id as
`build_id`:

```sh
curl -s https://app.example.com/ | grep -o 'Build [0-9a-z-]*'
curl -s https://app.example.com/healthz
```

Compare it with `scripts/build-id.sh` on the commit you meant to deploy. The first part is the UTC build
date, the second the short commit, and a trailing `-dirty` means the build had uncommitted changes to
tracked files. `smoke.sh` checks the id: `/healthz` must report a well-formed `build_id`, `/` must show
the same id in its footer, and with `EXPECTED_BUILD_ID` set (as `deploy.sh` does; set it yourself when
running `smoke.sh` by hand) `/healthz`, `/` and `/app/` must all show exactly that id.

## Rollback and restore

If the new release is not healthy within the timeout:

- **No migration in this release** (the highest migration file, as printed by
  `goweb schema-version`, equals the previous release's): `current` is switched back,
  the service restarted and health-checked, and the deploy exits non-zero saying
  "rolled back automatically".
- **The release carries a migration**: the binary is **not** rolled back, because the
  previous binary may not work against the migrated schema. The deploy prints the exact
  commands to put the previous release back and restore the pre-deploy backup with
  `restore.sh` (run on the server, with `GOWEB_BIN` pointing at the previous release's binary file). `restore.sh` verifies the backup, stops the
  service, saves the live data as `pre-restore-*`, swaps the backup in, restarts and
  health-checks. `pre-restore-*` copies are never pruned automatically: delete them by hand after you have
  verified the restore. See [backups.md](backups.md).
- **Previous binary without `schema-version`** (a release from before that subcommand existed): treated
  as "may have migrated", so no automatic rollback; the restore command is printed.
- **First deploy**: there is no previous release; the deploy says so and exits non-zero.
  Read the service log (`journalctl --user -u goweb`; check it first in every failure case, a migration may
  still be running) and `~/goweb/data/logs/`.

### Release notes convention

Every release that adds a migration states in its notes, in one line, whether **the
previous binary still works against the new schema**. Prefer expand-then-contract
migrations (add compatible schema, ship code that handles both, drop the old schema in a
later release) so the answer is "yes" and a binary rollback is always safe. Never edit a
migration that has been released.

## Backups

The timer from step 3 runs `goweb backup --keep 14` daily at 03:15 on the server. Pre-deploy sets
(`--label predeploy`, 5 kept) are separate and never count against those 14.
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
REMOTE=deploy@host.example.com REMOTE_DIR=/ SSH_KEY=~/.ssh/goweb-pull scripts/pull-backups.sh
```

Verify the restriction by hand: `ssh -i ~/.ssh/goweb-pull deploy@host.example.com whoami`
must print `denied`, and the pull command above must still pull a set.

Schedule the pull from the other machine with launchd or cron, and read
[backups.md](backups.md) for the exit codes and the freshness alert.

## Housekeeping the server does by itself

- Expired sessions are purged when the service starts and then every hour.
- Upload temp files (`storage/.upload-*`) older than an hour, left by a crash or kill during an upload, are
  removed when the service starts.
- The app log rotates by size (see [backups.md](backups.md)); daily and pre-deploy backup sets are pruned
  by `goweb backup`. `pre-restore-*` copies are not: delete them once a restore is verified.

## Monitoring

- Point an external uptime monitor at `https://app.example.com/healthz` (it returns
  `status`, `version`, `commit` and `build_id`), and alert on a non-200 or on an unexpected version.
- Alert when disk usage on the data volume passes 80 percent.
- Check after install that the monitor is really running (look at its log), and only
  monitor URLs you have fetched with `curl` yourself.
- Keep an eye on `systemctl --user list-timers` for the backup timer and on the age of
  the newest local copy (the pull script alerts on that).
