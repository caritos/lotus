// Package server builds the HTTP handler and http.Server.
package server

import (
	"database/sql"
	"encoding/json"
	"log/slog"
	"net/http"
	"time"

	"goweb/internal/apigen"
	"goweb/internal/auth"
	"goweb/internal/config"
	"goweb/internal/notes"
	"goweb/internal/storage"
	"goweb/internal/version"
	"goweb/internal/web"
)

// Deps carries the server's collaborators; it grows as features are added.
type Deps struct {
	DB   *sql.DB
	Auth *auth.Service
	// Storage holds uploaded photos; the notes routes need it, DB and Auth.
	Storage *storage.Store
	// Logger receives request logs; nil falls back to slog.Default().
	Logger *slog.Logger
}

// maxBodyBytes is the global request body cap (the notes upload enforces its own).
const maxBodyBytes = 8 << 20

// New returns the application handler wrapped in the middleware chain
// (outermost first): TrustedProxy, RequestID, RequestLog, Recover, SecurityHeaders,
// SameOrigin, BodyLimit. RequestID is outside RequestLog so the log line has the
// id; Recover is just inside RequestLog so the 500 it writes is logged and a
// panic never escapes the logger; TrustedProxy stays outermost so everything
// sees the resolved client IP.
// cfg must come from config.Load, which validates TRUSTED_PROXY.
func New(cfg config.Config, deps Deps) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", healthz)
	if deps.Auth != nil {
		// Public routes, registered explicitly. /api/me answers 401 itself when signed out. The paths
		// are method-less on purpose so a wrong method keeps getting the handler's own 405.
		// The list must match publicRoutes in tests/guardrails_test.go.
		api := auth.Middleware(deps.Auth)(auth.Handlers(deps.Auth))
		for _, p := range []string{"/api/login", "/api/logout", "/api/me"} {
			mux.Handle(p, api)
		}
		// Default-deny: every other /api/ path, existing or not, is behind auth.Require. A new API
		// route is mounted inside `private` and is therefore private; signed out it is a 401 before
		// any 404, signed in an unknown path is a 404.
		private := http.NewServeMux()
		private.HandleFunc("/api/", func(w http.ResponseWriter, r *http.Request) {
			writeError(w, http.StatusNotFound, "not found")
		})
		if deps.DB != nil && deps.Storage != nil {
			h := notes.Handlers(notes.NewStore(deps.DB), deps.Storage)
			private.Handle("/api/notes", h)
			private.Handle("/api/notes/", h)
		}
		mux.Handle("/api/", auth.Middleware(deps.Auth)(auth.Require(private)))
	}
	// Everything the API does not claim: public pages, /static/*, /app/*, 404.
	mux.Handle("/", web.Handler())

	return Wrap(cfg, deps.Logger, mux)
}

// Wrap puts the middleware chain documented on New around h. It is exported only because
// the integration tests live in a separate package (web/api/tests): it exists for New and
// for those tests, which put a handler that panics inside the real chain. Production code
// goes through New.
func Wrap(cfg config.Config, logger *slog.Logger, h http.Handler) http.Handler {
	if logger == nil {
		logger = slog.Default()
	}
	// Load validated TrustedProxy; on a hand-built invalid Config fail closed
	// by trusting no proxy.
	proxy, err := TrustedProxy(cfg.TrustedProxy)
	if err != nil {
		proxy, _ = TrustedProxy("")
	}
	h = BodyLimit(maxBodyBytes)(h)
	h = SameOrigin(cfg.PublicOrigin)(h)
	h = SecurityHeaders()(h)
	h = Recover(logger)(h)
	h = RequestLog(logger)(h)
	h = RequestID()(h)
	return proxy(h)
}

func healthz(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(apigen.Health{Status: "ok", Version: version.Version, Commit: version.Commit, BuildId: version.BuildID})
}

// NewHTTPServer returns an http.Server with every timeout set.
func NewHTTPServer(cfg config.Config, h http.Handler) *http.Server {
	return &http.Server{
		Addr:              cfg.Addr,
		Handler:           h,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      60 * time.Second,
		IdleTimeout:       120 * time.Second,
		MaxHeaderBytes:    1 << 20,
	}
}
