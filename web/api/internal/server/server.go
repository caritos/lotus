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
// (outermost first): TrustedProxy, RequestLog, SecurityHeaders, SameOrigin, BodyLimit.
// cfg must come from config.Load, which validates TRUSTED_PROXY.
func New(cfg config.Config, deps Deps) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", healthz)
	if deps.Auth != nil {
		api := auth.Middleware(deps.Auth)(auth.Handlers(deps.Auth))
		for _, p := range []string{"/api/login", "/api/logout", "/api/me"} {
			mux.Handle(p, api)
		}
	}
	if deps.Auth != nil && deps.DB != nil && deps.Storage != nil {
		h := auth.Middleware(deps.Auth)(auth.Require(notes.Handlers(notes.NewStore(deps.DB), deps.Storage)))
		mux.Handle("/api/notes", h)
		mux.Handle("/api/notes/", h)
	}
	// Everything the API does not claim: public pages, /static/*, /app/*, 404.
	mux.Handle("/", web.Handler())

	logger := deps.Logger
	if logger == nil {
		logger = slog.Default()
	}
	// Load validated TrustedProxy; on a hand-built invalid Config fail closed
	// by trusting no proxy.
	proxy, err := TrustedProxy(cfg.TrustedProxy)
	if err != nil {
		proxy, _ = TrustedProxy("")
	}
	var h http.Handler = mux
	h = BodyLimit(maxBodyBytes)(h)
	h = SameOrigin(cfg.PublicOrigin)(h)
	h = SecurityHeaders()(h)
	h = RequestLog(logger)(h)
	return proxy(h)
}

func healthz(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(apigen.Health{Status: "ok", Version: version.Version, Commit: version.Commit})
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
