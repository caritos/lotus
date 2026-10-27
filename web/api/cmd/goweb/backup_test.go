package main

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"goweb/internal/config"
	"goweb/internal/db"
)

func seededDataDir(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	cfg, _ := config.Load(userEnv(dir))
	d, err := db.Open(cfg.DBPath())
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	if err := db.Migrate(context.Background(), d); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(cfg.StorageDir(), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cfg.StorageDir(), "a.jpg"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	return dir
}

func TestBackupCommandPrintsDirAndVerifies(t *testing.T) {
	dir := seededDataDir(t)
	var out bytes.Buffer
	if err := run([]string{"backup", "--keep", "3"}, userEnv(dir), &out); err != nil {
		t.Fatal(err)
	}
	p := strings.TrimSpace(out.String())
	if !strings.HasPrefix(p, filepath.Join(dir, "backups")+string(filepath.Separator)) {
		t.Fatalf("stdout = %q", out.String())
	}
	if _, err := os.Stat(filepath.Join(p, "storage", "a.jpg")); err != nil {
		t.Fatal(err)
	}
	var vout bytes.Buffer
	if err := run([]string{"verify-backup", p}, userEnv(dir), &vout); err != nil {
		t.Fatal(err)
	}
	if vout.String() != "ok\n" {
		t.Fatalf("verify stdout = %q", vout.String())
	}
}

func TestBackupCommandRejectsBadKeep(t *testing.T) {
	dir := seededDataDir(t)
	if err := run([]string{"backup", "--keep", "0"}, userEnv(dir), &bytes.Buffer{}); err == nil {
		t.Fatal("want error")
	}
	if err := run([]string{"backup", "extra"}, userEnv(dir), &bytes.Buffer{}); err == nil {
		t.Fatal("want usage error")
	}
}

func TestVerifyBackupCommandFailsOnBadDir(t *testing.T) {
	if err := run([]string{"verify-backup", t.TempDir()}, userEnv(""), &bytes.Buffer{}); err == nil {
		t.Fatal("want error")
	}
	if err := run([]string{"verify-backup"}, userEnv(""), &bytes.Buffer{}); err == nil {
		t.Fatal("want usage error")
	}
}
