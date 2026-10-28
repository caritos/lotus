package db_test

import (
	"context"
	"database/sql"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"testing/fstest"

	"app/internal/db"
)

func openMem(t *testing.T) *sql.DB {
	t.Helper()
	d, err := db.Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { d.Close() })
	return d
}

func scanInt(t *testing.T, d *sql.DB, q string) int {
	t.Helper()
	var n int
	if err := d.QueryRow(q).Scan(&n); err != nil {
		t.Fatalf("%s: %v", q, err)
	}
	return n
}

func TestMigrateConcurrentIsSafe(t *testing.T) {
	ctx := context.Background()
	d, err := db.Open(filepath.Join(t.TempDir(), "c.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	const workers = 4
	errs := make([]error, workers)
	start := make(chan struct{})
	var wg sync.WaitGroup
	for i := range workers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			errs[i] = db.Migrate(ctx, d)
		}()
	}
	close(start)
	wg.Wait()
	for i, e := range errs {
		if e != nil {
			t.Fatalf("worker %d: %v", i, e)
		}
	}
	if n := scanInt(t, d, "SELECT count(*) FROM schema_migrations"); n != 1 {
		t.Fatalf("schema_migrations rows = %d, want 1", n)
	}
}

func TestMigrateFreshAppliesAll(t *testing.T) {
	ctx := context.Background()
	d := openMem(t)
	if err := db.Migrate(ctx, d); err != nil {
		t.Fatal(err)
	}
	for _, tbl := range []string{"users", "sessions", "notes", "schema_migrations"} {
		var n int
		if err := d.QueryRow("SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?", tbl).Scan(&n); err != nil || n != 1 {
			t.Fatalf("table %s missing (n=%d, err=%v)", tbl, n, err)
		}
	}
	var v string
	if err := d.QueryRow("SELECT version FROM schema_migrations").Scan(&v); err != nil || v != "0001_init.sql" {
		t.Fatalf("version = %q, %v", v, err)
	}
}

func TestMigrateIsIdempotent(t *testing.T) {
	ctx := context.Background()
	d := openMem(t)
	for i := 0; i < 2; i++ {
		if err := db.Migrate(ctx, d); err != nil {
			t.Fatalf("run %d: %v", i, err)
		}
	}
	if n := scanInt(t, d, "SELECT count(*) FROM schema_migrations"); n != 1 {
		t.Fatalf("schema_migrations rows = %d, want 1", n)
	}
}

func TestMigrateUpgradesPopulatedDB(t *testing.T) {
	ctx := context.Background()
	d := openMem(t)
	fsys := fstest.MapFS{
		"0001_a.sql": {Data: []byte("CREATE TABLE p (id TEXT PRIMARY KEY); CREATE TABLE c (id TEXT PRIMARY KEY, p_id TEXT NOT NULL REFERENCES p(id));")},
	}
	if err := db.MigrateFS(ctx, d, fsys); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec("INSERT INTO p VALUES ('p1'); INSERT INTO c VALUES ('c1','p1');"); err != nil {
		t.Fatal(err)
	}
	fsys["0002_b.sql"] = &fstest.MapFile{Data: []byte("ALTER TABLE c ADD COLUMN note TEXT;")}
	if err := db.MigrateFS(ctx, d, fsys); err != nil {
		t.Fatal(err)
	}
	var id string
	if err := d.QueryRow("SELECT id FROM c WHERE p_id='p1'").Scan(&id); err != nil || id != "c1" {
		t.Fatalf("row lost: %q, %v", id, err)
	}
	rows, err := d.Query("PRAGMA foreign_key_check")
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	if rows.Next() {
		t.Fatal("foreign_key_check reported violations")
	}
}

func TestMigrateFailureRollsBack(t *testing.T) {
	ctx := context.Background()
	d := openMem(t)
	fsys := fstest.MapFS{
		"0001_ok.sql":  {Data: []byte("CREATE TABLE ok (id TEXT);")},
		"0002_bad.sql": {Data: []byte("CREATE TABLE half (id TEXT); THIS IS NOT SQL;")},
	}
	err := db.MigrateFS(ctx, d, fsys)
	if err == nil || !strings.Contains(err.Error(), "0002_bad.sql") {
		t.Fatalf("err = %v, want mention of 0002_bad.sql", err)
	}
	if n := scanInt(t, d, "SELECT count(*) FROM schema_migrations WHERE version='0002_bad.sql'"); n != 0 {
		t.Fatal("failed migration was recorded")
	}
	if n := scanInt(t, d, "SELECT count(*) FROM sqlite_master WHERE name='half'"); n != 0 {
		t.Fatal("failed migration left partial schema")
	}
	if n := scanInt(t, d, "SELECT count(*) FROM schema_migrations WHERE version='0001_ok.sql'"); n != 1 {
		t.Fatal("earlier migration not kept")
	}
	if n := scanInt(t, d, "SELECT count(*) FROM sqlite_master WHERE name='ok'"); n != 1 {
		t.Fatal("earlier migration's table missing")
	}
}
