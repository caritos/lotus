// Package tests holds integration tests that boot the real application wiring
// through internal/apptest. They are skipped under -short (the fast tier); the
// full tier (go test -race ./...) runs them.
package tests

import (
	"os"
	"testing"

	"goweb/internal/auth"
)

func TestMain(m *testing.M) {
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
