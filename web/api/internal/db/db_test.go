package db_test

import (
	"context"
	"database/sql"
	"errors"
	"path/filepath"
	"testing"
	"time"

	"goweb/internal/db"
)

func TestOpenSetsPragmas(t *testing.T) {
	d, err := db.Open(filepath.Join(t.TempDir(), "sub", "x.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	var mode string
	if err := d.QueryRow("PRAGMA journal_mode").Scan(&mode); err != nil || mode != "wal" {
		t.Fatalf("journal_mode = %q, %v", mode, err)
	}
	var fk, busy int
	if err := d.QueryRow("PRAGMA foreign_keys").Scan(&fk); err != nil || fk != 1 {
		t.Fatalf("foreign_keys = %d, %v", fk, err)
	}
	if err := d.QueryRow("PRAGMA busy_timeout").Scan(&busy); err != nil || busy != 15000 {
		t.Fatalf("busy_timeout = %d, %v", busy, err)
	}
}

func TestOpenMemoryUsesOneConnection(t *testing.T) {
	d, err := db.Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	if n := d.Stats().MaxOpenConnections; n != 1 {
		t.Fatalf("MaxOpenConnections = %d, want 1", n)
	}
}

func TestOpenFilePoolBounds(t *testing.T) {
	d, err := db.Open(filepath.Join(t.TempDir(), "x.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	if n := d.Stats().MaxOpenConnections; n < 4 || n > 16 {
		t.Fatalf("MaxOpenConnections = %d, want within [4,16]", n)
	}
}

func TestPragmasApplyToEveryPooledConnection(t *testing.T) {
	ctx := context.Background()
	d, err := db.Open(filepath.Join(t.TempDir(), "x.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	c1, err := d.Conn(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer c1.Close()
	c2, err := d.Conn(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer c2.Close()
	for i, c := range []interface {
		QueryRowContext(context.Context, string, ...any) *sql.Row
	}{c1, c2} {
		var fk, busy int
		if err := c.QueryRowContext(ctx, "PRAGMA foreign_keys").Scan(&fk); err != nil || fk != 1 {
			t.Fatalf("conn %d foreign_keys = %d, %v", i, fk, err)
		}
		if err := c.QueryRowContext(ctx, "PRAGMA busy_timeout").Scan(&busy); err != nil || busy != 15000 {
			t.Fatalf("conn %d busy_timeout = %d, %v", i, busy, err)
		}
	}
}

// With _txlock=immediate, BeginTx takes the write lock right away, so a second
// writer must block even though the first has run no statement yet.
func TestTransactionsAreImmediate(t *testing.T) {
	d, err := db.Open(filepath.Join(t.TempDir(), "x.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	// Short busy timeout on the second connection so the test is fast.
	tx1, err := d.BeginTx(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer tx1.Rollback()

	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	tx2, err := d.BeginTx(ctx, nil)
	if err == nil {
		tx2.Rollback()
		t.Fatal("second write transaction started while the first was open; transactions are not immediate")
	}
	if !errors.Is(err, context.DeadlineExceeded) && ctx.Err() == nil {
		t.Fatalf("unexpected error: %v", err)
	}
}
