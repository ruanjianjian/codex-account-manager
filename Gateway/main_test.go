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
func TestBoundHistoryCannotMove(t *testing.T) {
	n := 0
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { n++; w.WriteHeader(429) }))
	defer up.Close()
	g := newGateway(func() (config, error) { return pool(), nil }, up.URL, func(event) {})
	w := ask(g, `{"input":[{"encrypted_content":"sealed"}]}`)
	if w.Code != 409 || n != 0 {
		t.Fatal("unknown sealed history was forwarded")
	}
	g.remember("test-session", "one")
	ask(g, `{"previous_response_id":"r1","input":[]}`)
	if n != 1 {
		t.Fatalf("bound request tried %d accounts", n)
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
	xs, _ := g.candidates(c, "", false)
	if len(xs) != 2 || xs[0].ID != "two" || xs[1].ID != "one" {
		t.Fatal(xs)
	}
	c.Accounts[1].Expires = 1
	xs, _ = g.candidates(c, "", false)
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
	g := newGateway(func() (config, error) { c := pool(); c.Accounts[1].Available = false; return c, nil }, up.URL, func(event) {})
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

func TestUnknownSealedOwnerNeverAssignedToPreferred(t *testing.T) {
	n := 0
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { n++; w.WriteHeader(200) }))
	defer up.Close()
	c := pool()
	c.Preferred = "two"
	var events []event
	g := newGateway(func() (config, error) { return c, nil }, up.URL, func(e event) { events = append(events, e) })
	if w := ask(g, `{"input":[{"encrypted_content":"sealed"}]}`); w.Code != 409 || n != 0 {
		t.Fatalf("sealed history with unknown owner was forwarded: %d %d", w.Code, n)
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
	if w := ask(g, `{"input":[{"encrypted_content":"sealed"}]}`); w.Code != 409 {
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
