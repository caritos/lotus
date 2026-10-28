package db

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"sort"
	"time"

	"app/internal/db/migrations"
)

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
func MigrateFS(ctx context.Context, d *sql.DB, fsys fs.FS) error {
	if err := ensureTable(ctx, d); err != nil {
		return err
	}
	names, err := fs.Glob(fsys, "*.sql")
	if err != nil {
		return fmt.Errorf("db: list migrations: %w", err)
	}
	sort.Strings(names)
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
