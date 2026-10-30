package main

import (
	"bytes"
	"fmt"
	"github.com/klauspost/compress/zstd"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

func pool() config {
	return config{Key: strings.Repeat("a", 64), Accounts: []account{{ID: "one", AccountID: "acct-one", Access: "token-one", Expires: float64(time.Now().Unix() + 3600), Available: true, Reset: 1}, {ID: "two", AccountID: "acct-two", Access: "token-two", Expires: float64(time.Now().Unix() + 3600), Available: true, Reset: 2}}}
}
func ask(g *gateway, body string) *httptest.ResponseRecorder {
	r := httptest.NewRequest("POST", "http://127.0.0.1:18455/v1/responses", strings.NewReader(body))
	r.Header.Set("Authorization", "Bearer "+pool().Key)
	r.Header.Set("session-id", "test-session")
	w := httptest.NewRecorder()
	g.ServeHTTP(w, r)
	return w
}

const good = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"ok\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":10,\"output_tokens\":1}}}\n\n"

func TestQuotaFailoverAndAffinity(t *testing.T) {
	var seen []string
	var mu sync.Mutex
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := r.Header.Get("chatgpt-account-id")
		mu.Lock()
		seen = append(seen, id)
		mu.Unlock()
		if r.Header.Get("Authorization") != "Bearer token-"+strings.TrimPrefix(id, "acct-") {
			t.Error("wrong credential")
		}
		if id == "acct-one" {
			w.WriteHeader(429)
			io.WriteString(w, `{"error":{"resets_in_seconds":7200}}`)
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, good)
	}))
	defer up.Close()
	g := newGateway(func() (config, error) { return pool(), nil }, up.URL, func(event) {})
	for i := 0; i < 2; i++ {
		w := ask(g, `{"model":"gpt-5","input":"hi"}`)
		if w.Code != 200 || !strings.Contains(w.Body.String(), "ok") {
			t.Fatalf("%d %s", w.Code, w.Body)
		}
	}
	if strings.Join(seen, ",") != "acct-one,acct-two,acct-two" {
		t.Fatal(seen)
	}
	if time.Until(g.rest["one"]) < 119*time.Minute {
		t.Fatal("reset not respected")
	}
}
func TestNoReplayAfterToolOrText(t *testing.T) {
	for _, kind := range []string{"response.output_text.delta", "response.output_item.added"} {
		t.Run(kind, func(t *testing.T) {
			n := 0
			up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				n++
				w.Header().Set("Content-Type", "text/event-stream")
				io.WriteString(w, "data: {\"type\":\""+kind+"\"}\n\ndata: {\"type\":\"response.failed\"}\n\n")
			}))
			defer up.Close()
			g := newGateway(func() (config, error) { return pool(), nil }, up.URL, func(event) {})
			ask(g, `{"input":"hi"}`)
			if n != 1 {
				t.Fatalf("request replayed %d times", n)
			}
		})
	}
}
func TestPreludeFailureRetries(t *testing.T) {
	n := 0
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n++
		w.Header().Set("Content-Type", "text/event-stream")
		if n == 1 {
			io.WriteString(w, "data: {\"type\":\"response.failed\"}\n\n")
		} else {
			io.WriteString(w, good)
		}
	}))
	defer up.Close()
	g := newGateway(func() (config, error) { return pool(), nil }, up.URL, func(event) {})
	w := ask(g, `{"input":"hi"}`)
	if n != 2 || !strings.Contains(w.Body.String(), "ok") {
		t.Fatalf("%d %s", n, w.Body)
	}
}
func TestStoredResponseCannotMove(t *testing.T) {
	n := 0
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { n++; w.WriteHeader(429) }))
	defer up.Close()
	g := newGateway(func() (config, error) { return pool(), nil }, up.URL, func(event) {})
	w := ask(g, `{"previous_response_id":"r1","input":[]}`)
	if w.Code != 409 || n != 0 {
		t.Fatal("stored response with unknown owner was forwarded")
	}
	g.remember("test-session", "one")
	ask(g, `{"previous_response_id":"r1","input":[]}`)
	if n != 1 {
		t.Fatalf("pinned request tried %d accounts", n)
	}
}

// The colleague's case: a conversation with encrypted history began on an account that has since run
// out. It continues on another account instead of failing; while the owner is fine it stays there.
func TestSealedConversationMovesWhenOwnerUnavailable(t *testing.T) {
	var seen []string
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen = append(seen, r.Header.Get("chatgpt-account-id"))
		if r.Header.Get("chatgpt-account-id") == "acct-one" && strings.HasSuffix(r.URL.Path, "/compact") {
			w.WriteHeader(429)
			io.WriteString(w, `{"error":{"type":"usage_limit_reached","resets_in_seconds":3600}}`)
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, good)
	}))
	defer up.Close()
	c := pool()
	g := newGateway(func() (config, error) { return c, nil }, up.URL, func(event) {})
	g.remember("test-session", "one")
	if w := ask(g, `{"input":[{"encrypted_content":"sealed"}]}`); w.Code != 200 || strings.Join(seen, ",") != "acct-one" {
		t.Fatalf("sealed conversation left an available owner: %d %v", w.Code, seen)
	}
	seen = nil
	c.Accounts[0].Available = false
	if w := ask(g, `{"input":[{"encrypted_content":"sealed"}]}`); w.Code != 200 || strings.Join(seen, ",") != "acct-two" {
		t.Fatalf("spent owner blocked its conversation: %d %v", w.Code, seen)
	}
	// Quota looked fine but the owner is used up: the same request moves on.
	seen = nil
	c.Accounts[0].Available = true
	g.remember("compacting", "one")
	r := httptest.NewRequest("POST", "http://127.0.0.1:18455/v1/responses/compact", strings.NewReader(`{"input":[{"encrypted_content":"sealed"}]}`))
	r.Header.Set("Authorization", "Bearer "+pool().Key)
	r.Header.Set("session-id", "compacting")
	w := httptest.NewRecorder()
	g.ServeHTTP(w, r)
	if w.Code != 200 || strings.Join(seen, ",") != "acct-one,acct-two" {
		t.Fatalf("used-up owner did not hand over: %d %v", w.Code, seen)
	}
}
func TestLocalAccessAndNoRedirect(t *testing.T) {
	n := 0
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n++
		w.Header().Set("Location", "http://127.0.0.1:1/stolen")
		w.WriteHeader(302)
	}))
	defer up.Close()
	g := newGateway(func() (config, error) { return pool(), nil }, up.URL, func(event) {})
	for _, s := range []struct{ host, key, origin string }{{"evil.example", pool().Key, ""}, {"127.0.0.1", "wrong", ""}, {"127.0.0.1", pool().Key, "https://evil.example"}} {
		r := httptest.NewRequest("POST", "http://"+s.host+"/v1/responses", strings.NewReader(`{}`))
		r.Header.Set("Authorization", "Bearer "+s.key)
		r.Header.Set("Origin", s.origin)
		w := httptest.NewRecorder()
		g.ServeHTTP(w, r)
		if w.Code != 401 && w.Code != 403 {
			t.Fatal(w.Code)
		}
	}
	if n != 0 {
		t.Fatal("untrusted caller reached upstream")
	}
	w := ask(g, `{}`)
	if n != 1 || w.Code != 302 {
		t.Fatal(n, w.Code)
	}
}
func TestExpiredAndPreferred(t *testing.T) {
	c := pool()
	c.Preferred = "two"
	g := newGateway(func() (config, error) { return c, nil }, "", func(event) {})
	xs, _ := g.candidates(c, "", false, "")
	if len(xs) != 2 || xs[0].ID != "two" || xs[1].ID != "one" {
		t.Fatal(xs)
	}
	c.Accounts[1].Expires = 1
	xs, _ = g.candidates(c, "", false, "")
	if len(xs) != 1 || xs[0].ID != "one" {
		t.Fatal("expired token used", xs)
	}
}

func TestNativeLegacyHistoryAndFastTier(t *testing.T) {
	seen := ""
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen = r.Header.Get("chatgpt-account-id")
		b, _ := io.ReadAll(r.Body)
		if !strings.Contains(string(b), `"service_tier":"priority"`) || !strings.Contains(string(b), `"encrypted_content":"sealed"`) {
			t.Error("request state or speed tier changed")
		}
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, good)
	}))
	defer up.Close()
	g := newGateway(func() (config, error) { return pool(), nil }, up.URL, func(event) {})
	r := httptest.NewRequest("POST", "http://127.0.0.1:18455/backend-api/codex/responses", strings.NewReader(`{"service_tier":"priority","input":[{"encrypted_content":"sealed"}]}`))
	r.Header.Set("Authorization", "Bearer token-two")
	r.Header.Set("chatgpt-account-id", "acct-two")
	r.Header.Set("session-id", "legacy")
	w := httptest.NewRecorder()
	g.ServeHTTP(w, r)
	if w.Code != 200 || seen != "acct-two" {
		t.Fatalf("legacy history routed incorrectly: %d %s", w.Code, seen)
	}
	r = httptest.NewRequest("POST", "http://127.0.0.1:18455/backend-api/codex/responses", strings.NewReader(`{}`))
	r.Header.Set("Authorization", "Bearer token-two")
	r.Header.Set("chatgpt-account-id", "acct-one")
	w = httptest.NewRecorder()
	g.ServeHTTP(w, r)
	if w.Code != 401 {
		t.Fatal("mismatched account accepted")
	}
}

func TestNativeWebsocketFallsBackAndZstdRequest(t *testing.T) {
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		if !strings.Contains(string(b), `"service_tier":"priority"`) {
			t.Error("tier missing")
		}
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, good)
	}))
	defer up.Close()
	g := newGateway(func() (config, error) { return pool(), nil }, up.URL, func(event) {})
	r := httptest.NewRequest("GET", "http://127.0.0.1:18455/backend-api/codex/responses", nil)
	r.Header.Set("Authorization", "Bearer token-two")
	r.Header.Set("Upgrade", "websocket")
	w := httptest.NewRecorder()
	g.ServeHTTP(w, r)
	if w.Code != 426 {
		t.Fatal(w.Code)
	}
	enc, _ := zstd.NewWriter(nil)
	defer enc.Close()
	data := enc.EncodeAll([]byte(`{"input":"hello","service_tier":"priority"}`), nil)
	r = httptest.NewRequest("POST", "http://127.0.0.1:18455/backend-api/codex/responses", bytes.NewReader(data))
	r.Header.Set("Authorization", "Bearer token-two")
	r.Header.Set("Content-Encoding", "zstd")
	w = httptest.NewRecorder()
	g.ServeHTTP(w, r)
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	r = httptest.NewRequest("POST", "http://127.0.0.1:18455/backend-api/codex/responses", strings.NewReader("broken"))
	r.Header.Set("Authorization", "Bearer token-two")
	r.Header.Set("Content-Encoding", "zstd")
	w = httptest.NewRecorder()
	g.ServeHTTP(w, r)
	if w.Code == 200 {
		t.Fatal("invalid zstd accepted")
	}
}

func TestActivityTraceCoversRetryAndTermination(t *testing.T) {
	var events []event
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("chatgpt-account-id") == "acct-one" {
			w.WriteHeader(429)
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, good)
	}))
	defer up.Close()
	g := newGateway(func() (config, error) { return pool(), nil }, up.URL, func(e event) { events = append(events, e) })
	ask(g, `{"input":"hi"}`)
	var kinds []string
	for _, e := range events {
		if e.Request == "" || e.Request != events[0].Request || e.Session != "test-session" {
			t.Fatalf("missing correlation: %+v", e)
		}
		kinds = append(kinds, e.Kind)
	}
	if strings.Join(kinds, ",") != "routing,refused,routing,completed,finished" {
		t.Fatal(kinds)
	}
	first := events[0].Request
	events = nil
	ask(g, `{"input":"next"}`)
	if events[0].Request == first || events[len(events)-1].Kind != "finished" {
		t.Fatal("request identity reused or not closed")
	}
}

// A menu-bar account click while routing only sets Preferred; it must not strand
// existing sealed conversations or block new ones when the chosen account is spent.
func TestPreferredKeepsSealedOwnerAndFallsBack(t *testing.T) {
	var seen []string
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen = append(seen, r.Header.Get("chatgpt-account-id"))
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, good)
	}))
	defer up.Close()
	c := pool()
	c.Preferred = "two"
	var events []event
	g := newGateway(func() (config, error) { return c, nil }, up.URL, func(e event) { events = append(events, e) })
	g.remember("test-session", "one")
	if w := ask(g, `{"input":[{"encrypted_content":"sealed"}]}`); w.Code != 200 || strings.Join(seen, ",") != "acct-one" {
		t.Fatalf("sealed conversation left its owner: %d %v", w.Code, seen)
	}
	seen = nil
	r := httptest.NewRequest("POST", "http://127.0.0.1:18455/v1/responses", strings.NewReader(`{"input":"hi"}`))
	r.Header.Set("Authorization", "Bearer "+pool().Key)
	r.Header.Set("session-id", "new-session")
	w := httptest.NewRecorder()
	g.ServeHTTP(w, r)
	if w.Code != 200 || strings.Join(seen, ",") != "acct-two" {
		t.Fatalf("new request ignored preferred account: %d %v", w.Code, seen)
	}
	seen = nil
	c.Accounts[1].Available = false
	r = httptest.NewRequest("POST", "http://127.0.0.1:18455/v1/responses", strings.NewReader(`{"input":"hi"}`))
	r.Header.Set("Authorization", "Bearer "+pool().Key)
	r.Header.Set("session-id", "another-session")
	w = httptest.NewRecorder()
	g.ServeHTTP(w, r)
	if w.Code != 200 || strings.Join(seen, ",") != "acct-one" {
		t.Fatalf("spent preferred account blocked new requests: %d %v", w.Code, seen)
	}
}

func TestUnknownStoredResponseOwnerNeverAssignedToPreferred(t *testing.T) {
	n := 0
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { n++; w.WriteHeader(200) }))
	defer up.Close()
	c := pool()
	c.Preferred = "two"
	var events []event
	g := newGateway(func() (config, error) { return c, nil }, up.URL, func(e event) { events = append(events, e) })
	if w := ask(g, `{"previous_response_id":"r1","input":[]}`); w.Code != 409 || n != 0 {
		t.Fatalf("stored response with unknown owner was forwarded: %d %d", w.Code, n)
	}
	if len(events) == 0 || events[0].Kind != "rejected" || events[0].Status != 409 || events[0].Reason != "sealed_owner_unknown" {
		t.Fatalf("rejection not recorded: %+v", events)
	}
}

func TestRejectionsAreRecordedWithReason(t *testing.T) {
	c := pool()
	c.Accounts[0].Available, c.Accounts[1].Available = false, false
	var events []event
	g := newGateway(func() (config, error) { return c, nil }, "http://127.0.0.1:1", func(e event) { events = append(events, e) })
	if w := ask(g, `{"input":"hi"}`); w.Code != 503 {
		t.Fatal(w.Code)
	}
	g.remember("test-session", "one")
	g.cool("one", time.Now().Add(time.Hour))
	if w := ask(g, `{"previous_response_id":"r1","input":[]}`); w.Code != 409 {
		t.Fatal(w.Code)
	}
	var got []string
	for _, e := range events {
		if e.Kind == "rejected" {
			got = append(got, fmt.Sprintf("%d:%s:%s", e.Status, e.Reason, e.Account))
		}
	}
	if strings.Join(got, ",") != "503:no_available_account:,409:sealed_owner_unavailable:one" {
		t.Fatal(got)
	}
}

func TestRouteNameKeepsOnlyShape(t *testing.T) {
	for path, want := range map[string]string{
		"/backend-api/codex/memories/trace_summarize":           "POST /backend-api/codex/memories/trace_summarize",
		"/backend-api/codex/files/file_9Xq2/content?sig=secret": "POST /backend-api/codex/files/:id/content",
		"/v1/Bearer.eyJhbGciOi/x":                               "POST /v1/:id/x",
		"/a/b/c/d/e/f/g/h":                                      "POST /a/b/c/d/e/f/...",
	} {
		r := httptest.NewRequest("POST", "http://127.0.0.1"+path, nil)
		if got := routeName(r); got != want {
			t.Errorf("%s: got %q want %q", path, got, want)
		}
	}
}

// Desktop logged in to B resumes a thread whose encrypted history B cannot read: B refuses it, the
// next account serves it and becomes the owner. The failed guess is never pinned.
func TestFailedOwnerGuessIsNotPinned(t *testing.T) {
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		if !strings.Contains(string(b), "sealed-"+r.Header.Get("chatgpt-account-id")) {
			w.WriteHeader(400)
			io.WriteString(w, `{"error":{"message":"The encrypted content could not be verified."}}`)
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, good)
	}))
	defer up.Close()
	g := newGateway(func() (config, error) { return pool(), nil }, up.URL, func(event) {})
	send := func(token, account string) int {
		r := httptest.NewRequest("POST", "http://127.0.0.1:18455/backend-api/codex/responses", strings.NewReader(`{"input":[{"encrypted_content":"sealed-acct-one"}]}`))
		r.Header.Set("Authorization", "Bearer "+token)
		r.Header.Set("chatgpt-account-id", account)
		r.Header.Set("session-id", "thread-from-one")
		w := httptest.NewRecorder()
		g.ServeHTTP(w, r)
		return w.Code
	}
	if code := send("token-two", "acct-two"); code != 200 {
		t.Fatalf("unreadable history did not move to the next account: %d", code)
	}
	if code := send("token-one", "acct-one"); code != 200 {
		t.Fatalf("thread stayed pinned to the failed guess: %d", code)
	}
	if code := send("token-two", "acct-two"); code != 200 {
		t.Fatalf("recorded owner not kept after success: %d", code)
	}
}

// Changing Preferred must not move a running conversation: its prompt cache lives on its account.
func TestOngoingConversationStaysBeforePreferred(t *testing.T) {
	c := pool()
	c.Preferred = "two"
	g := newGateway(func() (config, error) { return c, nil }, "", func(event) {})
	g.remember("running", "one")
	if xs, _ := g.candidates(c, "running", false, ""); len(xs) != 2 || xs[0].ID != "one" || xs[1].ID != "two" {
		t.Fatal("running conversation moved to preferred", xs)
	}
	if xs, _ := g.candidates(c, "fresh", false, ""); xs[0].ID != "two" {
		t.Fatal("new conversation ignored preferred", xs)
	}
	c.Accounts[0].Available = false
	if xs, _ := g.candidates(c, "running", false, ""); len(xs) != 1 || xs[0].ID != "two" {
		t.Fatal("unavailable owner not replaced by preferred", xs)
	}
}

func TestCompletedEventCarriesCachedTokens(t *testing.T) {
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, "data: {\"type\":\"response.output_text.delta\",\"delta\":\"ok\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":100,\"input_tokens_details\":{\"cached_tokens\":64},\"output_tokens\":1}}}\n\n")
	}))
	defer up.Close()
	var events []event
	g := newGateway(func() (config, error) { return pool(), nil }, up.URL, func(e event) { events = append(events, e) })
	ask(g, `{"input":"hi"}`)
	for _, e := range events {
		if e.Kind == "completed" {
			if e.Input != 100 || e.Cached != 64 {
				t.Fatal(e)
			}
			return
		}
	}
	t.Fatal("no completed event", events)
}

// The real backend sends SSE with no Content-Type; it must still stream and report usage.
func TestUntypedEventStreamStillStreams(t *testing.T) {
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header()["Content-Type"] = nil
		io.WriteString(w, "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"ok\"}\n\nevent: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":23313,\"input_tokens_details\":{\"cached_tokens\":23168},\"output_tokens\":6}}}\n\n")
	}))
	defer up.Close()
	var events []event
	g := newGateway(func() (config, error) { return pool(), nil }, up.URL, func(e event) { events = append(events, e) })
	w := ask(g, `{"input":"hi"}`)
	if w.Code != 200 || w.Header().Get("Content-Type") != "text/event-stream" || !strings.Contains(w.Body.String(), "response.completed") {
		t.Fatal(w.Code, w.Header(), w.Body.String())
	}
	for _, e := range events {
		if e.Kind == "completed" && e.Input == 23313 && e.Cached == 23168 {
			return
		}
	}
	t.Fatal("usage not recorded", events)
}

// The helper has no proxy environment variables; it must follow the Mac's own proxy settings.
func TestSystemProxyFollowsMacSettings(t *testing.T) {
	https := "<dictionary> {\n  HTTPEnable : 0\n  HTTPSEnable : 1\n  HTTPSPort : 7890\n  HTTPSProxy : 127.0.0.1\n}"
	if u := parseSystemProxy(https); u == nil || u.String() != "http://127.0.0.1:7890" {
		t.Fatal("https proxy", u)
	}
	socks := "<dictionary> {\n  SOCKSEnable : 1\n  SOCKSPort : 1080\n  SOCKSProxy : 10.0.0.2\n}"
	if u := parseSystemProxy(socks); u == nil || u.String() != "socks5://10.0.0.2:1080" {
		t.Fatal("socks proxy", u)
	}
	if u := parseSystemProxy("<dictionary> {\n  HTTPSEnable : 0\n  HTTPSProxy : 127.0.0.1\n  HTTPSPort : 7890\n}"); u != nil {
		t.Fatal("disabled proxy used", u)
	}
	reads := 0
	p := &systemProxy{read: func() string { reads++; return https }}
	r := httptest.NewRequest("POST", "https://chatgpt.com/backend-api/codex/responses", nil)
	for i := 0; i < 3; i++ {
		if u, _ := p.For(r); u == nil || u.Host != "127.0.0.1:7890" {
			t.Fatal("request not proxied", u)
		}
	}
	if reads != 1 {
		t.Fatal("settings re-read on every request", reads)
	}
	if u, _ := p.For(httptest.NewRequest("GET", "http://127.0.0.1:9/x", nil)); u != nil {
		t.Fatal("loopback sent through the proxy", u)
	}
}

// Automatic routing spends the quota that resets first; a chosen account and a running conversation still come first.
func TestNewConversationsUseTheEarliestReset(t *testing.T) {
	c := pool()
	c.Accounts[0].Reset, c.Accounts[1].Reset = 900, 300
	g := newGateway(func() (config, error) { return c, nil }, "", func(event) {})
	if xs, _ := g.candidates(c, "fresh", false, ""); xs[0].ID != "two" {
		t.Fatal("new conversation skipped the earliest reset", xs)
	}
	c.Accounts[1].Reset = 0
	if xs, _ := g.candidates(c, "fresh", false, ""); xs[0].ID != "one" {
		t.Fatal("unknown reset ranked before a known one", xs)
	}
	c.Accounts[1].Reset, c.Preferred = 300, "one"
	if xs, _ := g.candidates(c, "fresh", false, ""); xs[0].ID != "one" {
		t.Fatal("chosen account ignored", xs)
	}
}
