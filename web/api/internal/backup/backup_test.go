package backup

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"goweb/internal/db"
	"goweb/internal/testutil"
)

var t0 = time.Date(2026, 10, 27, 12, 0, 0, 0, time.UTC)

const photoA = "11111111-1111-1111-1111-111111111111.jpg"

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}

func seedNote(t *testing.T, d *sql.DB, id string, photo any) {
	t.Helper()
	d.Exec(`INSERT OR IGNORE INTO users (id, email, password_hash, created_at) VALUES ('u1','a@b.c','x',1)`)
	if _, err := d.Exec(`INSERT INTO notes (id, user_id, title, photo, created_at, updated_at) VALUES (?, 'u1', 't', ?, 1, 1)`, id, photo); err != nil {
		t.Fatal(err)
	}
}

func TestBackupIntegrityOK(t *testing.T) {
	d := testutil.NewDB(t)
	seedNote(t, d, "n1", nil)
	dataDir := t.TempDir()
	res, err := Run(context.Background(), d, dataDir, 5, t0)
	if err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(dataDir, "backups", "20261027T120000Z"); res.Dir != want {
		t.Fatalf("Dir = %q, want %q", res.Dir, want)
	}
	if err := Verify(res.Dir); err != nil {
		t.Fatalf("Verify: %v", err)
	}
}

func TestBackupWhileWriting(t *testing.T) {
	path := filepath.Join(t.TempDir(), "live.db")
	d, err := db.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	if err := db.Migrate(context.Background(), d); err != nil {
		t.Fatal(err)
	}
	d2, err := db.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer d2.Close()
	seedNote(t, d, "seed", nil)

	stop := make(chan struct{})
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; ; i++ {
			select {
			case <-stop:
				return
			default:
			}
			d2.Exec(`INSERT INTO notes (id, user_id, title, created_at, updated_at) VALUES (?, 'u1', 't', 1, 1)`, fmt.Sprintf("w%d", i))
		}
	}()
	time.Sleep(20 * time.Millisecond)
	dataDir := t.TempDir()
	res, err := Run(context.Background(), d, dataDir, 5, t0)
	close(stop)
	wg.Wait()
	if err != nil {
		t.Fatal(err)
	}
	if err := Verify(res.Dir); err != nil {
		t.Fatalf("Verify: %v", err)
	}
}

func TestBackupCopiesStorage(t *testing.T) {
	d := testutil.NewDB(t)
	dataDir := t.TempDir()
	writeFile(t, filepath.Join(dataDir, "storage", photoA), "jpegdata")
	writeFile(t, filepath.Join(dataDir, "storage", "b.png"), "pngdata")
	res, err := Run(context.Background(), d, dataDir, 5, t0)
	if err != nil {
		t.Fatal(err)
	}
	if res.Files != 2 {
		t.Fatalf("Files = %d, want 2", res.Files)
	}
	got, err := os.ReadFile(filepath.Join(res.Dir, "storage", photoA))
	if err != nil || string(got) != "jpegdata" {
		t.Fatalf("copy = %q, %v", got, err)
	}
}

func TestBackupSkipsSymlinksAndTempFiles(t *testing.T) {
	d := testutil.NewDB(t)
	dataDir := t.TempDir()
	secret := filepath.Join(t.TempDir(), "secret.txt")
	writeFile(t, secret, "secret")
	st := filepath.Join(dataDir, "storage")
	writeFile(t, filepath.Join(st, photoA), "ok")
	writeFile(t, filepath.Join(st, ".upload-123"), "partial")
	if err := os.Symlink(secret, filepath.Join(st, "link.jpg")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Dir(secret), filepath.Join(st, "dirlink")); err != nil {
		t.Fatal(err)
	}
	res, err := Run(context.Background(), d, dataDir, 5, t0)
	if err != nil {
		t.Fatal(err)
	}
	if res.Files != 1 {
		t.Fatalf("Files = %d, want 1", res.Files)
	}
	entries, _ := os.ReadDir(filepath.Join(res.Dir, "storage"))
	if len(entries) != 1 || entries[0].Name() != photoA {
		t.Fatalf("entries = %v", entries)
	}
}

func names(t *testing.T, dir string) []string {
	t.Helper()
	es, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, e := range es {
		out = append(out, e.Name())
	}
	return out
}

func TestPruneKeepsNewest(t *testing.T) {
	d := testutil.NewDB(t)
	dataDir := t.TempDir()
	for i := 0; i < 5; i++ {
		if _, err := Run(context.Background(), d, dataDir, 3, t0.Add(time.Duration(i)*time.Hour)); err != nil {
			t.Fatal(err)
		}
	}
	got := strings.Join(names(t, filepath.Join(dataDir, "backups")), ",")
	if want := "20261027T140000Z,20261027T150000Z,20261027T160000Z"; got != want {
		t.Fatalf("got %s, want %s", got, want)
	}
}

func TestPruneIgnoresForeignEntries(t *testing.T) {
	d := testutil.NewDB(t)
	dataDir := t.TempDir()
	b := filepath.Join(dataDir, "backups")
	writeFile(t, filepath.Join(b, "pre-restore-20260101T000000Z", "x"), "x")
	writeFile(t, filepath.Join(b, "notes.txt"), "x")
	if err := os.MkdirAll(filepath.Join(b, "20261027T120000Zextra"), 0o700); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 3; i++ {
		if _, err := Run(context.Background(), d, dataDir, 1, t0.Add(time.Duration(i)*time.Hour)); err != nil {
			t.Fatal(err)
		}
	}
	got := strings.Join(names(t, b), ",")
	want := "20261027T120000Zextra,20261027T140000Z,notes.txt,pre-restore-20260101T000000Z"
	if got != want {
		t.Fatalf("got %s, want %s", got, want)
	}
}

func TestStalePartialRemoved(t *testing.T) {
	d := testutil.NewDB(t)
	dataDir := t.TempDir()
	b := filepath.Join(dataDir, "backups")
	writeFile(t, filepath.Join(b, "20261027T110000Z.partial", "goweb.db"), "junk")
	writeFile(t, filepath.Join(b, "20261027T130000Z.partial", "goweb.db"), "future")
	if _, err := Run(context.Background(), d, dataDir, 5, t0); err != nil {
		t.Fatal(err)
	}
	got := strings.Join(names(t, b), ",")
	if want := "20261027T120000Z,20261027T130000Z.partial"; got != want {
		t.Fatalf("got %s, want %s", got, want)
	}
}

func TestBackupFilesOwnerOnly(t *testing.T) {
	d := testutil.NewDB(t)
	dataDir := t.TempDir()
	writeFile(t, filepath.Join(dataDir, "storage", photoA), "x")
	res, err := Run(context.Background(), d, dataDir, 5, t0)
	if err != nil {
		t.Fatal(err)
	}
	check := func(p string, want os.FileMode) {
		fi, err := os.Stat(p)
		if err != nil {
			t.Fatal(err)
		}
		if fi.Mode().Perm() != want {
			t.Errorf("%s mode = %o, want %o", p, fi.Mode().Perm(), want)
		}
	}
	check(filepath.Join(dataDir, "backups"), 0o700)
	check(res.Dir, 0o700)
	check(filepath.Join(res.Dir, "storage"), 0o700)
	check(filepath.Join(res.Dir, "goweb.db"), 0o600)
	check(filepath.Join(res.Dir, "storage", photoA), 0o600)
}

func TestRunRejectsKeepLessThanOne(t *testing.T) {
	d := testutil.NewDB(t)
	dataDir := t.TempDir()
	if _, err := Run(context.Background(), d, dataDir, 0, t0); err == nil {
		t.Fatal("want error")
	}
	if _, err := os.Stat(filepath.Join(dataDir, "backups")); err == nil {
		t.Fatal("backups dir created despite error")
	}
}

func TestRunQuotesPath(t *testing.T) {
	d := testutil.NewDB(t)
	dataDir := filepath.Join(t.TempDir(), "it's data")
	res, err := Run(context.Background(), d, dataDir, 5, t0)
	if err != nil {
		t.Fatal(err)
	}
	if err := Verify(res.Dir); err != nil {
		t.Fatal(err)
	}
}

func makeBackup(t *testing.T, photo any) (string, string) {
	t.Helper()
	d := testutil.NewDB(t)
	seedNote(t, d, "n1", photo)
	dataDir := t.TempDir()
	if s, ok := photo.(string); ok {
		writeFile(t, filepath.Join(dataDir, "storage", s), "img")
	}
	res, err := Run(context.Background(), d, dataDir, 5, t0)
	if err != nil {
		t.Fatal(err)
	}
	return res.Dir, dataDir
}

func TestVerifyOK(t *testing.T) {
	dir, _ := makeBackup(t, photoA)
	if err := Verify(dir); err != nil {
		t.Fatal(err)
	}
}

func TestVerifyDetectsMissingPhoto(t *testing.T) {
	dir, _ := makeBackup(t, photoA)
	if err := os.Remove(filepath.Join(dir, "storage", photoA)); err != nil {
		t.Fatal(err)
	}
	err := Verify(dir)
	if err == nil || !strings.Contains(err.Error(), photoA) {
		t.Fatalf("err = %v", err)
	}
}

func TestVerifyDetectsArchivedNoteMissingPhoto(t *testing.T) {
	d := testutil.NewDB(t)
	seedNote(t, d, "n1", photoA)
	d.Exec(`UPDATE notes SET archived_at = 5`)
	res, err := Run(context.Background(), d, t.TempDir(), 5, t0)
	if err != nil {
		t.Fatal(err)
	}
	if err := Verify(res.Dir); err == nil {
		t.Fatal("want error for archived note photo")
	}
}

func TestVerifyRejectsTraversalPhoto(t *testing.T) {
	dir, _ := makeBackup(t, "../goweb.db")
	if err := Verify(dir); err == nil {
		t.Fatal("want error")
	}
}

func TestVerifyDetectsCorruptDB(t *testing.T) {
	dir, _ := makeBackup(t, nil)
	p := filepath.Join(dir, "goweb.db")
	b, _ := os.ReadFile(p)
	for i := 4096; i < len(b); i++ {
		b[i] = 0xAB
	}
	if err := os.WriteFile(p, b, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := Verify(dir); err == nil {
		t.Fatal("want error")
	}
}

func TestVerifyMissingDB(t *testing.T) {
	if err := Verify(t.TempDir()); err == nil {
		t.Fatal("want error")
	}
}
