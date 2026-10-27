// Package backup writes consistent snapshots of the database and uploaded files,
// prunes old ones, and verifies a snapshot.
package backup

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"syscall"
	"time"

	_ "modernc.org/sqlite" // registers the "sqlite" driver for Verify
)

const (
	stampLayout = "20060102T150405Z"
	dbName      = "goweb.db"
	storageName = "storage"
)

var (
	// setName matches an unlabeled (daily) set; labeledName a labeled one, such as
	// 20261027T031500Z-predeploy. Each kind is pruned separately.
	setName     = regexp.MustCompile(`^\d{8}T\d{6}Z$`)
	labeledName = regexp.MustCompile(`^\d{8}T\d{6}Z-([a-z][a-z0-9-]{0,15})$`)
	partialName = regexp.MustCompile(`^(\d{8}T\d{6}Z)(-[a-z][a-z0-9-]{0,15})?\.partial$`)
	validLabel  = regexp.MustCompile(`^[a-z][a-z0-9-]{0,15}$`)
)

// ErrBusy is returned when another backup run holds the lock.
var ErrBusy = errors.New("backup: another backup is running")

// Result describes a completed backup set.
type Result struct {
	Dir   string // the backup set directory
	Files int    // storage files copied
}

// Run writes an unlabeled backup set <dataDir>/backups/<UTC timestamp>/ containing goweb.db
// (a VACUUM INTO snapshot) and storage/ (a copy of <dataDir>/storage), then keeps
// only the newest `keep` completed sets. The set is built in <name>.partial and
// renamed into place last; the rename is the completion marker.
//
// Known limitation: the snapshot is taken first and storage is copied afterwards,
// so a photo added or removed between the two steps can leave the set slightly
// inconsistent (a referenced file missing, or an unreferenced file present).
// Verify reports referenced files that are missing.
func Run(ctx context.Context, d *sql.DB, dataDir string, keep int, now time.Time) (Result, error) {
	return RunLabel(ctx, d, dataDir, "", keep, now)
}

// RunLabel is Run for a labeled set: with a non-empty label the set is named
// <UTC timestamp>-<label> (label: a lowercase letter, then up to 15 lowercase
// letters, digits or '-') and keep applies only to sets with that same label.
// Unlabeled (daily) sets and labeled sets never prune each other. An empty label
// is Run.
func RunLabel(ctx context.Context, d *sql.DB, dataDir, label string, keep int, now time.Time) (Result, error) {
	if label != "" && !validLabel.MatchString(label) {
		return Result{}, fmt.Errorf("backup: invalid label %q: use a lowercase letter followed by up to 15 lowercase letters, digits or '-'", label)
	}
	if keep < 1 {
		return Result{}, fmt.Errorf("backup: keep must be at least 1, got %d", keep)
	}
	root := filepath.Join(dataDir, "backups")
	if err := os.MkdirAll(root, 0o700); err != nil {
		return Result{}, fmt.Errorf("backup: create %s: %w", root, err)
	}
	if err := os.Chmod(root, 0o700); err != nil {
		return Result{}, fmt.Errorf("backup: chmod %s: %w", root, err)
	}
	// One run at a time: the lock covers building, finalizing and pruning, so a
	// concurrent run can never clear or finalize our .partial directory.
	lock, err := os.OpenFile(filepath.Join(root, ".lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return Result{}, fmt.Errorf("backup: open lock: %w", err)
	}
	defer lock.Close() // closing releases the flock
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return Result{}, ErrBusy
		}
		return Result{}, fmt.Errorf("backup: lock: %w", err)
	}
	stamp := now.UTC().Format(stampLayout)
	name := stamp
	if label != "" {
		name += "-" + label
	}
	final := filepath.Join(root, name)
	partial := final + ".partial"
	if _, err := os.Lstat(final); err == nil {
		return Result{}, fmt.Errorf("backup: %s already exists", final)
	}
	// Mkdir (no prior RemoveAll) fails if a same-stamp partial exists.
	if err := os.Mkdir(partial, 0o700); err != nil {
		return Result{}, fmt.Errorf("backup: create %s: %w", partial, err)
	}
	files, err := build(ctx, d, dataDir, partial)
	if err != nil {
		os.RemoveAll(partial)
		return Result{}, err
	}
	if err := os.Rename(partial, final); err != nil {
		os.RemoveAll(partial)
		return Result{}, fmt.Errorf("backup: finalize: %w", err)
	}
	if err := prune(root, stamp, label, keep); err != nil {
		return Result{Dir: final, Files: files}, err
	}
	return Result{Dir: final, Files: files}, nil
}

func build(ctx context.Context, d *sql.DB, dataDir, partial string) (int, error) {
	snap := filepath.Join(partial, dbName)
	// The path is a bound parameter, so quotes in it cannot alter the statement.
	if _, err := d.ExecContext(ctx, "VACUUM INTO ?", snap); err != nil {
		return 0, fmt.Errorf("backup: snapshot: %w", err)
	}
	if err := os.Chmod(snap, 0o600); err != nil {
		return 0, fmt.Errorf("backup: chmod snapshot: %w", err)
	}
	if err := integrity(ctx, snap); err != nil {
		return 0, fmt.Errorf("backup: snapshot failed verification: %w", err)
	}
	n, err := copyStorage(ctx, filepath.Join(dataDir, storageName), filepath.Join(partial, storageName))
	if err != nil {
		return 0, err
	}
	return n, nil
}

// copyStorage copies the regular files of src (flat directory) into a new dst.
// Symlinks, subdirectories and in-flight .upload-* temp files are skipped.
func copyStorage(ctx context.Context, src, dst string) (int, error) {
	if err := os.Mkdir(dst, 0o700); err != nil {
		return 0, fmt.Errorf("backup: create storage dir: %w", err)
	}
	entries, err := os.ReadDir(src)
	if errors.Is(err, os.ErrNotExist) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("backup: read storage: %w", err)
	}
	n := 0
	for _, e := range entries {
		if err := ctx.Err(); err != nil {
			return n, err
		}
		if !e.Type().IsRegular() || strings.HasPrefix(e.Name(), ".upload-") {
			continue
		}
		copied, err := copyFile(filepath.Join(src, e.Name()), filepath.Join(dst, e.Name()))
		if err != nil {
			return n, err
		}
		if copied {
			n++
		}
	}
	return n, nil
}

// copyFile copies one regular file without following symlinks. A file that
// vanished (deleted concurrently) is skipped.
func copyFile(src, dst string) (bool, error) {
	in, err := os.OpenFile(src, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("backup: open %s: %w", src, err)
	}
	defer in.Close()
	if fi, err := in.Stat(); err != nil || !fi.Mode().IsRegular() {
		return false, nil
	}
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return false, fmt.Errorf("backup: create %s: %w", dst, err)
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return false, fmt.Errorf("backup: copy %s: %w", src, err)
	}
	if err := out.Sync(); err != nil {
		out.Close()
		return false, fmt.Errorf("backup: sync %s: %w", dst, err)
	}
	if err := out.Close(); err != nil {
		return false, fmt.Errorf("backup: close %s: %w", dst, err)
	}
	return true, nil
}

// prune removes stale .partial dirs (of any label) older than the current run
// and all but the newest keep completed sets carrying label ("" means the
// unlabeled daily sets). Sets with another label and entries with any other
// name (pre-restore-*, foreign files) are never touched.
func prune(root, currentStamp, label string, keep int) error {
	entries, err := os.ReadDir(root)
	if err != nil {
		return fmt.Errorf("backup: prune: %w", err)
	}
	var sets []string
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		name := e.Name()
		if m := partialName.FindStringSubmatch(name); m != nil {
			if m[1] < currentStamp {
				if err := os.RemoveAll(filepath.Join(root, name)); err != nil {
					return fmt.Errorf("backup: prune: %w", err)
				}
			}
			continue
		}
		if label == "" {
			if setName.MatchString(name) {
				sets = append(sets, name)
			}
		} else if m := labeledName.FindStringSubmatch(name); m != nil && m[1] == label {
			sets = append(sets, name)
		}
	}
	sort.Strings(sets)
	for len(sets) > keep {
		if err := os.RemoveAll(filepath.Join(root, sets[0])); err != nil {
			return fmt.Errorf("backup: prune: %w", err)
		}
		sets = sets[1:]
	}
	return nil
}

func openReadOnly(path string) (*sql.DB, error) {
	abs, err := filepath.Abs(path)
	if err != nil {
		return nil, err
	}
	u := url.URL{Scheme: "file", Path: abs, RawQuery: url.Values{"mode": {"ro"}}.Encode()}
	return sql.Open("sqlite", u.String())
}

func integrity(ctx context.Context, path string) error {
	d, err := openReadOnly(path)
	if err != nil {
		return err
	}
	defer d.Close()
	return checkIntegrity(ctx, d)
}

func checkIntegrity(ctx context.Context, d *sql.DB) error {
	rows, err := d.QueryContext(ctx, "PRAGMA integrity_check")
	if err != nil {
		return fmt.Errorf("integrity_check: %w", err)
	}
	defer rows.Close()
	var bad []string
	for rows.Next() {
		var s string
		if err := rows.Scan(&s); err != nil {
			return fmt.Errorf("integrity_check: %w", err)
		}
		if s != "ok" {
			bad = append(bad, s)
		}
	}
	if err := rows.Err(); err != nil {
		return fmt.Errorf("integrity_check: %w", err)
	}
	if len(bad) > 0 {
		return fmt.Errorf("integrity_check: %s", strings.Join(bad, "; "))
	}
	return nil
}

// Verify checks a backup set directory: the database passes integrity_check,
// schema_migrations exists and is non-empty, and every non-null notes.photo
// (archived notes included) is a regular file in storage/. All problems are
// reported together.
func Verify(dir string) error {
	ctx := context.Background()
	dbPath := filepath.Join(dir, dbName)
	if fi, err := os.Stat(dbPath); err != nil || !fi.Mode().IsRegular() {
		return fmt.Errorf("verify: %s is missing", dbPath)
	}
	d, err := openReadOnly(dbPath)
	if err != nil {
		return fmt.Errorf("verify: open: %w", err)
	}
	defer d.Close()
	if err := checkIntegrity(ctx, d); err != nil {
		return fmt.Errorf("verify: %w", err)
	}
	var problems []string
	var n int
	if err := d.QueryRowContext(ctx, "SELECT count(*) FROM schema_migrations").Scan(&n); err != nil {
		problems = append(problems, fmt.Sprintf("schema_migrations: %v", err))
	} else if n == 0 {
		problems = append(problems, "schema_migrations is empty")
	}
	rows, err := d.QueryContext(ctx, "SELECT id, photo FROM notes WHERE photo IS NOT NULL")
	if err != nil {
		problems = append(problems, fmt.Sprintf("notes: %v", err))
	} else {
		defer rows.Close()
		for rows.Next() {
			var id, photo string
			if err := rows.Scan(&id, &photo); err != nil {
				problems = append(problems, fmt.Sprintf("notes: %v", err))
				break
			}
			if photo == "" || photo == "." || photo == ".." || strings.ContainsAny(photo, `/\`) {
				problems = append(problems, fmt.Sprintf("note %s: invalid photo name %q", id, photo))
				continue
			}
			fi, err := os.Lstat(filepath.Join(dir, storageName, photo))
			if err != nil || !fi.Mode().IsRegular() {
				problems = append(problems, fmt.Sprintf("note %s: photo %s missing from storage/", id, photo))
			}
		}
		if err := rows.Err(); err != nil {
			problems = append(problems, fmt.Sprintf("notes: %v", err))
		}
	}
	if len(problems) > 0 {
		return fmt.Errorf("verify: %d problem(s):\n  %s", len(problems), strings.Join(problems, "\n  "))
	}
	return nil
}
