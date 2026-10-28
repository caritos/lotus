package tests

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// Guard rails for agent-written features. They are cheap file scans, so unlike the integration tests they
// run in the fast tier too. Conventions they rely on (keep to them when adding an endpoint):
//   - register routes with a literal "METHOD /path" pattern: mux.HandleFunc("GET /api/things/{id}", ...)
//   - declare the operation in web/api/openapi.yaml with an operationId
//   - name the operation in a "// covers: <operationId>" comment on the integration test that exercises it
//     (see notes_flow_test.go for the pattern to copy)

func TestSpecAndRegisteredRoutesMatch(t *testing.T) {
	spec := readFile(t, filepath.Join("..", "openapi.yaml"))
	ops, err := parseSpecOperations(spec)
	if err != nil {
		t.Fatal(err)
	}
	routes := goRoutes(t)
	for route := range routes {
		if _, ok := ops[route]; !ok {
			t.Errorf("%s is registered in %s but missing from openapi.yaml: add it (with an operationId), then run `make api`", route, routes[route])
		}
	}
	for route, id := range ops {
		if _, ok := routes[route]; !ok {
			t.Errorf("openapi.yaml declares %s (%s) but no handler registers that \"METHOD /path\" pattern", route, id)
		}
	}
}

func TestEveryOperationHasAnIntegrationTest(t *testing.T) {
	ops, err := parseSpecOperations(readFile(t, filepath.Join("..", "openapi.yaml")))
	if err != nil {
		t.Fatal(err)
	}
	covered := map[string]string{} // operationId -> file
	files, err := filepath.Glob("*_test.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range files {
		if f == "guardrails_test.go" {
			continue // its own examples are not coverage
		}
		for _, id := range parseCovers(readFile(t, f)) {
			covered[id] = f
		}
	}
	known := map[string]bool{}
	for route, id := range ops {
		known[id] = true
		if _, ok := covered[id]; !ok {
			t.Errorf("operation %s (%s) has no integration test: add one in web/api/tests and mark it with `// covers: %s` (see notes_flow_test.go)", id, route, id)
		}
	}
	for id, f := range covered {
		if !known[id] {
			t.Errorf("%s says `// covers: %s` but openapi.yaml has no such operationId (renamed or removed?)", f, id)
		}
	}
}

func TestParseSpecOperations(t *testing.T) {
	const spec = `openapi: 3.0.3
paths:
  /healthz:
    get:
      operationId: getHealth
  /api/notes/{id}:
    parameters:
      - name: id
    get:
      operationId: getNote
    delete:
      summary: x
      operationId: deleteNote
components:
  responses:
    post:
      operationId: notAnOperation
`
	got, err := parseSpecOperations(spec)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]string{"GET /healthz": "getHealth", "GET /api/notes/{id}": "getNote", "DELETE /api/notes/{id}": "deleteNote"}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Errorf("got %v, want %v", got, want)
	}
	for name, bad := range map[string]string{
		"no paths":            "openapi: 3.0.3\ninfo:\n  title: x\n",
		"no operationId":      "paths:\n  /a:\n    get:\n      summary: x\n",
		"duplicate operation": "paths:\n  /a:\n    get:\n      operationId: same\n  /b:\n    get:\n      operationId: same\n",
	} {
		if _, err := parseSpecOperations(bad); err == nil {
			t.Errorf("%s: want an error, got none", name)
		}
	}
}

func TestScanRoutes(t *testing.T) {
	const src = `package x
func Handlers() {
	mux.HandleFunc("GET /api/notes", a.list)
	mux.Handle("PATCH /api/notes/{id}", h)
	mux.HandleFunc("GET /{$}", home)
	mux.Handle("/api/notes/", h) // no method: a prefix mount, not an operation
	// mux.HandleFunc("GET /api/commented-out", a.nope)
	log.Println("GET /api/in-a-string")
}`
	got := scanRoutes(src)
	sort.Strings(got)
	want := []string{"GET /", "GET /api/notes", "PATCH /api/notes/{id}"}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestParseCovers(t *testing.T) {
	const src = `package tests
// covers: login, logout
// covers: getMe
// covers:   listNotes createNote
// an ordinary comment that mentions covers: nothing
func TestX(t *testing.T) {}`
	got := parseCovers(src)
	want := []string{"login", "logout", "getMe", "listNotes", "createNote"}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestGoRoutesFindsTheRealRoutes(t *testing.T) {
	// Guards the guard: if the scan ever matched nothing, the drift test above would pass vacuously.
	routes := goRoutes(t)
	for _, want := range []string{"GET /healthz", "POST /api/login", "GET /api/notes/{id}"} {
		if _, ok := routes[want]; !ok {
			t.Errorf("goRoutes did not find %q (found %d routes)", want, len(routes))
		}
	}
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// goRoutes returns every "METHOD /path" pattern registered in non-test Go files under internal/ and cmd/,
// mapped to the file that registers it.
func goRoutes(t *testing.T) map[string]string {
	t.Helper()
	routes := map[string]string{}
	for _, root := range []string{filepath.Join("..", "internal"), filepath.Join("..", "cmd")} {
		err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
			if err != nil || d.IsDir() || !strings.HasSuffix(p, ".go") || strings.HasSuffix(p, "_test.go") {
				return err
			}
			for _, r := range scanRoutes(readFile(t, p)) {
				routes[r] = strings.TrimPrefix(filepath.ToSlash(p), "../")
			}
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	return routes
}
