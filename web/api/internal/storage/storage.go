// Package storage keeps uploaded files in one flat directory under generated names.
package storage

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"goweb/internal/uid"
)

var (
	ErrTooLarge        = errors.New("storage: file too large")
	ErrUnsupportedType = errors.New("storage: unsupported file type")
	ErrInvalidName     = errors.New("storage: invalid file name")
)

// validName matches only names Save generates (lowercase UUID + known extension).
var validName = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$`)

var extByType = map[string]string{
	"image/jpeg": ".jpg",
	"image/png":  ".png",
	"image/webp": ".webp",
}

// Store is a directory of uploaded files.
type Store struct{ dir string }

// New creates dir (0700) if needed and returns a Store rooted there.
func New(dir string) (*Store, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("storage: create dir: %w", err)
	}
	return &Store{dir: dir}, nil
}

// Save stores at most maxBytes from r and returns the generated bare file name.
// The extension comes from sniffing the content (JPEG, PNG or WebP only).
// On any error no file, temporary or final, remains.
func (s *Store) Save(ctx context.Context, r io.Reader, maxBytes int64) (name string, err error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	r = io.LimitReader(r, maxBytes+1)
	head := make([]byte, 512)
	n, err := io.ReadFull(r, head)
	if err != nil && !errors.Is(err, io.EOF) && !errors.Is(err, io.ErrUnexpectedEOF) {
		return "", fmt.Errorf("storage: read upload: %w", err)
	}
	head = head[:n]
	ext, ok := extByType[http.DetectContentType(head)]
	if !ok {
		return "", ErrUnsupportedType
	}

	tmp, err := os.CreateTemp(s.dir, ".upload-*")
	if err != nil {
		return "", fmt.Errorf("storage: create temp: %w", err)
	}
	defer func() {
		if err != nil {
			tmp.Close()
			os.Remove(tmp.Name())
		}
	}()
	if err = tmp.Chmod(0o600); err != nil {
		return "", fmt.Errorf("storage: chmod temp: %w", err)
	}
	if _, err = tmp.Write(head); err != nil {
		return "", fmt.Errorf("storage: write temp: %w", err)
	}
	rest, err := io.Copy(tmp, &ctxReader{ctx: ctx, r: r})
	if err != nil {
		return "", fmt.Errorf("storage: write temp: %w", err)
	}
	if int64(n)+rest > maxBytes {
		return "", ErrTooLarge
	}
	if err = tmp.Close(); err != nil {
		return "", fmt.Errorf("storage: close temp: %w", err)
	}
	id, err := uid.New()
	if err != nil {
		return "", fmt.Errorf("storage: new id: %w", err)
	}
	name = id + ext
	if err = os.Rename(tmp.Name(), filepath.Join(s.dir, name)); err != nil {
		return "", fmt.Errorf("storage: rename: %w", err)
	}
	return name, nil
}

type ctxReader struct {
	ctx context.Context
	r   io.Reader
}

func (c *ctxReader) Read(p []byte) (int, error) {
	if err := c.ctx.Err(); err != nil {
		return 0, err
	}
	return c.r.Read(p)
}

func (s *Store) path(name string) (string, error) {
	if !validName.MatchString(name) {
		return "", ErrInvalidName
	}
	return filepath.Join(s.dir, name), nil
}

// Open opens a stored file. A missing file returns an error matching os.ErrNotExist.
func (s *Store) Open(name string) (*os.File, error) {
	p, err := s.path(name)
	if err != nil {
		return nil, err
	}
	return os.Open(p)
}

// Delete removes a stored file; a missing file is not an error.
func (s *Store) Delete(name string) error {
	p, err := s.path(name)
	if err != nil {
		return err
	}
	if err := os.Remove(p); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("storage: delete: %w", err)
	}
	return nil
}

// SweepTemp removes leftover upload temp files (".upload-*", from a crash or
// kill in the middle of Save) whose modification time is older than maxAge. It
// looks only directly inside the storage directory: it never recurses, never
// follows symlinks and never touches any other name. A missing directory is not
// an error. It returns how many files it removed.
func (s *Store) SweepTemp(maxAge time.Duration) (int, error) {
	entries, err := os.ReadDir(s.dir)
	if errors.Is(err, os.ErrNotExist) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("storage: sweep: %w", err)
	}
	cutoff := time.Now().Add(-maxAge)
	n := 0
	for _, e := range entries {
		if !strings.HasPrefix(e.Name(), ".upload-") || !e.Type().IsRegular() {
			continue
		}
		p := filepath.Join(s.dir, e.Name())
		fi, err := os.Lstat(p)
		if err != nil || !fi.Mode().IsRegular() || !fi.ModTime().Before(cutoff) {
			continue
		}
		if err := os.Remove(p); err != nil && !errors.Is(err, os.ErrNotExist) {
			return n, fmt.Errorf("storage: sweep: %w", err)
		}
		n++
	}
	return n, nil
}
