package web

import (
	"net/http"
	"net/http/httptest"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"testing/fstest"
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

func TestStaticServesNestedFiles(t *testing.T) {
	h := newHandler(builtApp, fstest.MapFS{
		"style.css":         {Data: []byte("body{}")},
		"fonts/inter.woff2": {Data: []byte("woff2-bytes")},
		"fonts/deep/y.woff": {Data: []byte("deep")},
	})
	for target, ctype := range map[string]string{
		"/static/style.css":         "text/css",
		"/static/fonts/inter.woff2": "font/woff2",
		"/static/fonts/deep/y.woff": "font/woff",
	} {
		rec := get(h, http.MethodGet, target)
		if rec.Code != 200 || !strings.HasPrefix(rec.Header().Get("Content-Type"), ctype) {
			t.Errorf("%s: status %d, content-type %q", target, rec.Code, rec.Header().Get("Content-Type"))
		}
		if cl := rec.Header().Get("Content-Length"); cl != strconv.Itoa(rec.Body.Len()) || cl == "0" {
			t.Errorf("%s: Content-Length %q, body %d", target, cl, rec.Body.Len())
		}
		if rec.Header().Get("ETag") == "" {
			t.Errorf("%s: no ETag", target)
		}
	}
	// A directory, a missing file and traversal are never served as a listing or a file outside static/.
	for _, target := range []string{"/static/fonts", "/static/fonts/", "/static/fonts/missing.woff2", "/static/", "/static/fonts/../../web.go"} {
		if rec := get(h, http.MethodGet, target); rec.Code == 200 {
			t.Errorf("%s: got 200, want 404 or a redirect", target)
		}
	}
}

func TestEtagMatchesForms(t *testing.T) {
	const tag = `"abc123"`
	for _, tc := range []struct {
		header string
		want   bool
	}{
		{tag, true},
		{`W/` + tag, true},
		{`"other", ` + tag, true},
		{`"other" ,  ` + tag + ` , "third"`, true},
		{"*", true},
		{`"other"`, false},
		{`abc123`, false}, // unquoted is not a valid entity-tag
		{"", false},
		{`,`, false},
	} {
		if got := etagMatches(tc.header, tag); got != tc.want {
			t.Errorf("etagMatches(%q) = %v, want %v", tc.header, got, tc.want)
		}
	}
}

func TestHeadWithMatchingIfNoneMatchIs304WithoutBody(t *testing.T) {
	h := NewHandler(builtApp)
	etag := get(h, http.MethodGet, "/faq").Header().Get("ETag")
	rec := get(h, http.MethodHead, "/faq", "If-None-Match", etag)
	if rec.Code != http.StatusNotModified || rec.Body.Len() != 0 {
		t.Errorf("status %d, body %d", rec.Code, rec.Body.Len())
	}
}

func TestErrorPagesHaveContentLengthAndNoETag(t *testing.T) {
	for name, rec := range map[string]*httptest.ResponseRecorder{
		"404":                 get(NewHandler(builtApp), http.MethodGet, "/nope"),
		"503 (app not built)": get(NewHandler(unbuiltApp), http.MethodGet, "/app/"),
	} {
		if cl := rec.Header().Get("Content-Length"); cl != strconv.Itoa(rec.Body.Len()) || cl == "0" {
			t.Errorf("%s: Content-Length %q, body %d", name, cl, rec.Body.Len())
		}
		if et := rec.Header().Get("ETag"); et != "" {
			t.Errorf("%s: error page must not carry ETag %q", name, et)
		}
	}
}
