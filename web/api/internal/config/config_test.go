package config

import (
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func env(m map[string]string) func(string) string {
	return func(k string) string { return m[k] }
}

func TestLoadDefaults(t *testing.T) {
	c, err := Load(env(nil))
	if err != nil {
		t.Fatal(err)
	}
	if c.Addr != ":8080" || c.DataDir != "." || c.Env != "development" {
		t.Fatalf("unexpected defaults: %+v", c)
	}
	if c.SessionTTL != 30*24*time.Hour {
		t.Fatalf("SessionTTL = %v", c.SessionTTL)
	}
	if c.SecureCookies {
		t.Fatal("SecureCookies should default to false in development")
	}
}

func TestLoadProductionRequiresSecrets(t *testing.T) {
	tests := []struct {
		name    string
		env     map[string]string
		wantKey string
	}{
		{"missing both", map[string]string{"APP_ENV": "production"}, "SESSION_SECRET"},
		{"missing origin", map[string]string{"APP_ENV": "production", "SESSION_SECRET": "x"}, "PUBLIC_ORIGIN"},
		{"missing secret", map[string]string{"APP_ENV": "production", "PUBLIC_ORIGIN": "https://a.example"}, "SESSION_SECRET"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := Load(env(tt.env))
			if err == nil || !strings.Contains(err.Error(), tt.wantKey) {
				t.Fatalf("err = %v, want mention of %s", err, tt.wantKey)
			}
		})
	}
}

func TestLoadProductionOK(t *testing.T) {
	c, err := Load(env(map[string]string{
		"APP_ENV": "production", "SESSION_SECRET": "s", "PUBLIC_ORIGIN": "https://a.example",
	}))
	if err != nil {
		t.Fatal(err)
	}
	if !c.SecureCookies {
		t.Fatal("SecureCookies should default to true in production")
	}
}

func TestLoadOverrides(t *testing.T) {
	c, err := Load(env(map[string]string{
		"ADDR": ":9000", "DATA_DIR": "/d", "SECURE_COOKIES": "true",
		"TRUSTED_PROXY": "10.0.0.0/8", "SESSION_TTL": "2h",
	}))
	if err != nil {
		t.Fatal(err)
	}
	if c.Addr != ":9000" || c.DataDir != "/d" || !c.SecureCookies || c.TrustedProxy != "10.0.0.0/8" || c.SessionTTL != 2*time.Hour {
		t.Fatalf("overrides not applied: %+v", c)
	}
}

func TestLoadInvalidValues(t *testing.T) {
	for _, m := range []map[string]string{
		{"SESSION_TTL": "soon"},
		{"SESSION_TTL": "-1h"},
		{"SECURE_COOKIES": "maybe"},
		{"APP_ENV": "staging"},
	} {
		if _, err := Load(env(m)); err == nil {
			t.Errorf("expected error for %v", m)
		}
	}
}

func TestDerivedPaths(t *testing.T) {
	c := Config{DataDir: "/data"}
	if got, want := c.DBPath(), filepath.Join("/data", "db", "goweb.db"); got != want {
		t.Errorf("DBPath = %q, want %q", got, want)
	}
	if got, want := c.LogPath(), filepath.Join("/data", "logs", "app.log"); got != want {
		t.Errorf("LogPath = %q, want %q", got, want)
	}
	if got, want := c.StorageDir(), filepath.Join("/data", "storage"); got != want {
		t.Errorf("StorageDir = %q, want %q", got, want)
	}
	if got, want := c.BackupDir(), filepath.Join("/data", "backups"); got != want {
		t.Errorf("BackupDir = %q, want %q", got, want)
	}
}
