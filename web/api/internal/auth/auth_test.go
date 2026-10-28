package auth

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"app/internal/config"
	"app/internal/testutil"
)

func TestMain(m *testing.M) {
	UseFastHashingForTests()
	os.Exit(m.Run())
}

type fakeClock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *fakeClock) Advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.t = c.t.Add(d)
}

func newService(t *testing.T, cfg config.Config) (*Service, *fakeClock) {
	t.Helper()
	clk := &fakeClock{t: time.Date(2026, 10, 27, 12, 0, 0, 0, time.UTC)}
	if cfg.SessionTTL == 0 {
		cfg.SessionTTL = time.Hour
	}
	return NewService(testutil.NewDB(t), cfg, clk.Now), clk
}

func TestHashAndCheck(t *testing.T) {
	h, err := HashPassword("correct horse")
	if err != nil {
		t.Fatal(err)
	}
	if h == "correct horse" {
		t.Fatal("hash equals password")
	}
	if !CheckPassword(h, "correct horse") {
		t.Error("right password rejected")
	}
	if CheckPassword(h, "wrong horse!") {
		t.Error("wrong password accepted")
	}
	if CheckPassword("not-a-hash", "correct horse") {
		t.Error("garbage hash accepted")
	}
}

func TestCreateUserNormalizesEmail(t *testing.T) {
	s, _ := newService(t, config.Config{})
	u, err := s.CreateUser(context.Background(), "  Alice@Example.COM ", "password1")
	if err != nil {
		t.Fatal(err)
	}
	if u.Email != "alice@example.com" || u.ID == "" {
		t.Fatalf("user = %+v", u)
	}
}

func TestCreateUserValidation(t *testing.T) {
	s, _ := newService(t, config.Config{})
	ctx := context.Background()
	for _, email := range []string{"", "   ", "noatsign"} {
		if _, err := s.CreateUser(ctx, email, "password1"); !errors.Is(err, ErrInvalidEmail) {
			t.Errorf("email %q: err = %v", email, err)
		}
	}
	for _, pw := range []string{"", "short", strings.Repeat("a", 73)} {
		if _, err := s.CreateUser(ctx, "a@b.c", pw); !errors.Is(err, ErrWeakPassword) {
			t.Errorf("password len %d: err = %v", len(pw), err)
		}
	}
	if _, err := s.CreateUser(ctx, "a@b.c", strings.Repeat("a", 72)); err != nil {
		t.Errorf("72-byte password rejected: %v", err)
	}
}

func TestDuplicateEmailCaseInsensitive(t *testing.T) {
	s, _ := newService(t, config.Config{})
	ctx := context.Background()
	if _, err := s.CreateUser(ctx, "bob@example.com", "password1"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.CreateUser(ctx, "BOB@example.com", "password2"); !errors.Is(err, ErrEmailTaken) {
		t.Fatalf("err = %v, want ErrEmailTaken", err)
	}
}

func TestLoginStoresOnlyTokenHash(t *testing.T) {
	s, _ := newService(t, config.Config{SessionSecret: "s3cret"})
	ctx := context.Background()
	if _, err := s.CreateUser(ctx, "a@b.c", "password1"); err != nil {
		t.Fatal(err)
	}
	token, u, err := s.Login(ctx, "A@B.c ", "password1", "1.2.3.4")
	if err != nil || token == "" || u.Email != "a@b.c" {
		t.Fatalf("token=%q user=%+v err=%v", token, u, err)
	}
	var stored string
	if err := s.db.QueryRow(`SELECT token_hash FROM sessions`).Scan(&stored); err != nil {
		t.Fatal(err)
	}
	if stored == token || len(stored) != 64 {
		t.Fatalf("stored hash = %q", stored)
	}
	got, err := s.UserFor(ctx, token)
	if err != nil || got.ID != u.ID {
		t.Fatalf("UserFor = %+v, %v", got, err)
	}
	if _, err := s.UserFor(ctx, "bogus"); !errors.Is(err, ErrUnauthenticated) {
		t.Fatalf("bogus token err = %v", err)
	}
}

func TestSessionExpires(t *testing.T) {
	s, clk := newService(t, config.Config{SessionTTL: time.Hour})
	ctx := context.Background()
	if _, err := s.CreateUser(ctx, "a@b.c", "password1"); err != nil {
		t.Fatal(err)
	}
	token, _, err := s.Login(ctx, "a@b.c", "password1", "1.2.3.4")
	if err != nil {
		t.Fatal(err)
	}
	clk.Advance(59 * time.Minute)
	if _, err := s.UserFor(ctx, token); err != nil {
		t.Fatalf("before expiry: %v", err)
	}
	clk.Advance(2 * time.Minute)
	if _, err := s.UserFor(ctx, token); !errors.Is(err, ErrUnauthenticated) {
		t.Fatalf("after expiry err = %v", err)
	}
	var n int
	if err := s.db.QueryRow(`SELECT count(*) FROM sessions`).Scan(&n); err != nil || n != 0 {
		t.Fatalf("expired session not deleted: n=%d err=%v", n, err)
	}
}

func TestPurgeExpired(t *testing.T) {
	s, clk := newService(t, config.Config{SessionTTL: time.Hour})
	ctx := context.Background()
	if _, err := s.CreateUser(ctx, "a@b.c", "password1"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.Login(ctx, "a@b.c", "password1", "1.2.3.4"); err != nil {
		t.Fatal(err)
	}
	clk.Advance(30 * time.Minute)
	if _, _, err := s.Login(ctx, "a@b.c", "password1", "1.2.3.4"); err != nil {
		t.Fatal(err)
	}
	clk.Advance(45 * time.Minute) // first expired, second still valid
	n, err := s.PurgeExpired(ctx)
	if err != nil || n != 1 {
		t.Fatalf("purged %d, err %v", n, err)
	}
}

func TestLogoutInvalidatesSession(t *testing.T) {
	s, _ := newService(t, config.Config{})
	ctx := context.Background()
	if _, err := s.CreateUser(ctx, "a@b.c", "password1"); err != nil {
		t.Fatal(err)
	}
	token, _, _ := s.Login(ctx, "a@b.c", "password1", "1.2.3.4")
	if err := s.Logout(ctx, token); err != nil {
		t.Fatal(err)
	}
	if _, err := s.UserFor(ctx, token); !errors.Is(err, ErrUnauthenticated) {
		t.Fatalf("err = %v", err)
	}
	if err := s.Logout(ctx, token); err != nil {
		t.Fatalf("second logout should be idempotent: %v", err)
	}
}

func TestLoginBadCredentials(t *testing.T) {
	s, _ := newService(t, config.Config{})
	ctx := context.Background()
	if _, err := s.CreateUser(ctx, "a@b.c", "password1"); err != nil {
		t.Fatal(err)
	}
	for _, c := range [][2]string{{"a@b.c", "wrongpass1"}, {"nobody@b.c", "password1"}, {"garbage", "password1"}} {
		if _, _, err := s.Login(ctx, c[0], c[1], "1.2.3.4"); !errors.Is(err, ErrBadCredentials) {
			t.Errorf("%v: err = %v", c, err)
		}
	}
}

func TestThrottleAfterFiveFailures(t *testing.T) {
	s, clk := newService(t, config.Config{})
	ctx := context.Background()
	if _, err := s.CreateUser(ctx, "a@b.c", "password1"); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 5; i++ {
		if _, _, err := s.Login(ctx, "a@b.c", "wrongpass1", "1.2.3.4"); !errors.Is(err, ErrBadCredentials) {
			t.Fatalf("attempt %d: %v", i, err)
		}
	}
	// Sixth attempt is throttled even with the right password.
	_, _, err := s.Login(ctx, "a@b.c", "password1", "1.2.3.4")
	var te *ThrottleError
	if !errors.Is(err, ErrThrottled) || !errors.As(err, &te) || te.RetryAfter <= 0 {
		t.Fatalf("err = %v", err)
	}
	// A different IP for the same email is not blocked by the pair limit.
	if _, _, err := s.Login(ctx, "a@b.c", "password1", "5.6.7.8"); err != nil {
		t.Fatalf("other ip: %v", err)
	}
	clk.Advance(16 * time.Minute)
	if _, _, err := s.Login(ctx, "a@b.c", "password1", "1.2.3.4"); err != nil {
		t.Fatalf("after window: %v", err)
	}
}

func TestSuccessClearsPairCounter(t *testing.T) {
	s, _ := newService(t, config.Config{})
	ctx := context.Background()
	if _, err := s.CreateUser(ctx, "a@b.c", "password1"); err != nil {
		t.Fatal(err)
	}
	for round := 0; round < 3; round++ {
		for i := 0; i < 4; i++ {
			s.Login(ctx, "a@b.c", "wrongpass1", "1.2.3.4")
		}
		if _, _, err := s.Login(ctx, "a@b.c", "password1", "1.2.3.4"); err != nil {
			t.Fatalf("round %d: %v", round, err)
		}
	}
}

func TestThrottlePerIPAndPerEmailLimits(t *testing.T) {
	clk := &fakeClock{t: time.Unix(1_000_000, 0)}
	th := newThrottle(clk.Now)
	// 20 failures against one email from 20 distinct IPs blocks the email.
	for i := 0; i < 20; i++ {
		th.attempt("v@x.y", "10.0.0."+string(rune('a'+i)))
	}
	if _, ok := th.attempt("v@x.y", "10.9.9.9"); ok {
		t.Error("email limit not enforced")
	}
	// 50 failures from one IP across distinct emails blocks the IP.
	th = newThrottle(clk.Now)
	for i := 0; i < 50; i++ {
		th.attempt("u"+string(rune('a'+i))+"@x.y", "9.9.9.9")
	}
	if _, ok := th.attempt("fresh@x.y", "9.9.9.9"); ok {
		t.Error("ip limit not enforced")
	}
}

func TestThrottleGroupsIPv6By64(t *testing.T) {
	clk := &fakeClock{t: time.Unix(1_000_000, 0)}
	th := newThrottle(clk.Now)
	for i := 0; i < 5; i++ {
		th.attempt("a@b.c", "2001:db8:1:2::"+string(rune('1'+i)))
	}
	if _, ok := th.attempt("a@b.c", "2001:db8:1:2:ffff::9"); ok {
		t.Error("same /64 not grouped")
	}
	if _, ok := th.attempt("a@b.c", "2001:db8:1:3::1"); !ok {
		t.Error("different /64 should not be blocked")
	}
}

func TestThrottleBoundedAndExpires(t *testing.T) {
	clk := &fakeClock{t: time.Unix(1_000_000, 0)}
	th := newThrottle(clk.Now)
	for i := 0; i < maxThrottleEntries+500; i++ {
		th.attempt("e"+itoa(i)+"@x.y", "1.1.1."+itoa(i%250))
	}
	if n := th.size(); n > 3*maxThrottleEntries {
		t.Fatalf("size = %d, not bounded", n)
	}
	clk.Advance(throttleWindow + time.Second)
	th.attempt("last@x.y", "8.8.8.8")
	if n := th.size(); n > 3 {
		t.Fatalf("expired entries not dropped, size = %d", n)
	}
}

func itoa(i int) string {
	b, _ := json.Marshal(i)
	return string(b)
}

func TestClientIPContext(t *testing.T) {
	ctx := WithClientIP(context.Background(), "9.9.9.9")
	if ClientIPFromContext(ctx) != "9.9.9.9" {
		t.Error("ip not round-tripped")
	}
	if ClientIPFromContext(context.Background()) != "" {
		t.Error("expected empty")
	}
}

// ---- HTTP ----

func newHandler(t *testing.T, cfg config.Config) (http.Handler, *Service, *fakeClock) {
	t.Helper()
	s, clk := newService(t, cfg)
	if _, err := s.CreateUser(context.Background(), "a@b.c", "password1"); err != nil {
		t.Fatal(err)
	}
	return Middleware(s)(Handlers(s)), s, clk
}

func post(h http.Handler, path, body string, cookies ...*http.Cookie) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodPost, path, bytes.NewBufferString(body))
	req.RemoteAddr = "1.2.3.4:5555"
	for _, c := range cookies {
		req.AddCookie(c)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func TestLoginSuccessSetsCookieAttributes(t *testing.T) {
	h, _, _ := newHandler(t, config.Config{SecureCookies: true, SessionTTL: 2 * time.Hour})
	rec := post(h, "/api/login", `{"email":"A@b.c","password":"password1"}`)
	if rec.Code != 200 {
		t.Fatalf("status = %d body=%s", rec.Code, rec.Body)
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
		t.Errorf("content-type = %q", ct)
	}
	var body map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil || body["email"] != "a@b.c" || body["id"] == "" {
		t.Fatalf("body = %s", rec.Body)
	}
	cs := rec.Result().Cookies()
	if len(cs) != 1 {
		t.Fatalf("cookies = %v", cs)
	}
	c := cs[0]
	if c.Name != "app_session" || !c.HttpOnly || !c.Secure || c.SameSite != http.SameSiteLaxMode || c.Path != "/" || c.Value == "" {
		t.Errorf("cookie = %+v", c)
	}
	if c.MaxAge != 7200 {
		t.Errorf("MaxAge = %d", c.MaxAge)
	}
}

func TestCookieNotSecureWhenDisabled(t *testing.T) {
	h, _, _ := newHandler(t, config.Config{SecureCookies: false})
	rec := post(h, "/api/login", `{"email":"a@b.c","password":"password1"}`)
	if c := rec.Result().Cookies()[0]; c.Secure {
		t.Error("cookie Secure with SecureCookies=false")
	}
}

func TestLoginWrongPasswordGeneric401(t *testing.T) {
	h, _, _ := newHandler(t, config.Config{})
	wrong := post(h, "/api/login", `{"email":"a@b.c","password":"nope-nope"}`)
	unknown := post(h, "/api/login", `{"email":"ghost@b.c","password":"nope-nope"}`)
	if wrong.Code != 401 || unknown.Code != 401 {
		t.Fatalf("codes = %d %d", wrong.Code, unknown.Code)
	}
	if wrong.Body.String() != unknown.Body.String() {
		t.Errorf("bodies differ: %q vs %q", wrong.Body, unknown.Body)
	}
	if strings.TrimSpace(wrong.Body.String()) != `{"error":"invalid email or password"}` {
		t.Errorf("body = %q", wrong.Body)
	}
	if len(wrong.Result().Cookies()) != 0 {
		t.Error("cookie set on failure")
	}
}

func TestLoginBadJSON(t *testing.T) {
	h, _, _ := newHandler(t, config.Config{})
	for _, b := range []string{"", "{", `[1]`, `{"email":1}`} {
		if rec := post(h, "/api/login", b); rec.Code != 400 {
			t.Errorf("body %q: status = %d", b, rec.Code)
		}
	}
}

func TestLoginThrottled429(t *testing.T) {
	h, _, _ := newHandler(t, config.Config{})
	for i := 0; i < 5; i++ {
		post(h, "/api/login", `{"email":"a@b.c","password":"wrongpass1"}`)
	}
	rec := post(h, "/api/login", `{"email":"a@b.c","password":"password1"}`)
	if rec.Code != 429 || rec.Header().Get("Retry-After") == "" {
		t.Fatalf("status=%d retry-after=%q", rec.Code, rec.Header().Get("Retry-After"))
	}
}

func TestLoginUsesClientIPFromContext(t *testing.T) {
	h, _, _ := newHandler(t, config.Config{})
	attempt := func(ip string) int {
		req := httptest.NewRequest(http.MethodPost, "/api/login", bytes.NewBufferString(`{"email":"a@b.c","password":"wrongpass1"}`))
		req = req.WithContext(WithClientIP(req.Context(), ip))
		req.RemoteAddr = "1.2.3.4:1"
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		return rec.Code
	}
	for i := 0; i < 5; i++ {
		attempt("7.7.7.7")
	}
	if attempt("7.7.7.7") != 429 {
		t.Error("context ip not used for throttling")
	}
	if attempt("8.8.8.8") != 401 {
		t.Error("different context ip should not be throttled")
	}
}

func TestMeAndLogoutFlow(t *testing.T) {
	h, _, _ := newHandler(t, config.Config{})
	login := post(h, "/api/login", `{"email":"a@b.c","password":"password1"}`)
	cookie := login.Result().Cookies()[0]

	me := httptest.NewRequest(http.MethodGet, "/api/me", nil)
	me.AddCookie(cookie)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, me)
	if rec.Code != 200 || !strings.Contains(rec.Body.String(), `"email":"a@b.c"`) {
		t.Fatalf("me: %d %s", rec.Code, rec.Body)
	}

	anon := httptest.NewRecorder()
	h.ServeHTTP(anon, httptest.NewRequest(http.MethodGet, "/api/me", nil))
	if anon.Code != 401 {
		t.Fatalf("anon me = %d", anon.Code)
	}

	out := post(h, "/api/logout", "", cookie)
	if out.Code != 204 {
		t.Fatalf("logout = %d", out.Code)
	}
	cleared := out.Result().Cookies()
	if len(cleared) != 1 || cleared[0].MaxAge >= 0 || cleared[0].Name != "app_session" {
		t.Fatalf("cookie not cleared: %v", cleared)
	}
	rec = httptest.NewRecorder()
	me = httptest.NewRequest(http.MethodGet, "/api/me", nil)
	me.AddCookie(cookie)
	h.ServeHTTP(rec, me)
	if rec.Code != 401 {
		t.Fatalf("me after logout = %d", rec.Code)
	}
	if again := post(h, "/api/logout", ""); again.Code != 204 {
		t.Fatalf("anonymous logout = %d", again.Code)
	}
}

func TestRequireAndMiddleware(t *testing.T) {
	s, _ := newService(t, config.Config{})
	ctx := context.Background()
	if _, err := s.CreateUser(ctx, "a@b.c", "password1"); err != nil {
		t.Fatal(err)
	}
	token, _, _ := s.Login(ctx, "a@b.c", "password1", "1.2.3.4")
	var seen string
	protected := Middleware(s)(Require(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		u, ok := FromContext(r.Context())
		if ok {
			seen = u.Email
		}
		w.WriteHeader(http.StatusNoContent)
	})))

	rec := httptest.NewRecorder()
	protected.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/x", nil))
	if rec.Code != 401 || strings.TrimSpace(rec.Body.String()) != `{"error":"unauthorized"}` || rec.Header().Get("Content-Type") != "application/json" {
		t.Fatalf("anon: %d %q", rec.Code, rec.Body)
	}
	req := httptest.NewRequest(http.MethodGet, "/x", nil)
	req.AddCookie(&http.Cookie{Name: "app_session", Value: token})
	rec = httptest.NewRecorder()
	protected.ServeHTTP(rec, req)
	if rec.Code != 204 || seen != "a@b.c" {
		t.Fatalf("authed: %d seen=%q", rec.Code, seen)
	}
	if _, ok := FromContext(context.Background()); ok {
		t.Error("user in empty context")
	}
}

func TestParallelWrongPasswordsCannotBypassThrottle(t *testing.T) {
	s, _ := newService(t, config.Config{})
	ctx := context.Background()
	if _, err := s.CreateUser(ctx, "a@b.c", "password1"); err != nil {
		t.Fatal(err)
	}
	const n = 20
	errs := make([]error, n)
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, _, errs[i] = s.Login(ctx, "a@b.c", "wrongpass1", "1.2.3.4")
		}()
	}
	wg.Wait()
	bad, throttled := 0, 0
	for _, err := range errs {
		switch {
		case errors.Is(err, ErrBadCredentials):
			bad++
		case errors.Is(err, ErrThrottled):
			throttled++
		default:
			t.Fatalf("unexpected err %v", err)
		}
	}
	if bad > pairLimit || bad+throttled != n {
		t.Fatalf("bad=%d throttled=%d, want bad <= %d", bad, throttled, pairLimit)
	}
}

func TestSuccessDoesNotResetEmailOrIPCounters(t *testing.T) {
	clk := &fakeClock{t: time.Unix(1_000_000, 0)}
	th := newThrottle(clk.Now)
	// 19 failures on one email from distinct IPs, then a success from another IP.
	for i := 0; i < 19; i++ {
		th.attempt("v@x.y", "10.0.0."+itoa(i))
	}
	th.attempt("v@x.y", "10.1.1.1")
	th.success("v@x.y", "10.1.1.1")
	if _, ok := th.attempt("v@x.y", "10.2.2.2"); !ok {
		t.Fatal("19 failures should not block yet")
	}
	if _, ok := th.attempt("v@x.y", "10.3.3.3"); ok {
		t.Fatal("success reset the per-email counter")
	}
}

func TestLoginRejectsPasswordsOver72Bytes(t *testing.T) {
	s, _ := newService(t, config.Config{})
	ctx := context.Background()
	pw := strings.Repeat("p", 72)
	if _, err := s.CreateUser(ctx, "a@b.c", pw); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.Login(ctx, "a@b.c", pw+"x", "1.2.3.4"); !errors.Is(err, ErrBadCredentials) {
		t.Fatalf("73-byte err = %v", err)
	}
	if _, _, err := s.Login(ctx, "a@b.c", pw, "1.2.3.4"); err != nil {
		t.Fatalf("exact 72-byte password: %v", err)
	}
}

func TestLoginOversizedEmailIsNotAThrottleKey(t *testing.T) {
	s, _ := newService(t, config.Config{})
	huge := strings.Repeat("a", 10*1024) + "@b.c"
	if _, _, err := s.Login(context.Background(), huge, "password1", "1.2.3.4"); !errors.Is(err, ErrBadCredentials) {
		t.Fatalf("err = %v", err)
	}
	for _, c := range []*counter{s.throttle.pair, s.throttle.email, s.throttle.ip} {
		for k := range c.m {
			if len(k) > 300 {
				t.Fatalf("throttle key of %d bytes", len(k))
			}
		}
	}
	if s.throttle.size() == 0 {
		t.Error("failure not recorded against the fixed key")
	}
}
