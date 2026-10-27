package notes

import (
	"bytes"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// captureLog swaps the default logger (the handlers log through slog) for the test.
func captureLog(t *testing.T) *bytes.Buffer {
	t.Helper()
	var buf bytes.Buffer
	old := slog.Default()
	slog.SetDefault(slog.New(slog.NewJSONHandler(&buf, nil)))
	t.Cleanup(func() { slog.SetDefault(old) })
	return &buf
}

func TestGetPhotoUnreadableFileIs500AndLogged(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root ignores file permissions")
	}
	e := newEnv(t)
	n := e.create(e.ca, "x")
	if rec := e.putPhoto(e.ca, n.ID, pngBytes); rec.Code != 200 {
		t.Fatalf("put = %d", rec.Code)
	}
	name := e.storedPhoto(n.ID)
	p := filepath.Join(e.dir, name)
	if err := os.Chmod(p, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(p, 0o600) })
	logs := captureLog(t)

	rec := e.do(e.ca, "GET", "/api/notes/"+n.ID+"/photo", nil, "")
	if rec.Code != 500 {
		t.Fatalf("status = %d, want 500 for a permission error", rec.Code)
	}
	out := logs.String()
	if !strings.Contains(out, `"level":"ERROR"`) || !strings.Contains(out, n.ID) {
		t.Fatalf("want an ERROR log naming note %s, got %q", n.ID, out)
	}
	if strings.Contains(out, name) || strings.Contains(out, e.dir) {
		t.Fatalf("log must not contain the file name or path: %q", out)
	}
}

func TestGetPhotoMissingFileIs404WithoutErrorLog(t *testing.T) {
	e := newEnv(t)
	n := e.create(e.ca, "x")
	if rec := e.putPhoto(e.ca, n.ID, pngBytes); rec.Code != 200 {
		t.Fatalf("put = %d", rec.Code)
	}
	if err := os.Remove(filepath.Join(e.dir, e.storedPhoto(n.ID))); err != nil {
		t.Fatal(err)
	}
	logs := captureLog(t)
	if rec := e.do(e.ca, "GET", "/api/notes/"+n.ID+"/photo", nil, ""); rec.Code != 404 {
		t.Fatalf("status = %d, want 404", rec.Code)
	}
	if strings.Contains(logs.String(), `"level":"ERROR"`) {
		t.Fatalf("a missing file is not a server error: %s", logs.String())
	}
}

func TestGetPhotoInvalidStoredNameIs404(t *testing.T) {
	e := newEnv(t)
	n := e.create(e.ca, "x")
	if _, err := e.db.Exec(`UPDATE notes SET photo = '../escape.jpg' WHERE id = ?`, n.ID); err != nil {
		t.Fatal(err)
	}
	logs := captureLog(t)
	if rec := e.do(e.ca, "GET", "/api/notes/"+n.ID+"/photo", nil, ""); rec.Code != 404 {
		t.Fatalf("status = %d, want 404", rec.Code)
	}
	if !strings.Contains(logs.String(), n.ID) || strings.Contains(logs.String(), "escape") {
		t.Fatalf("want a log line naming the note but not the stored name: %q", logs.String())
	}
}
