// Package server builds the HTTP handler and http.Server.
package server

import (
	"encoding/json"
	"net/http"
	"time"

	"goweb/internal/config"
	"goweb/internal/version"
	"goweb/internal/web"
)

// Deps carries the server's collaborators; it grows as features are added.
type Deps struct{}

// New returns the application handler.
func New(cfg config.Config, deps Deps) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", healthz)
	// Everything the API does not claim: public pages, /static/*, /app/*, 404.
	mux.Handle("/", web.Handler())
	return mux
}

func healthz(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(struct {
		Status  string `json:"status"`
		Version string `json:"version"`
		Commit  string `json:"commit"`
	}{"ok", version.Version, version.Commit})
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
