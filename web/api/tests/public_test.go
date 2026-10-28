package tests

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"goweb/internal/apptest"
	"goweb/internal/web"
)

// covers: getHealth
func TestHealthzReportsVersion(t *testing.T) {
	integration(t)
	a := apptest.NewServer(t)
	st, hdr, body := req(t, a.Client, http.MethodGet, a.URL+"/healthz", nil, nil)
	if st != http.StatusOK || !strings.HasPrefix(hdr.Get("Content-Type"), "application/json") {
		t.Fatalf("healthz = %d %s", st, hdr.Get("Content-Type"))
	}
	var m map[string]string
	if err := json.Unmarshal(body, &m); err != nil {
		t.Fatal(err)
	}
	if m["status"] != "ok" || m["version"] == "" || m["commit"] == "" {
		t.Fatalf("healthz body = %s", body)
	}
	if !buildIDRe.MatchString(m["build_id"]) {
		t.Fatalf("healthz build_id = %q, want YYYYMMDD-<commit>", m["build_id"])
	}
}

var buildIDRe = regexp.MustCompile(`^[0-9]{8}-([0-9a-f]{7}|unknown|[0-9a-z]+)(-dirty)?$`)

// Every HTML page the app serves shows "Build <id>" in its footer, and the id is the one
// /healthz reports. /app/ is skipped locally when the React app is not built (CI fails).
func TestEveryPageFooterShowsTheHealthzBuildID(t *testing.T) {
	integration(t)
	a := apptest.NewServer(t)
	_, _, hz := req(t, a.Client, http.MethodGet, a.URL+"/healthz", nil, nil)
	var health struct {
		BuildID string `json:"build_id"`
	}
	if err := json.Unmarshal(hz, &health); err != nil {
		t.Fatal(err)
	}
	if !buildIDRe.MatchString(health.BuildID) {
		t.Fatalf("healthz build_id = %q", health.BuildID)
	}
	want := "Build " + health.BuildID
	paths := []string{"/", "/faq", "/privacy", "/terms", "/support", "/nope"}
	if os.Getenv("CI") != "" || web.AppBuilt() {
		builtIndex(t) // fails under CI when the app is missing
		paths = append(paths, "/app/", "/app/notes/1")
	}
	for _, path := range paths {
		_, _, body := req(t, a.Client, http.MethodGet, a.URL+path, nil, nil)
		if !strings.Contains(string(body), want) {
			t.Errorf("%s: no %q in the page", path, want)
		}
		if strings.Contains(string(body), "@@BUILD_ID@@") || strings.Contains(string(body), "__BUILD_ID__") {
			t.Errorf("%s: placeholder left in the page", path)
		}
	}
}

func TestSecurityHeadersOnAllRoutes(t *testing.T) {
	integration(t)
	a := apptest.NewServer(t)
	want := []string{"X-Content-Type-Options", "X-Frame-Options", "Referrer-Policy", "Permissions-Policy", "Content-Security-Policy"}
	for _, path := range []string{"/", "/app/", "/api/me", "/healthz", "/nope", "/static/style.css"} {
		_, hdr, _ := req(t, a.Client, http.MethodGet, a.URL+path, nil, nil)
		for _, h := range want {
			if hdr.Get(h) == "" {
				t.Errorf("%s: missing header %s", path, h)
			}
		}
		if csp := hdr.Get("Content-Security-Policy"); !strings.Contains(csp, "frame-ancestors 'none'") {
			t.Errorf("%s: CSP %q lacks frame-ancestors", path, csp)
		}
	}
}

func TestPublicPagesServed(t *testing.T) {
	integration(t)
	a := apptest.NewServer(t)
	tags := regexp.MustCompile(`(?s)<(script|style)[^>]*>.*?</(script|style)>|<[^>]*>`)
	for _, path := range []string{"/", "/faq", "/privacy", "/terms", "/support"} {
		st, hdr, body := req(t, a.Client, http.MethodGet, a.URL+path, nil, nil)
		if st != http.StatusOK || !strings.HasPrefix(hdr.Get("Content-Type"), "text/html") {
			t.Errorf("%s = %d %s", path, st, hdr.Get("Content-Type"))
			continue
		}
		if text := strings.TrimSpace(tags.ReplaceAllString(string(body), "")); len(text) < 40 {
			t.Errorf("%s has too little body text: %q", path, text)
		}
	}
	if st, _, _ := req(t, a.Client, http.MethodGet, a.URL+"/nope", nil, nil); st != http.StatusNotFound {
		t.Errorf("/nope = %d, want 404", st)
	}
}

func TestMigrationsAppliedOnStartup(t *testing.T) {
	integration(t)
	a := apptest.NewServer(t)
	onDisk, err := filepath.Glob(filepath.Join("..", "internal", "db", "migrations", "*.sql"))
	if err != nil || len(onDisk) == 0 {
		t.Fatalf("migrations on disk: %v, %v", onDisk, err)
	}
	for _, p := range onDisk {
		var n int
		if err := a.DB.QueryRow(`SELECT count(*) FROM schema_migrations WHERE version = ?`, filepath.Base(p)).Scan(&n); err != nil || n != 1 {
			t.Errorf("migration %s recorded %d times (err %v)", filepath.Base(p), n, err)
		}
	}
}

func TestLogsWrittenToDataDir(t *testing.T) {
	integration(t)
	a := apptest.NewServer(t)
	a.CreateUser(testEmail, testPassword)
	c := a.NewClient()
	mustLogin(t, a, c, testEmail, testPassword)
	var token string
	for _, ck := range c.Jar.Cookies(mustURL(t, a.URL)) {
		if ck.Name == "goweb_session" {
			token = ck.Value
		}
	}
	if token == "" {
		t.Fatal("no session cookie in jar")
	}
	req(t, c, http.MethodGet, a.URL+"/api/me?secretparam=hunter2", nil, nil)

	b, err := os.ReadFile(filepath.Join(a.DataDir, "logs", "app.log"))
	if err != nil {
		t.Fatal(err)
	}
	log := string(b)
	if !strings.Contains(log, `"path":"/api/me"`) || !strings.Contains(log, `"msg":"request"`) {
		t.Fatalf("request not logged:\n%s", log)
	}
	for _, leak := range []string{token, "hunter2", "secretparam", testPassword} {
		if strings.Contains(log, leak) {
			t.Errorf("log leaks %q", leak)
		}
	}
}
