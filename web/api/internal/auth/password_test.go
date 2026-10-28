package auth

import (
	"os"
	"os/exec"
	"testing"

	"golang.org/x/crypto/bcrypt"
)

func TestFastHashingLowersCost(t *testing.T) {
	h, err := HashPassword("password1")
	if err != nil {
		t.Fatal(err)
	}
	cost, err := bcrypt.Cost([]byte(h))
	if err != nil || cost != bcrypt.MinCost {
		t.Fatalf("cost = %d, err %v", cost, err)
	}
	if productionCost != 12 {
		t.Fatalf("production cost = %d", productionCost)
	}
}

func TestUseFastHashingPanicsOutsideTests(t *testing.T) {
	if os.Getenv("APP_AUTH_PANIC_CHILD") == "1" {
		inTestBinary = func() bool { return false }
		UseFastHashingForTests()
		return
	}
	cmd := exec.Command(os.Args[0], "-test.run=TestUseFastHashingPanicsOutsideTests")
	cmd.Env = append(os.Environ(), "APP_AUTH_PANIC_CHILD=1")
	if err := cmd.Run(); err == nil {
		t.Fatal("expected the child process to panic")
	}
}
