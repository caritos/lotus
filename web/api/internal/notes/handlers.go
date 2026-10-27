package notes

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"mime/multipart"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"

	"goweb/internal/apigen"
	"goweb/internal/auth"
	"goweb/internal/storage"
)

const (
	maxJSONBytes  = 64 << 10
	maxPhotoBytes = 5 << 20
	maxUploadBody = maxPhotoBytes + 64<<10 // photo plus multipart overhead
	maxTitleRunes = 200
	maxBodyBytes  = 20000
)

var idRe = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

type api struct {
	s  *Store
	st *storage.Store
}

// Handlers serves /api/notes. Mount it behind auth.Middleware and auth.Require;
// a request without a user is answered 401 as a safeguard.
func Handlers(s *Store, st *storage.Store) http.Handler {
	a := &api{s: s, st: st}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/notes", a.guard(a.list))
	mux.HandleFunc("POST /api/notes", a.guard(a.create))
	mux.HandleFunc("GET /api/notes/{id}", a.guard(a.get))
	mux.HandleFunc("PATCH /api/notes/{id}", a.guard(a.patch))
	mux.HandleFunc("DELETE /api/notes/{id}", a.guard(a.archive))
	mux.HandleFunc("PUT /api/notes/{id}/photo", a.guard(a.putPhoto))
	mux.HandleFunc("GET /api/notes/{id}/photo", a.guard(a.getPhoto))
	mux.HandleFunc("DELETE /api/notes/{id}/photo", a.guard(a.deletePhoto))
	return mux
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func fail(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, apigen.Error{Error: msg})
}

func serverError(w http.ResponseWriter, err error) {
	slog.Error("notes request failed", "err", err)
	fail(w, http.StatusInternalServerError, "internal error")
}

func toAPI(n Note) apigen.Note {
	return apigen.Note{ID: n.ID, Title: n.Title, Body: n.Body, Photo: n.Photo != "", CreatedAt: n.CreatedAt, UpdatedAt: n.UpdatedAt}
}

type handler func(w http.ResponseWriter, r *http.Request, userID, id string)

// guard resolves the user and validates the {id} path value (404 when malformed).
func (a *api) guard(h handler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		u, ok := auth.FromContext(r.Context())
		if !ok {
			fail(w, http.StatusUnauthorized, "unauthorized")
			return
		}
		id := r.PathValue("id")
		if strings.Contains(r.Pattern, "{id}") && !idRe.MatchString(id) {
			fail(w, http.StatusNotFound, "not found")
			return
		}
		h(w, r, u.ID, id)
	}
}

// storeErr maps a store error to a response.
func storeErr(w http.ResponseWriter, err error) {
	if errors.Is(err, ErrNotFound) {
		fail(w, http.StatusNotFound, "not found")
		return
	}
	serverError(w, err)
}

// decode reads one JSON object of at most 64 KiB, rejecting unknown fields and
// trailing data. It writes the error response and returns false on failure.
func decode(w http.ResponseWriter, r *http.Request, v any) bool {
	body := http.MaxBytesReader(w, r.Body, maxJSONBytes)
	dec := json.NewDecoder(body)
	dec.DisallowUnknownFields()
	err := dec.Decode(v)
	if err == nil {
		if _, err2 := dec.Token(); err2 != io.EOF {
			err = errors.New("trailing data")
		}
	}
	if err != nil {
		var mbe *http.MaxBytesError
		if errors.As(err, &mbe) {
			fail(w, http.StatusRequestEntityTooLarge, "request body too large")
		} else {
			fail(w, http.StatusBadRequest, "invalid request")
		}
		return false
	}
	return true
}

func validTitle(t string) (string, string) {
	t = strings.TrimSpace(t)
	if n := utf8.RuneCountInString(t); n < 1 || n > maxTitleRunes {
		return "", "title must be 1 to 200 characters"
	}
	return t, ""
}

func validBody(b string) string {
	if len(b) > maxBodyBytes {
		return "body must be at most 20000 bytes"
	}
	return ""
}

func (a *api) list(w http.ResponseWriter, r *http.Request, uid, _ string) {
	ns, err := a.s.List(r.Context(), uid)
	if err != nil {
		serverError(w, err)
		return
	}
	out := make([]apigen.Note, 0, len(ns))
	for _, n := range ns {
		out = append(out, toAPI(n))
	}
	writeJSON(w, http.StatusOK, out)
}

func (a *api) create(w http.ResponseWriter, r *http.Request, uid, _ string) {
	var in apigen.NoteInput
	if !decode(w, r, &in) {
		return
	}
	title, msg := validTitle(in.Title)
	if msg == "" {
		msg = validBody(in.Body)
	}
	if msg != "" {
		fail(w, http.StatusBadRequest, msg)
		return
	}
	n, err := a.s.Create(r.Context(), uid, title, in.Body)
	if err != nil {
		serverError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, toAPI(n))
}

func (a *api) get(w http.ResponseWriter, r *http.Request, uid, id string) {
	n, err := a.s.Get(r.Context(), uid, id)
	if err != nil {
		storeErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, toAPI(n))
}

func (a *api) patch(w http.ResponseWriter, r *http.Request, uid, id string) {
	var in apigen.NotePatch
	if !decode(w, r, &in) {
		return
	}
	var msg string
	if in.Title != nil {
		var t string
		t, msg = validTitle(*in.Title)
		in.Title = &t
	}
	if msg == "" && in.Body != nil {
		msg = validBody(*in.Body)
	}
	if msg != "" {
		fail(w, http.StatusBadRequest, msg)
		return
	}
	n, err := a.s.Update(r.Context(), uid, id, in.Title, in.Body)
	if err != nil {
		storeErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, toAPI(n))
}

func (a *api) archive(w http.ResponseWriter, r *http.Request, uid, id string) {
	if err := a.s.Archive(r.Context(), uid, id); err != nil {
		storeErr(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *api) putPhoto(w http.ResponseWriter, r *http.Request, uid, id string) {
	ctx := r.Context()
	if _, err := a.s.Get(ctx, uid, id); err != nil {
		storeErr(w, err)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxUploadBody)
	mr, err := r.MultipartReader()
	if err != nil {
		fail(w, http.StatusBadRequest, "expected multipart/form-data")
		return
	}
	name, ok := a.savePart(w, ctx, mr)
	if !ok {
		return
	}
	n, prev, err := a.s.SetPhoto(ctx, uid, id, name)
	if err != nil {
		a.removeFile(name)
		storeErr(w, err)
		return
	}
	a.removeFile(prev.Photo)
	writeJSON(w, http.StatusOK, toAPI(n))
}

// savePart stores the first multipart part named "photo"; on failure it writes
// the response and returns false.
func (a *api) savePart(w http.ResponseWriter, ctx context.Context, mr *multipart.Reader) (string, bool) {
	for {
		part, err := mr.NextPart()
		if err != nil {
			if isTooLarge(err) {
				fail(w, http.StatusRequestEntityTooLarge, "photo too large (max 5 MiB)")
			} else {
				fail(w, http.StatusBadRequest, "missing photo part")
			}
			return "", false
		}
		if part.FormName() != "photo" {
			continue
		}
		name, err := a.st.Save(ctx, part, maxPhotoBytes)
		switch {
		case err == nil:
			return name, true
		case errors.Is(err, storage.ErrTooLarge), isTooLarge(err):
			fail(w, http.StatusRequestEntityTooLarge, "photo too large (max 5 MiB)")
		case errors.Is(err, storage.ErrUnsupportedType):
			fail(w, http.StatusUnsupportedMediaType, "photo must be a JPEG, PNG or WebP image")
		case errors.Is(err, io.ErrUnexpectedEOF), errors.Is(err, multipart.ErrMessageTooLarge):
			fail(w, http.StatusBadRequest, "malformed upload")
		default:
			serverError(w, err)
		}
		return "", false
	}
}

func isTooLarge(err error) bool {
	var mbe *http.MaxBytesError
	return errors.As(err, &mbe)
}

func (a *api) removeFile(name string) {
	if name == "" {
		return
	}
	if err := a.st.Delete(name); err != nil {
		slog.Error("delete photo file", "err", err)
	}
}

var photoTypes = map[string]string{".jpg": "image/jpeg", ".png": "image/png", ".webp": "image/webp"}

func (a *api) getPhoto(w http.ResponseWriter, r *http.Request, uid, id string) {
	n, err := a.s.Get(r.Context(), uid, id)
	if err != nil {
		storeErr(w, err)
		return
	}
	if n.Photo == "" {
		fail(w, http.StatusNotFound, "not found")
		return
	}
	f, err := a.st.Open(n.Photo)
	if err != nil {
		switch {
		case errors.Is(err, os.ErrNotExist):
			fail(w, http.StatusNotFound, "not found")
		case errors.Is(err, storage.ErrInvalidName):
			// The row names something Save could never have written: a data
			// problem worth a warning, but to the client the photo just isn't there.
			slog.Warn("note photo has an invalid stored name", "note", id)
			fail(w, http.StatusNotFound, "not found")
		default:
			// Permissions, I/O and the like: a server fault, not a missing photo.
			// Log the cause without the file name or path.
			slog.Error("open note photo", "note", id, "err", pathless(err))
			fail(w, http.StatusInternalServerError, "internal error")
		}
		return
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		serverError(w, err)
		return
	}
	ct := photoTypes[n.Photo[strings.LastIndexByte(n.Photo, '.'):]]
	if ct == "" {
		serverError(w, errors.New("unknown photo extension"))
		return
	}
	h := w.Header()
	h.Set("Content-Type", ct)
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Cache-Control", "private, no-cache")
	h.Set("Content-Length", strconv.FormatInt(fi.Size(), 10))
	w.WriteHeader(http.StatusOK)
	_, _ = io.Copy(w, f)
}

// pathless drops the path from an *os.PathError so logs never carry file names.
func pathless(err error) error {
	var pe *os.PathError
	if errors.As(err, &pe) {
		return fmt.Errorf("%s: %w", pe.Op, pe.Err)
	}
	return err
}

func (a *api) deletePhoto(w http.ResponseWriter, r *http.Request, uid, id string) {
	_, prev, err := a.s.SetPhoto(r.Context(), uid, id, "")
	if err != nil {
		storeErr(w, err)
		return
	}
	a.removeFile(prev.Photo)
	w.WriteHeader(http.StatusNoContent)
}
