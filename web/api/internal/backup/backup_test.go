package backup

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"app/internal/db"
	"app/internal/testutil"
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

func isBusy(err error) bool {
	m := err.Error()
	return strings.Contains(m, "SQLITE_BUSY") || strings.Contains(m, "database is locked")
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
	// Enough rows that VACUUM INTO takes a measurable time.
	if _, err := d.Exec(`WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM c WHERE i < 5000)
		INSERT INTO notes (id, user_id, title, body, created_at, updated_at) SELECT 'bulk'||i, 'u1', 't', hex(randomblob(64)), 1, 1 FROM c`); err != nil {
		t.Fatal(err)
	}

	var inserts, busy atomic.Int64
	var fatal atomic.Value
	stop := make(chan struct{})
	ready := make(chan struct{})
	var once sync.Once
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
			_, err := d2.Exec(`INSERT INTO notes (id, user_id, title, created_at, updated_at) VALUES (?, 'u1', 't', 1, 1)`, fmt.Sprintf("w%d", i))
			switch {
			case err == nil:
				inserts.Add(1)
				once.Do(func() { close(ready) })
			case isBusy(err):
				busy.Add(1)
			default:
				fatal.Store(err)
				once.Do(func() { close(ready) })
				return
			}
		}
	}()
	<-ready // the writer is demonstrably active before the backup starts

	before := inserts.Load()
	res, err := Run(context.Background(), d, t.TempDir(), 5, t0)
	after := inserts.Load()
	close(stop)
	wg.Wait()
	if f := fatal.Load(); f != nil {
		t.Fatalf("writer failed: %v", f)
	}
	if err != nil {
		t.Fatal(err)
	}
	if after <= before {
		t.Fatalf("no inserts landed while Run executed (before=%d after=%d busy=%d)", before, after, busy.Load())
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
		if e.Name() == ".lock" {
			continue
		}
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
	writeFile(t, filepath.Join(b, "20261027T110000Z.partial", "app.db"), "junk")
	writeFile(t, filepath.Join(b, "20261027T130000Z.partial", "app.db"), "future")
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
	check(filepath.Join(res.Dir, "app.db"), 0o600)
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
	dir, _ := makeBackup(t, "../app.db")
	if err := Verify(dir); err == nil {
		t.Fatal("want error")
	}
}

func TestVerifyDetectsCorruptDB(t *testing.T) {
	dir, _ := makeBackup(t, nil)
	p := filepath.Join(dir, "app.db")
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

func holdLock(t *testing.T, dataDir string) {
	t.Helper()
	root := filepath.Join(dataDir, "backups")
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatal(err)
	}
	f, err := os.OpenFile(filepath.Join(root, ".lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { f.Close() })
}

func TestRunFailsWhenAnotherBackupHoldsLock(t *testing.T) {
	d := testutil.NewDB(t)
	dataDir := t.TempDir()
	holdLock(t, dataDir)
	_, err := Run(context.Background(), d, dataDir, 5, t0)
	if !errors.Is(err, ErrBusy) {
		t.Fatalf("err = %v, want ErrBusy", err)
	}
	if got := names(t, filepath.Join(dataDir, "backups")); len(got) != 0 {
		t.Fatalf("entries = %v", got)
	}
}

func TestStalePartialCleanedOnlyWhileLockHeld(t *testing.T) {
	d := testutil.NewDB(t)
	dataDir := t.TempDir()
	b := filepath.Join(dataDir, "backups")
	writeFile(t, filepath.Join(b, "20261027T110000Z.partial", "app.db"), "in flight elsewhere")
	holdLock(t, dataDir)
	if _, err := Run(context.Background(), d, dataDir, 5, t0); !errors.Is(err, ErrBusy) {
		t.Fatalf("err = %v", err)
	}
	if _, err := os.Stat(filepath.Join(b, "20261027T110000Z.partial")); err != nil {
		t.Fatalf("partial removed without the lock: %v", err)
	}
}

func TestConcurrentRunsSameSecond(t *testing.T) {
	d := testutil.NewDB(t)
	seedNote(t, d, "n1", nil)
	dataDir := t.TempDir()
	var wg sync.WaitGroup
	errs := make([]error, 2)
	for i := range errs {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, errs[i] = Run(context.Background(), d, dataDir, 5, t0)
		}()
	}
	wg.Wait()
	ok := 0
	for _, e := range errs {
		if e == nil {
			ok++
		}
	}
	if ok != 1 {
		t.Fatalf("errs = %v, want exactly one success", errs)
	}
	var sets []string
	for _, n := range names(t, filepath.Join(dataDir, "backups")) {
		if setName.MatchString(n) {
			sets = append(sets, n)
		}
		if strings.HasSuffix(n, ".partial") {
			t.Fatalf("partial left behind: %s", n)
		}
	}
	if len(sets) != 1 {
		t.Fatalf("sets = %v", sets)
	}
	if err := Verify(filepath.Join(dataDir, "backups", sets[0])); err != nil {
		t.Fatal(err)
	}
}

func TestRunRefusesExistingFinalSet(t *testing.T) {
	d := testutil.NewDB(t)
	dataDir := t.TempDir()
	if _, err := Run(context.Background(), d, dataDir, 5, t0); err != nil {
		t.Fatal(err)
	}
	if _, err := Run(context.Background(), d, dataDir, 5, t0); err == nil {
		t.Fatal("want error for same-second collision")
	}
	if err := Verify(filepath.Join(dataDir, "backups", t0.Format(stampLayout))); err != nil {
		t.Fatalf("existing set damaged: %v", err)
	}
}
