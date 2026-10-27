// Package notes stores each user's notes and serves them over the JSON API.
package notes

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"goweb/internal/uid"
)

// ErrNotFound means the note does not exist, is archived, or belongs to someone else.
var ErrNotFound = errors.New("notes: not found")

// Note is a stored note. Photo is the bare storage file name, "" when none.
type Note struct {
	ID        string
	Title     string
	Body      string
	Photo     string
	CreatedAt int64
	UpdatedAt int64
}

// Store reads and writes notes; every method is scoped to one user.
type Store struct {
	db  *sql.DB
	now func() time.Time
}

// NewStore returns a Store using time.Now.
func NewStore(d *sql.DB) *Store { return &Store{db: d, now: time.Now} }

const cols = `id, title, body, COALESCE(photo, ''), created_at, updated_at`

type scanner interface{ Scan(...any) error }

func scan(r scanner) (Note, error) {
	var n Note
	err := r.Scan(&n.ID, &n.Title, &n.Body, &n.Photo, &n.CreatedAt, &n.UpdatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return Note{}, ErrNotFound
	}
	return n, err
}

// Create inserts a note for userID.
func (s *Store) Create(ctx context.Context, userID, title, body string) (Note, error) {
	id, err := uid.New()
	if err != nil {
		return Note{}, fmt.Errorf("notes: new id: %w", err)
	}
	ms := s.now().UnixMilli()
	if _, err := s.db.ExecContext(ctx,
		`INSERT INTO notes (id, user_id, title, body, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)`,
		id, userID, title, body, ms, ms); err != nil {
		return Note{}, fmt.Errorf("notes: create: %w", err)
	}
	return Note{ID: id, Title: title, Body: body, CreatedAt: ms, UpdatedAt: ms}, nil
}

// List returns userID's live notes, most recently updated first.
func (s *Store) List(ctx context.Context, userID string) ([]Note, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT `+cols+` FROM notes WHERE user_id = ? AND archived_at IS NULL ORDER BY updated_at DESC, id`, userID)
	if err != nil {
		return nil, fmt.Errorf("notes: list: %w", err)
	}
	defer rows.Close()
	out := []Note{}
	for rows.Next() {
		n, err := scan(rows)
		if err != nil {
			return nil, fmt.Errorf("notes: list: %w", err)
		}
		out = append(out, n)
	}
	return out, rows.Err()
}

// Get returns one live note owned by userID, or ErrNotFound.
func (s *Store) Get(ctx context.Context, userID, id string) (Note, error) {
	n, err := scan(s.db.QueryRowContext(ctx,
		`SELECT `+cols+` FROM notes WHERE id = ? AND user_id = ? AND archived_at IS NULL`, id, userID))
	if err != nil && !errors.Is(err, ErrNotFound) {
		return Note{}, fmt.Errorf("notes: get: %w", err)
	}
	return n, err
}

// Update changes only the non-nil fields and bumps updated_at.
func (s *Store) Update(ctx context.Context, userID, id string, title, body *string) (Note, error) {
	n, err := scan(s.db.QueryRowContext(ctx,
		`UPDATE notes SET title = COALESCE(?, title), body = COALESCE(?, body), updated_at = ?
		 WHERE id = ? AND user_id = ? AND archived_at IS NULL RETURNING `+cols,
		title, body, s.now().UnixMilli(), id, userID))
	if err != nil && !errors.Is(err, ErrNotFound) {
		return Note{}, fmt.Errorf("notes: update: %w", err)
	}
	return n, err
}

// Archive soft-deletes a note. Its photo file is kept.
func (s *Store) Archive(ctx context.Context, userID, id string) error {
	ms := s.now().UnixMilli()
	res, err := s.db.ExecContext(ctx,
		`UPDATE notes SET archived_at = ?, updated_at = ? WHERE id = ? AND user_id = ? AND archived_at IS NULL`,
		ms, ms, id, userID)
	if err != nil {
		return fmt.Errorf("notes: archive: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

// SetPhoto stores the bare photo file name ("" clears it) and returns the
// updated note plus the previous file name so the caller can delete it.
func (s *Store) SetPhoto(ctx context.Context, userID, id, name string) (n, prev Note, err error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return n, prev, fmt.Errorf("notes: set photo: %w", err)
	}
	defer tx.Rollback()
	prev, err = scan(tx.QueryRowContext(ctx,
		`SELECT `+cols+` FROM notes WHERE id = ? AND user_id = ? AND archived_at IS NULL`, id, userID))
	if err != nil {
		if !errors.Is(err, ErrNotFound) {
			err = fmt.Errorf("notes: set photo: %w", err)
		}
		return n, prev, err
	}
	var v any
	if name != "" {
		v = name
	}
	n, err = scan(tx.QueryRowContext(ctx,
		`UPDATE notes SET photo = ?, updated_at = ? WHERE id = ? AND user_id = ? RETURNING `+cols,
		v, s.now().UnixMilli(), id, userID))
	if err != nil {
		return n, prev, fmt.Errorf("notes: set photo: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return n, prev, fmt.Errorf("notes: set photo: %w", err)
	}
	return n, prev, nil
}
