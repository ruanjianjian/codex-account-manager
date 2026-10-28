package main

import (
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
	if len(xs) != 1 || xs[0].ID != "two" {
		t.Fatal(xs)
	}
	c.Accounts[1].Expires = 1
	xs, _ = g.candidates(c, "", false)
	if len(xs) != 0 {
		t.Fatal("expired token used")
	}
}
