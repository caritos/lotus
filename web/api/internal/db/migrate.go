package db

import (
	"context"
	"database/sql"
	"fmt"
	"io/fs"
	"sort"
	"time"

	"goweb/internal/db/migrations"
)

// Migrate applies the embedded migrations.
func Migrate(ctx context.Context, d *sql.DB) error {
	return MigrateFS(ctx, d, migrations.FS)
}

// MigrateFS applies every *.sql file in fsys (sorted by name) that is not yet
// recorded in schema_migrations, one transaction per file. A failing file
// rolls back, is not recorded, and stops the run with an error naming it.
func MigrateFS(ctx context.Context, d *sql.DB, fsys fs.FS) error {
	if _, err := d.ExecContext(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (
		version TEXT PRIMARY KEY,
		applied_at INTEGER NOT NULL
	)`); err != nil {
		return fmt.Errorf("db: create schema_migrations: %w", err)
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

func apply(ctx context.Context, d *sql.DB, name, body string) error {
	tx, err := d.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("db: migration %s: begin: %w", name, err)
	}
	defer tx.Rollback() //nolint:errcheck // no-op after commit
	// Checked inside the write transaction (BEGIN IMMEDIATE) so a concurrent
	// migrator that committed first is seen and this one skips the file.
	var n int
	if err := tx.QueryRowContext(ctx, "SELECT count(*) FROM schema_migrations WHERE version = ?", name).Scan(&n); err != nil {
		return fmt.Errorf("db: migration %s: check: %w", name, err)
	}
	if n > 0 {
		return nil
	}
	// modernc.org/sqlite executes every statement in a multi-statement string.
	if _, err := tx.ExecContext(ctx, body); err != nil {
		return fmt.Errorf("db: migration %s: %w", name, err)
	}
	if _, err := tx.ExecContext(ctx, "INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)", name, time.Now().UnixMilli()); err != nil {
		return fmt.Errorf("db: migration %s: record: %w", name, err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("db: migration %s: commit: %w", name, err)
	}
	return nil
}
