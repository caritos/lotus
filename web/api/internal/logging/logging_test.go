package logging

import (
	"os"
	"path/filepath"
	"strings"
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
