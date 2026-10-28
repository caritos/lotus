package app_test

import (
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"app/internal/app"
	"app/internal/config"
)

func TestNewBuildsHandlerAndMigrates(t *testing.T) {
	cfg := config.Config{DataDir: t.TempDir(), Env: "development"}
	a, err := app.New(cfg, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer a.Close()
	rec := httptest.NewRecorder()
	a.Handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("healthz = %d", rec.Code)
	}
	var n int
	if err := a.DB.QueryRow("SELECT count(*) FROM schema_migrations").Scan(&n); err != nil || n == 0 {
		t.Fatalf("migrations recorded = %d, err %v", n, err)
	}
}

func TestNewFailsOnMissingDataDir(t *testing.T) {
	if _, err := app.New(config.Config{}, nil); err == nil {
		t.Fatal("expected error for empty DataDir")
	}
}

func TestNewFailsOnUnwritableDataDir(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root ignores directory permissions")
	}
	parent := t.TempDir()
	if err := os.Chmod(parent, 0o500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(parent, 0o700) })
	if _, err := app.New(config.Config{DataDir: filepath.Join(parent, "data")}, nil); err == nil {
		t.Fatal("expected error for unwritable DataDir")
	}
}

func TestNewSweepsStaleUploadTempFiles(t *testing.T) {
	dataDir := t.TempDir()
	st := filepath.Join(dataDir, "storage")
	if err := os.MkdirAll(st, 0o700); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-2 * time.Hour)
	for _, name := range []string{".upload-stale", ".upload-fresh"} {
		if err := os.WriteFile(filepath.Join(st, name), []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Chtimes(filepath.Join(st, ".upload-stale"), old, old); err != nil {
		t.Fatal(err)
	}
	a, err := app.New(config.Config{DataDir: dataDir, Env: "development"}, slog.New(slog.DiscardHandler))
	if err != nil {
		t.Fatal(err)
	}
	defer a.Close()
	if _, err := os.Stat(filepath.Join(st, ".upload-stale")); !os.IsNotExist(err) {
		t.Errorf("stale temp file still there (err %v)", err)
	}
	if _, err := os.Stat(filepath.Join(st, ".upload-fresh")); err != nil {
		t.Errorf("fresh temp file removed: %v", err)
	}
}
