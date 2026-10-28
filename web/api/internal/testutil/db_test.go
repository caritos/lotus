package testutil_test

import (
	"testing"

	"app/internal/testutil"
)

func TestNewDBIsMigrated(t *testing.T) {
	d := testutil.NewDB(t)
	if _, err := d.Exec("INSERT INTO users (id,email,password_hash,created_at) VALUES ('u','A@x.io','h',1)"); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec("INSERT INTO users (id,email,password_hash,created_at) VALUES ('v','a@X.io','h',1)"); err == nil {
		t.Fatal("email uniqueness should be case-insensitive")
	}
	if _, err := d.Exec("INSERT INTO notes (id,user_id,title,created_at,updated_at) VALUES ('n','missing','t',1,1)"); err == nil {
		t.Fatal("foreign key should be enforced")
	}
}
