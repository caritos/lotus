package tests

import (
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"
)

// The import-direction rules. Package names are relative to goweb/internal.
// These run in every tier: they are cheap and guard the layering.

// forbidRules: each package in Pkgs must not import any package in Forbid.
var forbidRules = []struct {
	Pkgs   []string
	Forbid []string
	Why    string
}{
	{
		Pkgs:   []string{"notes", "auth", "storage", "backup", "db", "db/migrations", "uid", "logging", "config", "version", "apigen", "web"},
		Forbid: []string{"server", "app", "apptest"},
		Why:    "only server, app and cmd compose features; features never reach back up",
	},
	{
		Pkgs:   []string{"db", "db/migrations", "uid", "version", "apigen", "config"},
		Forbid: []string{"auth", "notes", "storage", "server", "backup", "web", "logging", "app", "apptest", "testutil"},
		Why:    "foundation packages import no feature package",
	},
	{
		Pkgs:   []string{"auth"},
		Forbid: []string{"notes", "storage", "backup", "web", "logging"},
		Why:    "auth is a feature below notes; it must not know about notes or storage",
	},
	{
		Pkgs:   []string{"notes"},
		Forbid: []string{"backup", "web", "logging", "db"},
		Why:    "notes talks to auth only through its public context API (goweb/internal/auth) and gets *sql.DB injected",
	},
	{
		Pkgs:   []string{"storage", "backup", "logging", "web"},
		Forbid: []string{"auth", "notes"},
		Why:    "infrastructure packages know nothing of features",
	},
}

// onlyImportedBy: the package may be imported only by the listed packages.
var onlyImportedBy = []struct {
	Pkg     string
	Allowed []string
	Why     string
}{
	{"web", []string{"server", "app", "apptest"}, "the embedded UI is wired in by server only"},
	{"apptest", nil, "the test harness is imported by tests, never by production packages"},
	{"testutil", nil, "test helpers are imported by tests, never by production packages"},
	{"app", []string{"apptest"}, "app is the composition root, used by cmd and the test harness"},
	{"server", []string{"app", "apptest"}, "server is assembled by the composition root"},
}

const minPackages = 12

// checkImports applies the rules to graph (package -> imported internal
// packages) and returns one message per violation, sorted.
func checkImports(graph map[string][]string) []string {
	var out []string
	for _, r := range forbidRules {
		for _, p := range r.Pkgs {
			for _, imp := range graph[p] {
				for _, f := range r.Forbid {
					if imp == f {
						out = append(out, p+" must not import "+imp+" ("+r.Why+")")
					}
				}
			}
		}
	}
	for _, r := range onlyImportedBy {
		allowed := map[string]bool{}
		for _, a := range r.Allowed {
			allowed[a] = true
		}
		for p, imps := range graph {
			for _, imp := range imps {
				if imp == r.Pkg && !allowed[p] {
					out = append(out, p+" must not import "+imp+" ("+r.Why+")")
				}
			}
		}
	}
	sort.Strings(out)
	return out
}

func TestCheckImportsFlagsForbiddenEdge(t *testing.T) {
	clean := map[string][]string{
		"server": {"auth", "notes", "web"},
		"notes":  {"auth", "storage", "uid"},
		"auth":   {"config", "uid"},
		"db":     {"db/migrations"},
		"app":    {"server", "db"},
	}
	if v := checkImports(clean); len(v) != 0 {
		t.Fatalf("clean graph flagged: %v", v)
	}
	for name, edge := range map[string][2]string{
		"feature imports server":  {"notes", "server"},
		"foundation imports auth": {"db", "auth"},
		"auth imports notes":      {"auth", "notes"},
		"web imported by notes":   {"notes", "web"},
		"prod imports apptest":    {"storage", "apptest"},
	} {
		g := map[string][]string{"server": {"auth"}}
		g[edge[0]] = append(g[edge[0]], edge[1])
		if len(checkImports(g)) == 0 {
			t.Errorf("%s: %s -> %s not flagged", name, edge[0], edge[1])
		}
	}
}

// importGraph parses the non-test Go files under internal/ (imports only).
func importGraph(t *testing.T) map[string][]string {
	t.Helper()
	root := filepath.Join("..", "internal")
	const prefix = "goweb/internal/"
	sets := map[string]map[string]bool{}
	fset := token.NewFileSet()
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return err
		}
		pkg := filepath.ToSlash(filepath.Dir(strings.TrimPrefix(path, root+string(os.PathSeparator))))
		f, err := parser.ParseFile(fset, path, nil, parser.ImportsOnly)
		if err != nil {
			return err
		}
		if sets[pkg] == nil {
			sets[pkg] = map[string]bool{}
		}
		for _, imp := range f.Imports {
			p, _ := strconv.Unquote(imp.Path.Value)
			if strings.HasPrefix(p, prefix) {
				sets[pkg][strings.TrimPrefix(p, prefix)] = true
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	graph := map[string][]string{}
	for pkg, set := range sets {
		graph[pkg] = nil
		for imp := range set {
			graph[pkg] = append(graph[pkg], imp)
		}
		sort.Strings(graph[pkg])
	}
	return graph
}

func TestImportDiscoveryFindsPackages(t *testing.T) {
	g := importGraph(t)
	if len(g) < minPackages {
		t.Fatalf("discovered %d packages under internal/, want at least %d: the guard may be scanning the wrong place", len(g), minPackages)
	}
	for _, p := range []string{"auth", "notes", "db", "server", "web"} {
		if _, ok := g[p]; !ok {
			t.Errorf("package %q not discovered", p)
		}
	}
	if len(g["server"]) == 0 {
		t.Error("server has no discovered imports; import parsing is broken")
	}
}

func TestImportDirection(t *testing.T) {
	if v := checkImports(importGraph(t)); len(v) != 0 {
		t.Fatalf("import direction violations:\n  %s", strings.Join(v, "\n  "))
	}
}
