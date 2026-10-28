// Codex Accounts gateway. Routing design inspired by yetone/magpie (MIT).
// Independently implemented, Codex-only; no upstream source is vendored.
package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const upstream = "https://chatgpt.com/backend-api/codex"

type account struct {
	ID        string  `json:"id"`
	AccountID string  `json:"accountID"`
	Access    string  `json:"access"`
	Expires   float64 `json:"expires"`
	Available bool    `json:"available"`
	Reset     float64 `json:"reset"`
}
type config struct {
	Key       string    `json:"key"`
	Preferred string    `json:"preferred"`
	Accounts  []account `json:"accounts"`
}
type event struct {
	Kind    string `json:"kind"`
	Account string `json:"account,omitempty"`
	Status  int    `json:"status,omitempty"`
	Input   int64  `json:"input,omitempty"`
	Output  int64  `json:"output,omitempty"`
}
type binding struct {
	ID    string
	Until time.Time
}
type gateway struct {
	config func() (config, error)
	base   string
	client *http.Client
	emit   func(event)
	mu     sync.Mutex
	sticky map[string]binding
	rest   map[string]time.Time
}

func newGateway(read func() (config, error), base string, emit func(event)) *gateway {
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.ResponseHeaderTimeout = 90 * time.Second
	return &gateway{config: read, base: base, client: &http.Client{Transport: tr, CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }}, emit: emit, sticky: map[string]binding{}, rest: map[string]time.Time{}}
}
func readConfig(path string) (config, error) {
	var c config
	st, err := os.Lstat(path)
	if err != nil {
		return c, err
	}
	if !st.Mode().IsRegular() || st.Mode().Perm()&0077 != 0 {
		return c, errors.New("insecure gateway configuration")
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return c, err
	}
	if len(b) > 2<<20 {
		return c, errors.New("configuration too large")
	}
	err = json.Unmarshal(b, &c)
	if len(c.Key) < 32 {
		return c, errors.New("missing local key")
	}
	return c, err
}
func fail(w http.ResponseWriter, status int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]any{"error": map[string]string{"message": msg, "type": "gateway_error"}})
}
func (g *gateway) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	c, err := g.config()
	if err != nil {
		fail(w, 503, "Account pool unavailable; refresh accounts in the menu-bar app.")
		return
	}
	host := r.Host
	if h, _, e := net.SplitHostPort(host); e == nil {
		host = h
	}
	ip := net.ParseIP(host)
	if (host != "localhost" && (ip == nil || !ip.IsLoopback())) || r.Header.Get("Origin") != "" || r.Header.Get("Sec-Fetch-Site") != "" {
		fail(w, 403, "Local non-browser clients only.")
		return
	}
	key := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	if subtle.ConstantTimeCompare([]byte(key), []byte(c.Key)) != 1 {
		fail(w, 401, "Invalid local gateway key.")
		return
	}
	if r.URL.Path == "/health" && r.Method == "GET" {
		w.Header().Set("Content-Type", "application/json")
		io.WriteString(w, `{"ready":true}`)
		return
	}
	path := strings.TrimPrefix(strings.TrimPrefix(r.URL.Path, "/backend-api/codex"), "/v1")
	if r.Method == "GET" && path == "/models" {
		g.models(w, r, c)
		return
	}
	if r.Method != "POST" || (path != "/responses" && path != "/responses/compact") {
		fail(w, 404, "Unsupported gateway route.")
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 32<<20))
	if err != nil {
		fail(w, 413, "Request too large.")
		return
	}
	var obj map[string]json.RawMessage
	if json.Unmarshal(body, &obj) != nil || obj == nil {
		fail(w, 400, "Expected JSON object.")
		return
	}
	// Codex subscriptions require ephemeral Responses and streaming.
	if path == "/responses" {
		obj["store"] = json.RawMessage("false")
		obj["stream"] = json.RawMessage("true")
		delete(obj, "max_output_tokens")
		delete(obj, "temperature")
		body, _ = json.Marshal(obj)
	}
	session := r.Header.Get("session-id")
	if session == "" {
		session = r.Header.Get("thread-id")
	}
	if session == "" {
		json.Unmarshal(obj["prompt_cache_key"], &session)
	}
	if session == "" {
		session = r.Header.Get("x-codex-session-id")
	}
	// Account-bound server state must never be silently stripped to enable fallback.
	bound := bytes.Contains(body, []byte(`"encrypted_content"`)) || bytes.Contains(body, []byte(`"encrypted_function_args"`)) || len(obj["previous_response_id"]) > 0 || path == "/responses/compact"
	candidates, stuck := g.candidates(c, session, bound)
	if stuck {
		fail(w, 409, "This conversation contains account-bound state. Keep its account or start a new conversation to use another account.")
		return
	}
	if len(candidates) == 0 {
		fail(w, 503, "No available account. Refresh or reconnect accounts in Codex Accounts.")
		return
	}
	for _, a := range candidates {
		if r.Context().Err() != nil {
			return
		}
		req, err := g.request(r, path, body, a)
		if err != nil {
			fail(w, 502, "Cannot create upstream request.")
			return
		}
		g.emit(event{Kind: "routing", Account: a.ID})
		res, err := g.client.Do(req)
		if err != nil {
			if r.Context().Err() != nil {
				return
			}
			g.emit(event{Kind: "network_error", Account: a.ID})
			g.cool(a.ID, time.Now().Add(15*time.Second))
			continue
		}
		if res.StatusCode < 200 || res.StatusCode >= 300 {
			b, _ := io.ReadAll(io.LimitReader(res.Body, 1<<20))
			res.Body.Close()
			g.emit(event{Kind: "refused", Account: a.ID, Status: res.StatusCode})
			if retryable(res.StatusCode) {
				g.cool(a.ID, retryAt(res.Header, b))
				continue
			}
			fail(w, res.StatusCode, "Upstream rejected the request; account "+a.ID+". No retry was made.")
			return
		}
		if !strings.Contains(res.Header.Get("Content-Type"), "text/event-stream") {
			b, e := io.ReadAll(io.LimitReader(res.Body, 32<<20))
			res.Body.Close()
			if e != nil {
				fail(w, 502, "Upstream reply interrupted.")
				return
			}
			w.Header().Set("Content-Type", "application/json")
			w.Header().Set("X-Codex-Accounts-Slot", a.ID)
			w.WriteHeader(res.StatusCode)
			w.Write(b)
			g.remember(session, a.ID)
			g.emit(event{Kind: "completed", Account: a.ID})
			return
		}
		committed, retry := g.stream(w, r, res, a, session)
		res.Body.Close()
		if committed {
			return
		}
		if !retry {
			fail(w, 502, "Upstream stream failed before output.")
			return
		}
	}
	fail(w, 503, "All available accounts declined this request. Refresh accounts or wait for quota reset.")
}
func retryable(code int) bool { return code == 401 || code == 403 || code == 429 || code >= 500 }
func retryAt(h http.Header, b []byte) time.Time {
	seconds := 60.0
	if n, e := strconv.ParseFloat(h.Get("Retry-After"), 64); e == nil && n > 0 {
		seconds = n
	} else if t, e := http.ParseTime(h.Get("Retry-After")); e == nil {
		return t
	}
	var obj struct {
		Error struct {
			ResetsIn float64 `json:"resets_in_seconds"`
			ResetsAt float64 `json:"resets_at"`
		} `json:"error"`
	}
	if json.Unmarshal(b, &obj) == nil {
		if obj.Error.ResetsIn > 0 {
			seconds = obj.Error.ResetsIn
		}
		if obj.Error.ResetsAt > float64(time.Now().Unix()) {
			return time.Unix(int64(obj.Error.ResetsAt), 0)
		}
	}
	if seconds > 7*86400 {
		seconds = 7 * 86400
	}
	return time.Now().Add(time.Duration(seconds * float64(time.Second)))
}
func (g *gateway) candidates(c config, session string, bound bool) ([]account, bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	now := time.Now()
	old := g.sticky[session]
	if old.Until.Before(now) {
		old = binding{}
	}
	var out []account
	for _, a := range c.Accounts {
		if c.Preferred != "" && a.ID != c.Preferred {
			continue
		}
		if a.Access == "" || a.Expires <= float64(now.Unix()+30) || !a.Available || g.rest[a.ID].After(now) {
			continue
		}
		if bound && old.ID != "" && old.ID != a.ID {
			continue
		}
		out = append(out, a)
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].ID == old.ID {
			return true
		}
		if out[j].ID == old.ID {
			return false
		}
		return out[i].Reset > 0 && (out[j].Reset == 0 || out[i].Reset < out[j].Reset)
	})
	// Without a recorded owner, legacy sealed histories cannot safely be assigned.
	if bound && old.ID == "" && c.Preferred == "" {
		return nil, true
	}
	return out, bound && len(out) == 0
}
func (g *gateway) remember(session, id string) {
	if session == "" {
		return
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	if len(g.sticky) > 2048 {
		for k, v := range g.sticky {
			if v.Until.Before(time.Now()) {
				delete(g.sticky, k)
			}
		}
	}
	g.sticky[session] = binding{ID: id, Until: time.Now().Add(24 * time.Hour)}
}
func (g *gateway) cool(id string, until time.Time) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.rest[id] = until
}
func (g *gateway) request(r *http.Request, path string, body []byte, a account) (*http.Request, error) {
	u := g.base + path
	if path == "/models" && r.URL.RawQuery != "" {
		u += "?" + r.URL.RawQuery
	}
	q, e := http.NewRequestWithContext(r.Context(), r.Method, u, bytes.NewReader(body))
	if e != nil {
		return nil, e
	}
	for _, k := range []string{"session-id", "thread-id", "x-codex-turn-state", "x-codex-turn-metadata", "x-codex-window-id", "version", "User-Agent", "OpenAI-Beta", "x-codex-beta-features"} {
		if v := r.Header.Get(k); v != "" {
			q.Header.Set(k, v)
		}
	}
	q.Header.Set("Authorization", "Bearer "+a.Access)
	q.Header.Set("chatgpt-account-id", a.AccountID)
	q.Header.Set("originator", "codex_cli_rs")
	q.Header.Set("Content-Type", "application/json")
	q.Header.Set("Accept", "text/event-stream")
	if q.Header.Get("User-Agent") == "" {
		q.Header.Set("User-Agent", "codex_cli_rs/0.165.0")
	}
	return q, nil
}
func (g *gateway) models(w http.ResponseWriter, r *http.Request, c config) {
	for _, a := range c.Accounts {
		if a.Access == "" || a.Expires <= float64(time.Now().Unix()) {
			continue
		}
		q, e := g.request(r, "/models", nil, a)
		if e != nil {
			continue
		}
		res, e := g.client.Do(q)
		if e != nil {
			continue
		}
		b, e := io.ReadAll(io.LimitReader(res.Body, 8<<20))
		res.Body.Close()
		if e == nil && res.StatusCode == 200 {
			w.Header().Set("Content-Type", "application/json")
			w.Write(b)
			return
		}
	}
	fail(w, 503, "Model catalog unavailable.")
}

// Buffer only the prelude, never replay a stream after text or a tool call escaped.
func (g *gateway) stream(w http.ResponseWriter, r *http.Request, res *http.Response, a account, session string) (bool, bool) {
	reader := bufio.NewReaderSize(res.Body, 64<<10)
	var pre bytes.Buffer
	committed := false
	completed := false
	for {
		line, err := reader.ReadBytes('\n')
		if len(line) > 0 {
			content := false
			failed := false
			var v struct {
				Type     string `json:"type"`
				Response struct {
					Usage struct {
						Input  int64 `json:"input_tokens"`
						Output int64 `json:"output_tokens"`
					} `json:"usage"`
				} `json:"response"`
			}
			if bytes.HasPrefix(line, []byte("data:")) {
				data := bytes.TrimSpace(line[5:])
				if json.Unmarshal(data, &v) == nil {
					failed = v.Type == "error" || v.Type == "response.failed"
					content = strings.Contains(v.Type, "delta") || strings.Contains(v.Type, "output_item") || v.Type == "response.completed"
					if v.Type == "response.completed" {
						completed = true
						g.emit(event{Kind: "completed", Account: a.ID, Input: v.Response.Usage.Input, Output: v.Response.Usage.Output})
					}
				}
			}
			if failed && !committed {
				g.cool(a.ID, time.Now().Add(time.Minute))
				g.emit(event{Kind: "refused", Account: a.ID, Status: 502})
				return false, true
			}
			if !committed {
				pre.Write(line)
				if content || pre.Len() > 256<<10 {
					committed = true
					g.remember(session, a.ID)
					w.Header().Set("Content-Type", "text/event-stream")
					w.Header().Set("Cache-Control", "no-cache")
					w.Header().Set("X-Codex-Accounts-Slot", a.ID)
					w.WriteHeader(200)
					if _, e := w.Write(pre.Bytes()); e != nil {
						return true, false
					}
					pre.Reset()
				}
			} else {
				if _, e := w.Write(line); e != nil {
					return true, false
				}
			}
			if committed {
				if f, ok := w.(http.Flusher); ok {
					f.Flush()
				}
			}
		}
		if err != nil {
			if committed && !completed && r.Context().Err() == nil {
				g.emit(event{Kind: "interrupted", Account: a.ID})
				io.WriteString(w, "event: error\ndata: {\"type\":\"error\",\"error\":{\"message\":\"Upstream stream interrupted; not replayed to avoid duplicate tool execution.\"}}\n\n")
			}
			return committed, !committed
		}
	}
}
func main() {
	path := flag.String("config", "", "private pool configuration")
	addr := flag.String("listen", "127.0.0.1:18455", "loopback listener")
	flag.Parse()
	host, _, e := net.SplitHostPort(*addr)
	if e != nil || net.ParseIP(host) == nil || !net.ParseIP(host).IsLoopback() {
		fmt.Fprintln(os.Stderr, "loopback address required")
		os.Exit(1)
	}
	if _, e = readConfig(*path); e != nil {
		fmt.Fprintln(os.Stderr, "gateway configuration unavailable")
		os.Exit(1)
	}
	var output sync.Mutex
	emit := func(e event) { output.Lock(); defer output.Unlock(); json.NewEncoder(os.Stdout).Encode(e) }
	g := newGateway(func() (config, error) { return readConfig(*path) }, upstream, emit)
	ln, e := net.Listen("tcp", *addr)
	if e != nil {
		fmt.Fprintln(os.Stderr, "gateway port is already occupied")
		os.Exit(1)
	}
	s := &http.Server{Handler: g, ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 60 * time.Second}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		c, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		s.Shutdown(c)
	}()
	emit(event{Kind: "ready"})
	if e = s.Serve(ln); e != nil && e != http.ErrServerClosed {
		os.Exit(1)
	}
}
