// Package db opens the SQLite database and runs its embedded migrations.
//
// Migration files are checksummed over their exact bytes (sha256). Whitespace, comment and
// line-ending changes therefore count as edits to an applied migration and stop the run; the
// repository's .gitattributes marks *.sql as -text so an autocrlf checkout cannot alter the bytes.
package db

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"regexp"
	"sort"
	"strings"
	"time"

	"app/internal/db/migrations"
)

// migrationName is the only accepted file name shape: a four-digit version, an underscore and a
// lowercase description, for example 0002_add_tags.sql.
var migrationName = regexp.MustCompile(`^[0-9]{4}_[a-z0-9_]+\.sql$`)

// Migrate applies the embedded migrations.
func Migrate(ctx context.Context, d *sql.DB) error {
	return MigrateFS(ctx, d, migrations.FS)
}

// MigrateFS applies every *.sql file in fsys (sorted by name) that is not yet
// recorded in schema_migrations, one transaction per file. A failing file
// rolls back, is not recorded, and stops the run with an error naming it.
//
// Each applied file's sha256 is recorded. A file that is already applied but
// whose bytes no longer match its recorded checksum stops the run with an error
// naming it, before anything further is applied. Rows from before checksums
// existed are backfilled from fsys the first time they are seen, so the history
// of such a database cannot be verified.
//
// The checksum is over the exact bytes of the file, so a change of whitespace or line endings is an
// edit and is refused like any other (see the package comment about .gitattributes).
//
// A recorded migration whose file is no longer in fsys is NOT verified and not an error: that keeps
// a rolled-back binary, which embeds fewer files than the database has recorded, working.
//
// Every *.sql file must be named NNNN_description.sql (^[0-9]{4}_[a-z0-9_]+\.sql$) and no two
// files may share the NNNN version; either problem is an error naming the file, found before any database access, so nothing
// (not even schema_migrations) is created or changed. A name that ends in .sql in any case but does
// not match (0002_x.SQL) is rejected, not skipped. Gaps in the numbering are allowed.
func MigrateFS(ctx context.Context, d *sql.DB, fsys fs.FS) error {
	// Validate the whole set before touching the database at all, so a bad file name or a duplicate
	// version changes nothing (not even schema_migrations).
	entries, err := fs.ReadDir(fsys, ".")
	if err != nil {
		return fmt.Errorf("db: list migrations: %w", err)
	}
	var names []string
	for _, e := range entries {
		// Anything that ends in .sql in any case is meant as a migration: a name like 0002_x.SQL
		// must be rejected, not silently skipped.
		if e.IsDir() || !strings.HasSuffix(strings.ToLower(e.Name()), ".sql") {
			continue
		}
		names = append(names, e.Name())
	}
	sort.Strings(names)
	byVersion := map[string]string{}
	for _, name := range names {
		if !migrationName.MatchString(name) {
			return fmt.Errorf("db: migration file %q: name must match NNNN_description.sql (four digits, then lowercase letters, digits and underscores)", name)
		}
		if other, dup := byVersion[name[:4]]; dup {
			return fmt.Errorf("db: migration files %q and %q have the same version %s", other, name, name[:4])
		}
		byVersion[name[:4]] = name
	}
	if err := ensureTable(ctx, d); err != nil {
		return err
	}
	for _, name := range names {
		body, err := fs.ReadFile(fsys, name)
		if err != nil {
			return fmt.Errorf("db: read %s: %w", name, err)
		}
		if err := apply(ctx, d, name, string(body)); err != nil {
			return err
		}
	}
	return nil
}

// ensureTable creates schema_migrations and adds the checksum column to a table
// that predates it. It runs in one write transaction so concurrent migrators
// cannot both try to add the column.
func ensureTable(ctx context.Context, d *sql.DB) error {
	tx, err := d.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("db: schema_migrations: begin: %w", err)
	}
	defer tx.Rollback() //nolint:errcheck // no-op after commit
	if _, err := tx.ExecContext(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (
		version TEXT PRIMARY KEY,
		applied_at INTEGER NOT NULL,
		checksum TEXT
	)`); err != nil {
		return fmt.Errorf("db: create schema_migrations: %w", err)
	}
	var n int
	if err := tx.QueryRowContext(ctx, "SELECT count(*) FROM pragma_table_info('schema_migrations') WHERE name = 'checksum'").Scan(&n); err != nil {
		return fmt.Errorf("db: inspect schema_migrations: %w", err)
	}
	if n == 0 {
		if _, err := tx.ExecContext(ctx, "ALTER TABLE schema_migrations ADD COLUMN checksum TEXT"); err != nil {
			return fmt.Errorf("db: add schema_migrations.checksum: %w", err)
		}
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("db: schema_migrations: commit: %w", err)
	}
	return nil
}

func apply(ctx context.Context, d *sql.DB, name, body string) error {
	sumBytes := sha256.Sum256([]byte(body))
	sum := hex.EncodeToString(sumBytes[:])
	tx, err := d.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("db: migration %s: begin: %w", name, err)
	}
	defer tx.Rollback() //nolint:errcheck // no-op after commit
	// Checked inside the write transaction (BEGIN IMMEDIATE) so a concurrent
	// migrator that committed first is seen and this one skips the file.
	var recorded sql.NullString
	err = tx.QueryRowContext(ctx, "SELECT checksum FROM schema_migrations WHERE version = ?", name).Scan(&recorded)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("db: migration %s: check: %w", name, err)
	}
	if err == nil {
		switch {
		case !recorded.Valid:
			// Applied before checksums existed: trust the embedded file once.
			if _, err := tx.ExecContext(ctx, "UPDATE schema_migrations SET checksum = ? WHERE version = ?", sum, name); err != nil {
				return fmt.Errorf("db: migration %s: backfill checksum: %w", name, err)
			}
			if err := tx.Commit(); err != nil {
				return fmt.Errorf("db: migration %s: commit: %w", name, err)
			}
		case recorded.String != sum:
			return fmt.Errorf("db: migration %s was edited after it was applied (recorded checksum %s, file checksum %s): add a new migration instead", name, recorded.String, sum)
		}
		return nil
	}
	// modernc.org/sqlite executes every statement in a multi-statement string.
	if _, err := tx.ExecContext(ctx, body); err != nil {
		return fmt.Errorf("db: migration %s: %w", name, err)
	}
	if _, err := tx.ExecContext(ctx, "INSERT INTO schema_migrations (version, applied_at, checksum) VALUES (?, ?, ?)", name, time.Now().UnixMilli(), sum); err != nil {
		return fmt.Errorf("db: migration %s: record: %w", name, err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("db: migration %s: commit: %w", name, err)
	}
	return nil
}
