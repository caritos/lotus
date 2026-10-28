package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

// permissiveUmask sets the process umask to 0 for the test and restores it after.
func permissiveUmask(t *testing.T) {
	t.Helper()
	old := syscall.Umask(0)
	t.Cleanup(func() { syscall.Umask(old) })
}

func currentUmask() int {
	m := syscall.Umask(0)
	syscall.Umask(m)
	return m
}

func checkMode(t *testing.T, path string, want os.FileMode) {
	t.Helper()
	fi, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := fi.Mode().Perm(); got != want {
		t.Errorf("%s mode = %o, want %o", path, got, want)
	}
}

// checkDBFiles checks db/, the database and any WAL/SHM files left beside it.
func checkDBFiles(t *testing.T, dataDir string) {
	t.Helper()
	checkMode(t, filepath.Join(dataDir, "db"), 0o700)
	checkMode(t, filepath.Join(dataDir, "db", "app.db"), 0o600)
	for _, suffix := range []string{"-wal", "-shm"} {
		p := filepath.Join(dataDir, "db", "app.db"+suffix)
		if _, err := os.Stat(p); err == nil {
			checkMode(t, p, 0o600)
		}
	}
}

func TestUserCreateMakesOwnerOnlyDatabaseUnderPermissiveUmask(t *testing.T) {
	permissiveUmask(t)
	dir := t.TempDir()
	old := stdin
	defer func() { stdin = old }()
	stdin = strings.NewReader("s3cretpass\n")
	if err := run([]string{"user", "create", "me@example.com"}, userEnv(dir), &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	checkDBFiles(t, dir)
	if m := currentUmask(); m != 0 {
		t.Errorf("run leaked umask %o into the process, want it restored to 0", m)
	}
}

func TestBackupMakesOwnerOnlyFilesUnderPermissiveUmask(t *testing.T) {
	permissiveUmask(t)
	dir := t.TempDir()
	var out bytes.Buffer
	if err := run([]string{"backup"}, userEnv(dir), &out); err != nil {
		t.Fatal(err)
	}
	checkDBFiles(t, dir)
	checkMode(t, filepath.Join(dir, "backups"), 0o700)
	set := strings.TrimSpace(out.String())
	checkMode(t, set, 0o700)
	checkMode(t, filepath.Join(set, "app.db"), 0o600)
}
