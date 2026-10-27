// Package auth implements password hashing, cookie sessions, login throttling and HTTP handlers.
package auth

import (
	"flag"

	"golang.org/x/crypto/bcrypt"
)

const productionCost = 12

// maxPasswordBytes is bcrypt's input limit; longer passwords are rejected, not truncated.
const maxPasswordBytes = 72

var (
	cost = productionCost
	// inTestBinary reports whether the process is a `go test` binary.
	inTestBinary = func() bool { return flag.Lookup("test.v") != nil }
)

// UseFastHashingForTests lowers the bcrypt cost to the minimum. It panics
// outside a test binary so it can never weaken production hashing.
func UseFastHashingForTests() {
	if !inTestBinary() {
		panic("auth.UseFastHashingForTests called outside a test binary")
	}
	cost = bcrypt.MinCost
}

// HashPassword returns a bcrypt hash of pw.
func HashPassword(pw string) (string, error) {
	h, err := bcrypt.GenerateFromPassword([]byte(pw), cost)
	if err != nil {
		return "", err
	}
	return string(h), nil
}

// CheckPassword reports whether pw matches hash.
func CheckPassword(hash, pw string) bool {
	return bcrypt.CompareHashAndPassword([]byte(hash), []byte(pw)) == nil
}
