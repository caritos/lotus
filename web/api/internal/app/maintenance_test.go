package app_test

import (
	"bytes"
	"context"
	"log/slog"
	"strings"
	"sync"
	"testing"
	"time"

	"goweb/internal/app"
	"goweb/internal/config"
)

// syncBuffer is a goroutine-safe log sink.
type syncBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuffer) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.Write(p)
}

func (s *syncBuffer) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.String()
}

func newApp(t *testing.T) (*app.App, string) {
	t.Helper()
	a, err := app.New(config.Config{DataDir: t.TempDir(), Env: "development"}, slog.New(slog.DiscardHandler))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { a.Close() })
	u, err := a.Auth.CreateUser(context.Background(), "a@b.c", "password1")
	if err != nil {
		t.Fatal(err)
	}
	return a, u.ID
}

func addSession(t *testing.T, a *app.App, userID, id string, expires time.Time) {
	t.Helper()
	if _, err := a.DB.Exec(`INSERT INTO sessions (id, user_id, token_hash, created_at, expires_at) VALUES (?, ?, ?, 1, ?)`,
		id, userID, "hash-"+id, expires.UnixMilli()); err != nil {
		t.Fatal(err)
	}
}

func sessionIDs(t *testing.T, a *app.App) string {
	t.Helper()
	rows, err := a.DB.Query(`SELECT id FROM sessions ORDER BY id`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			t.Fatal(err)
		}
		ids = append(ids, id)
	}
	return strings.Join(ids, ",")
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func TestMaintenancePurgesAtStartAndOnEveryTick(t *testing.T) {
	a, uid := newApp(t)
	now := time.Now()
	addSession(t, a, uid, "expired-1", now.Add(-time.Minute))
	addSession(t, a, uid, "valid", now.Add(time.Hour))

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	logs := &syncBuffer{}
	go func() {
		defer close(done)
		a.RunMaintenance(ctx, slog.New(slog.NewJSONHandler(logs, nil)), 20*time.Millisecond)
	}()
	waitFor(t, "the start-up purge", func() bool { return sessionIDs(t, a) == "valid" })

	addSession(t, a, uid, "expired-2", time.Now().Add(-time.Minute))
	waitFor(t, "a purge on a later tick", func() bool { return sessionIDs(t, a) == "valid" })

	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("RunMaintenance did not return after the context was cancelled")
	}
	if strings.Contains(logs.String(), `"level":"ERROR"`) {
		t.Fatalf("unexpected error log: %s", logs.String())
	}
}

func TestMaintenanceRunsOnceImmediatelyWithALongInterval(t *testing.T) {
	a, uid := newApp(t)
	addSession(t, a, uid, "expired", time.Now().Add(-time.Minute))
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go a.RunMaintenance(ctx, slog.New(slog.DiscardHandler), time.Hour)
	waitFor(t, "the start-up purge", func() bool { return sessionIDs(t, a) == "" })
}

func TestMaintenanceLogsErrorsAndKeepsRunning(t *testing.T) {
	a, _ := newApp(t)
	if _, err := a.DB.Exec(`DROP TABLE sessions`); err != nil {
		t.Fatal(err)
	}
	logs := &syncBuffer{}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		a.RunMaintenance(ctx, slog.New(slog.NewJSONHandler(logs, nil)), 10*time.Millisecond)
	}()
	waitFor(t, "two logged purge errors", func() bool {
		return strings.Count(logs.String(), `"level":"ERROR"`) >= 2
	})
	cancel()
	<-done
	if !strings.Contains(logs.String(), "purge") {
		t.Fatalf("error log does not say what failed: %s", logs.String())
	}
}
