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

	"app/internal/auth"
	"app/internal/config"
	"app/internal/storage"
	"app/internal/testutil"
	"app/internal/version"
)

func TestMain(m *testing.M) {
	auth.UseFastHashingForTests()
	os.Exit(m.Run())
}

func TestHealthz(t *testing.T) {
	version.Version, version.Commit, version.BuildID = "v1.2.3", "abc123", "20261027-abc1234"
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
	if body["status"] != "ok" || body["version"] != "v1.2.3" || body["commit"] != "abc123" || body["build_id"] != "20261027-abc1234" {
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

func TestNotesRoutesMountedOnlyWithAllDeps(t *testing.T) {
	d := testutil.NewDB(t)
	svc := auth.NewService(d, config.Config{SessionTTL: time.Hour}, time.Now)
	if _, err := svc.CreateUser(context.Background(), "a@b.c", "password1"); err != nil {
		t.Fatal(err)
	}
	st, err := storage.New(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	h := New(config.Config{}, Deps{DB: d, Auth: svc, Storage: st})
	get := func(h http.Handler, path string, c *http.Cookie) *httptest.ResponseRecorder {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodGet, path, nil)
		if c != nil {
			req.AddCookie(c)
		}
		h.ServeHTTP(rec, req)
		return rec
	}
	for _, p := range []string{"/api/notes", "/api/notes/00000000-0000-4000-8000-000000000000/photo"} {
		if rec := get(h, p, nil); rec.Code != http.StatusUnauthorized {
			t.Errorf("anonymous %s = %d", p, rec.Code)
		}
	}
	tok, _, err := svc.Login(context.Background(), "a@b.c", "password1", "1.2.3.4")
	if err != nil {
		t.Fatal(err)
	}
	rec := get(h, "/api/notes", &http.Cookie{Name: "app_session", Value: tok})
	if rec.Code != http.StatusOK || strings.TrimSpace(rec.Body.String()) != "[]" {
		t.Fatalf("authed list = %d %q", rec.Code, rec.Body)
	}
	// Without Storage the notes routes are not mounted, but /api/ is still default-deny:
	// signed out is a 401, signed in a JSON 404.
	h2 := New(config.Config{}, Deps{DB: d, Auth: svc})
	if rec := get(h2, "/api/notes", nil); rec.Code != http.StatusUnauthorized {
		t.Errorf("unmounted /api/notes signed out = %d, want 401", rec.Code)
	}
	if rec := get(h2, "/api/notes", &http.Cookie{Name: "app_session", Value: tok}); rec.Code != http.StatusNotFound || !strings.Contains(rec.Body.String(), `"error"`) {
		t.Errorf("unmounted /api/notes signed in = %d %q, want a JSON 404", rec.Code, rec.Body)
	}
}
