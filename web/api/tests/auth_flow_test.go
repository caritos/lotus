package tests

import (
	"net/http"
	"testing"

	"app/internal/apptest"
)

// covers: login, logout, getMe
func TestAuthFlow(t *testing.T) {
	integration(t)
	a := apptest.NewServer(t)
	a.CreateUser(testEmail, testPassword)

	if st, _, _ := req(t, a.Client, http.MethodGet, a.URL+"/api/me", nil, nil); st != http.StatusUnauthorized {
		t.Fatalf("me before login = %d, want 401", st)
	}

	st, hdr, body := login(t, a, a.Client, testEmail, testPassword)
	if st != http.StatusOK {
		t.Fatalf("login = %d %s", st, body)
	}
	if !contains(string(body), testEmail) {
		t.Fatalf("login body %s lacks email", body)
	}
	var cookie *http.Cookie
	resp := &http.Response{Header: hdr}
	for _, c := range resp.Cookies() {
		if c.Name == "app_session" {
			cookie = c
		}
	}
	if cookie == nil {
		t.Fatal("no app_session cookie")
	}
	if !cookie.HttpOnly || cookie.SameSite != http.SameSiteLaxMode || cookie.Path != "/" || cookie.MaxAge <= 0 || cookie.Value == "" {
		t.Fatalf("cookie attributes wrong: %+v", cookie)
	}
	if cookie.Secure {
		t.Fatal("development config must not set Secure (httptest is plain HTTP)")
	}

	if st, _, body := req(t, a.Client, http.MethodGet, a.URL+"/api/me", nil, nil); st != http.StatusOK || !contains(string(body), testEmail) {
		t.Fatalf("me after login = %d %s", st, body)
	}

	if st, _, _ := req(t, a.Client, http.MethodPost, a.URL+"/api/logout", nil, nil); st != http.StatusNoContent {
		t.Fatalf("logout = %d, want 204", st)
	}
	if st, _, _ := req(t, a.Client, http.MethodGet, a.URL+"/api/me", nil, nil); st != http.StatusUnauthorized {
		t.Fatalf("me after logout = %d, want 401", st)
	}
}

func TestLoginFailuresAreIndistinguishable(t *testing.T) {
	integration(t)
	a := apptest.NewServer(t)
	a.CreateUser(testEmail, testPassword)

	st1, _, b1 := login(t, a, a.NewClient(), testEmail, "wrong password here")
	st2, _, b2 := login(t, a, a.NewClient(), "nobody@example.com", "wrong password here")
	if st1 != http.StatusUnauthorized || st2 != http.StatusUnauthorized {
		t.Fatalf("statuses = %d, %d; want 401, 401", st1, st2)
	}
	if string(b1) != string(b2) {
		t.Fatalf("bodies differ: %q vs %q", b1, b2)
	}
}

func TestCrossOriginMutationRefused(t *testing.T) {
	integration(t)
	a := apptest.NewServer(t)
	a.CreateUser(testEmail, testPassword)

	c := a.NewClient()
	st, hdr, _ := req(t, c, http.MethodPost, a.URL+"/api/login",
		jsonBody(testEmail, testPassword),
		map[string]string{"Content-Type": "application/json", "Origin": "http://evil.example"})
	if st != http.StatusForbidden {
		t.Fatalf("cross-origin login = %d, want 403", st)
	}
	if len((&http.Response{Header: hdr}).Cookies()) != 0 {
		t.Fatal("cross-origin login set a cookie")
	}
	if st, _, _ := req(t, c, http.MethodGet, a.URL+"/api/me", nil, nil); st != http.StatusUnauthorized {
		t.Fatalf("me = %d, want 401 (no session)", st)
	}
}
