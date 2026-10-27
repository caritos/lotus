package auth

import (
	"encoding/json"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"strconv"
	"time"
)

// Small explicit wire types; a later task replaces them with generated models.
type (
	loginRequest struct {
		Email    string `json:"email"`
		Password string `json:"password"`
	}
	userBody struct {
		ID    string `json:"id"`
		Email string `json:"email"`
	}
	errorBody struct {
		Error string `json:"error"`
	}
)

const maxBodyBytes = 1 << 14

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// Handlers serves POST /api/login, POST /api/logout and GET /api/me.
// Wrap it in Middleware so /api/me can see the session.
func Handlers(s *Service) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/login", s.login)
	mux.HandleFunc("POST /api/logout", s.logout)
	mux.Handle("GET /api/me", Require(http.HandlerFunc(me)))
	return mux
}

func (s *Service) sessionCookie(value string, maxAge int) *http.Cookie {
	return &http.Cookie{
		Name:     cookieName,
		Value:    value,
		Path:     "/",
		MaxAge:   maxAge,
		HttpOnly: true,
		Secure:   s.cfg.SecureCookies,
		SameSite: http.SameSiteLaxMode,
	}
}

func clientIP(r *http.Request) string {
	if ip := ClientIPFromContext(r.Context()); ip != "" {
		return ip
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

func (s *Service) login(w http.ResponseWriter, r *http.Request) {
	var req loginRequest
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBodyBytes))
	if err := dec.Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorBody{"invalid request"})
		return
	}
	token, u, err := s.Login(r.Context(), req.Email, req.Password, clientIP(r))
	var te *ThrottleError
	switch {
	case errors.As(err, &te):
		secs := int((te.RetryAfter + time.Second - 1) / time.Second)
		w.Header().Set("Retry-After", strconv.Itoa(max(secs, 1)))
		writeJSON(w, http.StatusTooManyRequests, errorBody{"too many attempts, try again later"})
	case errors.Is(err, ErrBadCredentials):
		writeJSON(w, http.StatusUnauthorized, errorBody{"invalid email or password"})
	case err != nil:
		slog.Error("login failed", "err", err)
		writeJSON(w, http.StatusInternalServerError, errorBody{"internal error"})
	default:
		http.SetCookie(w, s.sessionCookie(token, int(s.cfg.SessionTTL/time.Second)))
		writeJSON(w, http.StatusOK, userBody{ID: u.ID, Email: u.Email})
	}
}

func (s *Service) logout(w http.ResponseWriter, r *http.Request) {
	if c, err := r.Cookie(cookieName); err == nil {
		if err := s.Logout(r.Context(), c.Value); err != nil {
			slog.Error("logout failed", "err", err)
		}
	}
	http.SetCookie(w, s.sessionCookie("", -1))
	w.WriteHeader(http.StatusNoContent)
}

func me(w http.ResponseWriter, r *http.Request) {
	u, _ := FromContext(r.Context())
	writeJSON(w, http.StatusOK, userBody{ID: u.ID, Email: u.Email})
}
