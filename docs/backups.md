# Backups

## What is backed up

`goweb backup` writes a set `<DATA_DIR>/backups/<UTC timestamp>/` (for example `20261027T031500Z`)
containing:

- `goweb.db`, a consistent SQLite snapshot (made with `VACUUM INTO`, never a plain
  copy of a live database, so WAL state is included), and
- `storage/`, a copy of the uploaded photos.

A set is built in a `*.partial` directory and renamed when complete, so a set without that suffix is whole.
Logs are not backed up.

## Schedule and retention

- **Server:** the `goweb-backup.timer` user unit runs `goweb backup --keep 14` daily at 03:15 (`Persistent=true`,
  so a missed run happens at the next start). The 14 newest sets are kept.
- **Pull copies:** `scripts/pull-backups.sh` runs on another machine (launchd or cron), copies new sets over SSH, verifies
  each with `PRAGMA integrity_check`, quarantines failures in `failed/`, and keeps the newest 30 (`KEEP`).
  `failed/` is never pruned automatically.
- **Pre-deploy sets:** every deploy runs `goweb backup --label predeploy --keep 5` with the running release.
  A labeled set is named `<UTC timestamp>-<label>` (for example `20261027T031500Z-predeploy`) and is pruned
  only against sets with the same label: the 5 newest pre-deploy sets are kept, and deploys never push daily
  sets out (the daily prune never touches labeled sets either). Pre-deploy sets stay on the server only:
  `pull-backups.sh` copies only the daily sets, and labeled sets count neither toward `KEEP` nor toward the
  freshness alert. `verify-backup` and `restore.sh` accept them like any other set.
- **`pre-restore-*` safety copies** (written by a real restore, see below) are never pruned automatically.
  Delete them by hand once you have checked that the restored data is right; until then each one costs a full
  copy of the data.

Both copies and the server live in your own accounts. Do not count them as protection against loss of
all of them at once (fire, theft, account loss). If you ever send backups to a third-party service, say so
in the privacy policy.

## Restoring

```sh
# rehearsal: restores into a scratch directory, touches neither DATA_DIR nor the service
# (on the server every deploy refreshes ~/goweb/restore.sh; from a checkout use scripts/restore.sh)
export GOWEB_BIN=$HOME/goweb/current/goweb      # must be the executable file, not a directory
bash ~/goweb/restore.sh ~/goweb/data/backups/20261027T031500Z --drill     # prints "DRILL OK <dir>"

# real restore (on the server); DATA_DIR is the one the service really uses
DATA_DIR=$HOME/goweb/data bash ~/goweb/restore.sh ~/goweb/data/backups/20261027T031500Z
```

A real restore verifies the backup, stages a copy next to `DATA_DIR`, stops the service, saves the live data as
`<DATA_DIR>/backups/pre-restore-<timestamp>/`, swaps the staged data in, starts the service and checks health.
If anything fails after the stop, it rolls back from the pre-restore copy and says what it could not restore.

Limits to know:

- **Same filesystem.** The swap uses renames, so the staged copy must be on the same filesystem as
  `DATA_DIR`. `restore.sh` stages in a `.restore-stage-*` directory inside `DATA_DIR` for that reason; it needs
  free space for a second copy of the data there. Do not make `db/` or `storage/` separate mounts.
- **Snapshot, then storage.** The database snapshot is taken first and the photos are copied after it. A
  photo uploaded in between exists in `storage/` without a row (harmless, unreferenced), and a photo deleted in
  between leaves a row whose file is missing in the copy; the drill and restore report that. This is a race
  window of seconds, accepted for a single small server.
- Restoring the database of an older schema onto a newer binary is fine (it migrates forward); restoring a newer
  schema onto an older binary may not work. See the release-notes convention in [deploy.md](deploy.md).

## A backup counts only after a restore drill

Run the drill against a pulled copy on the machine that holds it, and record it here and in the project's
Done log. A pulled copy that never went through a drill is a hope, not a backup.

| Date (UTC) | Set | Where | Result |
|---|---|---|---|
| _not yet drilled_ | | | |

## Pulling backups to another machine

Set up the restricted key as described in [deploy.md](deploy.md), then schedule:

```sh
REMOTE=deploy@host.example.com REMOTE_DIR=/ SSH_KEY=~/.ssh/goweb-pull DEST=$HOME/Backups/goweb scripts/pull-backups.sh
```

Needs the `sqlite3` CLI on the pulling machine. Optional `MIRROR_DIR` (copied to only if it already exists) and
`NOTIFY_CMD`. Exit status:

| Code | Meaning |
|---|---|
| 0 | all good, the newest verified copy is fresh |
| 1 | something failed (ssh, rsync, integrity check) or the newest copy is older than `STALE_DAYS` (3) or missing |
| 2 | bad configuration |
| 3 | another pull holds the lock; no notification (the freshness alert still runs) |

A notification is raised on exit 1 conditions. Check that the scheduled job actually runs (launchd log
or `launchctl list`), and look at `DEST` now and then.

## Mac backup agent

`scripts/install-backup-agent.sh` installs a launchd user agent (`com.goweb.backup-pull`) that runs
`pull-backups.sh` daily at 03:30. Settings live in one file, not in the plist:

```sh
mkdir -p ~/.config/goweb
cp scripts/backup-pull.env.example ~/.config/goweb/backup-pull.env   # set REMOTE and REMOTE_DIR, others optional
scripts/install-backup-agent.sh               # install or replace the agent; verifies it with launchctl list
scripts/install-backup-agent.sh --uninstall   # unload and remove it
```

- `REMOTE` and `REMOTE_DIR` are required (exit 2 and nothing written if either is missing). `DEST`, `KEEP`,
  `SSH_KEY`, `STALE_DAYS` and `MIRROR_DIR` are optional and behave as in `pull-backups.sh`. The agent sources the
  file when it runs, so edits apply without reinstalling, and values with spaces must be quoted.
- Re-running the installer replaces the agent (it boots the old one out first); it never leaves two.
- Output goes to `~/Library/Logs/goweb/backup-pull.log`. A Mac that is asleep at 03:30 runs the job on wake.
- Check it with `launchctl list com.goweb.backup-pull` and the log. A failed pull or a stale copy raises a
  notification (see the exit table above).
- Environment overrides for tests: `ENV_FILE`, `LAUNCHAGENTS_DIR`, `LAUNCHCTL`, `PULL_SCRIPT`.

## Disk and logs

- Each set is roughly the database plus the photos, so 14 daily sets plus 5 pre-deploy sets (plus any
  `pre-restore-*` copies) on the server cost that many times the data; watch the disk usage of the data volume
  and alert at 80 percent.
- The app rotates its own log under `<DATA_DIR>/logs/` by size (5 MiB, 5 generations kept); there is no system
  logrotate to configure for a non-root user.
- The service's own output goes to the user journal (`journalctl --user -u goweb`).
