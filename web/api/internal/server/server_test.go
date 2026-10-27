package server

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"goweb/internal/auth"
	"goweb/internal/config"
	"goweb/internal/testutil"
	"goweb/internal/version"
)

func TestMain(m *testing.M) {
	auth.UseFastHashingForTests()
	os.Exit(m.Run())
}

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

func TestServesPublicPagesAndStaticAnd404(t *testing.T) {
	h := New(config.Config{}, Deps{})
	for path, want := range map[string]int{
		"/":                 http.StatusOK,
		"/privacy":          http.StatusOK,
		"/static/style.css": http.StatusOK,
		"/nope":             http.StatusNotFound,
		"/healthz":          http.StatusOK,
	} {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
		if rec.Code != want {
			t.Errorf("%s: status = %d, want %d", path, rec.Code, want)
		}
	}
}

func TestAuthRoutesMountedWhenServiceProvided(t *testing.T) {
	d := testutil.NewDB(t)
	svc := auth.NewService(d, config.Config{SessionTTL: time.Hour}, time.Now)
	if _, err := svc.CreateUser(context.Background(), "a@b.c", "password1"); err != nil {
		t.Fatal(err)
	}
	h := New(config.Config{}, Deps{DB: d, Auth: svc})

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/me", nil))
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("anonymous /api/me = %d", rec.Code)
	}

	rec = httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/login", strings.NewReader(`{"email":"a@b.c","password":"password1"}`))
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK || len(rec.Result().Cookies()) != 1 {
		t.Fatalf("login = %d", rec.Code)
	}
	rec2 := httptest.NewRecorder()
	req = httptest.NewRequest(http.MethodGet, "/api/me", nil)
	req.AddCookie(rec.Result().Cookies()[0])
	h.ServeHTTP(rec2, req)
	if rec2.Code != http.StatusOK {
		t.Fatalf("authed /api/me = %d", rec2.Code)
	}
}

func TestAuthRoutesAbsentWithoutService(t *testing.T) {
	h := New(config.Config{}, Deps{})
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/me", nil))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("/api/me without auth = %d", rec.Code)
	}
}
