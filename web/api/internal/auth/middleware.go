package auth

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
)

const cookieName = "goweb_session"

type ctxKey int

const (
	userKey ctxKey = iota
	ipKeyCtx
)

// WithClientIP records the client IP (set by a trusted-proxy middleware).
func WithClientIP(ctx context.Context, ip string) context.Context {
	return context.WithValue(ctx, ipKeyCtx, ip)
}

// ClientIPFromContext returns the IP set by WithClientIP, or "".
func ClientIPFromContext(ctx context.Context) string {
	ip, _ := ctx.Value(ipKeyCtx).(string)
	return ip
}

// FromContext returns the signed-in user, if any.
func FromContext(ctx context.Context) (User, bool) {
	u, ok := ctx.Value(userKey).(User)
	return u, ok
}

// Middleware loads the session user into the request context. Anonymous
// requests pass through without a user; use Require to reject them.
func Middleware(s *Service) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if c, err := r.Cookie(cookieName); err == nil {
				u, err := s.UserFor(r.Context(), c.Value)
				switch {
				case err == nil:
					r = r.WithContext(context.WithValue(r.Context(), userKey, u))
				case !errors.Is(err, ErrUnauthenticated):
					slog.Error("session lookup failed", "err", err)
					writeJSON(w, http.StatusInternalServerError, errorBody{"internal error"})
					return
				}
			}
			next.ServeHTTP(w, r)
		})
	}
}

// Require responds 401 JSON unless Middleware found a user.
func Require(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if _, ok := FromContext(r.Context()); !ok {
			writeJSON(w, http.StatusUnauthorized, errorBody{"unauthorized"})
			return
		}
		next.ServeHTTP(w, r)
	})
}
