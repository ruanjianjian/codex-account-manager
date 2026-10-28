package main

import (
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func localToken(id, nonce string, expiry int64) string {
	b, _ := json.Marshal(map[string]any{"exp": expiry, "nonce": nonce, "https://api.openai.com/auth": map[string]string{"chatgpt_account_id": id}})
	return "header." + base64.RawURLEncoding.EncodeToString(b) + ".signature"
}
func putDesktop(t *testing.T, path, id, token string) {
	t.Helper()
	b, _ := json.Marshal(map[string]any{"tokens": map[string]string{"access_token": token, "account_id": id}})
	if e := os.WriteFile(path, b, 0600); e != nil {
		t.Fatal(e)
	}
}
func nativeFixture(t *testing.T) (*nativeAuth, config, string) {
	t.Helper()
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	n := &nativeAuth{path: filepath.Join(dir, "auth.json"), cache: filepath.Join(dir, "hashes.json")}
	c := pool()
	c.Clients = []clientIdentity{{"one", "acct-one"}, {"two", "acct-two"}}
	token := localToken("acct-two", "desktop", time.Now().Unix()+3600)
	putDesktop(t, n.path, "acct-two", token)
	return n, c, token
}
func health(g *gateway, token, id string) int {
	r := httptest.NewRequest("GET", "http://127.0.0.1/health", nil)
	r.Header.Set("Authorization", "Bearer "+token)
	r.Header.Set("chatgpt-account-id", id)
	w := httptest.NewRecorder()
	g.ServeHTTP(w, r)
	return w.Code
}
func TestActualMismatchAndRefreshAcrossRestart(t *testing.T) {
	n, c, old := nativeFixture(t)
	if err := n.validateDesktop(c); err != nil {
		t.Fatal(err)
	}
	unknown := c
	unknown.Clients = nil
	if n.validateDesktop(unknown) == nil {
		t.Fatal("unenrolled desktop accepted at startup")
	}
	g := newGateway(func() (config, error) { return c, nil }, "", func(event) {})
	if got := health(g, old, "acct-two"); got != 401 {
		t.Fatal("old implementation did not reproduce", got)
	}
	g.native = n
	if got := health(g, old, "acct-two"); got != 200 {
		t.Fatal("desktop not authenticated", got)
	}
	fresh := localToken("acct-two", "refreshed", time.Now().Unix()+7200)
	putDesktop(t, n.path, "acct-two", fresh)
	if got := health(g, fresh, "acct-two"); got != 200 {
		t.Fatal("refresh gap", got)
	}
	if got := health(g, old, "acct-two"); got != 200 {
		t.Fatal("cached old session broke", got)
	}
	g.native = &nativeAuth{path: n.path, cache: n.cache}
	if got := health(g, old, "acct-two"); got != 200 {
		t.Fatal("restart lost old session", got)
	}
	b, _ := os.ReadFile(n.cache)
	if strings.Contains(string(b), old) || strings.Contains(string(b), fresh) {
		t.Fatal("raw token persisted in registry")
	}
	st, _ := os.Stat(n.cache)
	if st.Mode().Perm() != 0600 {
		t.Fatal("insecure cache")
	}
}
func TestNativeAdmissionSeparateFromRoutingAndRevocation(t *testing.T) {
	n, c, token := nativeFixture(t)
	c.Accounts = c.Accounts[:1] // paused/excluded desktop account
	g := newGateway(func() (config, error) { return c, nil }, "", func(event) {})
	g.native = n
	if health(g, token, "acct-two") != 200 {
		t.Fatal("paused client cannot authenticate")
	}
	updated, _, _ := n.authenticate(c, token, "acct-two")
	if len(updated.Accounts) != 1 {
		t.Fatal("paused account reintroduced")
	}
	c.Clients = c.Clients[:1]
	if health(g, token, "acct-two") != 401 {
		t.Fatal("removed membership still accepted")
	}
	if health(g, "anything", "acct-one") != 401 {
		t.Fatal("account ID accepted without token")
	}
}
func TestNativeRejectsForgedExpiredMismatchedAndUnsafe(t *testing.T) {
	n, c, token := nativeFixture(t)
	g := newGateway(func() (config, error) { return c, nil }, "", func(event) {})
	g.native = n
	if health(g, token, "acct-one") != 401 {
		t.Fatal("header account mismatch accepted")
	}
	forged := localToken("acct-two", "never-observed", time.Now().Unix()+3600)
	if health(g, forged, "acct-two") != 401 {
		t.Fatal("arbitrary signed-looking JWT accepted")
	}
	expired := localToken("acct-two", "expired", time.Now().Unix()-1)
	putDesktop(t, n.path, "acct-two", expired)
	if health(g, expired, "acct-two") != 401 {
		t.Fatal("expired token accepted")
	}
	os.Remove(n.cache) // test first observation, not an already-trusted historical hash
	putDesktop(t, n.path, "acct-one", token)
	if health(g, token, "acct-two") != 401 {
		t.Fatal("JWT/file identity mismatch accepted")
	}
	putDesktop(t, n.path, "acct-two", token)
	os.Chmod(n.path, 0644)
	if health(g, token, "acct-two") != 401 {
		t.Fatal("public auth file trusted")
	}
	os.Chmod(n.path, 0600)
	other := n.path + ".real"
	os.Rename(n.path, other)
	os.Symlink(other, n.path)
	if health(g, token, "acct-two") != 401 {
		t.Fatal("symlink auth file trusted")
	}
}
func TestExpiredRegistryAndKeyRotation(t *testing.T) {
	n, c, token := nativeFixture(t)
	expired := localToken("acct-two", "old", time.Now().Unix()-1)
	b, _ := json.Marshal([]clientHash{{digestToken(expired), "acct-two", float64(time.Now().Unix() - 1)}})
	os.WriteFile(n.cache, b, 0600)
	g := newGateway(func() (config, error) { return c, nil }, "", func(event) {})
	g.native = n
	if health(g, expired, "acct-two") != 401 {
		t.Fatal("expired hash accepted")
	}
	oldKey := c.Key
	c.Key = strings.Repeat("b", 64)
	if health(g, oldKey, "") != 401 || health(g, c.Key, "") != 200 || health(g, token, "acct-two") != 200 {
		t.Fatal("key rotation authentication incorrect")
	}
}
func TestNativeNewAndSealedOldSessionsUseRefreshedUpstream(t *testing.T) {
	n, c, token := nativeFixture(t)
	c.Preferred = "two"
	var seen []string
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+token {
			t.Error("stale upstream credential")
		}
		seen = append(seen, r.Header.Get("chatgpt-account-id"))
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, good)
	}))
	defer up.Close()
	g := newGateway(func() (config, error) { return c, nil }, up.URL, func(event) {})
	g.native = n
	for _, body := range []string{`{"input":"new"}`, `{"input":[{"encrypted_content":"sealed"}],"service_tier":"priority"}`} {
		r := httptest.NewRequest("POST", "http://127.0.0.1/backend-api/codex/responses", strings.NewReader(body))
		r.Header.Set("Authorization", "Bearer "+token)
		r.Header.Set("chatgpt-account-id", "acct-two")
		r.Header.Set("session-id", body)
		w := httptest.NewRecorder()
		g.ServeHTTP(w, r)
		if w.Code != 200 {
			t.Fatal(w.Code)
		}
	}
	if strings.Join(seen, ",") != "acct-two,acct-two" {
		t.Fatal("wrong routing", seen)
	}
}
