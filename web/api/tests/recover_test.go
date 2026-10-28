package tests

import (
	"bytes"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"app/internal/config"
	"app/internal/server"
)

// A panic in a handler behind the real chain is a JSON 500 with a request id,
// and the server keeps serving. The panicking handler is test-only; the chain
// around it is the production one (server.Wrap).
func TestHandlerPanicIsAJSON500AndServerKeepsServing(t *testing.T) {
	integration(t)
	inner := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/boom" {
			panic("kaboom")
		}
		w.WriteHeader(http.StatusNoContent)
	})
	var logs bytes.Buffer
	ts := httptest.NewServer(server.Wrap(config.Config{PublicOrigin: "https://app.example"}, slog.New(slog.NewJSONHandler(&logs, nil)), inner))
	defer ts.Close()

	for i := 0; i < 2; i++ {
		st, hdr, body := req(t, ts.Client(), http.MethodGet, ts.URL+"/boom", nil, nil)
		if st != http.StatusInternalServerError || hdr.Get("Content-Type") != "application/json" ||
			strings.TrimSpace(string(body)) != `{"error":"internal error"}` || hdr.Get("X-Request-Id") == "" {
			t.Fatalf("panic request %d: %d %v %q", i, st, hdr, body)
		}
	}
	if got := strings.Count(logs.String(), `"msg":"panic"`); got != 2 || !strings.Contains(logs.String(), `"request_id"`) {
		t.Errorf("want 2 panic log lines with a request_id, got: %s", logs.String())
	}
	if st, _, _ := req(t, ts.Client(), http.MethodGet, ts.URL+"/ok", nil, nil); st != http.StatusNoContent {
		t.Fatalf("after panics: status = %d, want 204", st)
	}
}
