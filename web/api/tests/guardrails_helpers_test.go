package tests

import (
	"fmt"
	"regexp"
	"sort"
	"strings"
)

// No YAML library is a dependency of this module, so the spec is read by its indentation: paths at two
// spaces, methods at four, operationId at six. A spec laid out differently makes parseSpecOperations
// fail loudly (no operations found), never pass quietly.
var (
	specPathRe   = regexp.MustCompile(`^  (/\S*):\s*$`)
	specMethodRe = regexp.MustCompile(`^    (get|put|post|delete|patch|head|options):\s*$`)
	specOpIDRe   = regexp.MustCompile(`^      operationId:\s*(\S+)\s*$`)
)

// parseSpecOperations returns "METHOD /path" -> operationId for every operation under `paths:`.
func parseSpecOperations(spec string) (map[string]string, error) {
	ops := map[string]string{}
	seenID := map[string]string{}
	inPaths := false
	var path, pending string // pending: the "METHOD /path" still waiting for its operationId
	finish := func() error {
		if pending != "" {
			return fmt.Errorf("openapi.yaml: %s has no operationId", pending)
		}
		return nil
	}
	for _, line := range strings.Split(spec, "\n") {
		if line == "" || strings.HasPrefix(strings.TrimSpace(line), "#") {
			continue
		}
		if !strings.HasPrefix(line, " ") { // a top-level key
			if err := finish(); err != nil {
				return nil, err
			}
			inPaths = strings.TrimSpace(line) == "paths:"
			path = ""
			continue
		}
		if !inPaths {
			continue
		}
		if m := specPathRe.FindStringSubmatch(line); m != nil {
			if err := finish(); err != nil {
				return nil, err
			}
			path, pending = m[1], ""
		} else if m := specMethodRe.FindStringSubmatch(line); m != nil && path != "" {
			if err := finish(); err != nil {
				return nil, err
			}
			pending = strings.ToUpper(m[1]) + " " + path
		} else if m := specOpIDRe.FindStringSubmatch(line); m != nil && pending != "" {
			if prev, dup := seenID[m[1]]; dup {
				return nil, fmt.Errorf("openapi.yaml: operationId %q is used by both %s and %s", m[1], prev, pending)
			}
			seenID[m[1]] = pending
			ops[pending] = m[1]
			pending = ""
		}
	}
	if err := finish(); err != nil {
		return nil, err
	}
	if len(ops) == 0 {
		return nil, fmt.Errorf("openapi.yaml: no operations found under `paths:` (expected two-space paths, four-space methods, six-space operationId)")
	}
	return ops, nil
}

var routeRe = regexp.MustCompile(`\.Handle(?:Func)?\(\s*"(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS) (/[^"\s]*)"`)

// scanRoutes returns the "METHOD /path" patterns registered in Go source. Commented-out lines and
// method-less prefix mounts are ignored; a trailing {$} (exact match) is dropped.
func scanRoutes(src string) []string {
	var out []string
	for _, line := range strings.Split(src, "\n") {
		if strings.HasPrefix(strings.TrimSpace(line), "//") {
			continue
		}
		for _, m := range routeRe.FindAllStringSubmatch(line, -1) {
			out = append(out, m[1]+" "+strings.TrimSuffix(m[2], "{$}"))
		}
	}
	sort.Strings(out)
	return out
}

var coversRe = regexp.MustCompile(`(?m)^\s*//\s*covers:\s*(.+?)\s*$`)

// parseCovers returns the operationIds named by `// covers: a, b` comments, in order.
func parseCovers(src string) []string {
	var out []string
	for _, m := range coversRe.FindAllStringSubmatch(src, -1) {
		out = append(out, strings.Fields(strings.ReplaceAll(m[1], ",", " "))...)
	}
	return out
}
