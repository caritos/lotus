// Package version holds build metadata injected with -ldflags.
package version

// Version, Commit and BuildID are set at build time; see the Makefile. BuildID comes from
// scripts/build-id.sh (YYYYMMDD-<short commit>, "-dirty" when the tree was modified); the
// default marks a binary built without it.
var (
	Version = "dev"
	Commit  = "unknown"
	BuildID = "00000000-unknown"
)
