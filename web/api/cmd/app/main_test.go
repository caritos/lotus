package main

import (
	"bytes"
	"io"
	"strings"
	"testing"
)

func TestRunUnknownCommand(t *testing.T) {
	var out bytes.Buffer
	err := run([]string{"frobnicate"}, func(string) string { return "" }, &out)
	if err == nil || !strings.Contains(err.Error(), "unknown command") || !strings.Contains(err.Error(), "frobnicate") {
		t.Fatalf("err = %v", err)
	}
}

func TestRunDefaultsToServe(t *testing.T) {
	called := ""
	old := commands
	defer func() { commands = old }()
	commands = map[string]command{"serve": func(args []string, getenv func(string) string, stdout io.Writer) error {
		called = "serve"
		return nil
	}}
	if err := run(nil, func(string) string { return "" }, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	if called != "serve" {
		t.Fatal("serve not called by default")
	}
}

func TestRunBadConfigFailsServe(t *testing.T) {
	env := map[string]string{"APP_ENV": "production"}
	err := run([]string{"serve"}, func(k string) string { return env[k] }, &bytes.Buffer{})
	if err == nil || !strings.Contains(err.Error(), "SESSION_SECRET") {
		t.Fatalf("err = %v", err)
	}
}
