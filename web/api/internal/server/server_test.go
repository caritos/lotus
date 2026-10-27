package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"goweb/internal/config"
	"goweb/internal/version"
)

func TestHealthz(t *testing.T) {
	version.Version, version.Commit = "v1.2.3", "abc123"
	h := New(config.Config{}, Deps{})
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
		t.Fatalf("content-type = %q", ct)
	}
	var body map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body["status"] != "ok" || body["version"] != "v1.2.3" || body["commit"] != "abc123" {
		t.Fatalf("body = %v", body)
	}
}

func TestHealthzRejectsPost(t *testing.T) {
	h := New(config.Config{}, Deps{})
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/healthz", nil))
	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status = %d", rec.Code)
	}
}

func TestHTTPServerTimeouts(t *testing.T) {
	s := NewHTTPServer(config.Config{Addr: ":1234"}, http.NewServeMux())
	if s.Addr != ":1234" {
		t.Errorf("Addr = %q", s.Addr)
	}
	if s.ReadHeaderTimeout != 5*time.Second || s.ReadTimeout != 30*time.Second ||
		s.WriteTimeout != 60*time.Second || s.IdleTimeout != 120*time.Second {
		t.Errorf("timeouts wrong: %v %v %v %v", s.ReadHeaderTimeout, s.ReadTimeout, s.WriteTimeout, s.IdleTimeout)
	}
	if s.MaxHeaderBytes != 1<<20 {
		t.Errorf("MaxHeaderBytes = %d", s.MaxHeaderBytes)
	}
}
