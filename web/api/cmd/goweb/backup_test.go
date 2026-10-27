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

func TestBackupCommandLabel(t *testing.T) {
	dir := seededDataDir(t)
	var daily, out bytes.Buffer
	if err := run([]string{"backup", "--keep", "1"}, userEnv(dir), &daily); err != nil {
		t.Fatal(err)
	}
	// Same second as the daily run is fine: the names differ.
	if err := run([]string{"backup", "--label", "predeploy", "--keep", "1"}, userEnv(dir), &out); err != nil {
		t.Fatal(err)
	}
	p := strings.TrimSpace(out.String())
	if !strings.HasSuffix(p, "-predeploy") || !strings.HasPrefix(p, filepath.Join(dir, "backups")+string(filepath.Separator)) {
		t.Fatalf("stdout = %q, want a <stamp>-predeploy set under backups/", out.String())
	}
	var vout bytes.Buffer
	if err := run([]string{"verify-backup", p}, userEnv(dir), &vout); err != nil || vout.String() != "ok\n" {
		t.Fatalf("verify-backup labeled set: %v %q", err, vout.String())
	}
	// The daily set survives labeled runs (it has its own retention).
	if _, err := os.Stat(strings.TrimSpace(daily.String())); err != nil {
		t.Fatalf("daily set pruned by a labeled run: %v", err)
	}
	for _, bad := range []string{"Bad", "x_y", "", "a/b"} {
		if err := run([]string{"backup", "--label", bad}, userEnv(dir), &bytes.Buffer{}); err == nil {
			t.Errorf("--label %q: want error", bad)
		}
	}
}
