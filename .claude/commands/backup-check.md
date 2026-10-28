---
description: Check the newest backup set for age and integrity (read-only)
---

Check the newest completed backup set.

1. Find the data directory. In development it is `web/`, so backups are in `web/backups/`. On a server it is whatever `DATA_DIR` is set to, with sets in `$DATA_DIR/backups`. If you are not sure which `DATA_DIR` I mean, ask me before looking.
2. The newest completed set is the newest directory named exactly like a UTC timestamp (`YYYYMMDDTHHMMSSZ`): not a `.partial`, not a labeled set such as `YYYYMMDDTHHMMSSZ-predeploy` (those are pre-deploy snapshots with their own retention) and not a `pre-restore-*` safety copy. If there is none, say so and stop.
3. Report its age from the timestamp in its name.
4. Verify it: build the binary if needed into a scratch directory (`d=$(mktemp -d)` then `cd web/api && go build -o "$d/app" ./cmd/app`) and run `"$d/app" verify-backup <set dir>`.
5. Flag it clearly if it is older than 3 days or if verification fails, and point to `web/docs/backups.md`.

This command is read-only apart from the scratch build. Never delete, move or restore anything.
