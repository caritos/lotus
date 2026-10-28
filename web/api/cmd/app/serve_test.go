package main

import (
	"bytes"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"app/internal/config"
)

func TestWarnDevExposure(t *testing.T) {
	tests := []struct {
		env, addr string
		warn      bool
	}{
		{"development", ":8080", true},
		{"development", "0.0.0.0:8080", true},
		{"development", "[::]:8080", true},
		{"development", "192.0.2.10:8080", true},
		{"development", "example.com:8080", true},
		{"development", "127.0.0.1:8080", false},
		{"development", "127.0.0.2:8080", false},
		{"development", "[::1]:8080", false},
		{"development", "localhost:8080", false},
		{"production", ":8080", false},
		{"production", "0.0.0.0:8080", false},
	}
	for _, tt := range tests {
		var buf bytes.Buffer
		logger := slog.New(slog.NewJSONHandler(&buf, nil))
		warnDevExposure(logger, config.Config{Env: tt.env, Addr: tt.addr})
		out := buf.String()
		got := strings.Contains(out, `"level":"WARN"`)
		if got != tt.warn {
			t.Errorf("env %s addr %s: warned = %v, want %v (log %q)", tt.env, tt.addr, got, tt.warn, out)
		}
		if tt.warn && !contains(out, "APP_ENV", tt.addr) {
			t.Errorf("env %s addr %s: warning %q should name APP_ENV and the address", tt.env, tt.addr, out)
		}
	}
}

// TestServeLogsDevExposureWarning runs the real serve path with an address that
// cannot be bound, so it returns right after logging startup messages.
func TestServeLogsDevExposureWarning(t *testing.T) {
	old := slog.Default()
	t.Cleanup(func() { slog.SetDefault(old) })
	dir := t.TempDir()
	env := map[string]string{"DATA_DIR": dir, "ADDR": "0.0.0.0:99999"}
	err := run([]string{"serve"}, func(k string) string { return env[k] }, &bytes.Buffer{})
	if err == nil {
		t.Fatal("serve with an invalid port must fail")
	}
	b, rerr := os.ReadFile(filepath.Join(dir, "logs", "app.log"))
	if rerr != nil {
		t.Fatal(rerr)
	}
	if !contains(string(b), `"level":"WARN"`, "APP_ENV", "0.0.0.0:99999") {
		t.Fatalf("app.log lacks the development exposure warning:\n%s", b)
	}
}

func contains(s string, subs ...string) bool {
	for _, sub := range subs {
		if !strings.Contains(s, sub) {
			return false
		}
	}
	return true
}
