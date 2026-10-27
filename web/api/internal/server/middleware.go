package server

import (
	"log/slog"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"strings"
	"time"

	"goweb/internal/auth"
	"goweb/internal/config"
)

// Middleware wraps a handler.
type Middleware = func(http.Handler) http.Handler

// SecurityHeaders sets the baseline response headers; HSTS only when secure.
func SecurityHeaders(secure bool) Middleware {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			h := w.Header()
			h.Set("X-Content-Type-Options", "nosniff")
			h.Set("X-Frame-Options", "DENY")
			h.Set("Referrer-Policy", "same-origin")
			h.Set("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
			h.Set("Content-Security-Policy", "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'")
			if secure {
				h.Set("Strict-Transport-Security", "max-age=31536000; includeSubDomains")
			}
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
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusForbidden)
				_, _ = w.Write([]byte(`{"error":"cross-origin request refused"}` + "\n"))
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

// BodyLimit caps request bodies at n bytes: 413 up front when Content-Length
// is larger, and http.MaxBytesReader for everything else.
func BodyLimit(n int64) Middleware {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.ContentLength > n {
				http.Error(w, "request body too large", http.StatusRequestEntityTooLarge)
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
			)
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
