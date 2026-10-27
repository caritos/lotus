package logging

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func TestNewWritesJSONToLogsDir(t *testing.T) {
	dir := t.TempDir()
	l, c, err := New(dir, 1<<20, 3)
	if err != nil {
		t.Fatal(err)
	}
	l.Info("hello", "k", "v")
	if err := c.Close(); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(filepath.Join(dir, "logs", "app.log"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), `"msg":"hello"`) || !strings.Contains(string(b), `"k":"v"`) {
		t.Fatalf("log = %s", b)
	}
	st, _ := os.Stat(filepath.Join(dir, "logs"))
	if st.Mode().Perm() != 0o700 {
		t.Errorf("logs dir mode = %v", st.Mode().Perm())
	}
	st, _ = os.Stat(filepath.Join(dir, "logs", "app.log"))
	if st.Mode().Perm() != 0o600 {
		t.Errorf("file mode = %v", st.Mode().Perm())
	}
}

func TestLogRotatesAtMaxBytes(t *testing.T) {
	dir := t.TempDir()
	const max, keep = 200, 3
	l, c, err := New(dir, max, keep)
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 60; i++ {
		l.Info(strings.Repeat("x", 40), "i", i)
	}
	if err := c.Close(); err != nil {
		t.Fatal(err)
	}
	logs := filepath.Join(dir, "logs")
	for _, name := range []string{"app.log", "app.log.1", "app.log.2", "app.log.3"} {
		st, err := os.Stat(filepath.Join(logs, name))
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if st.Size() > max {
			t.Errorf("%s size %d > %d", name, st.Size(), max)
		}
	}
	if _, err := os.Stat(filepath.Join(logs, "app.log.4")); !os.IsNotExist(err) {
		t.Fatalf("app.log.4 should not exist: %v", err)
	}
	// Newest line is in app.log, older ones in higher generations.
	cur, _ := os.ReadFile(filepath.Join(logs, "app.log"))
	if !strings.Contains(string(cur), `"i":59`) {
		t.Fatalf("newest entry missing from app.log: %s", cur)
	}
}

func TestReopenAppendsToExisting(t *testing.T) {
	dir := t.TempDir()
	l, c, _ := New(dir, 1<<20, 2)
	l.Info("one")
	_ = c.Close()
	l, c, _ = New(dir, 1<<20, 2)
	l.Info("two")
	_ = c.Close()
	b, _ := os.ReadFile(filepath.Join(dir, "logs", "app.log"))
	if !strings.Contains(string(b), "one") || !strings.Contains(string(b), "two") {
		t.Fatalf("log = %s", b)
	}
}

func TestNewRejectsBadArgs(t *testing.T) {
	if _, _, err := New(t.TempDir(), 0, 3); err == nil {
		t.Fatal("maxBytes 0 should fail")
	}
	if _, _, err := New(t.TempDir(), 100, 0); err == nil {
		t.Fatal("keep 0 should fail")
	}
}

func TestRotationFailureDoesNotKillLogging(t *testing.T) {
	dir := t.TempDir()
	l, c, err := New(dir, 100, 3)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	logs := filepath.Join(dir, "logs")
	// A non-empty directory at app.log.1 makes rename(app.log, app.log.1) fail.
	blocker := filepath.Join(logs, "app.log.1")
	if err := os.MkdirAll(filepath.Join(blocker, "x"), 0o700); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 20; i++ {
		l.Info(strings.Repeat("y", 40), "i", i)
	}
	b, err := os.ReadFile(filepath.Join(logs, "app.log"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), `"i":19`) {
		t.Fatalf("latest entry not in app.log after failed rotations: %s", b)
	}
	// Once the blocker is gone, rotation works again.
	if err := os.RemoveAll(blocker); err != nil {
		t.Fatal(err)
	}
	l.Info(strings.Repeat("z", 40), "i", 20)
	if _, err := os.Stat(filepath.Join(logs, "app.log.1")); err != nil {
		t.Fatalf("rotation did not recover: %v", err)
	}
}

func TestVanishedLogFileRecovers(t *testing.T) {
	dir := t.TempDir()
	l, c, _ := New(dir, 100, 2)
	defer c.Close()
	logs := filepath.Join(dir, "logs")
	l.Info(strings.Repeat("a", 40))
	_ = os.Remove(filepath.Join(logs, "app.log"))
	for i := 0; i < 5; i++ {
		l.Info(strings.Repeat("b", 40), "i", i)
	}
	b, err := os.ReadFile(filepath.Join(logs, "app.log"))
	if err != nil || !strings.Contains(string(b), `"i":4`) {
		t.Fatalf("err=%v log=%s", err, b)
	}
}

func TestGenerationOrderAndCount(t *testing.T) {
	dir := t.TempDir()
	l, c, _ := New(dir, 150, 3)
	for i := 0; i < 30; i++ {
		l.Info(strings.Repeat("x", 40), "seq", i)
	}
	_ = c.Close()
	logs := filepath.Join(dir, "logs")
	last := 1 << 30
	for _, name := range []string{"app.log", "app.log.1", "app.log.2", "app.log.3"} {
		b, err := os.ReadFile(filepath.Join(logs, name))
		if err != nil {
			t.Fatal(err)
		}
		lines := strings.Split(strings.TrimSpace(string(b)), "\n")
		var seq int
		if _, err := fmt.Sscanf(lines[0][strings.Index(lines[0], `"seq":`):], `"seq":%d`, &seq); err != nil {
			t.Fatal(err)
		}
		if seq >= last {
			t.Fatalf("%s starts at seq %d, not older than previous (%d)", name, seq, last)
		}
		last = seq
	}
	entries, _ := os.ReadDir(logs)
	if len(entries) != 4 {
		t.Fatalf("%d files, want 4", len(entries))
	}
}

func TestConcurrentWriters(t *testing.T) {
	dir := t.TempDir()
	l, c, _ := New(dir, 500, 2)
	var wg sync.WaitGroup
	for g := 0; g < 8; g++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 100; i++ {
				l.Info("concurrent", "i", i)
			}
		}()
	}
	wg.Wait()
	if err := c.Close(); err != nil {
		t.Fatal(err)
	}
}
