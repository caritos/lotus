package tests

import (
	"bytes"
	"net/http"
	"testing"

	"goweb/internal/apptest"
)

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

func TestUnauthenticatedAPIRefused(t *testing.T) {
	integration(t)
	a := apptest.NewServer(t)
	const id = "00000000-0000-4000-8000-000000000000"
	for _, rt := range []struct{ method, path string }{
		{"GET", "/api/notes"}, {"POST", "/api/notes"},
		{"GET", "/api/notes/" + id}, {"PATCH", "/api/notes/" + id}, {"DELETE", "/api/notes/" + id},
		{"PUT", "/api/notes/" + id + "/photo"}, {"GET", "/api/notes/" + id + "/photo"}, {"DELETE", "/api/notes/" + id + "/photo"},
	} {
		if st, _, _ := req(t, a.Client, rt.method, a.URL+rt.path, nil, nil); st != http.StatusUnauthorized {
			t.Errorf("%s %s = %d, want 401", rt.method, rt.path, st)
		}
	}
}
