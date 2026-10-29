// Package embed holds the user interface the binary serves, as one embedded tree:
//
//	pages/   public HTML pages  (copied from web/public/pages by web/scripts/sync-public.sh)
//	static/  CSS, fonts, icons  (copied from web/public/static by the same script)
//	spa/     the React build    (written by `pnpm build` from web/src)
//
// Everything but this file and .gitkeep is generated and gitignored. The frontend source lives in
// web/src and web/public; go:embed cannot reach outside the Go module, so the build copies it here.
// The pattern all:* always matches (.gitkeep), so a missing build compiles and is reported at
// start-up by internal/web instead of as a compile error.
package embed

import stdembed "embed"

//go:embed all:*
var FS stdembed.FS
