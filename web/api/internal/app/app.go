// Package app composes the production wiring (database, migrations, auth,
// storage, HTTP handler) so `serve` and the integration-test harness share it.
package app

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"goweb/internal/auth"
	"goweb/internal/config"
	"goweb/internal/db"
	"goweb/internal/server"
	"goweb/internal/storage"
)

// App is the composed application.
type App struct {
	Handler http.Handler
	DB      *sql.DB
	Auth    *auth.Service
}

// New opens the database under cfg.DataDir, applies migrations and builds the
// handler. The caller owns logger (nil falls back to slog.Default()) and must
// call Close.
func New(cfg config.Config, logger *slog.Logger) (*App, error) {
	if cfg.DataDir == "" {
		return nil, errors.New("app: DataDir is required")
	}
	d, err := db.Open(cfg.DBPath())
	if err != nil {
		return nil, err
	}
	if err := db.Migrate(context.Background(), d); err != nil {
		d.Close()
		return nil, err
	}
	svc := auth.NewService(d, cfg, time.Now)
	st, err := storage.New(cfg.StorageDir())
	if err != nil {
		d.Close()
		return nil, err
	}
	h := server.New(cfg, server.Deps{DB: d, Auth: svc, Storage: st, Logger: logger})
	return &App{Handler: h, DB: d, Auth: svc}, nil
}

// Close releases the database.
func (a *App) Close() error {
	if err := a.DB.Close(); err != nil {
		return fmt.Errorf("app: close db: %w", err)
	}
	return nil
}

// MaintenanceInterval is how often serve runs RunMaintenance's periodic work.
const MaintenanceInterval = time.Hour

// RunMaintenance purges expired sessions once right away and then every
// interval until ctx is done. Failures are logged and never stop the loop or
// the server. logger nil falls back to slog.Default(). It blocks; run it in a
// goroutine and cancel ctx (and wait for it) before Close.
func (a *App) RunMaintenance(ctx context.Context, logger *slog.Logger, every time.Duration) {
	if logger == nil {
		logger = slog.Default()
	}
	purge := func() {
		n, err := a.Auth.PurgeExpired(ctx)
		switch {
		case err != nil && ctx.Err() == nil:
			logger.Error("maintenance: purge expired sessions", "err", err)
		case n > 0:
			logger.Info("maintenance: purged expired sessions", "count", n)
		}
	}
	purge()
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			purge()
		}
	}
}
