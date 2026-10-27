// Package version holds build metadata injected with -ldflags.
package version

// Version and Commit are set at build time; see the Makefile.
var (
	Version = "dev"
	Commit  = "unknown"
)
