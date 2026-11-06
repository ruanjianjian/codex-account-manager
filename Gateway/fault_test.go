package main

import (
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"
)

func askAs(g *gateway, session, body string, header map[string]string) *httptest.ResponseRecorder {
	r := httptest.NewRequest("POST", "http://127.0.0.1:18455/v1/responses", strings.NewReader(body))
	r.Header.Set("Authorization", "Bearer "+pool().Key)
	r.Header.Set("session-id", session)
	for k, v := range header {
		r.Header.Set(k, v)
	}
	w := httptest.NewRecorder()
	g.ServeHTTP(w, r)
	return w
}

// 2026-11-03 13:38: the service failed one conversation on three accounts in a row; each one paused, and a
// healthy conversation on the first was pushed off it (cache 99% → 45%) and then refused with a 503. Now the
// failing conversation tries two accounts and gets the service's own answer; the other one stays put.
func TestOneConversationsFailureMovesNoOtherConversation(t *testing.T) {
	for _, mode := range []string{"http 502", "stream server_error"} {
		t.Run(mode, func(t *testing.T) {
			var mu sync.Mutex
			var bad, fine []string
			up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				body, _ := io.ReadAll(r.Body)
				w.Header().Set("Content-Type", "text/event-stream")
				mu.Lock()
				defer mu.Unlock()
				if strings.Contains(string(body), "broken") {
					bad = append(bad, r.Header.Get("chatgpt-account-id"))
					if mode == "http 502" {
						w.WriteHeader(502)
						io.WriteString(w, `{"error":{"message":"upstream hiccup"}}`)
						return
					}
					io.WriteString(w, "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"server_error\",\"message\":\"upstream hiccup\"}}}\n\n")
					return
				}
				fine = append(fine, r.Header.Get("chatgpt-account-id"))
				io.WriteString(w, good)
			}))
			defer up.Close()
			c := pool()
			c.Accounts = append(c.Accounts, account{ID: "three", AccountID: "acct-three", Access: "token-three", Expires: float64(time.Now().Unix() + 3600), Available: true, Reset: 3})
			g := newGateway(func() (config, error) { return c, nil }, up.URL, func(event) {})
			g.remember("healthy", "one")
			g.remember("failing", "one")
			for i := 0; i < 3; i++ { // Codex retrying the failed turn
				w := askAs(g, "failing", `{"input":"broken"}`, nil)
				if w.Code == 200 && mode == "http 502" || !strings.Contains(w.Body.String(), "upstream hiccup") {
					t.Fatalf("Codex did not get the service's own failure: %d %s", w.Code, w.Body)
				}
				if w := askAs(g, "healthy", `{"input":"fine"}`, nil); w.Code != 200 {
					t.Fatalf("healthy conversation refused: %d %s", w.Code, w.Body)
				}
			}
			if strings.Join(bad, ",") != "acct-one,acct-two,acct-one,acct-two,acct-one,acct-two" {
				t.Fatalf("failing conversation tried %v", bad)
			}
			if strings.Join(fine, ",") != "acct-one,acct-one,acct-one" {
				t.Fatalf("healthy conversation was moved: %v", fine)
			}
			if len(g.rest) != 0 {
				t.Fatalf("accounts paused for one conversation: %v", g.rest)
			}
		})
	}
}

// Three different conversations failing on one account within a minute, with nothing succeeding there, is the
// account's own trouble: it pauses briefly and new requests go elsewhere.
func TestThreeConversationsFailingPauseAnAccount(t *testing.T) {
	var mu sync.Mutex
	var seen []string
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		seen = append(seen, r.Header.Get("chatgpt-account-id"))
		mu.Unlock()
		w.Header().Set("Content-Type", "text/event-stream")
		if r.Header.Get("chatgpt-account-id") == "acct-one" {
			w.WriteHeader(500)
			return
		}
		io.WriteString(w, good)
	}))
	defer up.Close()
	g := newGateway(func() (config, error) { return pool(), nil }, up.URL, func(event) {})
	for _, s := range []string{"a", "b", "c"} {
		if w := askAs(g, s, `{"input":"hi"}`, nil); w.Code != 200 {
			t.Fatalf("%s: %d", s, w.Code)
		}
	}
	if !g.rest["one"].After(time.Now()) {
		t.Fatal("account failing for three conversations was not paused")
	}
	seen = nil
	askAs(g, "d", `{"input":"hi"}`, nil)
	if strings.Join(seen, ",") != "acct-two" {
		t.Fatalf("paused account still tried first: %v", seen)
	}
}

// The network fails the same way for every account: no account pauses, none is tried in its place, and Codex is
// told what failed instead of "every account declined".
func TestNetworkErrorEndsAtOnceWithoutPausing(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	dead := "http://" + ln.Addr().String()
	ln.Close()
	var events []event
	g := newGateway(func() (config, error) { return pool(), nil }, dead, func(e event) { events = append(events, e) })
	w := ask(g, `{"input":"hi"}`)
	if w.Code != 502 || !strings.Contains(w.Body.String(), "connection refused") || !strings.Contains(w.Body.String(), "not an account problem") {
		t.Fatalf("%d %s", w.Code, w.Body)
	}
	routed := 0
	for _, e := range events {
		if e.Kind == "routing" {
			routed++
		}
		if e.Kind == "network_error" && e.Reason != "refused" {
			t.Fatalf("network error category %q", e.Reason)
		}
	}
	if routed != 1 || len(g.rest) != 0 {
		t.Fatalf("tried %d accounts, paused %v", routed, g.rest)
	}
	// The next request goes straight out again: nothing waits on a pause.
	if w := ask(g, `{"input":"again"}`); w.Code != 502 || strings.Contains(w.Body.String(), "pausing") {
		t.Fatalf("second request: %d %s", w.Code, w.Body)
	}
}

func TestNetworkFaultWords(t *testing.T) {
	for _, c := range []struct {
		err     error
		proxied bool
		want    string
	}{
		{errText("net/http: timeout awaiting response headers"), true, "header_timeout"},
		{errText("remote error: tls: handshake failure"), false, "tls"},
		{errText("remote error: tls: handshake failure"), true, "proxy_tls"},
		{&net.DNSError{Err: "no such host", Name: "chatgpt.com"}, false, "dns"},
		{timeoutErr{}, true, "proxy_timeout"},
	} {
		if got := networkFault(c.err, c.proxied); got != c.want {
			t.Errorf("%v: %s, want %s", c.err, got, c.want)
		}
	}
}

// Through a real Go transport and a real proxy: the failures Go reports without saying a proxy was involved
// are still named as the proxy's, with no account paused and none tried in its place.
func TestProxyFailuresAreNamedAsTheProxys(t *testing.T) {
	refuse := func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(502) }
	drop := func(w http.ResponseWriter, r *http.Request) {
		conn, _, err := w.(http.Hijacker).Hijack()
		if err == nil {
			conn.Close()
		}
	}
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	dead := "http://" + ln.Addr().String()
	ln.Close()
	for _, c := range []struct {
		name, want, words string
		proxy             http.HandlerFunc
	}{
		{"refuses CONNECT", "proxy_upstream", "through the proxy: the proxy could not connect onward", refuse},
		{"drops CONNECT", "proxy_eof", "through the proxy: connection closed", drop},
		{"not running", "proxy_refused", "through the proxy: connection refused", nil},
	} {
		t.Run(c.name, func(t *testing.T) {
			address := dead
			if c.proxy != nil {
				p := httptest.NewServer(c.proxy)
				defer p.Close()
				address = p.URL
			}
			var events []event
			g := newGateway(func() (config, error) { return pool(), nil }, "https://chatgpt.invalid/backend-api/codex", func(e event) { events = append(events, e) })
			proxy, _ := url.Parse(address)
			g.client.Transport.(*http.Transport).Proxy = http.ProxyURL(proxy)
			w := ask(g, `{"input":"hi"}`)
			if w.Code != 502 || !strings.Contains(w.Body.String(), c.words) {
				t.Fatalf("%d %s", w.Code, w.Body)
			}
			routed, reason := 0, ""
			for _, e := range events {
				if e.Kind == "routing" {
					routed++
				}
				if e.Kind == "network_error" {
					reason = e.Reason
				}
			}
			if reason != c.want || routed != 1 || len(g.rest) != 0 {
				t.Fatalf("reason %q, tried %d, paused %v", reason, routed, g.rest)
			}
		})
	}
}

type timeoutErr struct{}

func (timeoutErr) Error() string   { return "i/o timeout" }
func (timeoutErr) Timeout() bool   { return true }
func (timeoutErr) Temporary() bool { return true }

type errText string

func (e errText) Error() string { return string(e) }

// A failure about the request itself reaches Codex as the service sent it, from the first account, so Codex
// can compact a context that is too long or explain a refused prompt; no account pauses.
func TestRequestFailuresReachCodexAsTheyAre(t *testing.T) {
	n := 0
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n++
		body, _ := io.ReadAll(r.Body)
		if strings.Contains(string(body), "http") {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(400)
			io.WriteString(w, `{"error":{"code":"invalid_value","message":"Unsupported parameter: foo"}}`)
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, "data: {\"type\":\"response.created\"}\n\ndata: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"context_length_exceeded\",\"message\":\"Your input exceeds the context window\"}}}\n\n")
	}))
	defer up.Close()
	var events []event
	g := newGateway(func() (config, error) { return pool(), nil }, up.URL, func(e event) { events = append(events, e) })
	w := ask(g, `{"input":"long"}`)
	if n != 1 || w.Code != 200 || !strings.Contains(w.Body.String(), "context_length_exceeded") || !strings.Contains(w.Body.String(), "response.created") {
		t.Fatalf("%d tries: %d %s", n, w.Code, w.Body)
	}
	if strings.Contains(w.Body.String(), "interrupted") {
		t.Fatal("a stream that ended with its own failure was reported as interrupted")
	}
	n = 0
	w = ask(g, `{"input":"http"}`)
	if n != 1 || w.Code != 400 || w.Body.String() != `{"error":{"code":"invalid_value","message":"Unsupported parameter: foo"}}` {
		t.Fatalf("%d tries: %d %s", n, w.Code, w.Body)
	}
	if len(g.rest) != 0 {
		t.Fatalf("paused for a request problem: %v", g.rest)
	}
	for _, e := range events {
		if e.Kind == "refused" && e.Status == 502 && e.Reason != "context_length_exceeded" {
			t.Fatalf("refusal reason %q", e.Reason)
		}
	}
}

// The account's own refusal inside a stream (its rate or usage limit) moves the request to the next account.
func TestAccountFailureInStreamMovesOn(t *testing.T) {
	var seen []string
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen = append(seen, r.Header.Get("chatgpt-account-id"))
		w.Header().Set("Content-Type", "text/event-stream")
		if r.Header.Get("chatgpt-account-id") == "acct-one" {
			io.WriteString(w, "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"usage_limit_reached\",\"resets_in_seconds\":3600}}}\n\n")
			return
		}
		io.WriteString(w, good)
	}))
	defer up.Close()
	g := newGateway(func() (config, error) { return pool(), nil }, up.URL, func(event) {})
	if w := ask(g, `{"input":"hi"}`); w.Code != 200 || !strings.Contains(w.Body.String(), "ok") {
		t.Fatalf("%d %s", w.Code, w.Body)
	}
	if strings.Join(seen, ",") != "acct-one,acct-two" || time.Until(g.limited["one"].until) < 59*time.Minute {
		t.Fatalf("tried %v, limit %v", seen, g.limited["one"])
	}
}

// Headers cross the gateway as they would without it, except the ones it owns.
func TestHeadersCrossBothWays(t *testing.T) {
	var got []http.Header
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = append(got, r.Header.Clone())
		if r.URL.Path == "/models" {
			if r.Header.Get("If-None-Match") == `"v1"` {
				w.Header().Set("ETag", `"v1"`)
				w.WriteHeader(304)
				return
			}
			w.Header().Set("ETag", `"v1"`)
			io.WriteString(w, `{"models":[]}`)
			return
		}
		h := w.Header()
		h.Set("Content-Type", "text/event-stream")
		h.Set("x-codex-primary-used-percent", "42")
		h.Set("x-codex-active-limit", "codex")
		h.Set("openai-model", "gpt-test")
		h.Set("x-models-etag", "etag-1")
		h.Set("x-reasoning-included", "true")
		h.Set("x-codex-turn-state", "turn-from-"+r.Header.Get("chatgpt-account-id"))
		h.Set("Set-Cookie", "__cf_bm=secret")
		io.WriteString(w, good)
	}))
	defer up.Close()
	c := pool()
	g := newGateway(func() (config, error) { return c, nil }, up.URL, func(event) {})
	client := map[string]string{"x-openai-subagent": "review", "x-codex-parent-thread-id": "parent-1", "x-client-request-id": "req-1",
		"originator": "Codex Desktop", "Cookie": "mine=1", "chatgpt-account-id": "acct-client", "x-codex-turn-state": "turn-from-acct-one"}
	w := askAs(g, "conv", `{"input":"hi"}`, client)
	if w.Code != 200 {
		t.Fatalf("%d %s", w.Code, w.Body)
	}
	for k, v := range map[string]string{"X-Codex-Primary-Used-Percent": "42", "X-Codex-Active-Limit": "codex", "Openai-Model": "gpt-test",
		"X-Models-Etag": "etag-1", "X-Reasoning-Included": "true", "X-Codex-Turn-State": "turn-from-acct-one", "Content-Type": "text/event-stream"} {
		if w.Header().Get(k) != v {
			t.Errorf("response header %s = %q, want %q", k, w.Header().Get(k), v)
		}
	}
	for _, k := range []string{"Set-Cookie"} {
		if w.Header().Get(k) != "" {
			t.Errorf("response header %s leaked", k)
		}
	}
	h := got[0]
	for k, v := range map[string]string{"X-Openai-Subagent": "review", "X-Codex-Parent-Thread-Id": "parent-1", "X-Client-Request-Id": "req-1",
		"Originator": "Codex Desktop", "Authorization": "Bearer token-one", "Chatgpt-Account-Id": "acct-one", "Cookie": ""} {
		if h.Get(k) != v {
			t.Errorf("upstream header %s = %q, want %q", k, h.Get(k), v)
		}
	}
	// A new conversation on a fresh account never carries another account's turn state.
	c.Preferred = "two"
	askAs(g, "new-conv", `{"input":"hi"}`, client)
	if h := got[1]; h.Get("Chatgpt-Account-Id") != "acct-two" || h.Get("X-Codex-Turn-State") != "" {
		t.Fatalf("turn state crossed accounts: %v", h)
	}
	// The model catalog keeps its etag, and an unchanged catalog is answered 304 rather than "unavailable".
	r := httptest.NewRequest("GET", "http://127.0.0.1:18455/backend-api/codex/models?client_version=1", nil)
	r.Header.Set("Authorization", "Bearer "+pool().Key)
	r.Header.Set("If-None-Match", `"v1"`)
	m := httptest.NewRecorder()
	g.ServeHTTP(m, r)
	if m.Code != 304 || m.Header().Get("ETag") != `"v1"` {
		t.Fatalf("models: %d %v", m.Code, m.Header())
	}
}

// The service fails the request on one account and the next refuses for its own limit: Codex gets the
// service's failure, not "every account declined, refresh your accounts".
func TestServiceFailureIsNotHiddenByALaterAccountRefusal(t *testing.T) {
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("chatgpt-account-id") == "acct-one" {
			w.WriteHeader(502)
			io.WriteString(w, `{"error":{"message":"upstream hiccup"}}`)
			return
		}
		w.WriteHeader(429)
		fmt.Fprintf(w, `{"error":{"type":"usage_limit_reached","resets_in_seconds":3600}}`)
	}))
	defer up.Close()
	g := newGateway(func() (config, error) { return pool(), nil }, up.URL, func(event) {})
	w := ask(g, `{"input":"hi"}`)
	if w.Code != 502 || !strings.Contains(w.Body.String(), "upstream hiccup") {
		t.Fatalf("%d %s", w.Code, w.Body)
	}
	if !g.limited["two"].until.After(time.Now()) || g.rest["one"].After(time.Now()) {
		t.Fatalf("limited %v, paused %v", g.limited, g.rest)
	}
}

// An empty reply is not an answer: the next account is tried, and the conversation is not bound to the empty one.
func TestAnEmptyReplyIsNotAnAnswer(t *testing.T) {
	var seen []string
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen = append(seen, r.Header.Get("chatgpt-account-id"))
		if r.Header.Get("chatgpt-account-id") == "acct-one" {
			return // 200, no Content-Type, no body
		}
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, good)
	}))
	defer up.Close()
	g := newGateway(func() (config, error) { return pool(), nil }, up.URL, func(event) {})
	w := ask(g, `{"input":"hi"}`)
	if w.Code != 200 || !strings.Contains(w.Body.String(), "ok") || strings.Join(seen, ",") != "acct-one,acct-two" || g.owner("test-session", "") != "two" {
		t.Fatalf("%d %s, tried %v, bound to %q", w.Code, w.Body, seen, g.owner("test-session", ""))
	}
}

// response.incomplete ends a stream as the service's own answer, after output or before it.
func TestAnIncompleteResponseIsAnAnswer(t *testing.T) {
	n := 0
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n++
		body, _ := io.ReadAll(r.Body)
		w.Header().Set("Content-Type", "text/event-stream")
		if strings.Contains(string(body), "after") {
			io.WriteString(w, "data: {\"type\":\"response.output_text.delta\",\"delta\":\"par\"}\n\n")
		}
		io.WriteString(w, "data: {\"type\":\"response.incomplete\",\"response\":{\"incomplete_details\":{\"reason\":\"content_filter\"}}}\n\n")
	}))
	defer up.Close()
	for _, input := range []string{"after", "before"} {
		n = 0
		var events []event
		g := newGateway(func() (config, error) { return pool(), nil }, up.URL, func(e event) { events = append(events, e) })
		w := ask(g, `{"input":"`+input+`"}`)
		if n != 1 || w.Code != 200 || !strings.Contains(w.Body.String(), "response.incomplete") || strings.Contains(w.Body.String(), "interrupted") {
			t.Fatalf("%s: %d tries, %d %s", input, n, w.Code, w.Body)
		}
		for _, e := range events {
			if e.Kind == "interrupted" || e.Kind == "refused" {
				t.Fatalf("%s: %+v", input, e)
			}
		}
	}
}
