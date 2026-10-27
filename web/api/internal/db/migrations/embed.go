// Package migrations embeds the numbered SQL migrations. Never edit a released file.
package migrations

import "embed"

// FS holds every *.sql migration.
//
//go:embed *.sql
var FS embed.FS
