package apigen_test

import (
	"encoding/json"
	"os"
	"strings"
	"testing"

	"goweb/internal/apigen"
)

func TestUserDecodesLoginResponse(t *testing.T) {
	var u apigen.User
	if err := json.Unmarshal([]byte(`{"id":"u-1","email":"a@b.co"}`), &u); err != nil {
		t.Fatal(err)
	}
	if u.ID != "u-1" || u.Email != "a@b.co" {
		t.Fatalf("got %+v", u)
	}
}

func TestNoteWireNames(t *testing.T) {
	b, err := json.Marshal(apigen.Note{ID: "n", Photo: true, CreatedAt: 1, UpdatedAt: 2})
	if err != nil {
		t.Fatal(err)
	}
	for _, k := range []string{`"id"`, `"title"`, `"body"`, `"photo":true`, `"created_at":1`, `"updated_at":2`} {
		if !strings.Contains(string(b), k) {
			t.Errorf("%s missing from %s", k, b)
		}
	}
}

func TestSpecDeclaresContractPaths(t *testing.T) {
	b, err := os.ReadFile("../../openapi.yaml")
	if err != nil {
		t.Fatal(err)
	}
	spec := string(b)
	for _, want := range []string{"openapi: 3.0.3", "/api/login:", "/api/me:", "/api/notes/{id}/photo:", "/healthz:", "goweb_session"} {
		if !strings.Contains(spec, want) {
			t.Errorf("openapi.yaml missing %q", want)
		}
	}
}
