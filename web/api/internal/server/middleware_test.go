package server

import (
	"bytes"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"testing"

	"app/internal/auth"
	"app/internal/config"
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
	rec := do(SecurityHeaders()(ok), "GET", "/", nil)
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
		t.Error("HSTS must never be set by the app")
	}
}

// The reverse proxy owns HSTS (staged max-age rollout, docs/https.md); a second
// header from the app would win in the browser and defeat that rollout.
func TestAppNeverSendsHSTS(t *testing.T) {
	for _, cfg := range []config.Config{
		{PublicOrigin: "https://app.example", Env: "production", SecureCookies: true, SessionSecret: "s"},
		{PublicOrigin: "http://localhost:5173", Env: "development"},
	} {
		h := New(cfg, Deps{Logger: slog.New(slog.DiscardHandler)})
		for _, target := range []string{"/healthz", "/", "/nope"} {
			rec := do(h, "GET", target, nil)
			if got := rec.Header().Get("Strict-Transport-Security"); got != "" {
				t.Errorf("env %s, GET %s: Strict-Transport-Security = %q, want none", cfg.Env, target, got)
			}
		}
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
	// Same shape as every other API error (apigen.Error).
	if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
		t.Errorf("413 Content-Type = %q, want application/json", ct)
	}
	if got := strings.TrimSpace(rec.Body.String()); got != `{"error":"request body too large"}` {
		t.Errorf("413 body = %q", got)
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

// TestNewAppliesChain pins the composition order in New (outermost first):
// TrustedProxy, RequestID, RequestLog, Recover, SecurityHeaders, SameOrigin, BodyLimit.
func TestNewAppliesChain(t *testing.T) {
	var buf bytes.Buffer
	cfg := config.Config{PublicOrigin: "https://app.example", TrustedProxy: "127.0.0.1/32"}
	h := New(cfg, Deps{Logger: slog.New(slog.NewJSONHandler(&buf, nil))})

	send := func(method, target string, hdr map[string]string, contentLength int64) *httptest.ResponseRecorder {
		t.Helper()
		buf.Reset()
		r := httptest.NewRequest(method, target, nil)
		r.RemoteAddr = "127.0.0.1:40000"
		r.Header.Set("X-Forwarded-For", "203.0.113.9")
		for k, v := range hdr {
			r.Header.Set(k, v)
		}
		if contentLength > 0 {
			r.ContentLength = contentLength
		}
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, r)
		return rec
	}
	hasSecurityHeaders := func(rec *httptest.ResponseRecorder) bool {
		return rec.Header().Get("X-Frame-Options") == "DENY" &&
			rec.Header().Get("X-Content-Type-Options") == "nosniff" &&
			rec.Header().Get("Content-Security-Policy") != ""
	}

	// Cross-origin POST: refused by SameOrigin, yet it carries the security
	// headers (SecurityHeaders is outside SameOrigin) and is logged with the
	// forwarded client IP (RequestLog is outside SameOrigin, TrustedProxy outside
	// RequestLog).
	rec := send("POST", "/api/login", map[string]string{"Origin": "https://evil.example"}, 0)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("cross-origin POST: status = %d, want 403", rec.Code)
	}
	if !hasSecurityHeaders(rec) {
		t.Errorf("cross-origin 403 lacks security headers: %v", rec.Header())
	}
	logged := buf.String()
	for _, want := range []string{`"path":"/api/login"`, `"status":403`, `"ip":"203.0.113.9"`} {
		if !strings.Contains(logged, want) {
			t.Errorf("request log for the refused POST lacks %s: %s", want, logged)
		}
	}

	// Oversized body (declared length): 413 from BodyLimit, with security headers, logged.
	rec = send("POST", "/api/login", map[string]string{"Origin": "https://app.example"}, maxBodyBytes+1)
	if rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("oversized POST: status = %d, want 413", rec.Code)
	}
	if !hasSecurityHeaders(rec) {
		t.Errorf("413 lacks security headers: %v", rec.Header())
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/json" || !strings.Contains(rec.Body.String(), `"error"`) {
		t.Errorf("413 is not a JSON Error: %q %q", ct, rec.Body.String())
	}
	if !strings.Contains(buf.String(), `"status":413`) {
		t.Errorf("413 not request-logged: %s", buf.String())
	}

	// A safe request is logged with the forwarded IP, and carries the headers.
	rec = send("GET", "/healthz", nil, 0)
	if rec.Code != http.StatusOK || !hasSecurityHeaders(rec) {
		t.Fatalf("GET /healthz: status = %d, headers = %v", rec.Code, rec.Header())
	}
	if !strings.Contains(buf.String(), `"ip":"203.0.113.9"`) {
		t.Errorf("trusted peer: handler chain did not see the forwarded client IP: %s", buf.String())
	}

	// From an untrusted peer the header is ignored.
	buf.Reset()
	r := httptest.NewRequest("GET", "/healthz", nil)
	r.RemoteAddr = "198.51.100.1:40000"
	r.Header.Set("X-Forwarded-For", "203.0.113.9")
	h.ServeHTTP(httptest.NewRecorder(), r)
	if !strings.Contains(buf.String(), `"ip":"198.51.100.1"`) {
		t.Errorf("untrusted peer: want the peer address logged: %s", buf.String())
	}
}

var requestIDPattern = regexp.MustCompile(`^[0-9a-f]{16}$`)

func TestRequestID(t *testing.T) {
	var seen string
	h := RequestID()(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen = RequestIDFromContext(r.Context())
		w.WriteHeader(http.StatusNoContent)
	}))
	tests := []struct {
		name    string
		inbound string
		reused  bool
	}{
		{"valid is reused", "abc.DEF_123-x", true},
		{"max length is reused", strings.Repeat("a", 64), true},
		{"too long is replaced", strings.Repeat("a", 65), false},
		{"bad characters are replaced", "evil id\"<script>", false},
		{"newline is replaced", "a\nb", false},
		{"empty is replaced", "", false},
		{"absent is generated", "-", false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			hdr := map[string]string{"X-Request-Id": tc.inbound}
			if tc.inbound == "-" {
				hdr = nil
			}
			rec := do(h, "GET", "/", hdr)
			got := rec.Header().Get("X-Request-Id")
			if tc.reused {
				if got != tc.inbound {
					t.Errorf("response id = %q, want %q", got, tc.inbound)
				}
			} else if !requestIDPattern.MatchString(got) {
				t.Errorf("response id = %q, want 16 hex characters", got)
			}
			if seen != got {
				t.Errorf("context id = %q, response id = %q", seen, got)
			}
		})
	}
	a := do(h, "GET", "/", nil).Header().Get("X-Request-Id")
	b := do(h, "GET", "/", nil).Header().Get("X-Request-Id")
	if a == b {
		t.Errorf("two requests share id %q", a)
	}
}

func TestRequestLogIncludesRequestID(t *testing.T) {
	var buf bytes.Buffer
	h := RequestID()(RequestLog(slog.New(slog.NewJSONHandler(&buf, nil)))(ok))
	do(h, "GET", "/", map[string]string{"X-Request-Id": "trace-1"})
	if !strings.Contains(buf.String(), `"request_id":"trace-1"`) {
		t.Errorf("log lacks request_id: %s", buf.String())
	}
}

func TestRecover(t *testing.T) {
	const secret = "SECRETPANICVALUE"
	var buf bytes.Buffer
	logger := slog.New(slog.NewJSONHandler(&buf, nil))
	chain := func(next http.HandlerFunc) http.Handler {
		return RequestID()(RequestLog(logger)(Recover(logger)(next)))
	}

	t.Run("panic becomes a JSON 500 and is logged", func(t *testing.T) {
		buf.Reset()
		rec := do(chain(func(http.ResponseWriter, *http.Request) { panic(secret) }), "GET", "/boom", map[string]string{"X-Request-Id": "rid-9"})
		if rec.Code != http.StatusInternalServerError {
			t.Fatalf("status = %d, want 500", rec.Code)
		}
		if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
			t.Errorf("Content-Type = %q", ct)
		}
		if got := strings.TrimSpace(rec.Body.String()); got != `{"error":"internal error"}` {
			t.Errorf("body = %q", got)
		}
		if rec.Header().Get("X-Request-Id") != "rid-9" {
			t.Errorf("X-Request-Id = %q", rec.Header().Get("X-Request-Id"))
		}
		if strings.Contains(rec.Body.String(), secret) {
			t.Errorf("panic value leaked to client: %s", rec.Body.String())
		}
		out := buf.String()
		for _, want := range []string{`"msg":"request"`, `"status":500`, `"path":"/boom"`, `"msg":"panic"`, `"level":"ERROR"`, secret, `"stack"`} {
			if !strings.Contains(out, want) {
				t.Errorf("log lacks %s: %s", want, out)
			}
		}
		if strings.Count(out, `"request_id":"rid-9"`) != 2 {
			t.Errorf("want request_id on both the panic and the request line: %s", out)
		}
	})

	t.Run("no second WriteHeader after a partial response", func(t *testing.T) {
		buf.Reset()
		rec := do(chain(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(http.StatusAccepted)
			_, _ = io.WriteString(w, "partial")
			panic(secret)
		}), "GET", "/", nil)
		if rec.Code != http.StatusAccepted || rec.Body.String() != "partial" {
			t.Errorf("response changed after headers were written: %d %q", rec.Code, rec.Body.String())
		}
		if !strings.Contains(buf.String(), `"msg":"panic"`) || !strings.Contains(buf.String(), `"status":202`) {
			t.Errorf("want the panic logged and the request logged with 202: %s", buf.String())
		}
	})

	t.Run("ErrAbortHandler is re-panicked", func(t *testing.T) {
		buf.Reset()
		defer func() {
			if v := recover(); v != http.ErrAbortHandler {
				t.Errorf("recovered %v, want http.ErrAbortHandler", v)
			}
			if strings.Contains(buf.String(), `"msg":"panic"`) {
				t.Errorf("abort logged as a panic: %s", buf.String())
			}
		}()
		do(Recover(logger)(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { panic(http.ErrAbortHandler) })), "GET", "/", nil)
	})
}

// TestWrapPanicOrder pins where RequestID and Recover sit: a panicking handler
// still gets the security headers, the request id, and a request log line with
// status 500, the id and the forwarded client IP.
func TestWrapPanicOrder(t *testing.T) {
	var buf bytes.Buffer
	cfg := config.Config{PublicOrigin: "https://app.example", TrustedProxy: "127.0.0.1/32"}
	h := Wrap(cfg, slog.New(slog.NewJSONHandler(&buf, nil)), http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		panic("boom")
	}))
	r := httptest.NewRequest("GET", "/boom", nil)
	r.RemoteAddr = "127.0.0.1:40000"
	r.Header.Set("X-Forwarded-For", "203.0.113.9")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, r)
	if rec.Code != http.StatusInternalServerError || rec.Header().Get("X-Frame-Options") != "DENY" {
		t.Fatalf("status = %d, headers = %v", rec.Code, rec.Header())
	}
	id := rec.Header().Get("X-Request-Id")
	if !requestIDPattern.MatchString(id) {
		t.Fatalf("X-Request-Id = %q", id)
	}
	for _, want := range []string{`"msg":"request"`, `"status":500`, `"ip":"203.0.113.9"`, `"request_id":"` + id + `"`, `"msg":"panic"`} {
		if !strings.Contains(buf.String(), want) {
			t.Errorf("log lacks %s: %s", want, buf.String())
		}
	}
}
