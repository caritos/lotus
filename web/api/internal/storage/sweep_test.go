package storage

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"
)

func writeAged(t *testing.T, path string, age time.Duration) {
	t.Helper()
	if err := os.WriteFile(path, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	ts := time.Now().Add(-age)
	if err := os.Chtimes(path, ts, ts); err != nil {
		t.Fatal(err)
	}
}

func listDir(t *testing.T, dir string) string {
	t.Helper()
	es, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, e := range es {
		out = append(out, e.Name())
	}
	sort.Strings(out)
	return strings.Join(out, ",")
}

func TestSweepTempRemovesOnlyOldUploadTempFiles(t *testing.T) {
	dir := t.TempDir()
	s, err := New(dir)
	if err != nil {
		t.Fatal(err)
	}
	photo := "11111111-1111-1111-1111-111111111111.jpg"
	writeAged(t, filepath.Join(dir, ".upload-old"), 2*time.Hour)
	writeAged(t, filepath.Join(dir, ".upload-fresh"), time.Minute)
	writeAged(t, filepath.Join(dir, photo), 48*time.Hour)
	writeAged(t, filepath.Join(dir, "upload-not-temp"), 48*time.Hour)
	// A symlink named like a temp file (pointing outside) is never followed or removed.
	outside := filepath.Join(t.TempDir(), "outside")
	writeAged(t, outside, 48*time.Hour)
	if err := os.Symlink(outside, filepath.Join(dir, ".upload-link")); err != nil {
		t.Fatal(err)
	}
	// A directory named like a temp file is not recursed into or removed.
	sub := filepath.Join(dir, ".upload-dir")
	if err := os.Mkdir(sub, 0o700); err != nil {
		t.Fatal(err)
	}
	writeAged(t, filepath.Join(sub, ".upload-nested"), 48*time.Hour)
	old := time.Now().Add(-48 * time.Hour)
	if err := os.Chtimes(sub, old, old); err != nil {
		t.Fatal(err)
	}

	n, err := s.SweepTemp(time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Errorf("removed %d, want 1", n)
	}
	want := "." + "upload-dir,.upload-fresh,.upload-link," + photo + ",upload-not-temp"
	if got := listDir(t, dir); got != want {
		t.Errorf("left %s\nwant %s", got, want)
	}
	if _, err := os.Stat(outside); err != nil {
		t.Errorf("symlink target touched: %v", err)
	}
	if _, err := os.Stat(filepath.Join(sub, ".upload-nested")); err != nil {
		t.Errorf("nested file touched: %v", err)
	}
}

func TestSweepTempOnMissingDirIsNotAnError(t *testing.T) {
	s := &Store{dir: filepath.Join(t.TempDir(), "gone")}
	if n, err := s.SweepTemp(time.Hour); err != nil || n != 0 {
		t.Fatalf("n = %d, err = %v", n, err)
	}
}
