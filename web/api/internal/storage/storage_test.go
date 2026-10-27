package storage

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

var (
	pngBytes  = append([]byte("\x89PNG\r\n\x1a\n"), make([]byte, 32)...)
	jpegBytes = append([]byte{0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 'J', 'F', 'I', 'F', 0}, make([]byte, 32)...)
	webpBytes = append([]byte("RIFF\x24\x00\x00\x00WEBPVP8 "), make([]byte, 32)...)
)

func newStore(t *testing.T) (*Store, string) {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "storage")
	s, err := New(dir)
	if err != nil {
		t.Fatal(err)
	}
	return s, dir
}

func entries(t *testing.T, dir string) []string {
	t.Helper()
	es, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, e := range es {
		names = append(names, e.Name())
	}
	return names
}

func TestNewCreatesDir0700(t *testing.T) {
	_, dir := newStore(t)
	fi, err := os.Stat(dir)
	if err != nil || !fi.IsDir() || fi.Mode().Perm() != 0o700 {
		t.Fatalf("stat = %v, %v", fi, err)
	}
}

func TestSaveSniffsContentNotExtension(t *testing.T) {
	s, dir := newStore(t)
	// The handler may have seen the client name "a.exe"; Save only sees bytes.
	for _, tc := range []struct {
		data []byte
		ext  string
	}{{pngBytes, ".png"}, {jpegBytes, ".jpg"}, {webpBytes, ".webp"}} {
		name, err := s.Save(context.Background(), bytes.NewReader(tc.data), 1<<20)
		if err != nil {
			t.Fatal(err)
		}
		if !strings.HasSuffix(name, tc.ext) || !validName.MatchString(name) {
			t.Fatalf("name = %q, want ext %s", name, tc.ext)
		}
		got, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil || !bytes.Equal(got, tc.data) {
			t.Fatalf("content mismatch: %v", err)
		}
		fi, _ := os.Stat(filepath.Join(dir, name))
		if fi.Mode().Perm() != 0o600 {
			t.Errorf("perm = %v", fi.Mode().Perm())
		}
	}
}

func TestSaveRejectsText415(t *testing.T) {
	s, dir := newStore(t)
	_, err := s.Save(context.Background(), strings.NewReader("hello, I am not a jpeg"), 1<<20)
	if !errors.Is(err, ErrUnsupportedType) {
		t.Fatalf("err = %v", err)
	}
	if n := entries(t, dir); len(n) != 0 {
		t.Fatalf("leftover files: %v", n)
	}
}

func TestSaveRejectsOver5MiB413AndLeavesNoFile(t *testing.T) {
	s, dir := newStore(t)
	max := int64(5 << 20)
	big := append(append([]byte{}, pngBytes...), make([]byte, max)...) // > max
	_, err := s.Save(context.Background(), bytes.NewReader(big), max)
	if !errors.Is(err, ErrTooLarge) {
		t.Fatalf("err = %v", err)
	}
	if n := entries(t, dir); len(n) != 0 {
		t.Fatalf("leftover files: %v", n)
	}
}

func TestSaveExactlyMaxIsAccepted(t *testing.T) {
	s, _ := newStore(t)
	data := append(append([]byte{}, pngBytes...), make([]byte, 1000-len(pngBytes))...)
	if _, err := s.Save(context.Background(), bytes.NewReader(data), 1000); err != nil {
		t.Fatal(err)
	}
}

func TestSaveEmptyIsUnsupported(t *testing.T) {
	s, dir := newStore(t)
	if _, err := s.Save(context.Background(), bytes.NewReader(nil), 100); !errors.Is(err, ErrUnsupportedType) {
		t.Fatalf("err = %v", err)
	}
	if n := entries(t, dir); len(n) != 0 {
		t.Fatalf("leftover: %v", n)
	}
}

type errReader struct{}

func (errReader) Read([]byte) (int, error) { return 0, errors.New("boom") }

func TestSaveReadErrorLeavesNoFile(t *testing.T) {
	s, dir := newStore(t)
	r := &concatReader{first: pngBytes, then: errReader{}}
	if _, err := s.Save(context.Background(), r, 1<<20); err == nil {
		t.Fatal("want error")
	}
	if n := entries(t, dir); len(n) != 0 {
		t.Fatalf("leftover: %v", n)
	}
}

type concatReader struct {
	first []byte
	then  errReader
}

func (c *concatReader) Read(p []byte) (int, error) {
	if len(c.first) > 0 {
		n := copy(p, c.first)
		c.first = c.first[n:]
		return n, nil
	}
	return c.then.Read(p)
}

func TestSaveCanceledContext(t *testing.T) {
	s, dir := newStore(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := s.Save(ctx, bytes.NewReader(pngBytes), 1<<20); err == nil {
		t.Fatal("want error")
	}
	if n := entries(t, dir); len(n) != 0 {
		t.Fatalf("leftover: %v", n)
	}
}

func TestOpenRejectsTraversal(t *testing.T) {
	s, dir := newStore(t)
	// A real file outside the store that traversal would reach.
	outside := filepath.Join(filepath.Dir(dir), "x")
	_ = os.WriteFile(outside, []byte("secret"), 0o600)
	good := "0123abcd-0123-4abc-8def-0123456789ab"
	for _, n := range []string{
		"../x", "/etc/passwd", "a/b", "..%2f", "a\x00.png", "", "..", ".",
		good + ".PNG", good + ".gif", good, "0123ABCD-0123-4abc-8def-0123456789ab.png",
		"../" + good + ".png", good + ".png/", good + ".png\n", "x" + good + ".png",
	} {
		if f, err := s.Open(n); !errors.Is(err, ErrInvalidName) {
			if f != nil {
				f.Close()
			}
			t.Errorf("Open(%q) err = %v", n, err)
		}
		if err := s.Delete(n); !errors.Is(err, ErrInvalidName) {
			t.Errorf("Delete(%q) err = %v", n, err)
		}
	}
	if _, err := os.Stat(outside); err != nil {
		t.Fatal("outside file touched")
	}
}

func TestOpenAndDelete(t *testing.T) {
	s, dir := newStore(t)
	name, err := s.Save(context.Background(), bytes.NewReader(pngBytes), 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	f, err := s.Open(name)
	if err != nil {
		t.Fatal(err)
	}
	f.Close()
	if err := s.Delete(name); err != nil {
		t.Fatal(err)
	}
	if len(entries(t, dir)) != 0 {
		t.Fatal("file not removed")
	}
	if err := s.Delete(name); err != nil {
		t.Fatalf("deleting missing file: %v", err)
	}
	if _, err := s.Open(name); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("Open missing err = %v", err)
	}
}
