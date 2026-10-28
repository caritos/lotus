// Package testutil holds helpers shared by tests.
package testutil

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"

	"app/internal/db"
)

// NewDB returns a migrated temp-file database, closed when the test ends.
func NewDB(t testing.TB) *sql.DB {
	t.Helper()
	d, err := db.Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("testutil.NewDB: open: %v", err)
	}
	t.Cleanup(func() { d.Close() })
	if err := db.Migrate(context.Background(), d); err != nil {
		t.Fatalf("testutil.NewDB: migrate: %v", err)
	}
	return d
}
