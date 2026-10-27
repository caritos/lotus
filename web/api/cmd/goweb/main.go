// Command goweb is the single-binary web server.
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"goweb/internal/app"
	"goweb/internal/config"
	"goweb/internal/logging"
	"goweb/internal/server"
	"goweb/internal/version"
)

type command func(args []string, getenv func(string) string, stdout io.Writer) error

// commands is the subcommand table. `user` and `backup` register themselves in user.go and backup.go.
var commands = map[string]command{
	"serve": serve,
}

func main() {
	if err := run(os.Args[1:], os.Getenv, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "goweb:", err)
		os.Exit(1)
	}
}

// run dispatches to a subcommand; serve is the default when none is given.
func run(args []string, getenv func(string) string, stdout io.Writer) error {
	name := "serve"
	if len(args) > 0 {
		name, args = args[0], args[1:]
	}
	cmd, ok := commands[name]
	if !ok {
		return fmt.Errorf("unknown command %q", name)
	}
	return cmd(args, getenv, stdout)
}

func serve(_ []string, getenv func(string) string, _ io.Writer) error {
	cfg, err := config.Load(getenv)
	if err != nil {
		return err
	}
	syscall.Umask(0o077)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	logger, logCloser, err := logging.New(cfg.DataDir, 5<<20, 5)
	if err != nil {
		return err
	}
	defer logCloser.Close()
	slog.SetDefault(logger)

	a, err := app.New(cfg, logger)
	if err != nil {
		return err
	}
	defer a.Close()

	srv := server.NewHTTPServer(cfg, a.Handler)
	errc := make(chan error, 1)
	go func() { errc <- srv.ListenAndServe() }()
	slog.Info("listening", "addr", cfg.Addr, "version", version.Version, "commit", version.Commit, "env", cfg.Env)

	select {
	case err := <-errc:
		return err
	case <-ctx.Done():
	}
	slog.Info("shutting down")
	shutCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutCtx); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return fmt.Errorf("shutdown: %w", err)
	}
	return nil
}
