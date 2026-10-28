package notes

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"net/textproto"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"app/internal/apigen"
	"app/internal/auth"
	"app/internal/config"
	"app/internal/storage"
	"app/internal/testutil"
)

func TestMain(m *testing.M) {
	auth.UseFastHashingForTests()
	os.Exit(m.Run())
}

var (
	pngBytes  = append([]byte("\x89PNG\r\n\x1a\n"), make([]byte, 32)...)
	jpegBytes = append([]byte{0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 'J', 'F', 'I', 'F', 0}, make([]byte, 32)...)
)

type clock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *clock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.t = c.t.Add(time.Second)
	return c.t
}

type env struct {
	t      *testing.T
	h      http.Handler
	db     *sql.DB
	dir    string
	ca, cb *http.Cookie // sessions for user A and B
	idA    string
}

func newEnv(t *testing.T) *env {
	t.Helper()
	d := testutil.NewDB(t)
	svc := auth.NewService(d, config.Config{SessionTTL: time.Hour}, time.Now)
	dir := filepath.Join(t.TempDir(), "storage")
	st, err := storage.New(dir)
	if err != nil {
		t.Fatal(err)
	}
	store := NewStore(d)
	clk := &clock{t: time.Date(2026, 10, 27, 12, 0, 0, 0, time.UTC)}
	store.now = clk.Now
	e := &env{t: t, db: d, dir: dir}
	e.h = auth.Middleware(svc)(auth.Require(Handlers(store, st)))
	login := func(email string) (*http.Cookie, string) {
		u, err := svc.CreateUser(context.Background(), email, "password1")
		if err != nil {
			t.Fatal(err)
		}
		tok, _, err := svc.Login(context.Background(), email, "password1", "1.2.3.4")
		if err != nil {
			t.Fatal(err)
		}
		return &http.Cookie{Name: "app_session", Value: tok}, u.ID
	}
	e.ca, e.idA = login("a@x.io")
	e.cb, _ = login("b@x.io")
	return e
}

func (e *env) do(c *http.Cookie, method, path string, body io.Reader, ctype string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, path, body)
	if ctype != "" {
		req.Header.Set("Content-Type", ctype)
	}
	if c != nil {
		req.AddCookie(c)
	}
	rec := httptest.NewRecorder()
	e.h.ServeHTTP(rec, req)
	return rec
}

func (e *env) json(c *http.Cookie, method, path, body string) *httptest.ResponseRecorder {
	return e.do(c, method, path, strings.NewReader(body), "application/json")
}

func (e *env) create(c *http.Cookie, title string) apigen.Note {
	e.t.Helper()
	rec := e.json(c, "POST", "/api/notes", `{"title":"`+title+`","body":"b"}`)
	if rec.Code != 201 {
		e.t.Fatalf("create = %d %s", rec.Code, rec.Body)
	}
	return decodeNote(e.t, rec)
}

func decodeNote(t *testing.T, rec *httptest.ResponseRecorder) apigen.Note {
	t.Helper()
	var n apigen.Note
	if err := json.Unmarshal(rec.Body.Bytes(), &n); err != nil {
		t.Fatalf("decode %q: %v", rec.Body, err)
	}
	return n
}

func multipartBody(field, filename string, data []byte) (*bytes.Buffer, string) {
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	h := textproto.MIMEHeader{}
	h.Set("Content-Disposition", `form-data; name="`+field+`"; filename="`+filename+`"`)
	h.Set("Content-Type", "application/octet-stream")
	w, _ := mw.CreatePart(h)
	w.Write(data)
	mw.Close()
	return &buf, mw.FormDataContentType()
}

func (e *env) putPhoto(c *http.Cookie, id string, data []byte) *httptest.ResponseRecorder {
	body, ct := multipartBody("photo", "a.exe", data)
	return e.do(c, "PUT", "/api/notes/"+id+"/photo", body, ct)
}

func (e *env) storedPhoto(id string) string {
	e.t.Helper()
	var p sql.NullString
	if err := e.db.QueryRow(`SELECT photo FROM notes WHERE id = ?`, id).Scan(&p); err != nil {
		e.t.Fatal(err)
	}
	return p.String
}

func (e *env) files() []string {
	es, _ := os.ReadDir(e.dir)
	var n []string
	for _, f := range es {
		n = append(n, f.Name())
	}
	return n
}

func TestUnauthenticatedIs401(t *testing.T) {
	e := newEnv(t)
	n := e.create(e.ca, "x")
	for _, r := range [][2]string{
		{"GET", "/api/notes"}, {"POST", "/api/notes"}, {"GET", "/api/notes/" + n.ID},
		{"PATCH", "/api/notes/" + n.ID}, {"DELETE", "/api/notes/" + n.ID},
		{"PUT", "/api/notes/" + n.ID + "/photo"}, {"GET", "/api/notes/" + n.ID + "/photo"},
		{"DELETE", "/api/notes/" + n.ID + "/photo"},
	} {
		if rec := e.json(nil, r[0], r[1], `{}`); rec.Code != 401 {
			t.Errorf("%s %s = %d", r[0], r[1], rec.Code)
		}
	}
}

func TestListEmptyIsJSONArray(t *testing.T) {
	e := newEnv(t)
	rec := e.do(e.ca, "GET", "/api/notes", nil, "")
	if rec.Code != 200 || strings.TrimSpace(rec.Body.String()) != "[]" {
		t.Fatalf("%d %q", rec.Code, rec.Body)
	}
}

func TestCreateListOrdering(t *testing.T) {
	e := newEnv(t)
	n1 := e.create(e.ca, "first")
	n2 := e.create(e.ca, "second")
	// Touching the first bumps it above the second.
	if rec := e.json(e.ca, "PATCH", "/api/notes/"+n1.ID, `{"body":"x"}`); rec.Code != 200 {
		t.Fatal(rec.Code)
	}
	var list []apigen.Note
	rec := e.do(e.ca, "GET", "/api/notes", nil, "")
	if err := json.Unmarshal(rec.Body.Bytes(), &list); err != nil || len(list) != 2 {
		t.Fatalf("%v %q", err, rec.Body)
	}
	if list[0].ID != n1.ID || list[1].ID != n2.ID {
		t.Fatalf("order = %v", list)
	}
	if n1.Photo || n1.CreatedAt == 0 || n1.UpdatedAt == 0 {
		t.Fatalf("note = %+v", n1)
	}
}

func TestPatchPartialUpdate(t *testing.T) {
	e := newEnv(t)
	n := e.create(e.ca, "title")
	rec := e.json(e.ca, "PATCH", "/api/notes/"+n.ID, `{"title":"  new  "}`)
	if rec.Code != 200 {
		t.Fatal(rec.Code, rec.Body)
	}
	g := decodeNote(t, rec)
	if g.Title != "new" || g.Body != "b" || g.UpdatedAt <= n.UpdatedAt || g.CreatedAt != n.CreatedAt {
		t.Fatalf("got %+v from %+v", g, n)
	}
	rec = e.json(e.ca, "PATCH", "/api/notes/"+n.ID, `{"body":""}`)
	g = decodeNote(t, rec)
	if g.Title != "new" || g.Body != "" {
		t.Fatalf("got %+v", g)
	}
}

func TestValidation(t *testing.T) {
	e := newEnv(t)
	n := e.create(e.ca, "ok")
	long := strings.Repeat("é", 201)
	cases := []struct{ name, method, path, body string }{
		{"empty title", "POST", "/api/notes", `{"title":"   ","body":""}`},
		{"long title", "POST", "/api/notes", `{"title":"` + long + `","body":""}`},
		{"big body", "POST", "/api/notes", `{"title":"t","body":"` + strings.Repeat("a", 20001) + `"}`},
		{"unknown field", "POST", "/api/notes", `{"title":"t","body":"","x":1}`},
		{"trailing data", "POST", "/api/notes", `{"title":"t","body":""}{}`},
		{"not json", "POST", "/api/notes", `nope`},
		{"patch empty title", "PATCH", "/api/notes/" + n.ID, `{"title":""}`},
		{"patch unknown", "PATCH", "/api/notes/" + n.ID, `{"photo":true}`},
	}
	for _, c := range cases {
		rec := e.json(e.ca, c.method, c.path, c.body)
		var er apigen.Error
		if rec.Code != 400 || json.Unmarshal(rec.Body.Bytes(), &er) != nil || er.Error == "" {
			t.Errorf("%s: %d %q", c.name, rec.Code, rec.Body)
		}
	}
	// 200 runes of multibyte is fine; 20000-byte body is fine.
	if rec := e.json(e.ca, "POST", "/api/notes", `{"title":"`+strings.Repeat("é", 200)+`","body":"`+strings.Repeat("a", 20000)+`"}`); rec.Code != 201 {
		t.Errorf("limits: %d %q", rec.Code, rec.Body)
	}
}

func TestJSONBodyOver64KiBIs413(t *testing.T) {
	e := newEnv(t)
	rec := e.json(e.ca, "POST", "/api/notes", `{"title":"t","body":"`+strings.Repeat("a", 70<<10)+`"}`)
	if rec.Code != 413 {
		t.Fatalf("%d", rec.Code)
	}
}

func TestInvalidIDIs404(t *testing.T) {
	e := newEnv(t)
	for _, id := range []string{"nope", "1", "00000000-0000-4000-8000-000000000000", "..%2f"} {
		for _, m := range []string{"GET", "PATCH", "DELETE"} {
			if rec := e.json(e.ca, m, "/api/notes/"+id, `{}`); rec.Code != 404 {
				t.Errorf("%s %s = %d", m, id, rec.Code)
			}
		}
	}
}

func TestNotesCRUDScopedToUser(t *testing.T) {
	e := newEnv(t)
	n := e.create(e.ca, "mine")
	if rec := e.putPhoto(e.ca, n.ID, pngBytes); rec.Code != 200 {
		t.Fatal(rec.Code, rec.Body)
	}
	p := "/api/notes/" + n.ID
	for _, r := range [][2]string{
		{"GET", p}, {"PATCH", p}, {"DELETE", p},
		{"GET", p + "/photo"}, {"DELETE", p + "/photo"},
	} {
		if rec := e.json(e.cb, r[0], r[1], `{"title":"hax"}`); rec.Code != 404 {
			t.Errorf("B %s %s = %d", r[0], r[1], rec.Code)
		}
	}
	if rec := e.putPhoto(e.cb, n.ID, jpegBytes); rec.Code != 404 {
		t.Errorf("B PUT photo = %d", rec.Code)
	}
	// B's list is empty and A's note is untouched.
	if rec := e.do(e.cb, "GET", "/api/notes", nil, ""); strings.TrimSpace(rec.Body.String()) != "[]" {
		t.Errorf("B list = %q", rec.Body)
	}
	rec := e.do(e.ca, "GET", p, nil, "")
	g := decodeNote(t, rec)
	if rec.Code != 200 || g.Title != "mine" || !g.Photo {
		t.Fatalf("A note = %d %+v", rec.Code, g)
	}
	// A's own delete archives: 204, then 404.
	if rec := e.do(e.ca, "DELETE", p, nil, ""); rec.Code != 204 {
		t.Fatal(rec.Code)
	}
	for _, m := range []string{"GET", "PATCH", "DELETE"} {
		if rec := e.json(e.ca, m, p, `{}`); rec.Code != 404 {
			t.Errorf("archived %s = %d", m, rec.Code)
		}
	}
	if rec := e.do(e.ca, "GET", "/api/notes", nil, ""); strings.TrimSpace(rec.Body.String()) != "[]" {
		t.Errorf("list after archive = %q", rec.Body)
	}
}

func TestArchiveKeepsPhotoFile(t *testing.T) {
	e := newEnv(t)
	n := e.create(e.ca, "p")
	e.putPhoto(e.ca, n.ID, pngBytes)
	name := e.storedPhoto(n.ID)
	if rec := e.do(e.ca, "DELETE", "/api/notes/"+n.ID, nil, ""); rec.Code != 204 {
		t.Fatal(rec.Code)
	}
	if _, err := os.Stat(filepath.Join(e.dir, name)); err != nil {
		t.Fatalf("photo file gone after archive: %v", err)
	}
	var archived sql.NullInt64
	e.db.QueryRow(`SELECT archived_at FROM notes WHERE id = ?`, n.ID).Scan(&archived)
	if !archived.Valid {
		t.Fatal("archived_at not set")
	}
	// Archived note's photo is no longer served.
	if rec := e.do(e.ca, "GET", "/api/notes/"+n.ID+"/photo", nil, ""); rec.Code != 404 {
		t.Fatal(rec.Code)
	}
}

func TestPhotoRequiresOwner(t *testing.T) {
	e := newEnv(t)
	n := e.create(e.ca, "p")
	e.putPhoto(e.ca, n.ID, pngBytes)
	rec := e.do(e.ca, "GET", "/api/notes/"+n.ID+"/photo", nil, "")
	if rec.Code != 200 || !bytes.Equal(rec.Body.Bytes(), pngBytes) {
		t.Fatalf("owner: %d", rec.Code)
	}
	h := rec.Header()
	if h.Get("Content-Type") != "image/png" || h.Get("X-Content-Type-Options") != "nosniff" ||
		h.Get("Cache-Control") != "private, no-cache" || h.Get("Content-Length") != "40" {
		t.Fatalf("headers = %v", h)
	}
	if rec := e.do(e.cb, "GET", "/api/notes/"+n.ID+"/photo", nil, ""); rec.Code != 404 || bytes.Contains(rec.Body.Bytes(), []byte("PNG")) {
		t.Fatalf("other user: %d", rec.Code)
	}
	if rec := e.do(nil, "GET", "/api/notes/"+n.ID+"/photo", nil, ""); rec.Code != 401 {
		t.Fatalf("anon: %d", rec.Code)
	}
}

func TestPhotoGetWithoutPhoto404(t *testing.T) {
	e := newEnv(t)
	n := e.create(e.ca, "p")
	if rec := e.do(e.ca, "GET", "/api/notes/"+n.ID+"/photo", nil, ""); rec.Code != 404 {
		t.Fatal(rec.Code)
	}
}

func TestStoresRelativeFilenameOnly(t *testing.T) {
	e := newEnv(t)
	n := e.create(e.ca, "p")
	rec := e.putPhoto(e.ca, n.ID, pngBytes)
	if rec.Code != 200 || !decodeNote(t, rec).Photo {
		t.Fatalf("%d %q", rec.Code, rec.Body)
	}
	if strings.Contains(rec.Body.String(), ".png") {
		t.Fatalf("filename leaked in JSON: %q", rec.Body)
	}
	name := e.storedPhoto(n.ID)
	if name == "" || strings.ContainsAny(name, `/\`) || !strings.HasSuffix(name, ".png") || name != filepath.Base(name) {
		t.Fatalf("stored = %q", name)
	}
}

func TestReplacePhotoDeletesOldFile(t *testing.T) {
	e := newEnv(t)
	n := e.create(e.ca, "p")
	e.putPhoto(e.ca, n.ID, pngBytes)
	old := e.storedPhoto(n.ID)
	if rec := e.putPhoto(e.ca, n.ID, jpegBytes); rec.Code != 200 {
		t.Fatal(rec.Code, rec.Body)
	}
	cur := e.storedPhoto(n.ID)
	if cur == old || !strings.HasSuffix(cur, ".jpg") {
		t.Fatalf("old %q cur %q", old, cur)
	}
	if f := e.files(); len(f) != 1 || f[0] != cur {
		t.Fatalf("files = %v", f)
	}
}

func TestDeletePhotoRemovesFile(t *testing.T) {
	e := newEnv(t)
	n := e.create(e.ca, "p")
	e.putPhoto(e.ca, n.ID, pngBytes)
	if rec := e.do(e.ca, "DELETE", "/api/notes/"+n.ID+"/photo", nil, ""); rec.Code != 204 {
		t.Fatal(rec.Code)
	}
	if f := e.files(); len(f) != 0 {
		t.Fatalf("files = %v", f)
	}
	if e.storedPhoto(n.ID) != "" {
		t.Fatal("column not cleared")
	}
	if g := decodeNote(t, e.do(e.ca, "GET", "/api/notes/"+n.ID, nil, "")); g.Photo {
		t.Fatal("photo still true")
	}
}

func TestPutPhotoRejections(t *testing.T) {
	e := newEnv(t)
	n := e.create(e.ca, "p")
	if rec := e.putPhoto(e.ca, n.ID, []byte("just text, named a.exe")); rec.Code != 415 {
		t.Errorf("text = %d", rec.Code)
	}
	if f := e.files(); len(f) != 0 {
		t.Errorf("files = %v", f)
	}
	// Not multipart at all.
	if rec := e.json(e.ca, "PUT", "/api/notes/"+n.ID+"/photo", `{}`); rec.Code != 400 {
		t.Errorf("non-multipart = %d", rec.Code)
	}
}

func TestMultipartWithoutPhotoPart400(t *testing.T) {
	e := newEnv(t)
	n := e.create(e.ca, "p")
	body, ct := multipartBody("other", "a.png", pngBytes)
	rec := e.do(e.ca, "PUT", "/api/notes/"+n.ID+"/photo", body, ct)
	if rec.Code != 400 {
		t.Fatalf("%d %q", rec.Code, rec.Body)
	}
	if f := e.files(); len(f) != 0 {
		t.Fatalf("files = %v", f)
	}
}

func TestOversizedMultipartBodyIs413(t *testing.T) {
	e := newEnv(t)
	n := e.create(e.ca, "p")
	for _, size := range []int{5<<20 + 100, 6 << 20} {
		data := append(append([]byte{}, pngBytes...), make([]byte, size)...)
		rec := e.putPhoto(e.ca, n.ID, data)
		if rec.Code != 413 {
			t.Fatalf("size %d = %d %q", size, rec.Code, rec.Body)
		}
	}
	// Junk before the photo part pushes the body past the cap itself.
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	w, _ := mw.CreateFormField("junk")
	w.Write(make([]byte, 6<<20))
	mw.Close()
	if rec := e.do(e.ca, "PUT", "/api/notes/"+n.ID+"/photo", &buf, mw.FormDataContentType()); rec.Code != 413 {
		t.Fatalf("junk = %d", rec.Code)
	}
	if f := e.files(); len(f) != 0 {
		t.Fatalf("files = %v", f)
	}
}
