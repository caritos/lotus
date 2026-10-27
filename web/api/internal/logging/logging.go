// Package logging provides a size-rotated JSON file logger.
package logging

import (
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"sync"
)

// New returns a JSON slog logger writing to <dataDir>/logs/app.log, rotating
// when a write would exceed maxBytes and keeping keep old generations
// (app.log.1 is the newest). The returned Closer closes the file.
func New(dataDir string, maxBytes int64, keep int) (*slog.Logger, io.Closer, error) {
	if maxBytes <= 0 || keep < 1 {
		return nil, nil, fmt.Errorf("logging: maxBytes must be positive and keep >= 1")
	}
	dir := filepath.Join(dataDir, "logs")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, nil, fmt.Errorf("logging: %w", err)
	}
	w := &rotatingWriter{path: filepath.Join(dir, "app.log"), max: maxBytes, keep: keep}
	if err := w.open(); err != nil {
		return nil, nil, err
	}
	return slog.New(slog.NewJSONHandler(w, nil)), w, nil
}

type rotatingWriter struct {
	mu   sync.Mutex
	path string
	max  int64
	keep int
	f    *os.File
	size int64
}

func (w *rotatingWriter) open() error {
	f, err := os.OpenFile(w.path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return fmt.Errorf("logging: %w", err)
	}
	st, err := f.Stat()
	if err != nil {
		_ = f.Close()
		return fmt.Errorf("logging: %w", err)
	}
	w.f, w.size = f, st.Size()
	return nil
}

func (w *rotatingWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.f == nil {
		return 0, os.ErrClosed
	}
	if w.size > 0 && w.size+int64(len(p)) > w.max {
		if err := w.rotate(); err != nil {
			return 0, err
		}
	}
	n, err := w.f.Write(p)
	w.size += int64(n)
	return n, err
}

func (w *rotatingWriter) rotate() error {
	if err := w.f.Close(); err != nil {
		return err
	}
	w.f = nil
	_ = os.Remove(fmt.Sprintf("%s.%d", w.path, w.keep))
	for i := w.keep - 1; i >= 1; i-- {
		if err := os.Rename(fmt.Sprintf("%s.%d", w.path, i), fmt.Sprintf("%s.%d", w.path, i+1)); err != nil && !os.IsNotExist(err) {
			return err
		}
	}
	if err := os.Rename(w.path, w.path+".1"); err != nil {
		return err
	}
	return w.open()
}

// Close closes the log file.
func (w *rotatingWriter) Close() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.f == nil {
		return nil
	}
	err := w.f.Close()
	w.f = nil
	return err
}
