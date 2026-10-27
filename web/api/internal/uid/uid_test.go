package uid

import (
	"regexp"
	"testing"
)

func TestNewIsV4UUID(t *testing.T) {
	re := regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)
	seen := map[string]bool{}
	for i := 0; i < 50; i++ {
		id, err := New()
		if err != nil || !re.MatchString(id) || seen[id] {
			t.Fatalf("New() = %q, %v", id, err)
		}
		seen[id] = true
	}
}
