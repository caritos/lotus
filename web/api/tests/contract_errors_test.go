package tests

import (
	"bytes"
	"encoding/json"
	"net/http"
	"testing"

	"goweb/internal/apigen"
	"goweb/internal/apptest"
)

// The OpenAPI contract declares a 403 Error on every mutating operation and a
// 413 Error on the ones that take a body; these check the real responses match.

func decodeError(t *testing.T, what string, hdr http.Header, body []byte) apigen.Error {
	t.Helper()
	if ct := hdr.Get("Content-Type"); ct != "application/json" {
		t.Fatalf("%s: Content-Type = %q, want application/json", what, ct)
	}
	var e apigen.Error
	if err := json.Unmarshal(body, &e); err != nil || e.Error == "" {
		t.Fatalf("%s: body %q is not an Error: %v", what, body, err)
	}
	return e
}

func TestEveryMutatingOperationRefusesCrossOriginWithAnError(t *testing.T) {
	integration(t)
	a := apptest.NewServer(t)
	a.CreateUser(testEmail, testPassword)
	c := a.NewClient()
	mustLogin(t, a, c, testEmail, testPassword)
	n := createNote(t, a, c, "target")
	for _, op := range []struct{ method, path string }{
		{http.MethodPost, "/api/login"},
		{http.MethodPost, "/api/logout"},
		{http.MethodPost, "/api/notes"},
		{http.MethodPatch, "/api/notes/" + n.ID},
		{http.MethodDelete, "/api/notes/" + n.ID},
		{http.MethodPut, "/api/notes/" + n.ID + "/photo"},
		{http.MethodDelete, "/api/notes/" + n.ID + "/photo"},
	} {
		st, hdr, body := req(t, c, op.method, a.URL+op.path, bytes.NewReader([]byte("{}")),
			map[string]string{"Content-Type": "application/json", "Origin": "https://evil.example"})
		if st != http.StatusForbidden {
			t.Errorf("%s %s cross-origin = %d, want 403", op.method, op.path, st)
			continue
		}
		decodeError(t, op.method+" "+op.path, hdr, body)
	}
}

func TestOversizedBodyIsA413Error(t *testing.T) {
	integration(t)
	a := apptest.NewServer(t)
	big := bytes.Repeat([]byte("x"), 8<<20+1)
	st, hdr, body := req(t, a.NewClient(), http.MethodPost, a.URL+"/api/login", bytes.NewReader(big),
		map[string]string{"Content-Type": "application/json"})
	if st != http.StatusRequestEntityTooLarge {
		t.Fatalf("oversized login = %d, want 413", st)
	}
	if e := decodeError(t, "413", hdr, body); e.Error != "request body too large" {
		t.Fatalf("error = %q", e.Error)
	}
}
