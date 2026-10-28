package tests

import (
	"bytes"
	"encoding/json"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"io"
	"mime/multipart"
	"net/http"
	"net/url"
	"strings"
	"testing"

	"app/internal/apigen"
	"app/internal/apptest"
)

const (
	testEmail    = "ann@example.com"
	testPassword = "correct horse battery"
)

// req sends one request with c and returns the status, headers and body.
func req(t *testing.T, c *http.Client, method, url string, body io.Reader, hdr map[string]string) (int, http.Header, []byte) {
	t.Helper()
	r, err := http.NewRequest(method, url, body)
	if err != nil {
		t.Fatal(err)
	}
	for k, v := range hdr {
		r.Header.Set(k, v)
	}
	resp, err := c.Do(r)
	if err != nil {
		t.Fatalf("%s %s: %v", method, url, err)
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	return resp.StatusCode, resp.Header, b
}

func login(t *testing.T, a *apptest.App, c *http.Client, email, password string) (int, http.Header, []byte) {
	t.Helper()
	return req(t, c, http.MethodPost, a.URL+"/api/login", jsonBody(email, password), map[string]string{"Content-Type": "application/json"})
}

func jsonBody(email, password string) io.Reader {
	b, _ := json.Marshal(apigen.LoginRequest{Email: email, Password: password})
	return bytes.NewReader(b)
}

func mustLogin(t *testing.T, a *apptest.App, c *http.Client, email, password string) {
	t.Helper()
	if st, _, body := login(t, a, c, email, password); st != http.StatusOK {
		t.Fatalf("login %s = %d %s", email, st, body)
	}
}

func createNote(t *testing.T, a *apptest.App, c *http.Client, title string) apigen.Note {
	t.Helper()
	b, _ := json.Marshal(apigen.NoteInput{Title: title, Body: "body of " + title})
	st, _, body := req(t, c, http.MethodPost, a.URL+"/api/notes", bytes.NewReader(b), map[string]string{"Content-Type": "application/json"})
	if st != http.StatusCreated {
		t.Fatalf("create note = %d %s", st, body)
	}
	var n apigen.Note
	if err := json.Unmarshal(body, &n); err != nil {
		t.Fatal(err)
	}
	return n
}

func listNotes(t *testing.T, a *apptest.App, c *http.Client) []apigen.Note {
	t.Helper()
	st, _, body := req(t, c, http.MethodGet, a.URL+"/api/notes", nil, nil)
	if st != http.StatusOK {
		t.Fatalf("list notes = %d %s", st, body)
	}
	var ns []apigen.Note
	if err := json.Unmarshal(body, &ns); err != nil {
		t.Fatal(err)
	}
	return ns
}

// putPhoto uploads photo bytes as a multipart PUT and returns the status.
func putPhoto(t *testing.T, a *apptest.App, c *http.Client, id string, photo []byte) (int, []byte) {
	t.Helper()
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	fw, err := mw.CreateFormFile("photo", "upload.bin")
	if err != nil {
		t.Fatal(err)
	}
	fw.Write(photo)
	mw.Close()
	st, _, body := req(t, c, http.MethodPut, a.URL+"/api/notes/"+id+"/photo", &buf, map[string]string{"Content-Type": mw.FormDataContentType()})
	return st, body
}

func testPNG(t *testing.T, shade uint8) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, 8, 8))
	for x := 0; x < 8; x++ {
		for y := 0; y < 8; y++ {
			img.Set(x, y, color.RGBA{shade, uint8(x * 30), uint8(y * 30), 255})
		}
	}
	var b bytes.Buffer
	if err := png.Encode(&b, img); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}

func testJPEG(t *testing.T) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, 16, 16))
	for x := 0; x < 16; x++ {
		img.Set(x, x, color.RGBA{200, 10, 10, 255})
	}
	var b bytes.Buffer
	if err := jpeg.Encode(&b, img, nil); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}

func contains(s string, subs ...string) bool {
	for _, sub := range subs {
		if !strings.Contains(s, sub) {
			return false
		}
	}
	return true
}

func mustURL(t *testing.T, s string) *url.URL {
	t.Helper()
	u, err := url.Parse(s)
	if err != nil {
		t.Fatal(err)
	}
	return u
}
