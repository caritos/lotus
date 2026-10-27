package auth

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"goweb/internal/config"
	"goweb/internal/uid"
)

var (
	ErrBadCredentials  = errors.New("auth: invalid email or password")
	ErrThrottled       = errors.New("auth: too many failed logins")
	ErrEmailTaken      = errors.New("auth: email already registered")
	ErrInvalidEmail    = errors.New("auth: invalid email")
	ErrWeakPassword    = errors.New("auth: password must be 8 to 72 bytes")
	ErrUnauthenticated = errors.New("auth: not signed in")
)

// ThrottleError is returned (matching ErrThrottled) when login is rate limited.
type ThrottleError struct{ RetryAfter time.Duration }

func (e *ThrottleError) Error() string   { return ErrThrottled.Error() }
func (e *ThrottleError) Is(t error) bool { return t == ErrThrottled }

// User is an authenticated account.
type User struct {
	ID    string
	Email string
}

const (
	maxEmailBytes = 254
	// oversizedEmailKey is the fixed throttle key for emails too long to track.
	oversizedEmailKey = "(oversized)"
)

// devSessionKey is a DEVELOPMENT-ONLY HMAC key used when SESSION_SECRET is
// empty. Config refuses an empty secret in production, so it is never used there.
const devSessionKey = "goweb-development-only-session-key-do-not-use-in-production"

// Service owns users and sessions.
type Service struct {
	db       *sql.DB
	cfg      config.Config
	now      func() time.Time
	key      []byte
	throttle *throttle

	dummyOnce sync.Once
	dummyHash string
}

// NewService returns a Service; now is time.Now in production.
func NewService(d *sql.DB, cfg config.Config, now func() time.Time) *Service {
	key := cfg.SessionSecret
	if key == "" {
		key = devSessionKey
	}
	return &Service{db: d, cfg: cfg, now: now, key: []byte(key), throttle: newThrottle(now)}
}

func normalizeEmail(e string) string { return strings.ToLower(strings.TrimSpace(e)) }

func (s *Service) tokenHash(token string) string {
	m := hmac.New(sha256.New, s.key)
	m.Write([]byte(token))
	return hex.EncodeToString(m.Sum(nil))
}

// CreateUser registers an account. Email is trimmed and lowercased.
func (s *Service) CreateUser(ctx context.Context, email, password string) (User, error) {
	email = normalizeEmail(email)
	if email == "" || !strings.Contains(email, "@") {
		return User{}, ErrInvalidEmail
	}
	if len(password) < 8 || len(password) > maxPasswordBytes {
		return User{}, ErrWeakPassword
	}
	hash, err := HashPassword(password)
	if err != nil {
		return User{}, fmt.Errorf("auth: hash password: %w", err)
	}
	id, err := uid.New()
	if err != nil {
		return User{}, fmt.Errorf("auth: new id: %w", err)
	}
	_, err = s.db.ExecContext(ctx,
		`INSERT INTO users (id, email, password_hash, created_at) VALUES (?, ?, ?, ?)`,
		id, email, hash, s.now().UnixMilli())
	if err != nil {
		if strings.Contains(err.Error(), "UNIQUE constraint failed") {
			return User{}, ErrEmailTaken
		}
		return User{}, fmt.Errorf("auth: insert user: %w", err)
	}
	return User{ID: id, Email: email}, nil
}

// dummy returns a bcrypt hash to compare against for unknown users, so the
// unknown-user path costs about the same as a wrong password.
func (s *Service) dummy() string {
	s.dummyOnce.Do(func() { s.dummyHash, _ = HashPassword("dummy-password-for-timing") })
	return s.dummyHash
}

// Login verifies credentials and starts a session, returning the raw cookie token.
func (s *Service) Login(ctx context.Context, email, password, ip string) (string, User, error) {
	email = normalizeEmail(email)
	// An oversized email must never become a throttle map key.
	oversized := len(email) > maxEmailBytes
	key := email
	if oversized {
		key = oversizedEmailKey
	}
	// Record the attempt before the slow bcrypt compare so parallel requests
	// cannot all slip past the limit; success gives it back below.
	if wait, ok := s.throttle.attempt(key, ip); !ok {
		return "", User{}, &ThrottleError{RetryAfter: wait}
	}
	if oversized || len(password) > maxPasswordBytes {
		CheckPassword(s.dummy(), password)
		return "", User{}, ErrBadCredentials
	}
	var u User
	var hash string
	err := s.db.QueryRowContext(ctx,
		`SELECT id, email, password_hash FROM users WHERE email = ? AND archived_at IS NULL`, email).
		Scan(&u.ID, &u.Email, &hash)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		CheckPassword(s.dummy(), password)
		return "", User{}, ErrBadCredentials
	case err != nil:
		return "", User{}, fmt.Errorf("auth: look up user: %w", err)
	}
	if !CheckPassword(hash, password) {
		return "", User{}, ErrBadCredentials
	}
	var raw [32]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", User{}, fmt.Errorf("auth: token: %w", err)
	}
	token := base64.RawURLEncoding.EncodeToString(raw[:])
	id, err := uid.New()
	if err != nil {
		return "", User{}, fmt.Errorf("auth: new id: %w", err)
	}
	now := s.now()
	_, err = s.db.ExecContext(ctx,
		`INSERT INTO sessions (id, user_id, token_hash, created_at, expires_at) VALUES (?, ?, ?, ?, ?)`,
		id, u.ID, s.tokenHash(token), now.UnixMilli(), now.Add(s.cfg.SessionTTL).UnixMilli())
	if err != nil {
		return "", User{}, fmt.Errorf("auth: insert session: %w", err)
	}
	s.throttle.success(key, ip)
	return token, u, nil
}

// Logout deletes the session for token; unknown tokens are not an error.
func (s *Service) Logout(ctx context.Context, token string) error {
	_, err := s.db.ExecContext(ctx, `DELETE FROM sessions WHERE token_hash = ?`, s.tokenHash(token))
	if err != nil {
		return fmt.Errorf("auth: delete session: %w", err)
	}
	return nil
}

// UserFor resolves a session token. Expired sessions are deleted and rejected.
func (s *Service) UserFor(ctx context.Context, token string) (User, error) {
	if token == "" {
		return User{}, ErrUnauthenticated
	}
	hash := s.tokenHash(token)
	var u User
	var expires int64
	err := s.db.QueryRowContext(ctx,
		`SELECT u.id, u.email, s.expires_at FROM sessions s JOIN users u ON u.id = s.user_id
		 WHERE s.token_hash = ? AND u.archived_at IS NULL`, hash).Scan(&u.ID, &u.Email, &expires)
	if errors.Is(err, sql.ErrNoRows) {
		return User{}, ErrUnauthenticated
	}
	if err != nil {
		return User{}, fmt.Errorf("auth: look up session: %w", err)
	}
	if expires <= s.now().UnixMilli() {
		if _, err := s.db.ExecContext(ctx, `DELETE FROM sessions WHERE token_hash = ?`, hash); err != nil {
			return User{}, fmt.Errorf("auth: delete expired session: %w", err)
		}
		return User{}, ErrUnauthenticated
	}
	return u, nil
}

// PurgeExpired deletes every expired session and returns how many.
func (s *Service) PurgeExpired(ctx context.Context) (int64, error) {
	res, err := s.db.ExecContext(ctx, `DELETE FROM sessions WHERE expires_at <= ?`, s.now().UnixMilli())
	if err != nil {
		return 0, fmt.Errorf("auth: purge sessions: %w", err)
	}
	return res.RowsAffected()
}
