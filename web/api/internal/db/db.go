// Package db opens the SQLite database and applies embedded migrations.
package db

import (
	"database/sql"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"runtime"

	_ "modernc.org/sqlite" // pure-Go driver, registers "sqlite"
)

const memoryPath = ":memory:"

// Open opens (creating if needed) the database at path with WAL, foreign keys,
// a 15s busy timeout and immediate write transactions. The parent directory is
// created with mode 0700. ":memory:" yields a single-connection pool.
func Open(path string) (*sql.DB, error) {
	q := url.Values{}
	q.Add("_pragma", "foreign_keys(1)")
	q.Add("_pragma", "busy_timeout(15000)")
	q.Add("_txlock", "immediate")

	var dsn string
	if path == memoryPath {
		dsn = "file::memory:?" + q.Encode()
	} else {
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			return nil, fmt.Errorf("db: create directory: %w", err)
		}
		q.Add("_pragma", "journal_mode(WAL)")
		dsn = (&url.URL{Scheme: "file", Opaque: filepath.ToSlash(path), RawQuery: q.Encode()}).String()
	}

	d, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("db: open: %w", err)
	}
	if path == memoryPath {
		d.SetMaxOpenConns(1)
		d.SetMaxIdleConns(1)
		d.SetConnMaxLifetime(0)
	} else {
		n := min(max(runtime.NumCPU(), 4), 16)
		d.SetMaxOpenConns(n)
		d.SetMaxIdleConns(n)
	}
	if err := d.Ping(); err != nil {
		d.Close()
		return nil, fmt.Errorf("db: ping: %w", err)
	}
	return d, nil
}
