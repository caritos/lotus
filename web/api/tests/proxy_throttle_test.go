package tests

import (
	"net/http"
	"testing"

	"app/internal/apptest"
	"app/internal/config"
)

// loginFrom signs in with an X-Forwarded-For header on a fresh client.
func loginFrom(t *testing.T, a *apptest.App, xff, password string) int {
	t.Helper()
	st, _, _ := req(t, a.NewClient(), http.MethodPost, a.URL+"/api/login", jsonBody(testEmail, password),
		map[string]string{"Content-Type": "application/json", "X-Forwarded-For": xff})
	return st
}

// TestTrustedProxyFeedsTheLoginThrottle checks the seam between the TrustedProxy
// middleware and the per-(email, IP) sign-in throttle through the real wiring:
// with the proxy trusted, failures are counted per forwarded client address.
func TestTrustedProxyFeedsTheLoginThrottle(t *testing.T) {
	integration(t)
	a := apptest.NewServer(t, apptest.WithConfig(func(c *config.Config) { c.TrustedProxy = "127.0.0.1/32" }))
	a.CreateUser(testEmail, testPassword)

	for i := 0; i < 5; i++ {
		if st := loginFrom(t, a, "203.0.113.7", "wrong password here"); st != http.StatusUnauthorized {
			t.Fatalf("failure %d from 203.0.113.7 = %d, want 401", i+1, st)
		}
	}
	if st := loginFrom(t, a, "203.0.113.7", testPassword); st != http.StatusTooManyRequests {
		t.Fatalf("6th attempt from 203.0.113.7 with the right password = %d, want 429", st)
	}
	// Another client behind the same proxy is not affected (the per-email counter
	// is at 5 of its 20).
	if st := loginFrom(t, a, "203.0.113.8", testPassword); st != http.StatusOK {
		t.Fatalf("login from 203.0.113.8 = %d, want 200", st)
	}
}

// Without TRUSTED_PROXY the header is ignored: every request counts against the
// peer address, so the "other" client is throttled too.
func TestUntrustedForwardedForDoesNotSplitTheLoginThrottle(t *testing.T) {
	integration(t)
	a := apptest.NewServer(t)
	a.CreateUser(testEmail, testPassword)

	for i := 0; i < 5; i++ {
		if st := loginFrom(t, a, "203.0.113.7", "wrong password here"); st != http.StatusUnauthorized {
			t.Fatalf("failure %d = %d, want 401", i+1, st)
		}
	}
	if st := loginFrom(t, a, "203.0.113.8", testPassword); st != http.StatusTooManyRequests {
		t.Fatalf("login claiming 203.0.113.8 without a trusted proxy = %d, want 429 (keyed on the peer)", st)
	}
}
