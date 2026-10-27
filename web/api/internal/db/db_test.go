package db_test

import (
	"path/filepath"
	"testing"

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
