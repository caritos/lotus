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

	"app/internal/auth"
	"app/internal/config"
	"app/internal/db"
	"app/internal/server"
	"app/internal/storage"
)

// staleUploadAge is how old a leftover .upload-* temp file must be before New removes it.
const staleUploadAge = time.Hour

// App is the composed application.
type App struct {
	Handler http.Handler
	DB      *sql.DB
	Auth    *auth.Service
}

// New opens the database under cfg.DataDir, applies migrations, removes upload
// temp files older than an hour from storage/ and builds the handler. The caller
// owns logger (nil falls back to slog.Default()) and must call Close.
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
	if logger == nil {
		logger = slog.Default()
	}
	// Upload temp files left by a crash or kill mid-upload; an in-flight upload
	// is far younger than an hour. Not fatal: log and carry on.
	if n, err := st.SweepTemp(staleUploadAge); err != nil {
		logger.Error("startup: sweep stale upload temp files", "err", err)
	} else if n > 0 {
		logger.Info("startup: removed stale upload temp files", "count", n)
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
