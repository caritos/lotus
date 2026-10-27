package web

import (
	"io/fs"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"testing/fstest"

	"goweb/internal/version"
)

var builtApp = fstest.MapFS{
	"index.html":          {Data: []byte(`<!doctype html><html><body><div id="root">SPA-INDEX</div></body></html>`)},
	"assets/index-abc.js": {Data: []byte(`console.log("hi")`)},
	"favicon.svg":         {Data: []byte(`<svg xmlns="http://www.w3.org/2000/svg"/>`)},
}

var unbuiltApp = fstest.MapFS{}

func get(h http.Handler, method, target string, hdr ...string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, target, nil)
	for i := 0; i+1 < len(hdr); i += 2 {
		req.Header.Set(hdr[i], hdr[i+1])
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

var (
	h1Re  = regexp.MustCompile(`(?s)<h1[^>]*>\s*([^<\s][^<]*)</h1>`)
	tagRe = regexp.MustCompile(`(?s)<[^>]*>`)
)

func TestPublicPagesHaveBodyText(t *testing.T) {
	h := NewHandler(builtApp)
	for _, p := range []string{"/", "/faq", "/privacy", "/terms", "/support"} {
		t.Run(p, func(t *testing.T) {
			rec := get(h, http.MethodGet, p)
			if rec.Code != 200 {
				t.Fatalf("status = %d", rec.Code)
			}
			if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "text/html") {
				t.Fatalf("content-type = %q", ct)
			}
			body := rec.Body.String()
			if !h1Re.MatchString(body) {
				t.Errorf("no non-empty <h1>")
			}
			if !regexp.MustCompile(`(?s)<title>\s*\S`).MatchString(body) {
				t.Errorf("no non-empty <title>")
			}
			if !strings.Contains(body, `href="/static/style.css"`) {
				t.Errorf("does not link shared stylesheet")
			}
			if n := len(strings.TrimSpace(tagRe.ReplaceAllString(body, " "))); n < 200 {
				t.Errorf("only %d bytes of text", n)
			}
			if strings.Contains(body, "{{") || strings.Contains(body, "<script") {
				t.Errorf("template syntax or script found")
			}
		})
	}
}

func TestPrivacyDatedAndMentionsData(t *testing.T) {
	body := get(NewHandler(builtApp), http.MethodGet, "/privacy").Body.String()
	for _, want := range []string{"2026-10-27", "email", "password", "photos", "cookie"} {
		if !strings.Contains(strings.ToLower(body), strings.ToLower(want)) {
			t.Errorf("privacy missing %q", want)
		}
	}
}

func TestStaticETagAndContentLength(t *testing.T) {
	h := NewHandler(builtApp)
	rec := get(h, http.MethodGet, "/static/style.css")
	if rec.Code != 200 {
		t.Fatalf("status = %d", rec.Code)
	}
	if !strings.HasPrefix(rec.Header().Get("Content-Type"), "text/css") {
		t.Errorf("content-type = %q", rec.Header().Get("Content-Type"))
	}
	etag := rec.Header().Get("ETag")
	if etag == "" {
		t.Fatal("no ETag")
	}
	if cl := rec.Header().Get("Content-Length"); cl != strconv.Itoa(rec.Body.Len()) || cl == "0" {
		t.Errorf("Content-Length = %q, body %d", cl, rec.Body.Len())
	}
	if cc := rec.Header().Get("Cache-Control"); cc != "no-cache" {
		t.Errorf("Cache-Control = %q", cc)
	}
	rec2 := get(h, http.MethodGet, "/static/style.css", "If-None-Match", etag)
	if rec2.Code != http.StatusNotModified || rec2.Body.Len() != 0 {
		t.Errorf("conditional: status %d body %d", rec2.Code, rec2.Body.Len())
	}
	head := get(h, http.MethodGet, "/", "If-None-Match", get(h, http.MethodGet, "/").Header().Get("ETag"))
	if head.Code != http.StatusNotModified {
		t.Errorf("page conditional status = %d", head.Code)
	}
}

func TestHeadHasLengthNoBody(t *testing.T) {
	rec := get(NewHandler(builtApp), http.MethodHead, "/faq")
	if rec.Code != 200 || rec.Body.Len() != 0 || rec.Header().Get("Content-Length") == "" {
		t.Errorf("status %d body %d CL %q", rec.Code, rec.Body.Len(), rec.Header().Get("Content-Length"))
	}
}

func TestPostRejected(t *testing.T) {
	if rec := get(NewHandler(builtApp), http.MethodPost, "/"); rec.Code != http.StatusMethodNotAllowed {
		t.Errorf("status = %d", rec.Code)
	}
}

func TestHashedAssetsImmutable(t *testing.T) {
	rec := get(NewHandler(builtApp), http.MethodGet, "/app/assets/index-abc.js")
	if rec.Code != 200 {
		t.Fatalf("status = %d", rec.Code)
	}
	if cc := rec.Header().Get("Cache-Control"); cc != "public, max-age=31536000, immutable" {
		t.Errorf("Cache-Control = %q", cc)
	}
	if rec.Header().Get("ETag") == "" || rec.Header().Get("Content-Length") == "" {
		t.Errorf("missing ETag or Content-Length")
	}
	if ct := rec.Header().Get("Content-Type"); !strings.Contains(ct, "javascript") {
		t.Errorf("content-type = %q", ct)
	}
}

func TestIndexNoCache(t *testing.T) {
	h := NewHandler(builtApp)
	for _, p := range []string{"/app/", "/app/index.html"} {
		rec := get(h, http.MethodGet, p)
		if rec.Code != 200 || !strings.Contains(rec.Body.String(), "SPA-INDEX") {
			t.Errorf("%s: status %d", p, rec.Code)
		}
		if cc := rec.Header().Get("Cache-Control"); cc != "no-cache" {
			t.Errorf("%s: Cache-Control = %q", p, cc)
		}
		if !strings.HasPrefix(rec.Header().Get("Content-Type"), "text/html") {
			t.Errorf("%s: content-type = %q", p, rec.Header().Get("Content-Type"))
		}
	}
}

func TestAppRedirectsToSlash(t *testing.T) {
	rec := get(NewHandler(builtApp), http.MethodGet, "/app")
	if rec.Code != http.StatusMovedPermanently || rec.Header().Get("Location") != "/app/" {
		t.Errorf("status %d location %q", rec.Code, rec.Header().Get("Location"))
	}
}

func TestSPAFallbackDeepLink(t *testing.T) {
	rec := get(NewHandler(builtApp), http.MethodGet, "/app/notes/123")
	if rec.Code != 200 || !strings.Contains(rec.Body.String(), "SPA-INDEX") {
		t.Fatalf("status %d body %q", rec.Code, rec.Body.String())
	}
	if rec.Header().Get("Cache-Control") != "no-cache" {
		t.Errorf("Cache-Control = %q", rec.Header().Get("Cache-Control"))
	}
}

func TestOtherAppFileServedNoCache(t *testing.T) {
	rec := get(NewHandler(builtApp), http.MethodGet, "/app/favicon.svg")
	if rec.Code != 200 || strings.Contains(rec.Body.String(), "SPA-INDEX") {
		t.Fatalf("status %d", rec.Code)
	}
	if rec.Header().Get("Cache-Control") != "no-cache" {
		t.Errorf("Cache-Control = %q", rec.Header().Get("Cache-Control"))
	}
}

func TestMissingAssetIs404(t *testing.T) {
	rec := get(NewHandler(builtApp), http.MethodGet, "/app/assets/nope.js")
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d", rec.Code)
	}
	if strings.Contains(rec.Body.String(), "SPA-INDEX") {
		t.Error("served SPA index for a missing asset")
	}
}

func TestPathTraversalDoesNotEscape(t *testing.T) {
	rec := get(NewHandler(builtApp), http.MethodGet, "/app/assets/../../pages/index.html")
	if strings.Contains(rec.Body.String(), "<h1") {
		t.Error("escaped the app tree")
	}
}

func TestFrontendNotBuiltMessage(t *testing.T) {
	h := NewHandler(unbuiltApp)
	for _, p := range []string{"/app/", "/app/notes/1", "/app/assets/x.js"} {
		rec := get(h, http.MethodGet, p)
		if rec.Code != http.StatusServiceUnavailable {
			t.Errorf("%s: status = %d", p, rec.Code)
		}
		if !strings.Contains(rec.Body.String(), "pnpm build") {
			t.Errorf("%s: body lacks 'pnpm build'", p)
		}
		if !strings.HasPrefix(rec.Header().Get("Content-Type"), "text/html") {
			t.Errorf("%s: content-type = %q", p, rec.Header().Get("Content-Type"))
		}
	}
	// public pages still work when the app is not built
	if rec := get(h, http.MethodGet, "/"); rec.Code != 200 {
		t.Errorf("/ status = %d", rec.Code)
	}
}

func TestUnknownIs404HTML(t *testing.T) {
	h := NewHandler(builtApp)
	for _, p := range []string{"/nope", "/faq/extra", "/static/missing.css", "/static/"} {
		rec := get(h, http.MethodGet, p)
		if rec.Code != http.StatusNotFound {
			t.Errorf("%s: status = %d", p, rec.Code)
		}
		if !strings.HasPrefix(rec.Header().Get("Content-Type"), "text/html") ||
			!strings.Contains(rec.Body.String(), "Page not found") ||
			!strings.Contains(rec.Body.String(), `href="/"`) {
			t.Errorf("%s: bad 404 body %q", p, rec.Body.String())
		}
	}
}

func TestDefaultHandlerAndAppBuilt(t *testing.T) {
	h := Handler()
	if rec := get(h, http.MethodGet, "/"); rec.Code != 200 {
		t.Fatalf("/ status = %d", rec.Code)
	}
	want := http.StatusServiceUnavailable
	if AppBuilt() {
		want = 200
	}
	if rec := get(h, http.MethodGet, "/app/"); rec.Code != want {
		t.Errorf("/app/ status = %d, want %d (AppBuilt=%v)", rec.Code, want, AppBuilt())
	}
}

// ---------------------------------------------------------------- build id footer

const testBuildID = "20261027-abc1234"

var builtAppWithMeta = fstest.MapFS{
	"index.html":        {Data: []byte(`<!doctype html><html><head><meta name="build-id" content="__BUILD_ID__" /></head><body><div id="root">SPA-INDEX</div></body></html>`)},
	"assets/index-a.js": {Data: []byte(`const s = "__BUILD_ID__";`)},
	"favicon.svg":       {Data: []byte(`<svg>__BUILD_ID__</svg>`)},
}

var pageFiles = func() []string {
	var files []string
	for _, f := range pageRoutes {
		files = append(files, f)
	}
	return files
}()

func TestEveryEmbeddedPageSourceHasTheFooterPlaceholderOnce(t *testing.T) {
	entries, err := content.ReadDir("pages")
	if err != nil {
		t.Fatal(err)
	}
	routed := map[string]bool{}
	for _, f := range pageFiles {
		routed[f] = true
	}
	for _, e := range entries {
		name := "pages/" + e.Name()
		if !routed[name] {
			t.Errorf("%s is embedded but has no route in pageRoutes", name)
		}
		b, err := content.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		src := string(b)
		if n := strings.Count(src, pagePlaceholder); n != 1 {
			t.Errorf("%s contains %q %d times, want exactly 1", name, pagePlaceholder, n)
		}
		if !strings.Contains(src, `<footer class="site-footer">`) || !strings.Contains(src, `class="build-id"`) {
			t.Errorf("%s lacks the site-footer element with a build-id span", name)
		}
	}
}

func TestServedPagesShowTheInjectedBuildID(t *testing.T) {
	h := NewHandlerWithBuildID(builtApp, testBuildID)
	for route := range pageRoutes {
		body := get(h, http.MethodGet, route).Body.String()
		if !strings.Contains(body, "Build "+testBuildID) {
			t.Errorf("%s: no %q in footer", route, "Build "+testBuildID)
		}
		if strings.Contains(body, pagePlaceholder) {
			t.Errorf("%s: placeholder left in the served page", route)
		}
	}
}

func TestDefaultHandlerUsesVersionBuildID(t *testing.T) {
	body := get(Handler(), http.MethodGet, "/").Body.String()
	if !strings.Contains(body, "Build "+version.BuildID) {
		t.Errorf("home page lacks Build %s", version.BuildID)
	}
	if body2 := get(NewHandler(builtApp), http.MethodGet, "/").Body.String(); body2 != body {
		t.Errorf("NewHandler and Handler disagree on the home page")
	}
}

func TestPageETagAndLengthFollowTheBuildID(t *testing.T) {
	a := get(NewHandlerWithBuildID(builtApp, "20261027-aaaaaaa"), http.MethodGet, "/faq")
	b := get(NewHandlerWithBuildID(builtApp, "20261028-bbbbbbb"), http.MethodGet, "/faq")
	if a.Header().Get("ETag") == "" || a.Header().Get("ETag") == b.Header().Get("ETag") {
		t.Errorf("ETag does not change with the id: %q vs %q", a.Header().Get("ETag"), b.Header().Get("ETag"))
	}
	if cl := a.Header().Get("Content-Length"); cl != strconv.Itoa(a.Body.Len()) {
		t.Errorf("Content-Length = %q, body %d", cl, a.Body.Len())
	}
}

func TestBuildIDIsHTMLEscaped(t *testing.T) {
	evil := `1"><script>alert(1)</script>&`
	h := NewHandlerWithBuildID(builtAppWithMeta, evil)
	for _, p := range []string{"/", "/app/", "/nope"} {
		body := get(h, http.MethodGet, p).Body.String()
		if strings.Contains(body, "<script>alert") {
			t.Errorf("%s: unescaped id in %q", p, body)
		}
		if p != "/nope" && !strings.Contains(body, "&lt;script&gt;") && !strings.Contains(body, "&lt;script") {
			t.Errorf("%s: escaped id not present", p)
		}
	}
}

func TestInjectBuildIDReplacesOnlyTheFirstPlaceholder(t *testing.T) {
	got := string(injectBuildID([]byte("a @@X@@ b @@X@@"), "@@X@@", "ID"))
	if got != "a ID b @@X@@" {
		t.Errorf("got %q", got)
	}
	if got := string(injectBuildID([]byte("no placeholder"), "@@X@@", "ID")); got != "no placeholder" {
		t.Errorf("got %q", got)
	}
	// the replacement text is never re-scanned
	if got := string(injectBuildID([]byte("@@X@@"), "@@X@@", "@@X@@")); got != "@@X@@" {
		t.Errorf("got %q", got)
	}
}

func TestNotFoundAndNotBuiltPagesHaveTheFooter(t *testing.T) {
	cases := []struct {
		name, path string
		app        fs.FS
		status     int
	}{
		{"404", "/nope", builtApp, http.StatusNotFound},
		{"404 asset", "/app/assets/nope.js", builtApp, http.StatusNotFound},
		{"503", "/app/", unbuiltApp, http.StatusServiceUnavailable},
	}
	for _, c := range cases {
		rec := get(NewHandlerWithBuildID(c.app, testBuildID), http.MethodGet, c.path)
		body := rec.Body.String()
		if rec.Code != c.status {
			t.Errorf("%s: status %d", c.name, rec.Code)
		}
		if !strings.Contains(body, `<footer class="site-footer">`) || !strings.Contains(body, `<span class="build-id">Build `+testBuildID+`</span>`) {
			t.Errorf("%s: no footer with the build id in %q", c.name, body)
		}
		if strings.Contains(body, pagePlaceholder) {
			t.Errorf("%s: placeholder left", c.name)
		}
		if cl := rec.Header().Get("Content-Length"); cl != strconv.Itoa(rec.Body.Len()) {
			t.Errorf("%s: Content-Length %q vs body %d", c.name, cl, rec.Body.Len())
		}
	}
}

func TestAppIndexGetsTheBuildIDAndOtherFilesAreUntouched(t *testing.T) {
	h := NewHandlerWithBuildID(builtAppWithMeta, testBuildID)
	for _, p := range []string{"/app/", "/app/index.html", "/app/notes/1"} {
		rec := get(h, http.MethodGet, p)
		body := rec.Body.String()
		if !strings.Contains(body, `<meta name="build-id" content="`+testBuildID+`" />`) {
			t.Errorf("%s: meta not replaced: %q", p, body)
		}
		if strings.Contains(body, appPlaceholder) {
			t.Errorf("%s: placeholder left", p)
		}
		if cl := rec.Header().Get("Content-Length"); cl != strconv.Itoa(rec.Body.Len()) {
			t.Errorf("%s: Content-Length = %q, body %d", p, cl, rec.Body.Len())
		}
	}
	for p, want := range map[string]string{
		"/app/assets/index-a.js": `const s = "__BUILD_ID__";`,
		"/app/favicon.svg":       `<svg>__BUILD_ID__</svg>`,
	} {
		if got := get(h, http.MethodGet, p).Body.String(); got != want {
			t.Errorf("%s was modified: %q", p, got)
		}
	}
}

func TestAppIndexETagChangesWithTheBuildID(t *testing.T) {
	a := get(NewHandlerWithBuildID(builtAppWithMeta, "20261027-aaaaaaa"), http.MethodGet, "/app/")
	b := get(NewHandlerWithBuildID(builtAppWithMeta, "20261028-bbbbbbb"), http.MethodGet, "/app/")
	if a.Header().Get("ETag") == "" || a.Header().Get("ETag") == b.Header().Get("ETag") {
		t.Errorf("ETag does not change with the id: %q vs %q", a.Header().Get("ETag"), b.Header().Get("ETag"))
	}
	h := NewHandlerWithBuildID(builtAppWithMeta, "20261027-aaaaaaa")
	if rec := get(h, http.MethodGet, "/app/", "If-None-Match", a.Header().Get("ETag")); rec.Code != http.StatusNotModified {
		t.Errorf("conditional request status = %d, want 304", rec.Code)
	}
	if rec := get(h, http.MethodGet, "/app/", "If-None-Match", b.Header().Get("ETag")); rec.Code != http.StatusOK {
		t.Errorf("stale ETag status = %d, want 200", rec.Code)
	}
}
