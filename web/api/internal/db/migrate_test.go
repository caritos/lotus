package db_test

import (
	"context"
	"strings"
	"testing"
	"testing/fstest"

	"goweb/internal/db"
)

func TestMigrateFreshAppliesAll(t *testing.T) {
	ctx := context.Background()
	d, err := db.Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
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
	d, _ := db.Open(":memory:")
	defer d.Close()
	for i := 0; i < 2; i++ {
		if err := db.Migrate(ctx, d); err != nil {
			t.Fatalf("run %d: %v", i, err)
		}
	}
	var n int
	d.QueryRow("SELECT count(*) FROM schema_migrations").Scan(&n)
	if n != 1 {
		t.Fatalf("schema_migrations rows = %d, want 1", n)
	}
}

func TestMigrateUpgradesPopulatedDB(t *testing.T) {
	ctx := context.Background()
	d, _ := db.Open(":memory:")
	defer d.Close()
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
	d, _ := db.Open(":memory:")
	defer d.Close()
	fsys := fstest.MapFS{
		"0001_ok.sql":  {Data: []byte("CREATE TABLE ok (id TEXT);")},
		"0002_bad.sql": {Data: []byte("CREATE TABLE half (id TEXT); THIS IS NOT SQL;")},
	}
	err := db.MigrateFS(ctx, d, fsys)
	if err == nil || !strings.Contains(err.Error(), "0002_bad.sql") {
		t.Fatalf("err = %v, want mention of 0002_bad.sql", err)
	}
	var n int
	d.QueryRow("SELECT count(*) FROM schema_migrations WHERE version='0002_bad.sql'").Scan(&n)
	if n != 0 {
		t.Fatal("failed migration was recorded")
	}
	d.QueryRow("SELECT count(*) FROM sqlite_master WHERE name='half'").Scan(&n)
	if n != 0 {
		t.Fatal("failed migration left partial schema")
	}
	d.QueryRow("SELECT count(*) FROM schema_migrations WHERE version='0001_ok.sql'").Scan(&n)
	if n != 1 {
		t.Fatal("earlier migration not kept")
	}
}
