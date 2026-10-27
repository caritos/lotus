package main

import (
	"bytes"
	"context"
	"os"
	"strings"
	"testing"
	"time"

	"goweb/internal/auth"
	"goweb/internal/config"
	"goweb/internal/db"
)

func TestMain(m *testing.M) {
	auth.UseFastHashingForTests()
	os.Exit(m.Run())
}

func userEnv(dir string) func(string) string {
	return func(k string) string {
		if k == "DATA_DIR" {
			return dir
		}
		return ""
	}
}

func TestUserCreateCommandReadsPasswordFromStdin(t *testing.T) {
	dir := t.TempDir()
	old := stdin
	defer func() { stdin = old }()
	stdin = strings.NewReader("s3cretpass\nignored\n")
	var out bytes.Buffer
	if err := run([]string{"user", "create", " Me@Example.com "}, userEnv(dir), &out); err != nil {
		t.Fatal(err)
	}
	if got := out.String(); got != "created me@example.com\n" {
		t.Fatalf("stdout = %q", got)
	}
	if strings.Contains(out.String(), "s3cretpass") {
		t.Fatal("password printed")
	}

	cfg, _ := config.Load(userEnv(dir))
	d, err := db.Open(cfg.DBPath())
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	s := auth.NewService(d, cfg, time.Now)
	if _, _, err := s.Login(context.Background(), "me@example.com", "s3cretpass", "1.1.1.1"); err != nil {
		t.Fatalf("login with created user: %v", err)
	}

	stdin = strings.NewReader("anotherpass\n")
	err = run([]string{"user", "create", "ME@example.com"}, userEnv(dir), &out)
	if err == nil || !strings.Contains(err.Error(), "already") {
		t.Fatalf("duplicate err = %v", err)
	}
}

func TestUserCreateErrors(t *testing.T) {
	dir := t.TempDir()
	old := stdin
	defer func() { stdin = old }()
	cases := []struct {
		name  string
		args  []string
		stdin string
		want  string
	}{
		{"no email", []string{"user", "create"}, "password1\n", "usage"},
		{"unknown sub", []string{"user", "frob"}, "", "usage"},
		{"empty stdin", []string{"user", "create", "a@b.c"}, "", "password"},
		{"weak", []string{"user", "create", "a@b.c"}, "short\n", "password"},
		{"bad email", []string{"user", "create", "nope"}, "password1\n", "email"},
	}
	for _, c := range cases {
		stdin = strings.NewReader(c.stdin)
		err := run(c.args, userEnv(dir), &bytes.Buffer{})
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: err = %v, want containing %q", c.name, err, c.want)
		}
	}
}
