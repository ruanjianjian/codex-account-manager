package main

// The gateway as a resident service: launchd keeps it running whether Tibot runs or not, it never makes Codex
// worse than going without it, and Tibot watches it over a local event stream.

import (
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"
)

// A ChatGPT login as Codex sends its own: an access token that names its account. The gateway trusts it for
// nothing; it only hands it on to the service, which checks it, exactly as Codex would without the gateway.
func ownLogin(token string) bool {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return false
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return false
	}
	var claims struct {
		Auth struct {
			AccountID string `json:"chatgpt_account_id"`
		} `json:"https://api.openai.com/auth"`
	}
	return json.Unmarshal(payload, &claims) == nil && claims.Auth.AccountID != ""
}

// Only hop-by-hop headers stop at the gateway on a direct request: the client's login, cookies and encodings
// reach the service, and the service's answer reaches Codex, as if the gateway were not there.
var directOwned = headerSet("Host", "Proxy-Authorization")

// direct sends a Codex request to the service on Codex's own login and streams the answer back untouched.
// body nil: the client's body as it arrived (still encoded); otherwise the decoded body the gateway already read.
// slot: the connected account that login belongs to ("" unknown).
func (g *gateway) direct(w http.ResponseWriter, r *http.Request, path string, body []byte, reason, slot string) {
	started := time.Now()
	var reader io.Reader = r.Body
	if body != nil {
		reader = bytes.NewReader(body)
	}
	u := g.base + path
	if r.URL.RawQuery != "" {
		u += "?" + r.URL.RawQuery
	}
	q, err := http.NewRequestWithContext(r.Context(), r.Method, u, reader)
	if err != nil {
		fail(w, 502, "Cannot create upstream request.")
		return
	}
	copyHeader(q.Header, r.Header, directOwned)
	// A conversation the gateway routed to another account carries that account's turn state; this login never
	// issued it.
	if owner := g.owner(headerSession(r), ""); owner != "" && owner != slot {
		q.Header.Del("X-Codex-Turn-State")
	}
	if body != nil {
		q.Header.Del("Content-Encoding")
		q.ContentLength = int64(len(body))
	} else {
		q.ContentLength = r.ContentLength
	}
	// Only a reply stream starts at once; anything else gets the long wait Codex itself would give it.
	client := g.slow
	if path == "/responses" {
		client = g.client
	}
	res, err := client.Do(q)
	if err != nil {
		if r.Context().Err() == nil {
			g.unreachable(w, r, q, "", err, started)
		}
		return
	}
	defer res.Body.Close()
	g.emitRequest(r, event{Kind: "direct", Reason: reason, Status: res.StatusCode, MS: since(started)})
	copyHeader(w.Header(), res.Header, directOwned)
	w.Header().Del("Content-Length")
	w.WriteHeader(res.StatusCode)
	flusher, _ := w.(http.Flusher)
	buf := make([]byte, 32<<10)
	for {
		n, err := res.Body.Read(buf)
		if n > 0 {
			if _, werr := w.Write(buf[:n]); werr != nil {
				return
			}
			if flusher != nil {
				flusher.Flush()
			}
		}
		if err == io.EOF {
			return
		}
		if err != nil {
			if r.Context().Err() == nil {
				g.emitRequest(r, event{Kind: "interrupted", Reason: networkFault(err, g.proxied(q))})
			}
			// Cut the connection rather than end the reply cleanly: Codex must see that it is incomplete.
			panic(http.ErrAbortHandler)
		}
	}
}

func headerSession(r *http.Request) string {
	for _, h := range []string{"session-id", "thread-id", "x-codex-session-id"} {
		if v := r.Header.Get(h); v != "" {
			return v
		}
	}
	return ""
}

// The caller is Tibot: the pool's key, or the key file when the pool cannot be read.
func (g *gateway) isTibot(key string, c config, poolErr error) bool {
	want := c.Key
	if poolErr != nil || want == "" {
		if g.keyFile == "" {
			return false
		}
		b, err := readPrivate(g.keyFile)
		if err != nil {
			return false
		}
		want = strings.TrimSpace(string(b))
	}
	return len(want) >= 32 && subtle.ConstantTimeCompare([]byte(key), []byte(want)) == 1
}

// The request path's shared state still answers. Pings go out only after it, so a gateway whose requests hang
// stops pinging and Tibot restarts it.
func (g *gateway) probe() {
	g.mu.Lock()
	g.mu.Unlock()
	g.config()
}

// Tibot's subscribers to the events. A subscriber that falls behind loses events; nobody waits for it.
type hub struct {
	mu     sync.Mutex
	subs   map[chan event]struct{}
	closed bool
	done   chan struct{}
	once   sync.Once
}

func (h *hub) publish(e event) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.subs) == 0 {
		return
	}
	if e.Time == "" {
		e.Time = time.Now().UTC().Format(time.RFC3339)
	}
	for ch := range h.subs {
		select {
		case ch <- e:
		default:
		}
	}
}
func (h *hub) subscribe() (chan event, <-chan struct{}) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.done == nil {
		h.done = make(chan struct{})
	}
	ch := make(chan event, 256)
	if !h.closed {
		h.subs[ch] = struct{}{}
	}
	return ch, h.done
}
func (h *hub) unsubscribe(ch chan event) {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.subs, ch)
}

// Ends every event stream, so a shutting-down server is not held open by Tibot's connection.
func (h *hub) close() {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.closed = true
	if h.done == nil {
		h.done = make(chan struct{})
	}
	h.once.Do(func() { close(h.done) })
}

// How often an idle event stream says it is alive; Tibot treats a stream silent for much longer as a gateway
// that stopped answering.
var eventsPing = 15 * time.Second

// GET /tibot/events (Tibot only, with the pool key): one "data:" line per event, starting with "ready".
func (g *gateway) events(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		fail(w, 500, "Streaming unsupported.")
		return
	}
	ch, done := g.hub.subscribe()
	defer g.hub.unsubscribe(ch)
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(200)
	send := func(e event) bool {
		b, err := json.Marshal(e)
		if err == nil {
			_, err = fmt.Fprintf(w, "data: %s\n\n", b)
		}
		flusher.Flush()
		return err == nil
	}
	if !send(event{Kind: "ready", Time: time.Now().UTC().Format(time.RFC3339)}) {
		return
	}
	ping := time.NewTicker(eventsPing)
	defer ping.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case <-done:
			return
		case e := <-ch:
			if !send(e) {
				return
			}
		case <-ping.C:
			g.probe()
			if _, err := io.WriteString(w, ": ping\n\n"); err != nil {
				return
			}
			flusher.Flush()
		}
	}
}

// An update replaced the gateway's binary: stop once no Codex request is being served (at most 10 minutes
// later), so no reply is cut, and launchd starts the new binary at once.
func (g *gateway) drain(s *http.Server) {
	g.emit(event{Kind: "restarting"})
	s.SetKeepAlivesEnabled(false)
	deadline := time.Now().Add(drainLimit)
	for g.inflight.Load() > 0 && time.Now().Before(deadline) {
		time.Sleep(50 * time.Millisecond)
	}
	shutdown(s, g, 30*time.Second)
}

var drainLimit = 10 * time.Minute

// Stops taking connections, ends Tibot's event streams, and waits up to wait for every reply in flight to be
// written out (a request that arrived after the last check included).
func shutdown(s *http.Server, g *gateway, wait time.Duration) {
	g.hub.close()
	ctx, cancel := context.WithTimeout(context.Background(), wait)
	defer cancel()
	s.Shutdown(ctx)
}
