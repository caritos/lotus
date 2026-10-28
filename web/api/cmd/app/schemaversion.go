package main

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"sort"

	"app/internal/db/migrations"
)

func init() { commands["schema-version"] = schemaVersionCmd }

// schemaVersionCmd prints the filename of the highest embedded migration. The
// deploy script compares it between releases to tell whether a release migrates.
func schemaVersionCmd(args []string, _ func(string) string, stdout io.Writer) error {
	if len(args) != 0 {
		return errors.New("usage: app schema-version")
	}
	names, err := fs.Glob(migrations.FS, "*.sql")
	if err != nil {
		return fmt.Errorf("list migrations: %w", err)
	}
	if len(names) == 0 {
		return errors.New("no embedded migrations")
	}
	sort.Strings(names)
	_, err = fmt.Fprintln(stdout, names[len(names)-1])
	return err
}
