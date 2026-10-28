// Package web serves the embedded public pages, static files and the built
// React app. Everything is embedded with go:embed so the release is one binary.
package web

import (
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"io/fs"
	"mime"
	"net/http"
	"path"
	"strconv"
	"strings"
)

//go:embed pages/*.html static/* all:app
var content embed.FS

const (
	cacheRevalidate = "no-cache"
	cacheImmutable  = "public, max-age=31536000, immutable"
)

// pageRoutes maps public URL paths to files in pages/.
var pageRoutes = map[string]string{
	"/":        "pages/index.html",
	"/faq":     "pages/faq.html",
	"/privacy": "pages/privacy.html",
	"/terms":   "pages/terms.html",
	"/support": "pages/support.html",
}

const notFoundHTML = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Page not found</title><link rel="stylesheet" href="/static/style.css"></head>
<body><main><h1>Page not found</h1><p>We could not find that page. <a href="/">Go to the home page</a>.</p></main></body></html>
`

const notBuiltHTML = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>App not built</title><link rel="stylesheet" href="/static/style.css"></head>
<body><main><h1>The web app is not built yet</h1><p>This binary was compiled without the React frontend. Run <code>pnpm build</code> in the <code>web/</code> directory, then rebuild the Go binary (or use the Vite dev server during development).</p><p><a href="/">Back to the home page</a></p></main></body></html>
`

type handler struct {
	app    fs.FS
	pages  map[string]asset // by URL path
	static map[string]asset // by URL path
}

type asset struct {
	body  []byte
	ctype string
	etag  string
}

// Handler serves the public site, /static/* and /app/* from the embedded files.
func Handler() http.Handler { return NewHandler(appFS()) }

// AppBuilt reports whether the embedded React build contains index.html.
func AppBuilt() bool {
	_, err := fs.Stat(appFS(), "index.html")
	return err == nil
}

func appFS() fs.FS {
	sub, err := fs.Sub(content, "app")
	if err != nil {
		panic(err) // the embed directive guarantees app/ exists
	}
	return sub
}

// NewHandler is Handler with an injectable React build FS (rooted at the
// build output, i.e. containing index.html and assets/). Pages and static
// files are always the embedded ones.
func NewHandler(app fs.FS) http.Handler {
	static, err := fs.Sub(content, "static")
	if err != nil {
		panic(err) // the embed directive guarantees static/ exists
	}
	return newHandler(app, static)
}

// newHandler also takes the static tree (rooted at static/, subfolders such as
// fonts/ included) so tests can inject one.
func newHandler(app, static fs.FS) http.Handler {
	h := &handler{app: app, pages: map[string]asset{}, static: map[string]asset{}}
	for route, file := range pageRoutes {
		h.pages[route] = mustLoad(file)
	}
	err := fs.WalkDir(static, ".", func(name string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
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

func mustLoad(name string) asset {
	b, err := content.ReadFile(name)
	if err != nil {
		panic(err)
	}
	return newAsset(name, b)
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
			notFound(w, r)
		}
	}
}

func (h *handler) serveApp(w http.ResponseWriter, r *http.Request, rel string) {
	index, err := fs.ReadFile(h.app, "index.html")
	if err != nil {
		serve(w, r, http.StatusServiceUnavailable, asset{body: []byte(notBuiltHTML), ctype: contentType("x.html")}, cacheRevalidate)
		return
	}
	rel = path.Clean("/" + rel)[1:] // collapses "..", never leaves the tree
	inAssets := strings.HasPrefix(rel, "assets/")
	if rel != "" {
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
			notFound(w, r)
			return
		}
	}
	serve(w, r, http.StatusOK, newAsset("index.html", index), cacheRevalidate)
}

func notFound(w http.ResponseWriter, r *http.Request) {
	serve(w, r, http.StatusNotFound, asset{body: []byte(notFoundHTML), ctype: contentType("x.html")}, cacheRevalidate)
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
