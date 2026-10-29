// Package tests holds integration tests that boot the real application wiring
// through internal/apptest. They are skipped under -short (the fast tier); the
// full tier (go test -race ./...) runs them.
package tests

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"app/internal/auth"
)

func TestMain(m *testing.M) {
	// The embedded UI is generated from web/src and web/public; fail fast and clearly when it is missing.
	if _, err := os.Stat(filepath.Join("..", "embed", "pages", "index.html")); err != nil {
		fmt.Fprintln(os.Stderr, "embedded UI missing (web/api/embed/pages/index.html): run `pnpm build` in web/ first, or `bash web/scripts/sync-public.sh` for the pages alone")
		os.Exit(2)
	}
	auth.UseFastHashingForTests()
	os.Exit(m.Run())
}

// integration skips the calling test in the fast tier.
func integration(t *testing.T) {
	t.Helper()
	if testing.Short() {
		t.Skip("integration test; skipped with -short")
	}
}
