// Package apptest boots the real application wiring (internal/app) against a
// temp SQLite file and temp DATA_DIR behind an httptest server, for
// integration tests. Production code must never import it.
package apptest

import (
	"context"
	"database/sql"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"testing"
	"time"

	"goweb/internal/app"
	"goweb/internal/config"
	"goweb/internal/logging"
)

// App is a running test application.
type App struct {
	URL     string
	Client  *http.Client // cookie jar; redirects are not followed
	DB      *sql.DB
	DataDir string
	// CreateUser registers an account, failing the test on error.
	CreateUser func(email, password string)
}

// NewClient returns a fresh client (own cookie jar, no redirect following),
// for tests that need a second user.
func (a *App) NewClient() *http.Client {
	jar, err := cookiejar.New(nil)
	if err != nil {
		panic(err) // cookiejar.New with nil options never fails
	}
	return &http.Client{
		Jar: jar,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
}

// NewServer starts the application. Everything is closed when the test ends.
func NewServer(t testing.TB) *App {
	t.Helper()
	dataDir := t.TempDir()

	// The config needs the server's URL (PUBLIC_ORIGIN), so start the server
	// first and install the handler once the app exists.
	var handler http.Handler
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		handler.ServeHTTP(w, r)
	}))
	t.Cleanup(ts.Close)

	cfg := config.Config{
		DataDir:       dataDir,
		PublicOrigin:  ts.URL,
		SessionSecret: "apptest-session-secret",
		Env:           "development",
		SessionTTL:    24 * time.Hour,
	}
	logger, closer, err := logging.New(dataDir, 5<<20, 5)
	if err != nil {
		t.Fatalf("apptest: logger: %v", err)
	}
	t.Cleanup(func() { closer.Close() })

	a, err := app.New(cfg, logger)
	if err != nil {
		t.Fatalf("apptest: app.New: %v", err)
	}
	handler = a.Handler
	t.Cleanup(func() { ts.Close(); a.Close() })

	out := &App{URL: ts.URL, DB: a.DB, DataDir: dataDir}
	out.Client = out.NewClient()
	out.CreateUser = func(email, password string) {
		t.Helper()
		if _, err := a.Auth.CreateUser(context.Background(), email, password); err != nil {
			t.Fatalf("apptest: create user %s: %v", email, err)
		}
	}
	return out
}
