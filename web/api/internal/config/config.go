// Package config loads runtime configuration from environment variables.
package config

import (
	"fmt"
	"net/netip"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Config is the runtime configuration. Defaults live in Load; .env.example documents them.
type Config struct {
	Addr          string
	DataDir       string
	PublicOrigin  string
	SessionSecret string
	Env           string
	SecureCookies bool
	TrustedProxy  string
	SessionTTL    time.Duration
}

// Load reads configuration through getenv (os.Getenv in production).
// In production it refuses to return a config without SESSION_SECRET and PUBLIC_ORIGIN.
func Load(getenv func(string) string) (Config, error) {
	str := func(key, def string) string {
		if v := getenv(key); v != "" {
			return v
		}
		return def
	}
	c := Config{
		Addr:          str("ADDR", ":8080"),
		DataDir:       str("DATA_DIR", "."),
		PublicOrigin:  getenv("PUBLIC_ORIGIN"),
		SessionSecret: getenv("SESSION_SECRET"),
		Env:           str("APP_ENV", "development"),
		TrustedProxy:  getenv("TRUSTED_PROXY"),
	}
	if c.Env != "development" && c.Env != "production" {
		return Config{}, fmt.Errorf("config: APP_ENV must be development or production, got %q", c.Env)
	}
	c.SecureCookies = c.Env == "production"
	if v := getenv("SECURE_COOKIES"); v != "" {
		b, err := strconv.ParseBool(v)
		if err != nil {
			return Config{}, fmt.Errorf("config: SECURE_COOKIES: %w", err)
		}
		c.SecureCookies = b
	}
	if _, err := ParseTrustedProxy(c.TrustedProxy); err != nil {
		return Config{}, fmt.Errorf("config: TRUSTED_PROXY: %w", err)
	}
	c.SessionTTL = 30 * 24 * time.Hour
	if v := getenv("SESSION_TTL"); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil {
			return Config{}, fmt.Errorf("config: SESSION_TTL: %w", err)
		}
		if d <= 0 {
			return Config{}, fmt.Errorf("config: SESSION_TTL must be positive, got %s", v)
		}
		c.SessionTTL = d
	}
	if c.Env == "production" {
		if c.SessionSecret == "" {
			return Config{}, fmt.Errorf("config: SESSION_SECRET is required when APP_ENV=production")
		}
		if c.PublicOrigin == "" {
			return Config{}, fmt.Errorf("config: PUBLIC_ORIGIN is required when APP_ENV=production")
		}
	}
	return c, nil
}

// DBPath is the SQLite database file.
func (c Config) DBPath() string { return filepath.Join(c.DataDir, "db", "goweb.db") }

// LogPath is the application log file.
func (c Config) LogPath() string { return filepath.Join(c.DataDir, "logs", "app.log") }

// StorageDir holds uploaded files.
func (c Config) StorageDir() string { return filepath.Join(c.DataDir, "storage") }

// BackupDir holds database snapshots.
func (c Config) BackupDir() string { return filepath.Join(c.DataDir, "backups") }

// ParseTrustedProxy parses a comma-separated list of CIDRs or single IPs.
// An empty string means no trusted proxies.
func ParseTrustedProxy(s string) ([]netip.Prefix, error) {
	var out []netip.Prefix
	for _, part := range strings.Split(s, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		if p, err := netip.ParsePrefix(part); err == nil {
			out = append(out, netip.PrefixFrom(p.Addr().Unmap(), unmapBits(p)).Masked())
			continue
		}
		a, err := netip.ParseAddr(part)
		if err != nil {
			return nil, fmt.Errorf("invalid CIDR or IP %q", part)
		}
		a = a.Unmap()
		out = append(out, netip.PrefixFrom(a, a.BitLen()))
	}
	return out, nil
}

// unmapBits converts the prefix length of an IPv4-mapped IPv6 prefix to IPv4 terms.
func unmapBits(p netip.Prefix) int {
	if p.Addr().Is4In6() {
		return max(p.Bits()-96, 0)
	}
	return p.Bits()
}
