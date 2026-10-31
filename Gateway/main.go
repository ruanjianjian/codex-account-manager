// Tibot's local gateway: routes Codex requests across the connected accounts.
// Independently implemented, Codex-only; no upstream source is vendored.
package main

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"github.com/klauspost/compress/zstd"
	"io"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
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
	Key       string           `json:"key"`
	Preferred string           `json:"preferred"`
	Accounts  []account        `json:"accounts"`
	Clients   []clientIdentity `json:"clients,omitempty"`
}
type event struct {
	Request string `json:"request,omitempty"`
	Session string `json:"session,omitempty"`
	Time    string `json:"time,omitempty"`
	Kind    string `json:"kind"`
	Account string `json:"account,omitempty"`
	Status  int    `json:"status,omitempty"`
	Reason  string `json:"reason,omitempty"`
	Route   string `json:"route,omitempty"`
	Input   int64  `json:"input,omitempty"`
	Cached  int64  `json:"cached,omitempty"`
	Output  int64  `json:"output,omitempty"`
}
type binding struct {
	ID    string
	Until time.Time
}
type gateway struct {
	native     *nativeAuth
	config     func() (config, error)
	base       string
	client     *http.Client
	emit       func(event)
	mu         sync.Mutex
	stickyFile string
	sticky     map[string]binding
	rest       map[string]time.Time
}

func newGateway(read func() (config, error), base string, emit func(event)) *gateway {
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.ResponseHeaderTimeout = 90 * time.Second
	tr.Proxy = newSystemProxy().For
	return &gateway{config: read, base: base, client: &http.Client{Transport: tr, CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }}, emit: emit, sticky: map[string]binding{}, rest: map[string]time.Time{}}
}

type requestTraceKey struct{}
type requestTrace struct{ id, session string }

var requestSequence atomic.Uint64

func (g *gateway) emitRequest(r *http.Request, e event) {
	if trace, ok := r.Context().Value(requestTraceKey{}).(requestTrace); ok {
		e.Request = trace.id
		e.Session = trace.session
	}
	g.emit(e)
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

// Route shape only, for diagnostics: no query string, and any segment that could be an
// identifier (digits, long, or unusual characters) becomes ":id".
func routeName(r *http.Request) string {
	parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	if len(parts) > 6 {
		parts = append(parts[:6], "...")
	}
	for i, p := range parts {
		if p == "..." {
			continue
		}
		version := len(p) == 2 && p[0] == 'v' && p[1] >= '0' && p[1] <= '9'
		if !version && (len(p) > 32 || strings.IndexFunc(p, func(c rune) bool { return !(c == '_' || c == '-' || c >= 'a' && c <= 'z') }) >= 0) {
			parts[i] = ":id"
		}
	}
	method := r.Method
	if len(method) > 8 || strings.IndexFunc(method, func(c rune) bool { return c < 'A' || c > 'Z' }) >= 0 {
		method = "OTHER"
	}
	return method + " /" + strings.Join(parts, "/")
}
func (g *gateway) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// Every gateway-side refusal is recorded with a fixed reason; upstream refusals emit "refused".
	reject := func(status int, reason, account, msg string) {
		e := event{Kind: "rejected", Status: status, Reason: reason, Account: account}
		if reason == "unsupported_route" {
			e.Route = routeName(r)
		}
		g.emitRequest(r, e)
		fail(w, status, msg)
	}
	c, err := g.config()
	if err != nil {
		reject(503, "pool_unavailable", "", "Account pool unavailable; refresh accounts in the menu-bar app.")
		return
	}
	host := r.Host
	if h, _, e := net.SplitHostPort(host); e == nil {
		host = h
	}
	ip := net.ParseIP(host)
	if (host != "localhost" && (ip == nil || !ip.IsLoopback())) || r.Header.Get("Origin") != "" || r.Header.Get("Sec-Fetch-Site") != "" {
		reject(403, "non_local_client", "", "Local non-browser clients only.")
		return
	}
	authorization := r.Header.Get("Authorization")
	if !strings.HasPrefix(authorization, "Bearer ") || len(authorization) <= 7 {
		fail(w, 401, "Invalid local gateway key.")
		return
	}
	key := strings.TrimPrefix(authorization, "Bearer ")
	nativeAccount := ""
	if g.native != nil {
		var authErr error
		c, nativeAccount, authErr = g.native.authenticate(c, key, r.Header.Get("chatgpt-account-id"))
		if authErr != nil {
			g.emit(event{Kind: "local_auth_unavailable", Status: 503})
			fail(w, 503, "Local credential registry unavailable; check account manager diagnostics.")
			return
		}
	}
	for _, a := range c.Accounts {
		if a.Expires > float64(time.Now().Unix()) && len(a.Access) > 0 && subtle.ConstantTimeCompare([]byte(key), []byte(a.Access)) == 1 {
			if id := r.Header.Get("chatgpt-account-id"); id != "" && id != a.AccountID {
				continue
			}
			nativeAccount = a.ID
			break
		}
	}
	if nativeAccount == "" && subtle.ConstantTimeCompare([]byte(key), []byte(c.Key)) != 1 {
		g.emit(event{Kind: "local_auth_rejected", Status: 401})
		fail(w, 401, "Invalid local gateway key.")
		return
	}
	if r.URL.Path == "/health" && r.Method == "GET" {
		w.Header().Set("Content-Type", "application/json")
		io.WriteString(w, `{"ready":true}`)
		return
	}
	path := strings.TrimPrefix(strings.TrimPrefix(r.URL.Path, "/backend-api/codex"), "/v1")
	if path == "/responses" && strings.EqualFold(r.Header.Get("Upgrade"), "websocket") {
		// Expected on every turn: the client falls back to HTTP. Not a refusal worth recording.
		fail(w, http.StatusUpgradeRequired, "Use HTTP Responses streaming.")
		return
	}
	if r.Method == "GET" && path == "/models" {
		g.models(w, r, c)
		return
	}
	if r.Method != "POST" || (path != "/responses" && path != "/responses/compact") {
		reject(404, "unsupported_route", "", "Unsupported gateway route.")
		return
	}
	compressed := http.MaxBytesReader(w, r.Body, 32<<20)
	var reader io.Reader = compressed
	switch strings.ToLower(r.Header.Get("Content-Encoding")) {
	case "", "identity":
	case "zstd":
		decoder, e := zstd.NewReader(compressed, zstd.WithDecoderMaxMemory(64<<20), zstd.WithDecoderConcurrency(1))
		if e != nil {
			reject(400, "invalid_body", "", "Invalid compressed request.")
			return
		}
		defer decoder.Close()
		reader = decoder
	case "gzip":
		decoder, e := gzip.NewReader(compressed)
		if e != nil {
			reject(400, "invalid_body", "", "Invalid compressed request.")
			return
		}
		defer decoder.Close()
		reader = decoder
	default:
		reject(415, "invalid_body", "", "Unsupported request encoding.")
		return
	}
	body, err := io.ReadAll(io.LimitReader(reader, (32<<20)+1))
	if len(body) > 32<<20 {
		reject(413, "invalid_body", "", "Decoded request too large.")
		return
	}
	if err != nil {
		reject(413, "invalid_body", "", "Request too large.")
		return
	}
	var obj map[string]json.RawMessage
	if json.Unmarshal(body, &obj) != nil || obj == nil {
		reject(400, "invalid_body", "", "Expected JSON object.")
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
	r = r.WithContext(context.WithValue(r.Context(), requestTraceKey{}, requestTrace{
		id: fmt.Sprintf("%d-%d", time.Now().UnixNano(), requestSequence.Add(1)), session: session,
	}))
	defer func() { g.emitRequest(r, event{Kind: "finished"}) }()
	// A stored previous response lives on one account's server; it can only continue there.
	pinned := len(obj["previous_response_id"]) > 0
	// Encrypted history (reasoning, compaction) is readable by other accounts too (verified with real
	// accounts on 2026-10-29), so it only prefers its owner and moves when the owner is unavailable.
	sealed := pinned || path == "/responses/compact" || bytes.Contains(body, []byte(`"encrypted_content"`)) || bytes.Contains(body, []byte(`"encrypted_function_args"`))
	// A sealed thread the gateway never served most likely began on the account the desktop is
	// logged in to (old direct threads), so that account goes first for its prompt cache. Only a
	// successful reply records the owner, so a wrong guess is not pinned.
	guess := ""
	if session != "" && sealed {
		guess = nativeAccount
	}
	candidates, stuck := g.candidates(c, session, pinned, guess)
	switch {
	case stuck == "sealed_owner_unknown":
		reject(409, stuck, "", "This conversation continues a response stored on an unknown account; it was not sent to another account. Start a new conversation.")
		return
	case stuck != "":
		owner := g.owner(session, guess)
		reject(409, stuck, owner, "This conversation continues a response stored on account "+owner+", which is unavailable now (quota, cooldown or expired login). Wait for it to recover or start a new conversation.")
		return
	case len(candidates) == 0:
		reject(503, "no_available_account", "", "No available account. Refresh or reconnect accounts in Codex Accounts.")
		return
	}
	for _, a := range candidates {
		if r.Context().Err() != nil {
			return
		}
		req, err := g.request(r, path, body, a)
		if err != nil {
			reject(502, "upstream_request_error", a.ID, "Cannot create upstream request.")
			return
		}
		g.emitRequest(r, event{Kind: "routing", Account: a.ID, Session: session})
		res, err := g.client.Do(req)
		if err != nil {
			if r.Context().Err() != nil {
				return
			}
			g.emitRequest(r, event{Kind: "network_error", Account: a.ID})
			g.cool(a.ID, time.Now().Add(15*time.Second))
			continue
		}
		if res.StatusCode < 200 || res.StatusCode >= 300 {
			b, _ := io.ReadAll(io.LimitReader(res.Body, 1<<20))
			res.Body.Close()
			g.emitRequest(r, event{Kind: "refused", Account: a.ID, Status: res.StatusCode, Session: session})
			if retryable(res.StatusCode) {
				g.cool(a.ID, retryAt(res.Header, b))
				continue
			}
			// An account that cannot read this conversation's encrypted history is not at fault; the next one may.
			if sealed && res.StatusCode == 400 && bytes.Contains(b, []byte("encrypted")) {
				continue
			}
			fail(w, res.StatusCode, "Upstream rejected the request; account "+a.ID+". No retry was made.")
			return
		}
		reply := bufio.NewReaderSize(res.Body, 64<<10)
		if !eventStream(res.Header.Get("Content-Type"), reply) {
			b, e := io.ReadAll(io.LimitReader(reply, 32<<20))
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
			g.emitRequest(r, event{Kind: "completed", Account: a.ID, Session: session})
			return
		}
		committed, retry := g.stream(w, r, reply, a, session)
		res.Body.Close()
		if committed {
			return
		}
		if !retry {
			fail(w, 502, "Upstream stream failed before output.")
			return
		}
	}
	reject(503, "all_accounts_declined", "", "All available accounts declined this request. Refresh accounts or wait for quota reset.")
}

// The Codex backend streams SSE without a Content-Type header, so the first bytes decide too.
func eventStream(contentType string, body *bufio.Reader) bool {
	if strings.Contains(contentType, "text/event-stream") {
		return true
	}
	if contentType != "" {
		return false
	}
	head, _ := body.Peek(6)
	return bytes.HasPrefix(head, []byte("event:")) || bytes.HasPrefix(head, []byte("data:")) || bytes.HasPrefix(head, []byte(":"))
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

// Returns the accounts to try in order, or why a pinned conversation cannot be served.
func (g *gateway) candidates(c config, session string, pinned bool, guess string) ([]account, string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	now := time.Now()
	old := g.sticky[session]
	if old.Until.Before(now) {
		old = binding{}
	}
	if old.ID == "" {
		old.ID = guess
	}
	// Without a recorded owner, a stored response cannot be assigned, not even to Preferred.
	if pinned && old.ID == "" {
		return nil, "sealed_owner_unknown"
	}
	var out []account
	for _, a := range c.Accounts {
		if a.Access == "" || a.Expires <= float64(now.Unix()+30) || g.rest[a.ID].After(now) {
			continue
		}
		// A stored response stays with its owner, even when another account is preferred or quota looks spent.
		if pinned {
			if a.ID == old.ID {
				out = append(out, a)
			}
			continue
		}
		if a.Available {
			out = append(out, a)
		}
	}
	// A conversation stays on its own account so its prompt cache survives; Preferred orders
	// new conversations and takes over only when that account is unavailable.
	rank := func(a account) int {
		switch a.ID {
		case old.ID:
			return 0
		case c.Preferred:
			return 1
		}
		return 2
	}
	sort.SliceStable(out, func(i, j int) bool {
		if ri, rj := rank(out[i]), rank(out[j]); ri != rj {
			return ri < rj
		}
		return out[i].Reset > 0 && (out[j].Reset == 0 || out[i].Reset < out[j].Reset)
	})
	if pinned && len(out) == 0 {
		return nil, "sealed_owner_unavailable"
	}
	return out, ""
}
func (g *gateway) owner(session, guess string) string {
	g.mu.Lock()
	defer g.mu.Unlock()
	if b := g.sticky[session]; b.ID != "" && b.Until.After(time.Now()) {
		return b.ID
	}
	return guess
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
	g.sticky[session] = binding{ID: id, Until: time.Now().Add(365 * 24 * time.Hour)}
	if g.stickyFile != "" {
		if data, err := json.Marshal(g.sticky); err == nil {
			temp := g.stickyFile + ".tmp"
			if os.WriteFile(temp, data, 0600) == nil {
				os.Rename(temp, g.stickyFile)
			}
		}
	}
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
func (g *gateway) stream(w http.ResponseWriter, r *http.Request, reader *bufio.Reader, a account, session string) (bool, bool) {
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
						Input        int64 `json:"input_tokens"`
						InputDetails struct {
							Cached int64 `json:"cached_tokens"`
						} `json:"input_tokens_details"`
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
						g.emitRequest(r, event{Kind: "completed", Account: a.ID, Input: v.Response.Usage.Input, Cached: v.Response.Usage.InputDetails.Cached, Output: v.Response.Usage.Output})
					}
				}
			}
			if failed && !committed {
				g.cool(a.ID, time.Now().Add(time.Minute))
				g.emitRequest(r, event{Kind: "refused", Account: a.ID, Status: 502})
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
				g.emitRequest(r, event{Kind: "interrupted", Account: a.ID})
				io.WriteString(w, "event: error\ndata: {\"type\":\"error\",\"error\":{\"message\":\"Upstream stream interrupted; not replayed to avoid duplicate tool execution.\"}}\n\n")
			}
			return committed, !committed
		}
	}
}

// eventSink hands each event to the app (stdout) and to the private log, never on the request's own goroutine:
// when the app stops reading or the log stalls, events are dropped instead of freezing every Codex request
// (2026-10-31: one event write stalled under the old shared lock for an hour, and no request got past its first event).
func eventSink(app io.Writer, logPath string) func(event) {
	toApp, toLog := make(chan event, 512), make(chan event, 512)
	go func() {
		out := json.NewEncoder(app)
		for e := range toApp {
			out.Encode(e)
		}
	}()
	go func() {
		for e := range toLog {
			appendLog(logPath, e)
		}
	}()
	return func(e event) {
		e.Time = time.Now().UTC().Format(time.RFC3339)
		select {
		case toApp <- e:
		default:
		}
		select {
		case toLog <- e:
		default:
		}
	}
}

// Bounded private diagnostics: no tokens, prompts, response bodies or tool arguments.
func appendLog(p string, e event) {
	if st, err := os.Lstat(p); err == nil {
		if !st.Mode().IsRegular() {
			return
		}
		if st.Size() > 2<<20 {
			os.Rename(p, p+".previous")
		}
	}
	if f, err := os.OpenFile(p, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600); err == nil {
		json.NewEncoder(f).Encode(e)
		f.Close()
	}
}

func main() {
	path := flag.String("config", "", "private pool configuration")
	addr := flag.String("listen", "127.0.0.1:18455", "loopback listener")
	desktopAuth := flag.String("desktop-auth", "", "trusted local desktop auth file (never a request parameter)")
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
	emit := eventSink(os.Stdout, filepath.Join(filepath.Dir(*path), "requests.jsonl"))
	g := newGateway(func() (config, error) { return readConfig(*path) }, upstream, emit)
	if *desktopAuth != "" {
		g.native = &nativeAuth{path: *desktopAuth, cache: filepath.Join(filepath.Dir(*path), "client-auth-hashes.json")}
		c, err := readConfig(*path)
		if err == nil {
			err = g.native.validateDesktop(c)
		}
		if err == nil {
			_, _, err = g.native.authenticate(c, "", "")
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, "local credential registry unavailable")
			os.Exit(1)
		}
	}
	g.stickyFile = filepath.Join(filepath.Dir(*path), "session-accounts.json")
	if st, err := os.Lstat(g.stickyFile); err == nil && st.Mode().IsRegular() && st.Mode().Perm()&0077 == 0 && st.Size() < 1<<20 {
		if data, err := os.ReadFile(g.stickyFile); err == nil {
			var saved map[string]binding
			if json.Unmarshal(data, &saved) == nil && saved != nil {
				g.sticky = saved
			}
		}
	}
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
