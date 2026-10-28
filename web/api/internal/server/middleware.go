package server

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"log/slog"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"regexp"
	"runtime/debug"
	"strings"
	"time"

	"goweb/internal/apigen"
	"goweb/internal/auth"
	"goweb/internal/config"
)

// Middleware wraps a handler.
type Middleware = func(http.Handler) http.Handler

// SecurityHeaders sets the baseline response headers. It never sets
// Strict-Transport-Security: the reverse proxy that terminates TLS owns HSTS, so
// its staged max-age rollout (docs/https.md) is the only one browsers see.
func SecurityHeaders() Middleware {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			h := w.Header()
			h.Set("X-Content-Type-Options", "nosniff")
			h.Set("X-Frame-Options", "DENY")
			h.Set("Referrer-Policy", "same-origin")
			h.Set("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
			h.Set("Content-Security-Policy", "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'")
			next.ServeHTTP(w, r)
		})
	}
}

// SameOrigin refuses cross-origin state-changing requests (POST, PUT, PATCH,
// DELETE). With an Origin header it must equal publicOrigin (or, when
// publicOrigin is empty, have the request's host). Without one, the request is
// allowed only if Sec-Fetch-Site is absent (non-browser client), same-origin
// or none.
func SameOrigin(publicOrigin string) Middleware {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			switch r.Method {
			case http.MethodPost, http.MethodPut, http.MethodPatch, http.MethodDelete:
			default:
				next.ServeHTTP(w, r)
				return
			}
			if !sameOriginOK(publicOrigin, r) {
				writeError(w, http.StatusForbidden, "cross-origin request refused")
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

func sameOriginOK(publicOrigin string, r *http.Request) bool {
	origin := r.Header.Get("Origin")
	if origin == "" {
		switch r.Header.Get("Sec-Fetch-Site") {
		case "", "same-origin", "none":
			return true
		}
		return false
	}
	if publicOrigin != "" {
		return origin == publicOrigin
	}
	u, err := url.Parse(origin)
	return err == nil && u.Host != "" && u.Host == r.Host
}

// writeError writes a JSON error body in the API's Error shape.
func writeError(w http.ResponseWriter, status int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(apigen.Error{Error: msg})
}

// BodyLimit caps request bodies at n bytes: 413 (JSON Error body) up front when
// Content-Length is larger, and http.MaxBytesReader for everything else.
func BodyLimit(n int64) Middleware {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.ContentLength > n {
				writeError(w, http.StatusRequestEntityTooLarge, "request body too large")
				return
			}
			r.Body = http.MaxBytesReader(w, r.Body, n)
			next.ServeHTTP(w, r)
		})
	}
}

// TrustedProxy resolves the client IP and stores it in the request context.
// X-Forwarded-For is honored only when the immediate peer is in cidrs (a
// comma-separated list of CIDRs or IPs); it is walked right to left and the
// first address that is not itself trusted wins.
func TrustedProxy(cidrs string) (Middleware, error) {
	trusted, err := config.ParseTrustedProxy(cidrs)
	if err != nil {
		return nil, err
	}
	isTrusted := func(a netip.Addr) bool {
		for _, p := range trusted {
			if p.Contains(a) {
				return true
			}
		}
		return false
	}
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			ip := clientIP(r, isTrusted)
			next.ServeHTTP(w, r.WithContext(auth.WithClientIP(r.Context(), ip)))
		})
	}, nil
}

func clientIP(r *http.Request, isTrusted func(netip.Addr) bool) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	peer, err := netip.ParseAddr(host)
	if err != nil {
		return host
	}
	peer = peer.Unmap()
	if !isTrusted(peer) {
		return peer.String()
	}
	parts := strings.Split(strings.Join(r.Header.Values("X-Forwarded-For"), ","), ",")
	for i := len(parts) - 1; i >= 0; i-- {
		a, err := netip.ParseAddr(strings.TrimSpace(parts[i]))
		if err != nil {
			return peer.String()
		}
		a = a.Unmap()
		if !isTrusted(a) {
			return a.String()
		}
	}
	return peer.String()
}

// RequestLog logs one line per request: method, path (never the query),
// status, bytes, duration and client IP. Cookies, Authorization and bodies are
// never logged.
func RequestLog(logger *slog.Logger) Middleware {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			start := time.Now()
			rw := &statusWriter{ResponseWriter: w, status: http.StatusOK}
			next.ServeHTTP(rw, r)
			logger.Info("request",
				"method", r.Method,
				"path", r.URL.Path,
				"status", rw.status,
				"bytes", rw.bytes,
				"duration_ms", time.Since(start).Milliseconds(),
				"ip", auth.ClientIPFromContext(r.Context()),
				"request_id", RequestIDFromContext(r.Context()),
			)
		})
	}
}

type requestIDKey struct{}

var validRequestID = regexp.MustCompile(`^[A-Za-z0-9._-]{1,64}$`)

// RequestIDFromContext returns the id RequestID stored, or "" outside it.
func RequestIDFromContext(ctx context.Context) string {
	id, _ := ctx.Value(requestIDKey{}).(string)
	return id
}

// RequestID gives every request an id: the inbound X-Request-Id when it matches
// ^[A-Za-z0-9._-]{1,64}$, otherwise 16 random hex characters. The id is set on
// the response, stored in the context and logged by RequestLog and Recover.
func RequestID() Middleware {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			id := r.Header.Get("X-Request-Id")
			if !validRequestID.MatchString(id) {
				var b [8]byte
				_, _ = rand.Read(b[:]) // the error is ignored on purpose: since Go 1.24 crypto/rand.Read cannot fail (it crashes the program instead); this module is Go 1.27.2
				id = hex.EncodeToString(b[:])
			}
			w.Header().Set("X-Request-Id", id)
			next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), requestIDKey{}, id)))
		})
	}
}

// Recover turns a handler panic into a 500 JSON Error ("internal error", never
// the panic value) and logs the value and stack at Error. When the handler had
// already started the response only the log happens. http.ErrAbortHandler is
// net/http's way to abort a response, so it is re-panicked untouched.
func Recover(logger *slog.Logger) Middleware {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			sw := &statusWriter{ResponseWriter: w, status: http.StatusOK}
			defer func() {
				v := recover()
				if v == nil {
					return
				}
				if v == http.ErrAbortHandler {
					panic(v)
				}
				logger.Error("panic",
					"panic", v,
					"stack", string(debug.Stack()),
					"method", r.Method,
					"path", r.URL.Path,
					"request_id", RequestIDFromContext(r.Context()),
				)
				if !sw.wroteHeader {
					writeError(sw, http.StatusInternalServerError, "internal error")
				}
			}()
			next.ServeHTTP(sw, r)
		})
	}
}

type statusWriter struct {
	http.ResponseWriter
	status      int
	bytes       int64
	wroteHeader bool
}

func (w *statusWriter) WriteHeader(code int) {
	if !w.wroteHeader {
		w.status, w.wroteHeader = code, true
	}
	w.ResponseWriter.WriteHeader(code)
}

func (w *statusWriter) Write(b []byte) (int, error) {
	w.wroteHeader = true
	n, err := w.ResponseWriter.Write(b)
	w.bytes += int64(n)
	return n, err
}

// Flush preserves http.Flusher.
func (w *statusWriter) Flush() {
	if f, ok := w.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

// Unwrap lets http.ResponseController reach the underlying writer.
func (w *statusWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }
