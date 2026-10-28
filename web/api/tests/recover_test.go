package tests

import (
	"bytes"
	"encoding/json"
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

// explodingHandler has a distinctive name so the logged stack can be checked for it.
func explodingHandler(http.ResponseWriter, *http.Request) {
	panic("kaboom-value")
}

// logRecords parses newline-delimited JSON log output into one map per record.
func logRecords(t *testing.T, raw string) []map[string]any {
	t.Helper()
	var out []map[string]any
	for _, line := range strings.Split(strings.TrimSpace(raw), "\n") {
		if line == "" {
			continue
		}
		var m map[string]any
		if err := json.Unmarshal([]byte(line), &m); err != nil {
			t.Fatalf("log line is not JSON: %q: %v", line, err)
		}
		out = append(out, m)
	}
	return out
}

// The panic log record names the panicking function in its stack, carries the panic
// value and the request id on the same record, and the request record for the same id
// says 500.
func TestPanicLogRecordHasStackValueAndRequestID(t *testing.T) {
	integration(t)
	var logs bytes.Buffer
	ts := httptest.NewServer(server.Wrap(config.Config{PublicOrigin: "https://app.example"}, slog.New(slog.NewJSONHandler(&logs, nil)), http.HandlerFunc(explodingHandler)))
	defer ts.Close()
	st, hdr, _ := req(t, ts.Client(), http.MethodGet, ts.URL+"/boom", nil, nil)
	if st != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500", st)
	}
	id := hdr.Get("X-Request-Id")
	if id == "" {
		t.Fatal("the response has no X-Request-Id header; the logged ids below would be compared with an empty string")
	}
	var panicRec, reqRec map[string]any
	for _, rec := range logRecords(t, logs.String()) {
		switch rec["msg"] {
		case "panic":
			panicRec = rec
		case "request":
			reqRec = rec
		}
	}
	if panicRec == nil || reqRec == nil {
		t.Fatalf("want one panic and one request record, got: %s", logs.String())
	}
	if panicRec["level"] != "ERROR" || panicRec["panic"] != "kaboom-value" || panicRec["request_id"] != id || panicRec["path"] != "/boom" {
		t.Errorf("panic record = %v, want level ERROR, panic kaboom-value, request_id %s, path /boom", panicRec, id)
	}
	if stack, _ := panicRec["stack"].(string); !strings.Contains(stack, "explodingHandler") {
		t.Errorf("stack does not name the panicking function:\n%v", panicRec["stack"])
	}
	if reqRec["request_id"] != id || reqRec["status"] != float64(500) {
		t.Errorf("request record = %v, want request_id %s and status 500 on one record", reqRec, id)
	}
}
