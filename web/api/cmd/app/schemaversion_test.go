package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestSchemaVersionPrintsHighestMigrationOnly(t *testing.T) {
	var out bytes.Buffer
	// No environment at all: the command needs no config or database.
	if err := run([]string{"schema-version"}, func(string) string { return "" }, &out); err != nil {
		t.Fatal(err)
	}
	got := out.String()
	if !strings.HasSuffix(got, ".sql\n") || strings.Count(got, "\n") != 1 || strings.Contains(strings.TrimSpace(got), " ") {
		t.Fatalf("output = %q, want one migration filename and a newline", got)
	}
	if !strings.HasPrefix(got, "0001_") {
		t.Fatalf("output = %q, want a name starting with 0001_ at minimum", got)
	}
}

func TestSchemaVersionRejectsArguments(t *testing.T) {
	if err := run([]string{"schema-version", "x"}, func(string) string { return "" }, &bytes.Buffer{}); err == nil {
		t.Fatal("expected a usage error")
	}
}
