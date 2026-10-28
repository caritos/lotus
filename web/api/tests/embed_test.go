package tests

import (
	"html"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"

	"app/internal/apptest"
	"app/internal/db/migrations"
	"app/internal/version"
	"app/internal/web"
)

// These tests are about the embeds, so they must not skip under -short.

func TestEmbeddedMigrationsPresent(t *testing.T) {
	onDisk, err := filepath.Glob(filepath.Join("..", "internal", "db", "migrations", "*.sql"))
	if err != nil {
		t.Fatal(err)
	}
	if len(onDisk) == 0 {
		t.Fatal("no migrations on disk")
	}
	entries, err := migrations.FS.ReadDir(".")
	if err != nil {
		t.Fatal(err)
	}
	var embedded []string
	for _, e := range entries {
		embedded = append(embedded, e.Name())
	}
	if !sort.StringsAreSorted(embedded) {
		t.Fatalf("embedded migrations not ordered: %v", embedded)
	}
	numbered := regexp.MustCompile(`^\d{4}_[a-z0-9_]+\.sql$`)
	have := map[string]bool{}
	for _, n := range embedded {
		have[n] = true
		if !numbered.MatchString(n) {
			t.Errorf("embedded migration %q is not NNNN_name.sql", n)
		}
	}
	for _, p := range onDisk {
		if !have[filepath.Base(p)] {
			t.Errorf("%s is on disk but not embedded", filepath.Base(p))
		}
	}
	if len(embedded) != len(onDisk) {
		t.Errorf("embedded %d migrations, %d on disk", len(embedded), len(onDisk))
	}
}

// builtIndex returns the on-disk React build's index.html. Locally it skips when
// the app has not been built; with CI set (as CI services do) a missing build is
// a failure, so the check can never be skipped silently there.
func builtIndex(t *testing.T) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("..", "internal", "web", "app", "index.html"))
	if err != nil {
		msg := "React app not built (internal/web/app/index.html missing); run `make build` first"
		if os.Getenv("CI") != "" {
			t.Fatal(msg + " (CI is set, so this is a failure, not a skip)")
		}
		t.Skip(msg)
	}
	return b
}

// withBuildID is the on-disk index.html as the server serves it: the only difference is
// the build id written over __BUILD_ID__.
func withBuildID(index []byte) string {
	return strings.ReplaceAll(string(index), "__BUILD_ID__", html.EscapeString(version.BuildID))
}

func TestEmbeddedAppPresentWhenBuilt(t *testing.T) {
	index := builtIndex(t)
	if !web.AppBuilt() {
		t.Fatal("index.html exists on disk but web.AppBuilt() is false: the embed is stale or missing")
	}
	a := apptest.NewServer(t)
	st, _, body := req(t, a.Client, http.MethodGet, a.URL+"/app/", nil, nil)
	if st != http.StatusOK || string(body) != withBuildID(index) {
		t.Fatalf("GET /app/ = %d, served index matches disk (plus build id): %v", st, string(body) == withBuildID(index))
	}
}

func TestAppDeepLinkServesIndexAndMissingAssetIs404(t *testing.T) {
	index := builtIndex(t)
	a := apptest.NewServer(t)
	st, _, body := req(t, a.Client, http.MethodGet, a.URL+"/app/missing/deep/link", nil, nil)
	if st != http.StatusOK || string(body) != withBuildID(index) {
		t.Fatalf("deep link = %d, serves index: %v", st, string(body) == withBuildID(index))
	}
	if st, _, _ := req(t, a.Client, http.MethodGet, a.URL+"/app/assets/nope.js", nil, nil); st != http.StatusNotFound {
		t.Fatalf("missing asset = %d, want 404", st)
	}
}
