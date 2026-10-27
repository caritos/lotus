package tests

import (
	"bytes"
	"context"
	"database/sql"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"

	"goweb/internal/apptest"
	"goweb/internal/backup"
	"goweb/internal/db"
)

// restoredNote is a notes row read from the restored database.
type restoredNote struct {
	ID, Title, Photo string
}

func liveNotes(t *testing.T, d *sql.DB) map[string]restoredNote {
	t.Helper()
	rows, err := d.Query(`SELECT id, title, COALESCE(photo, '') FROM notes WHERE archived_at IS NULL`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	out := map[string]restoredNote{}
	for rows.Next() {
		var n restoredNote
		if err := rows.Scan(&n.ID, &n.Title, &n.Photo); err != nil {
			t.Fatal(err)
		}
		out[n.ID] = n
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return out
}

func copyTree(t *testing.T, src, dst string) {
	t.Helper()
	err := filepath.WalkDir(src, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, p)
		target := filepath.Join(dst, rel)
		if d.IsDir() {
			return os.MkdirAll(target, 0o700)
		}
		in, err := os.Open(p)
		if err != nil {
			return err
		}
		defer in.Close()
		out, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
		if err != nil {
			return err
		}
		defer out.Close()
		_, err = io.Copy(out, in)
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestBackupRestoreRoundTrip(t *testing.T) {
	integration(t)
	a := apptest.NewServer(t)
	a.CreateUser(testEmail, testPassword)
	a.CreateUser("bob@example.com", testPassword)
	mustLogin(t, a, a.Client, testEmail, testPassword)
	bob := a.NewClient()
	mustLogin(t, a, bob, "bob@example.com", testPassword)

	withPhoto := createNote(t, a, a.Client, "with photo")
	plain := createNote(t, a, a.Client, "plain")
	bobNote := createNote(t, a, bob, "bobs")
	original := testPNG(t, 90)
	if st, body := putPhoto(t, a, a.Client, withPhoto.ID, original); st != http.StatusOK {
		t.Fatalf("upload = %d %s", st, body)
	}

	res, err := backup.Run(context.Background(), a.DB, a.DataDir, 3, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if err := backup.Verify(res.Dir); err != nil {
		t.Fatalf("Verify on fresh set: %v", err)
	}

	// Mutate after the backup.
	createNote(t, a, a.Client, "added later")
	if st, _, _ := req(t, a.Client, http.MethodDelete, a.URL+"/api/notes/"+plain.ID, nil, nil); st != http.StatusNoContent {
		t.Fatalf("archive = %d", st)
	}
	if st, body := putPhoto(t, a, a.Client, withPhoto.ID, testJPEG(t)); st != http.StatusOK {
		t.Fatalf("replace photo = %d %s", st, body)
	}

	// Restore into a scratch DATA_DIR the documented way: copy goweb.db and storage/.
	scratch := t.TempDir()
	cfgDB := filepath.Join(scratch, "db", "goweb.db")
	if err := os.MkdirAll(filepath.Dir(cfgDB), 0o700); err != nil {
		t.Fatal(err)
	}
	copyTree(t, filepath.Join(res.Dir, "storage"), filepath.Join(scratch, "storage"))
	snap, err := os.ReadFile(filepath.Join(res.Dir, "goweb.db"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(cfgDB, snap, 0o600); err != nil {
		t.Fatal(err)
	}

	d, err := db.Open(cfgDB)
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()

	got := liveNotes(t, d)
	if len(got) != 3 {
		t.Fatalf("restored notes = %d, want 3 (state at backup time): %+v", len(got), got)
	}
	for _, n := range []struct{ id, title string }{{withPhoto.ID, "with photo"}, {plain.ID, "plain"}, {bobNote.ID, "bobs"}} {
		if got[n.id].Title != n.title {
			t.Errorf("note %s title = %q, want %q", n.id, got[n.id].Title, n.title)
		}
	}
	photo := got[withPhoto.ID].Photo
	if photo == "" {
		t.Fatal("restored note lost its photo reference")
	}
	b, err := os.ReadFile(filepath.Join(scratch, "storage", photo))
	if err != nil {
		t.Fatalf("restored photo file: %v", err)
	}
	if !bytes.Equal(b, original) {
		t.Fatal("restored photo bytes differ from the state at backup time")
	}

	// The restored database is current: migrating it is a no-op.
	var before, after int
	if err := d.QueryRow(`SELECT count(*) FROM schema_migrations`).Scan(&before); err != nil {
		t.Fatal(err)
	}
	if err := db.Migrate(context.Background(), d); err != nil {
		t.Fatalf("migrate restored db: %v", err)
	}
	if err := d.QueryRow(`SELECT count(*) FROM schema_migrations`).Scan(&after); err != nil {
		t.Fatal(err)
	}
	if before == 0 || before != after {
		t.Fatalf("schema_migrations rows before/after = %d/%d, want equal and non-zero", before, after)
	}
}
