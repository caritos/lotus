package tests

import (
	"bytes"
	"encoding/json"
	"net/http"
	"testing"

	"app/internal/apigen"
	"app/internal/apptest"
)

// covers: listNotes, createNote, putNotePhoto, getNotePhoto, deleteNotePhoto, deleteNote
func TestNotesFlowWithPhoto(t *testing.T) {
	integration(t)
	a := apptest.NewServer(t)
	a.CreateUser(testEmail, testPassword)
	a.CreateUser("bob@example.com", testPassword)
	mustLogin(t, a, a.Client, testEmail, testPassword)

	n := createNote(t, a, a.Client, "first")
	if n.Photo {
		t.Fatal("new note must not have a photo")
	}
	noteURL := a.URL + "/api/notes/" + n.ID

	pngBytes := testPNG(t, 40)
	if st, body := putPhoto(t, a, a.Client, n.ID, pngBytes); st != http.StatusOK {
		t.Fatalf("upload png = %d %s", st, body)
	}
	st, hdr, got := req(t, a.Client, http.MethodGet, noteURL+"/photo", nil, nil)
	if st != http.StatusOK || !bytes.Equal(got, pngBytes) || hdr.Get("Content-Type") != "image/png" {
		t.Fatalf("photo = %d %s, bytes equal %v", st, hdr.Get("Content-Type"), bytes.Equal(got, pngBytes))
	}

	jpgBytes := testJPEG(t)
	if st, body := putPhoto(t, a, a.Client, n.ID, jpgBytes); st != http.StatusOK {
		t.Fatalf("replace with jpeg = %d %s", st, body)
	}
	st, hdr, got = req(t, a.Client, http.MethodGet, noteURL+"/photo", nil, nil)
	if st != http.StatusOK || !bytes.Equal(got, jpgBytes) || hdr.Get("Content-Type") != "image/jpeg" {
		t.Fatalf("replaced photo = %d %s, bytes equal %v", st, hdr.Get("Content-Type"), bytes.Equal(got, jpgBytes))
	}

	// Another user cannot see the note or its photo.
	bob := a.NewClient()
	mustLogin(t, a, bob, "bob@example.com", testPassword)
	for _, path := range []string{"", "/photo"} {
		if st, _, _ := req(t, bob, http.MethodGet, noteURL+path, nil, nil); st != http.StatusNotFound {
			t.Fatalf("bob GET note%s = %d, want 404", path, st)
		}
	}
	if st, _, _ := req(t, bob, http.MethodDelete, noteURL, nil, nil); st != http.StatusNotFound {
		t.Fatalf("bob DELETE note = %d, want 404", st)
	}
	if len(listNotes(t, a, bob)) != 0 {
		t.Fatal("bob's list must be empty")
	}

	if st, _, _ := req(t, a.Client, http.MethodDelete, noteURL+"/photo", nil, nil); st != http.StatusNoContent {
		t.Fatalf("delete photo = %d, want 204", st)
	}
	if st, _, _ := req(t, a.Client, http.MethodGet, noteURL+"/photo", nil, nil); st != http.StatusNotFound {
		t.Fatalf("photo after delete = %d, want 404", st)
	}

	if st, _, _ := req(t, a.Client, http.MethodDelete, noteURL, nil, nil); st != http.StatusNoContent {
		t.Fatalf("archive = %d, want 204", st)
	}
	if st, _, _ := req(t, a.Client, http.MethodGet, noteURL, nil, nil); st != http.StatusNotFound {
		t.Fatalf("archived note = %d, want 404", st)
	}
	if len(listNotes(t, a, a.Client)) != 0 {
		t.Fatal("archived note still listed")
	}
}

// (The signed-out 401 for every notes route is covered by TestAPIIsPrivateByDefault in guardrails_test.go.)

// covers: getNote, updateNote
func TestNoteGetAndUpdate(t *testing.T) {
	integration(t)
	a := apptest.NewServer(t)
	a.CreateUser(testEmail, testPassword)
	a.CreateUser("bob@example.com", testPassword)
	mustLogin(t, a, a.Client, testEmail, testPassword)
	n := createNote(t, a, a.Client, "first")
	noteURL := a.URL + "/api/notes/" + n.ID

	get := func(c *http.Client) (int, apigen.Note) {
		t.Helper()
		st, _, body := req(t, c, http.MethodGet, noteURL, nil, nil)
		var got apigen.Note
		if st == http.StatusOK {
			if err := json.Unmarshal(body, &got); err != nil {
				t.Fatalf("GET note body %q: %v", body, err)
			}
		}
		return st, got
	}
	patch := func(c *http.Client, p apigen.NotePatch) (int, apigen.Note) {
		t.Helper()
		b, _ := json.Marshal(p)
		st, _, body := req(t, c, http.MethodPatch, noteURL, bytes.NewReader(b), map[string]string{"Content-Type": "application/json"})
		var got apigen.Note
		if st == http.StatusOK {
			if err := json.Unmarshal(body, &got); err != nil {
				t.Fatalf("PATCH note body %q: %v", body, err)
			}
		}
		return st, got
	}
	str := func(s string) *string { return &s }

	if st, got := get(a.Client); st != http.StatusOK || got.ID != n.ID || got.Title != "first" || got.Body != "body of first" {
		t.Fatalf("GET own note = %d %+v", st, got)
	}

	// A title-only patch trims the title and leaves the body alone; the response matches a fresh GET.
	st, patched := patch(a.Client, apigen.NotePatch{Title: str("  renamed  ")})
	if st != http.StatusOK || patched.Title != "renamed" || patched.Body != "body of first" {
		t.Fatalf("title patch = %d %+v", st, patched)
	}
	if _, fresh := get(a.Client); fresh != patched {
		t.Errorf("GET after PATCH = %+v, PATCH returned %+v", fresh, patched)
	}
	// A body-only patch leaves the title alone.
	if st, got := patch(a.Client, apigen.NotePatch{Body: str("new body")}); st != http.StatusOK || got.Title != "renamed" || got.Body != "new body" {
		t.Fatalf("body patch = %d %+v", st, got)
	}

	// Invalid input is a 400 and changes nothing.
	for name, p := range map[string]apigen.NotePatch{
		"blank title":    {Title: str("   ")},
		"empty title":    {Title: str("")},
		"too long title": {Title: str(string(bytes.Repeat([]byte("x"), 201)))},
	} {
		if st, _ := patch(a.Client, p); st != http.StatusBadRequest {
			t.Errorf("%s: PATCH = %d, want 400", name, st)
		}
	}
	if _, got := get(a.Client); got.Title != "renamed" || got.Body != "new body" {
		t.Errorf("rejected patches changed the note: %+v", got)
	}

	// Another user can neither read nor change it.
	bob := a.NewClient()
	mustLogin(t, a, bob, "bob@example.com", testPassword)
	if st, _ := get(bob); st != http.StatusNotFound {
		t.Errorf("bob GET = %d, want 404", st)
	}
	if st, _ := patch(bob, apigen.NotePatch{Title: str("hijacked")}); st != http.StatusNotFound {
		t.Errorf("bob PATCH = %d, want 404", st)
	}
	if _, got := get(a.Client); got.Title != "renamed" {
		t.Errorf("bob's patch changed the note: %+v", got)
	}
}
