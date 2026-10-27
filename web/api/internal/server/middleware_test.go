package server

import (
	"bytes"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"goweb/internal/auth"
)

var ok = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
	_, _ = io.Copy(io.Discard, r.Body)
	w.WriteHeader(http.StatusNoContent)
})

func do(h http.Handler, method, target string, hdr map[string]string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, target, nil)
	for k, v := range hdr {
		r.Header.Set(k, v)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, r)
	return rec
}

func TestSecurityHeadersPresent(t *testing.T) {
	rec := do(SecurityHeaders(false)(ok), "GET", "/", nil)
	want := map[string]string{
		"X-Content-Type-Options":  "nosniff",
		"X-Frame-Options":         "DENY",
		"Referrer-Policy":         "same-origin",
		"Permissions-Policy":      "camera=(), microphone=(), geolocation=()",
		"Content-Security-Policy": "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'",
	}
	for k, v := range want {
		if got := rec.Header().Get(k); got != v {
			t.Errorf("%s = %q, want %q", k, got, v)
		}
	}
	if rec.Header().Get("Strict-Transport-Security") != "" {
		t.Error("HSTS must not be set when not secure")
	}
}

func TestSecurityHeadersHSTSOnlyWhenSecure(t *testing.T) {
	rec := do(SecurityHeaders(true)(ok), "GET", "/", nil)
	if got := rec.Header().Get("Strict-Transport-Security"); got != "max-age=31536000; includeSubDomains" {
		t.Fatalf("HSTS = %q", got)
	}
}

func TestSameOriginRejectsForeignOrigin(t *testing.T) {
	h := SameOrigin("https://app.example")(ok)
	rec := do(h, "POST", "/api/x", map[string]string{"Origin": "https://evil.example"})
	if rec.Code != 403 {
		t.Fatalf("status = %d", rec.Code)
	}
	if strings.TrimSpace(rec.Body.String()) != `{"error":"cross-origin request refused"}` {
		t.Fatalf("body = %q", rec.Body.String())
	}
	if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "application/json") {
		t.Fatalf("content-type = %q", ct)
	}
	// Scheme and port must match exactly.
	for _, o := range []string{"http://app.example", "https://app.example:8443", "null"} {
		if rec := do(h, "DELETE", "/api/x", map[string]string{"Origin": o}); rec.Code != 403 {
			t.Errorf("origin %q: status = %d", o, rec.Code)
		}
	}
}

func TestSameOriginAllowsMatching(t *testing.T) {
	h := SameOrigin("https://app.example")(ok)
	for _, m := range []string{"POST", "PUT", "PATCH", "DELETE"} {
		if rec := do(h, m, "/api/x", map[string]string{"Origin": "https://app.example"}); rec.Code != 204 {
			t.Errorf("%s: status = %d", m, rec.Code)
		}
	}
}

func TestSameOriginSecFetchSite(t *testing.T) {
	h := SameOrigin("https://app.example")(ok)
	tests := []struct {
		site string
		want int
	}{
		{"", 204}, {"same-origin", 204}, {"none", 204},
		{"cross-site", 403}, {"same-site", 403}, {"bogus", 403},
	}
	for _, tt := range tests {
		hdr := map[string]string{}
		if tt.site != "" {
			hdr["Sec-Fetch-Site"] = tt.site
		}
		if rec := do(h, "POST", "/api/x", hdr); rec.Code != tt.want {
			t.Errorf("Sec-Fetch-Site %q: status = %d, want %d", tt.site, rec.Code, tt.want)
		}
	}
}

func TestSameOriginEmptyPublicOriginComparesHost(t *testing.T) {
	h := SameOrigin("")(ok)
	r := httptest.NewRequest("POST", "http://localhost:8080/api/x", nil)
	r.Header.Set("Origin", "http://localhost:8080")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, r)
	if rec.Code != 204 {
		t.Fatalf("matching host: status = %d", rec.Code)
	}
	r = httptest.NewRequest("POST", "http://localhost:8080/api/x", nil)
	r.Header.Set("Origin", "http://evil.example")
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, r)
	if rec.Code != 403 {
		t.Fatalf("foreign host: status = %d", rec.Code)
	}
}

func TestSameOriginNeverBlocksSafeMethods(t *testing.T) {
	h := SameOrigin("https://app.example")(ok)
	for _, m := range []string{"GET", "HEAD", "OPTIONS"} {
		hdr := map[string]string{"Origin": "https://evil.example", "Sec-Fetch-Site": "cross-site"}
		if rec := do(h, m, "/", hdr); rec.Code != 204 {
			t.Errorf("%s: status = %d", m, rec.Code)
		}
	}
}

func TestBodyLimit413(t *testing.T) {
	h := BodyLimit(10)(ok)
	r := httptest.NewRequest("POST", "/", strings.NewReader(strings.Repeat("a", 11)))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, r)
	if rec.Code != 413 {
		t.Fatalf("declared length: status = %d", rec.Code)
	}
	// Unknown length (chunked): the reader enforces the cap.
	var read int
	reader := BodyLimit(10)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, err := io.ReadAll(r.Body)
		read = len(b)
		if err != nil {
			w.WriteHeader(http.StatusRequestEntityTooLarge)
			return
		}
		w.WriteHeader(204)
	}))
	r = httptest.NewRequest("POST", "/", io.NopCloser(strings.NewReader(strings.Repeat("a", 50))))
	r.ContentLength = -1
	rec = httptest.NewRecorder()
	reader.ServeHTTP(rec, r)
	if rec.Code != 413 || read > 10 {
		t.Fatalf("status = %d, read = %d", rec.Code, read)
	}
	// Within the limit passes.
	r = httptest.NewRequest("POST", "/", strings.NewReader("0123456789"))
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, r)
	if rec.Code != 204 {
		t.Fatalf("within limit: status = %d", rec.Code)
	}
}

// ipEcho reports the client IP the handler sees in context.
var ipEcho = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
	_, _ = io.WriteString(w, auth.ClientIPFromContext(r.Context()))
})

func peerIP(t *testing.T, cidrs, remote, xff string) string {
	t.Helper()
	mw, err := TrustedProxy(cidrs)
	if err != nil {
		t.Fatal(err)
	}
	r := httptest.NewRequest("GET", "/", nil)
	r.RemoteAddr = remote
	if xff != "" {
		r.Header.Set("X-Forwarded-For", xff)
	}
	rec := httptest.NewRecorder()
	mw(ipEcho).ServeHTTP(rec, r)
	return rec.Body.String()
}

func TestForwardedForIgnoredFromUntrustedPeer(t *testing.T) {
	if got := peerIP(t, "10.0.0.0/8", "203.0.113.9:5555", "1.2.3.4"); got != "203.0.113.9" {
		t.Fatalf("got %q", got)
	}
	if got := peerIP(t, "", "203.0.113.9:5555", "1.2.3.4"); got != "203.0.113.9" {
		t.Fatalf("no proxies: got %q", got)
	}
}

func TestForwardedForWalksRightToLeft(t *testing.T) {
	// Client spoofs 6.6.6.6; chain is client -> 10.0.0.2 -> 10.0.0.1 (peer).
	got := peerIP(t, "10.0.0.0/8", "10.0.0.1:1", "6.6.6.6, 198.51.100.7, 10.0.0.2")
	if got != "198.51.100.7" {
		t.Fatalf("got %q", got)
	}
	// Single trusted hop.
	if got := peerIP(t, "10.0.0.1", "10.0.0.1:1", "198.51.100.7"); got != "198.51.100.7" {
		t.Fatalf("got %q", got)
	}
	// All trusted: fall back to the peer.
	if got := peerIP(t, "10.0.0.0/8", "10.0.0.1:1", "10.0.0.5"); got != "10.0.0.1" {
		t.Fatalf("got %q", got)
	}
}

func TestForwardedForGarbageAndMapped(t *testing.T) {
	if got := peerIP(t, "10.0.0.0/8", "10.0.0.1:1", "not-an-ip"); got != "10.0.0.1" {
		t.Fatalf("garbage: got %q", got)
	}
	if got := peerIP(t, "10.0.0.0/8", "10.0.0.1:1", ""); got != "10.0.0.1" {
		t.Fatalf("absent: got %q", got)
	}
	if got := peerIP(t, "10.0.0.0/8", "10.0.0.1:1", "::ffff:198.51.100.7"); got != "198.51.100.7" {
		t.Fatalf("mapped xff: got %q", got)
	}
	if got := peerIP(t, "10.0.0.0/8", "[::ffff:10.0.0.1]:1", "198.51.100.7"); got != "198.51.100.7" {
		t.Fatalf("mapped peer: got %q", got)
	}
}

func TestTrustedProxyInvalid(t *testing.T) {
	if _, err := TrustedProxy("10.0.0.0/8,bogus"); err == nil {
		t.Fatal("want error")
	}
}

func TestRequestLogOmitsSecrets(t *testing.T) {
	var buf bytes.Buffer
	logger := slog.New(slog.NewJSONHandler(&buf, nil))
	h := RequestLog(logger)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "hello")
	}))
	r := httptest.NewRequest("POST", "/api/login?token=SECRETQUERY", strings.NewReader("password=SECRETBODY"))
	r.Header.Set("Cookie", "session=SECRETCOOKIE")
	r.Header.Set("Authorization", "Bearer SECRETAUTH")
	r = r.WithContext(auth.WithClientIP(r.Context(), "198.51.100.7"))
	h.ServeHTTP(httptest.NewRecorder(), r)
	out := buf.String()
	for _, s := range []string{"SECRETQUERY", "SECRETBODY", "SECRETCOOKIE", "SECRETAUTH", "token="} {
		if strings.Contains(out, s) {
			t.Errorf("log contains %q: %s", s, out)
		}
	}
	for _, s := range []string{`"method":"POST"`, `"path":"/api/login"`, `"status":200`, `"bytes":5`, `"ip":"198.51.100.7"`, `"duration_ms"`} {
		if !strings.Contains(out, s) {
			t.Errorf("log missing %s: %s", s, out)
		}
	}
}

type flushRec struct {
	*httptest.ResponseRecorder
}

func TestRequestLogPreservesFlusher(t *testing.T) {
	var flushed bool
	h := RequestLog(slog.New(slog.NewJSONHandler(io.Discard, nil)))(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
			flushed = true
		}
	}))
	h.ServeHTTP(flushRec{httptest.NewRecorder()}, httptest.NewRequest("GET", "/", nil))
	if !flushed {
		t.Fatal("Flusher not preserved")
	}
}

func TestNewAppliesChain(t *testing.T) {
	h := New(configDev(), Deps{})
	rec := do(h, "GET", "/healthz", nil)
	if rec.Header().Get("X-Frame-Options") != "DENY" {
		t.Fatal("security headers missing from New")
	}
	r := httptest.NewRequest("POST", "/api/login", nil)
	r.Header.Set("Origin", "https://evil.example")
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, r)
	if rec.Code != 403 {
		t.Fatalf("status = %d", rec.Code)
	}
}
