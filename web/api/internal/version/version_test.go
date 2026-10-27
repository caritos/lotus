package version

import (
	"regexp"
	"testing"
)

func TestBuildIDDefaultIsWellFormed(t *testing.T) {
	// Tests are not built with -ldflags, so this is the default; a real build id has the
	// same shape (YYYYMMDD-<short commit or unknown>, optionally -dirty).
	re := regexp.MustCompile(`^[0-9]{8}-[0-9a-z]+(-dirty)?$`)
	if !re.MatchString(BuildID) {
		t.Fatalf("BuildID = %q, want YYYYMMDD-<commit>", BuildID)
	}
}
