// Package web serves the embedded public pages, static files and the built
// React app. Everything is embedded with go:embed so the release is one binary.
package web

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"html"
	"io/fs"
	"mime"
	"net/http"
	"path"
	"strconv"
	"strings"

	uiembed "app/embed"
	"app/internal/version"
)

// content is the embedded UI tree: pages/, static/ and spa/ (see package embed).
var content = uiembed.FS

const (
	cacheRevalidate = "no-cache"
	cacheImmutable  = "public, max-age=31536000, immutable"
)

// pageRoutes maps public URL paths to files in the embedded pages/.
var pageRoutes = map[string]string{
	"/":        "pages/index.html",
	"/faq":     "pages/faq.html",
	"/privacy": "pages/privacy.html",
	"/terms":   "pages/terms.html",
	"/support": "pages/support.html",
}

const (
	// pagePlaceholder marks where the build id goes in every page source under pages/
	// and in the generated 404 and 503 pages. It is replaced once, at startup.
	pagePlaceholder = "@@BUILD_ID@@"
	// appPlaceholder is the build id in web/index.html (the React app's meta tag).
	appPlaceholder = "__BUILD_ID__"
)

// footerHTML is the footer of the pages generated in Go; the static pages carry the same
// markup in their source files.
const footerHTML = `<footer class="site-footer"><p><span class="build-id">Build ` + pagePlaceholder + `</span></p></footer>`

var notFoundHTML = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Page not found</title><link rel="stylesheet" href="/static/style.css"></head>
<body><main><h1>Page not found</h1><p>We could not find that page. <a href="/">Go to the home page</a>.</p></main>
` + footerHTML + `</body></html>
`

var notBuiltHTML = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>App not built</title><link rel="stylesheet" href="/static/style.css"></head>
<body><main><h1>The web app is not built yet</h1><p>This binary was compiled without the React frontend. Run <code>pnpm build</code> in the <code>web/</code> directory, then rebuild the Go binary (or use the Vite dev server during development).</p><p><a href="/">Back to the home page</a></p></main>
` + footerHTML + `</body></html>
`

type handler struct {
	app      fs.FS
	pages    map[string]asset // by URL path
	static   map[string]asset // by URL path
	index    *asset           // the React app's index.html with the build id, nil when not built
	notFound asset
	notBuilt asset
}

type asset struct {
	body  []byte
	ctype string
	etag  string
}

// Handler serves the public site, /static/* and /app/* from the embedded files.
func Handler() http.Handler { return NewHandler(appFS()) }

// injectBuildID returns b with every occurrence of placeholder replaced by id,
// HTML-escaped (the id comes from -ldflags, but it ends up inside markup). It is the only
// templating in this package and the replacement is not re-scanned. The page sources hold
// the placeholder exactly once (a test enforces it); the app's index.html holds it twice
// (the meta tag and the no-JavaScript fallback).
func injectBuildID(b []byte, placeholder, id string) []byte {
	return bytes.Replace(b, []byte(placeholder), []byte(html.EscapeString(id)), -1)
}

// AppBuilt reports whether the embedded React build contains index.html.
func AppBuilt() bool {
	_, err := fs.Stat(appFS(), "index.html")
	return err == nil
}

func appFS() fs.FS {
	sub, err := fs.Sub(content, "spa")
	if err != nil {
		panic(err) // the embed directive guarantees the tree exists; requireUI reports an empty one
	}
	return sub
}

// NewHandler is Handler with an injectable React build FS (rooted at the
// build output, i.e. containing index.html and assets/). Pages and static
// files are always the embedded ones.
func NewHandler(app fs.FS) http.Handler { return NewHandlerWithBuildID(app, version.BuildID) }

// NewHandlerWithBuildID is NewHandler with an explicit build id, which is substituted once
// (before ETags and lengths are computed) into the page footers and the app's index.html.
func NewHandlerWithBuildID(app fs.FS, buildID string) http.Handler {
	static, err := fs.Sub(content, "static")
	if err != nil {
		panic(err) // the embed directive guarantees static/ exists
	}
	return newHandlerWithBuildID(app, static, buildID)
}

// newHandler also takes the static tree (rooted at static/, subfolders such as
// fonts/ included) so tests can inject one.
func newHandler(app, static fs.FS) http.Handler {
	return newHandlerWithBuildID(app, static, version.BuildID)
}

// newHandlerWithBuildID is the constructor behind all of the above. Static files are served
// byte for byte; only the pages, the generated 404 and 503 pages and the app's index.html
// get the build id.
func newHandlerWithBuildID(app, static fs.FS, buildID string) http.Handler {
	if err := requireUI(content); err != nil {
		panic(err)
	}
	h := &handler{app: app, pages: map[string]asset{}, static: map[string]asset{}}
	for route, file := range pageRoutes {
		h.pages[route] = mustLoad(file, buildID)
	}
	h.notFound = errorPage(injectBuildID([]byte(notFoundHTML), pagePlaceholder, buildID))
	h.notBuilt = errorPage(injectBuildID([]byte(notBuiltHTML), pagePlaceholder, buildID))
	if b, err := fs.ReadFile(app, "index.html"); err == nil {
		a := newAsset("index.html", injectBuildID(b, appPlaceholder, buildID))
		h.index = &a
	}
	err := fs.WalkDir(static, ".", func(name string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if strings.HasPrefix(d.Name(), ".") && name != "." { // .DS_Store and friends are never served
			if d.IsDir() {
				return fs.SkipDir
			}
			return nil
		}
		if d.IsDir() {
			return nil
		}
		b, err := fs.ReadFile(static, name)
		if err != nil {
			return err
		}
		h.static["/static/"+name] = newAsset(name, b)
		return nil
	})
	if err != nil {
		panic(err)
	}
	return h
}

// requireUI fails when the embedded UI tree holds no pages. The tree is generated from web/src and
// web/public (go:embed cannot reach outside the Go module), so an empty one means the build was
// skipped; serving a site with nothing in it, or failing later with "file does not exist", would hide that.
func requireUI(fsys fs.FS) error {
	pages, err := fs.Glob(fsys, "pages/*.html")
	if err != nil || len(pages) == 0 {
		return errors.New("web: the embedded UI (web/api/embed) has no pages; run `pnpm build` in web/ first (or `bash web/scripts/sync-public.sh` for the pages alone; every make target does it)")
	}
	return nil
}

// mustLoad reads an embedded page from pages/ and fills in the footer build id.
func mustLoad(name, buildID string) asset {
	b, err := content.ReadFile(name)
	if err != nil {
		panic(err)
	}
	return newAsset(name, injectBuildID(b, pagePlaceholder, buildID))
}

// errorPage is a generated 404 or 503 page: it has a Content-Length (set by serve) but no
// ETag, so an error is never answered with a 304 and never cached as a validator.
func errorPage(b []byte) asset {
	return asset{body: b, ctype: contentType("x.html")}
}

func newAsset(name string, b []byte) asset {
	sum := sha256.Sum256(b)
	return asset{body: b, ctype: contentType(name), etag: `"` + hex.EncodeToString(sum[:16]) + `"`}
}

func contentType(name string) string {
	switch strings.ToLower(path.Ext(name)) {
	case ".html":
		return "text/html; charset=utf-8"
	case ".css":
		return "text/css; charset=utf-8"
	case ".js", ".mjs":
		return "text/javascript; charset=utf-8"
	case ".svg":
		return "image/svg+xml"
	case ".woff2": // not in Go's built-in table; system mime files differ between machines
		return "font/woff2"
	case ".woff":
		return "font/woff"
	}
	if t := mime.TypeByExtension(path.Ext(name)); t != "" {
		return t
	}
	return "application/octet-stream"
}

func (h *handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	p := r.URL.Path
	switch {
	case p == "/app":
		http.Redirect(w, r, "/app/", http.StatusMovedPermanently)
	case strings.HasPrefix(p, "/app/"):
		h.serveApp(w, r, strings.TrimPrefix(p, "/app/"))
	default:
		if a, ok := h.pages[p]; ok {
			serve(w, r, http.StatusOK, a, cacheRevalidate)
		} else if a, ok := h.static[p]; ok {
			serve(w, r, http.StatusOK, a, cacheRevalidate)
		} else {
			h.notFoundPage(w, r)
		}
	}
}

func (h *handler) serveApp(w http.ResponseWriter, r *http.Request, rel string) {
	if h.index == nil {
		serve(w, r, http.StatusServiceUnavailable, h.notBuilt, cacheRevalidate)
		return
	}
	rel = path.Clean("/" + rel)[1:] // collapses "..", never leaves the tree
	inAssets := strings.HasPrefix(rel, "assets/")
	if rel != "" && rel != "index.html" { // index.html is served below, with the build id
		if info, err := fs.Stat(h.app, rel); err == nil && !info.IsDir() {
			if b, err := fs.ReadFile(h.app, rel); err == nil {
				cc := cacheRevalidate
				if inAssets {
					cc = cacheImmutable
				}
				serve(w, r, http.StatusOK, newAsset(rel, b), cc)
				return
			}
		}
		if inAssets {
			h.notFoundPage(w, r)
			return
		}
	}
	serve(w, r, http.StatusOK, *h.index, cacheRevalidate)
}

func (h *handler) notFoundPage(w http.ResponseWriter, r *http.Request) {
	serve(w, r, http.StatusNotFound, h.notFound, cacheRevalidate)
}

// serve writes a fully buffered response with an explicit Content-Length (the
// panel's HTTP/1.0 proxy corrupts chunked bodies) and honours If-None-Match.
func serve(w http.ResponseWriter, r *http.Request, status int, a asset, cacheControl string) {
	hd := w.Header()
	hd.Set("Content-Type", a.ctype)
	hd.Set("Cache-Control", cacheControl)
	hd.Set("X-Content-Type-Options", "nosniff")
	if a.etag != "" {
		hd.Set("ETag", a.etag)
		if status == http.StatusOK && etagMatches(r.Header.Get("If-None-Match"), a.etag) {
			w.WriteHeader(http.StatusNotModified)
			return
		}
	}
	hd.Set("Content-Length", strconv.Itoa(len(a.body)))
	w.WriteHeader(status)
	if r.Method != http.MethodHead {
		_, _ = w.Write(a.body)
	}
}

func etagMatches(header, etag string) bool {
	for _, c := range strings.Split(header, ",") {
		c = strings.TrimPrefix(strings.TrimSpace(c), "W/")
		if c == etag || c == "*" {
			return true
		}
	}
	return false
}
