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

// Inline screenshots can exceed 32 MiB well before Codex's token-based
// compaction threshold. Keep transport and decoded bodies bounded, while
// allowing these histories through both responses and responses/compact.
const maxRequestBodyBytes = 128 << 20

type account struct {
	ID        string  `json:"id"`
	AccountID string  `json:"accountID"`
	Access    string  `json:"access"`
	Expires   float64 `json:"expires"`
	Available bool    `json:"available"`
	Reset     float64 `json:"reset"`
	// Under Tibot's reserve line: used only when no account with more left can take the request.
	Low bool `json:"low"`
	// When every spent window of an unavailable account has reset (Unix seconds; 0 unknown). Past it the account
	// is tried again even if Tibot, not running, never wrote that it came back.
	Back float64 `json:"back,omitempty"`
}

// The account can take new requests by its quota as last reported.
func (a account) usable(now time.Time) bool {
	return a.Available || (a.Back > 0 && float64(now.Unix()) >= a.Back)
}

type config struct {
	Key       string `json:"key"`
	Preferred string `json:"preferred"`
	// Routing is switched off in Tibot: Codex's own login goes straight to the service, as without Tibot.
	Off      bool             `json:"off,omitempty"`
	Accounts []account        `json:"accounts"`
	Clients  []clientIdentity `json:"clients,omitempty"`
	// When Tibot wrote the pool (zero: unknown). Tibot rewrites it every few seconds while it runs.
	written time.Time
}

// Tibot has not written the pool for a while: it is not running, and the quota it last reported may be old.
func (c config) stale(now time.Time) bool {
	return !c.written.IsZero() && now.Sub(c.written) > 10*time.Minute
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
	// How long the upstream attempt took, for refusals and network errors.
	MS int64 `json:"ms,omitempty"`
}
type binding struct {
	ID    string
	Until time.Time
}
type gateway struct {
	native *nativeAuth
	config func() (config, error)
	base   string
	client *http.Client
	// Remote compaction: the service reads the whole conversation before its first byte.
	slow *http.Client
	sink func(event)
	// Tibot's live view of the events (GET /tibot/events).
	hub hub
	// Codex requests being served, so a restart for an update waits for none.
	inflight atomic.Int64
	// Set by main: POST /tibot/restart asks for a restart once no request is being served.
	onRestart func()
	// Tibot's key on disk, for Tibot's endpoints when the pool cannot be read.
	keyFile    string
	mu         sync.Mutex
	stickyFile string
	sticky     map[string]binding
	// Wakes the writer of stickyFile; nothing is written to disk while a request holds mu.
	stickyWake  chan struct{}
	stickyWrite sync.Mutex
	rest        map[string]time.Time
	limited     map[string]limit
	strikes     map[string][]strike
}

// One conversation the service failed on an account (a 5xx, or a stream that failed before any output).
type strike struct {
	conversation string
	at           time.Time
}

// Why an account did not answer a request.
type fault int

const (
	faultNone     fault = iota
	faultAccount        // the account's own refusal: its login, its quota or its rate limit; it pauses
	faultUpstream       // the service had a moment; another account may get through, nobody pauses
	faultRequest        // the request itself; every account would answer the same, so Codex gets the answer
)

// A request the service fails is tried on one more account at most, then Codex gets the failure and retries on
// its own: trying every account turned one bad moment into minutes of waiting.
const maxUpstreamTries = 2

// An account the server refused for its usage limit. A different quota reset from Tibot afterwards
// means its quota came back early (a banked reset, a reset for everyone), so it is used again at once.
type limit struct {
	until time.Time
	reset float64
}

func newGateway(read func() (config, error), base string, emit func(event)) *gateway {
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.ResponseHeaderTimeout = 90 * time.Second
	tr.Proxy = newSystemProxy().For
	slow := tr.Clone()
	slow.ResponseHeaderTimeout = 5 * time.Minute
	noRedirect := func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }
	return &gateway{config: read, base: base, sink: emit, hub: hub{subs: map[chan event]struct{}{}},
		client: &http.Client{Transport: tr, CheckRedirect: noRedirect}, slow: &http.Client{Transport: slow, CheckRedirect: noRedirect},
		sticky: map[string]binding{}, stickyWake: make(chan struct{}, 1), rest: map[string]time.Time{}, limited: map[string]limit{}, strikes: map[string][]strike{}}
}

func (g *gateway) emit(e event) {
	if g.sink != nil {
		g.sink(e)
	}
	g.hub.publish(e)
}

// The client for a route: remote compaction may think for minutes before its first byte.
func (g *gateway) clientFor(path string) *http.Client {
	if path == "/responses/compact" {
		return g.slow
	}
	return g.client
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
	c.written = st.ModTime()
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
	path := strings.TrimPrefix(strings.TrimPrefix(r.URL.Path, "/backend-api/codex"), "/v1")
	if strings.EqualFold(r.Header.Get("Upgrade"), "websocket") {
		// Expected on every turn: Codex falls back to HTTP at once. Before anything goes direct: a WebSocket cannot
		// be passed on, and stripped to a plain GET it costs Codex seconds of reconnect attempts.
		fail(w, http.StatusUpgradeRequired, "Use HTTP Responses streaming.")
		return
	}
	// The gateway's own endpoints, for Tibot; everything else is a Codex request.
	local := strings.HasPrefix(r.URL.Path, "/tibot/") || r.URL.Path == "/health"
	if !local {
		g.inflight.Add(1)
		defer g.inflight.Add(-1)
	}
	// Codex signed in with its own ChatGPT login can always be served as if Tibot were not there: whenever the
	// gateway cannot help (no pool, routing off, a login Tibot does not know, a route it does not handle), the
	// request goes straight to the service with that login. Codex never stops because of Tibot.
	nativeAccount := "" // the connected account the caller's own login belongs to, once known
	direct := func(reason string) bool {
		if local || !ownLogin(key) {
			return false
		}
		g.direct(w, r, path, nil, reason, nativeAccount)
		return true
	}
	c, err := g.config()
	if strings.HasPrefix(r.URL.Path, "/tibot/") {
		// Tibot's own endpoints work with an unreadable pool too, so Tibot never takes a gateway that is serving
		// Codex for a dead one.
		switch {
		case !g.isTibot(key, c, err):
			fail(w, 401, "Invalid local gateway key.")
		case r.URL.Path == "/tibot/events" && r.Method == "GET":
			g.events(w, r)
		case r.URL.Path == "/tibot/restart" && r.Method == "POST":
			if g.onRestart != nil {
				g.onRestart()
			}
			w.WriteHeader(http.StatusAccepted)
		default:
			fail(w, 404, "Unsupported gateway route.")
		}
		return
	}
	if err != nil {
		if !direct("pool_unavailable") {
			reject(503, "pool_unavailable", "", "Account pool unavailable; open Tibot so it can write it again.")
		}
		return
	}
	poolKey := subtle.ConstantTimeCompare([]byte(key), []byte(c.Key)) == 1
	if g.native != nil && !poolKey {
		c, nativeAccount = g.native.authenticate(c, key, r.Header.Get("chatgpt-account-id"))
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
	if nativeAccount == "" && !poolKey {
		// A login Tibot has not connected (or one it cannot check now): Codex still works, on that login.
		if direct("unknown_login") {
			return
		}
		g.emit(event{Kind: "local_auth_rejected", Status: 401})
		fail(w, 401, "Invalid local gateway key.")
		return
	}
	if r.URL.Path == "/health" && r.Method == "GET" {
		w.Header().Set("Content-Type", "application/json")
		io.WriteString(w, `{"ready":true}`)
		return
	}
	if c.Off && direct("routing_off") {
		return
	}
	if r.Method == "GET" && path == "/models" {
		if !g.models(w, r, c) && !direct("models_unavailable") {
			fail(w, 503, "Model catalog unavailable.")
		}
		return
	}
	if r.Method != "POST" || (path != "/responses" && path != "/responses/compact") {
		if !direct("route") {
			reject(404, "unsupported_route", "", "Unsupported gateway route.")
		}
		return
	}
	compressed := http.MaxBytesReader(w, r.Body, maxRequestBodyBytes)
	var reader io.Reader = compressed
	switch strings.ToLower(r.Header.Get("Content-Encoding")) {
	case "", "identity":
	case "zstd":
		decoder, e := zstd.NewReader(compressed, zstd.WithDecoderMaxMemory(maxRequestBodyBytes), zstd.WithDecoderConcurrency(1))
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
	body, err := io.ReadAll(io.LimitReader(reader, maxRequestBodyBytes+1))
	if len(body) > maxRequestBodyBytes {
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
	candidates, stuck := g.candidates(c, session, pinned, guess, nativeAccount)
	switch {
	case stuck == "sealed_owner_unknown":
		reject(409, stuck, "", "This conversation continues a response stored on an unknown account; it was not sent to another account. Start a new conversation.")
		return
	case stuck != "":
		owner := g.owner(session, guess)
		reject(409, stuck, owner, "This conversation continues a response stored on account "+owner+", which is unavailable now (quota, cooldown or expired login). Wait for it to recover or start a new conversation.")
		return
	case len(candidates) == 0:
		v := g.verdict(c, "no_available_account", "No available account. Refresh or reconnect accounts in Tibot.")
		// Nothing in the pool can sign in, or the pool's quota is old news (Tibot is not running to say an account
		// came back): Codex's own login can still try, and the service says whether it may.
		if (v.reason == "no_accounts" || v.reason == "logins_expired" || v.reason == "usage_limit" && c.stale(time.Now())) && !poolKey && ownLogin(key) {
			reason := v.reason
			if reason == "usage_limit" {
				reason = "pool_stale"
			}
			g.direct(w, r, path, body, reason, nativeAccount)
			return
		}
		g.refuse(w, r, v)
		return
	}
	owner := g.owner(session, guess)
	upstreamFaults := 0
	// The service's own failure of this request, for Codex when no later account answers either: it says what
	// happened, where "every account declined" would send the user to refresh accounts that were fine.
	var pending func()
	for i, a := range candidates {
		if r.Context().Err() != nil {
			return
		}
		// The last chance to answer: no account is left, or the service already failed this request elsewhere.
		last := i == len(candidates)-1 || upstreamFaults+1 >= maxUpstreamTries
		req, err := g.request(r, path, body, a, a.ID == owner)
		if err != nil {
			reject(502, "upstream_request_error", a.ID, "Cannot create upstream request.")
			return
		}
		g.emitRequest(r, event{Kind: "routing", Account: a.ID, Session: session})
		started := time.Now()
		res, err := g.clientFor(path).Do(req)
		if err != nil {
			if r.Context().Err() != nil {
				return
			}
			// Every account goes through this Mac's network and proxy, so none would get through and none is
			// at fault: Codex hears it at once, with what failed, and retries on its own.
			g.unreachable(w, r, req, a.ID, err, started)
			return
		}
		if res.StatusCode < 200 || res.StatusCode >= 300 {
			b, _ := io.ReadAll(io.LimitReader(res.Body, 1<<20))
			res.Body.Close()
			g.emitRequest(r, event{Kind: "refused", Account: a.ID, Status: res.StatusCode, Session: session, MS: since(started)})
			switch statusFault(res.StatusCode) {
			case faultAccount:
				until := retryAt(res.Header, b)
				g.cool(a.ID, until)
				if res.StatusCode == 429 {
					g.limit(a, until)
				}
				continue
			case faultUpstream:
				upstreamFaults++
				g.strike(a.ID, conversation(r))
				if !last {
					pending = func() { relay(w, res, b, a.ID) }
					continue
				}
			default:
				// An account that cannot read this conversation's encrypted history is not at fault; the next one may.
				if sealed && res.StatusCode == 400 && bytes.Contains(b, []byte("encrypted")) && !last {
					continue
				}
			}
			relay(w, res, b, a.ID)
			return
		}
		reply := bufio.NewReaderSize(res.Body, 64<<10)
		var done bool
		var f fault
		if eventStream(res.Header.Get("Content-Type"), reply) {
			done, f = g.stream(w, r, reply, res, a, session, last, started)
		} else if b, e := io.ReadAll(io.LimitReader(reply, 32<<20)); e != nil {
			done = r.Context().Err() != nil || g.unreachable(w, r, req, a.ID, e, started)
		} else if len(b) == 0 {
			done, f = g.closedEarly(w, r, a, last, started), faultUpstream
		} else {
			g.remember(session, a.ID)
			relay(w, res, b, a.ID)
			g.emitRequest(r, event{Kind: "completed", Account: a.ID, Session: session})
			done = true
		}
		res.Body.Close()
		if done {
			return
		}
		if f == faultUpstream {
			upstreamFaults++
			pending = func() { fail(w, 502, "The Codex service failed this request before any output; retry in Codex.") }
		}
	}
	if pending != nil {
		pending()
		return
	}
	g.refuse(w, r, g.verdict(c, "all_accounts_declined", "All available accounts declined this request. Refresh accounts in Tibot or wait for a quota reset."))
}

// Why no account can take a request, worded for Codex to show. When every signed-in account is out
// of quota, or was just refused for its usage limit, the answer is the usage-limit error Codex knows:
// it shows "You've hit your usage limit. Try again at …" and stops, where a 503 had it retry dozens
// of times and then print a hint to reconnect accounts that were fine.
type verdict struct {
	status int
	reason string
	until  time.Time // when the first account comes back (429) or the soonest pause ends (503)
	msg    string
}

func (g *gateway) verdict(c config, reason, msg string) verdict {
	g.mu.Lock()
	defer g.mu.Unlock()
	now := time.Now()
	signedIn, limited := 0, 0
	var back, retry time.Time
	soonest := func(t *time.Time, v time.Time) {
		if v.After(now) && (t.IsZero() || v.Before(*t)) {
			*t = v
		}
	}
	for _, a := range c.Accounts {
		if a.Access == "" || a.Expires <= float64(now.Unix()+30) {
			continue
		}
		signedIn++
		switch {
		case g.limited[a.ID].until.After(now):
			limited++
			soonest(&back, g.limited[a.ID].until)
		case !a.usable(now):
			limited++
			if a.Back > 0 {
				soonest(&back, time.Unix(int64(a.Back), 0))
			} else {
				soonest(&back, time.Unix(int64(a.Reset), 0))
			}
		case g.rest[a.ID].After(now):
			soonest(&retry, g.rest[a.ID])
		default: // usable, yet it declined this request
			return verdict{status: 503, reason: reason, msg: msg}
		}
	}
	switch {
	case len(c.Accounts) == 0:
		return verdict{status: 503, reason: "no_accounts", msg: "No account is connected to Tibot. Connect one in Tibot."}
	case signedIn == 0:
		return verdict{status: 503, reason: "logins_expired", msg: "Every account's login has expired. Open Tibot so it can renew them, or reconnect the accounts."}
	case limited == signedIn:
		v := verdict{status: 429, reason: "usage_limit", until: back, msg: "Every account in Tibot has hit its usage limit."}
		if !back.IsZero() {
			v.msg += " The first one comes back at " + back.Local().Format("Jan 2 15:04") + "."
		}
		return v
	}
	return verdict{status: 503, reason: "accounts_cooling", until: retry, msg: "Every account is pausing after an upstream error; retry in a moment."}
}

func (g *gateway) refuse(w http.ResponseWriter, r *http.Request, v verdict) {
	g.emitRequest(r, event{Kind: "rejected", Status: v.status, Reason: v.reason})
	if v.status != 429 {
		if !v.until.IsZero() {
			w.Header().Set("Retry-After", strconv.Itoa(int(time.Until(v.until).Seconds())+1))
		}
		fail(w, v.status, v.msg)
		return
	}
	body := map[string]any{"type": "usage_limit_reached", "message": v.msg}
	if !v.until.IsZero() {
		body["resets_at"] = v.until.Unix()
		body["resets_in_seconds"] = int64(time.Until(v.until).Seconds())
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(429)
	json.NewEncoder(w).Encode(map[string]any{"error": body})
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
func statusFault(code int) fault {
	switch {
	case code == 401 || code == 403 || code == 429:
		return faultAccount
	case code >= 500:
		return faultUpstream
	}
	return faultRequest
}

// The error codes a stream can fail with before any output. Codes about the request (context too long, a flagged
// prompt) reach Codex as they are: it compacts, explains or retries by itself, and no account would do better.
func codeFault(code string) fault {
	switch code {
	case "insufficient_quota", "usage_limit_reached", "usage_not_included", "rate_limit_exceeded":
		return faultAccount
	case "", "server_error", "server_is_overloaded", "slow_down":
		return faultUpstream
	}
	return faultRequest
}

// Only fixed words reach the diagnostics log.
func safeCode(code string) string {
	if code == "" {
		return "no_code"
	}
	if len(code) > 48 || strings.IndexFunc(code, func(c rune) bool { return !(c == '_' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9') }) >= 0 {
		return "other"
	}
	return code
}

// Hop-by-hop headers and the ones the gateway itself sets never cross it. Everything else does: the service sees
// the client's own headers (subagent, parent thread, request id, originator) and Codex sees the service's (its
// rate limits, model, models etag, turn state), as without the gateway.
var requestOwned = headerSet("Authorization", "Chatgpt-Account-Id", "Content-Length", "Content-Encoding", "Accept-Encoding",
	"Host", "Cookie", "Origin", "Proxy-Authorization")
var responseOwned = headerSet("Content-Length", "Content-Encoding", "Set-Cookie")

func headerSet(names ...string) map[string]bool {
	set := map[string]bool{}
	for _, n := range append(names, "Connection", "Keep-Alive", "Proxy-Connection", "Te", "Trailer", "Transfer-Encoding", "Upgrade") {
		set[http.CanonicalHeaderKey(n)] = true
	}
	return set
}
func copyHeader(dst, src http.Header, owned map[string]bool) {
	named := map[string]bool{}
	for _, v := range src.Values("Connection") {
		for _, n := range strings.Split(v, ",") {
			named[http.CanonicalHeaderKey(strings.TrimSpace(n))] = true
		}
	}
	for k, vs := range src {
		k = http.CanonicalHeaderKey(k)
		if owned[k] || named[k] || strings.HasPrefix(k, "Sec-Fetch-") {
			continue
		}
		dst[k] = append([]string(nil), vs...)
	}
}

// Codex gets the service's own answer: its status, headers and body, which it knows how to show and retry.
func relay(w http.ResponseWriter, res *http.Response, body []byte, slot string) {
	copyHeader(w.Header(), res.Header, responseOwned)
	if w.Header().Get("Content-Type") == "" && bytes.HasPrefix(bytes.TrimSpace(body), []byte("{")) {
		w.Header().Set("Content-Type", "application/json")
	}
	w.Header().Set("X-Codex-Accounts-Slot", slot)
	w.WriteHeader(res.StatusCode)
	w.Write(body)
}

func since(t time.Time) int64 { return time.Since(t).Milliseconds() }

// The conversation a request belongs to, for counting how many conversations failed on an account.
func conversation(r *http.Request) string {
	if trace, ok := r.Context().Value(requestTraceKey{}).(requestTrace); ok {
		if trace.session != "" {
			return trace.session
		}
		return trace.id
	}
	return ""
}

// What failed on the way to the service, as a fixed word for the log (the error text itself names hosts and ports).
// proxied: the request went through a proxy. Go reports a proxy that refused CONNECT, dropped it or timed out
// with a bare status text, EOF or deadline, without saying a proxy was involved.
func networkFault(err error, proxied bool) string {
	s := err.Error()
	via := ""
	if proxied || strings.Contains(s, "proxyconnect") || strings.Contains(s, "socks connect") {
		via = "proxy_"
	}
	var dns *net.DNSError
	var ne net.Error
	switch {
	case strings.Contains(s, "timeout awaiting response headers"):
		return "header_timeout"
	case via != "" && (strings.HasSuffix(s, "Bad Gateway") || strings.HasSuffix(s, "Gateway Timeout") || strings.HasSuffix(s, "Service Unavailable")):
		return "proxy_upstream"
	case errors.As(err, &dns):
		return via + "dns"
	case errors.Is(err, syscall.ECONNREFUSED):
		return via + "refused"
	case errors.Is(err, syscall.ECONNRESET), errors.Is(err, syscall.EPIPE):
		return via + "reset"
	case strings.Contains(s, "tls:") || strings.Contains(s, "x509:"):
		return via + "tls"
	case errors.As(err, &ne) && ne.Timeout():
		return via + "timeout"
	case errors.Is(err, io.EOF), errors.Is(err, io.ErrUnexpectedEOF):
		return via + "eof"
	}
	return via + "other"
}

var networkWords = map[string]string{
	"header_timeout": "no reply in time", "upstream": "the proxy could not connect onward",
	"dns": "name lookup failed", "refused": "connection refused", "reset": "connection reset",
	"tls": "secure connection failed", "timeout": "connection timed out", "eof": "connection closed",
}

// A network failure ends the request at once, with no account paused and none tried in its place. Always
// answers Codex, so it returns true for the caller's done.
func (g *gateway) unreachable(w http.ResponseWriter, r *http.Request, upstream *http.Request, id string, err error, started time.Time) bool {
	reason := networkFault(err, g.proxied(upstream))
	g.emitRequest(r, event{Kind: "network_error", Account: id, Reason: reason, MS: since(started)})
	what := networkWords[strings.TrimPrefix(reason, "proxy_")]
	if what == "" {
		what = "network error"
	}
	where := ""
	if strings.HasPrefix(reason, "proxy_") {
		where = " through the proxy"
	}
	fail(w, 502, "Cannot reach the Codex service"+where+": "+what+". Check the network or proxy; this is not an account problem, and Tibot changed no account.")
	return true
}

// Whether the upstream request goes through a proxy (the environment's, or the Mac's network settings).
func (g *gateway) proxied(upstream *http.Request) bool {
	tr, ok := g.client.Transport.(*http.Transport)
	if !ok || tr.Proxy == nil || upstream == nil {
		return false
	}
	u, err := tr.Proxy(upstream)
	return err == nil && u != nil
}

// The service closed the reply before any output: its moment, not the account's. Returns done when this was
// the last try and Codex got the failure.
func (g *gateway) closedEarly(w http.ResponseWriter, r *http.Request, a account, last bool, started time.Time) bool {
	g.emitRequest(r, event{Kind: "refused", Account: a.ID, Status: 502, Reason: "closed_before_output", MS: since(started)})
	g.strike(a.ID, conversation(r))
	if last {
		fail(w, 502, "The Codex service closed the reply before any output; retry in Codex.")
	}
	return last
}

// Pauses an account for the service's own failures only when three conversations failed on it within a minute
// and nothing succeeded on it since: one bad request, or one conversation's retries, never pushes the other
// conversations off their accounts (and their prompt caches).
func (g *gateway) strike(id, conversation string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	now := time.Now()
	kept := []strike{{conversation, now}}
	seen := map[string]bool{conversation: true}
	for _, s := range g.strikes[id] {
		if now.Sub(s.at) < time.Minute && len(kept) < 16 {
			kept = append(kept, s)
			seen[s.conversation] = true
		}
	}
	if len(seen) >= 3 {
		g.rest[id] = now.Add(30 * time.Second)
		delete(g.strikes, id)
		return
	}
	g.strikes[id] = kept
}
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

// Returns the accounts to try in order, or why a pinned conversation cannot be served. native is the
// account whose login the client presented.
func (g *gateway) candidates(c config, session string, pinned bool, guess, native string) ([]account, string) {
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
		if l, ok := g.limited[a.ID]; ok && a.Available && a.Reset != l.reset {
			delete(g.limited, a.ID)
			delete(g.rest, a.ID)
		}
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
		if a.usable(now) {
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
	// An account nearly out goes behind every account with more left, even for a conversation it owns
	// or when it is preferred: running it to empty fails the turn that hits the limit. Among those, the
	// client's own login goes last, since Codex locks its composer when that account is out.
	reserve := func(a account) int {
		switch {
		case !a.Low:
			return 0
		case a.ID != native:
			return 1
		}
		return 2
	}
	sort.SliceStable(out, func(i, j int) bool {
		if ri, rj := reserve(out[i]), reserve(out[j]); ri != rj {
			return ri < rj
		}
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
	g.mu.Lock()
	defer g.mu.Unlock()
	delete(g.strikes, id) // it answered: the failures before were the service's moment, not this account
	if session == "" {
		return
	}
	if len(g.sticky) > 2048 {
		for k, v := range g.sticky {
			if v.Until.Before(time.Now()) {
				delete(g.sticky, k)
			}
		}
	}
	g.sticky[session] = binding{ID: id, Until: time.Now().Add(365 * 24 * time.Hour)}
	select {
	case g.stickyWake <- struct{}{}:
	default:
	}
}

// Writes the conversations' owners to disk off the request path, at most once a second: a disk that stalls
// must not hold the lock every request needs (2026-10-31: one stalled write froze every Codex request).
func (g *gateway) keepSticky() {
	for range g.stickyWake {
		time.Sleep(time.Second)
		g.saveSticky()
	}
}
func (g *gateway) saveSticky() {
	if g.stickyFile == "" {
		return
	}
	g.mu.Lock()
	data, err := json.Marshal(g.sticky)
	g.mu.Unlock()
	if err != nil {
		return
	}
	g.stickyWrite.Lock()
	defer g.stickyWrite.Unlock()
	temp := g.stickyFile + ".tmp"
	if os.WriteFile(temp, data, 0600) == nil {
		os.Rename(temp, g.stickyFile)
	}
}
func (g *gateway) cool(id string, until time.Time) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.rest[id] = until
}
func (g *gateway) limit(a account, until time.Time) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.limited[a.ID] = limit{until: until, reset: a.Reset}
}

// owner: the account is the one this conversation was last served by. The service's turn state belongs to the
// account that issued it, so it goes along only there.
func (g *gateway) request(r *http.Request, path string, body []byte, a account, owner bool) (*http.Request, error) {
	u := g.base + path
	if path == "/models" && r.URL.RawQuery != "" {
		u += "?" + r.URL.RawQuery
	}
	q, e := http.NewRequestWithContext(r.Context(), r.Method, u, bytes.NewReader(body))
	if e != nil {
		return nil, e
	}
	copyHeader(q.Header, r.Header, requestOwned)
	if !owner {
		q.Header.Del("X-Codex-Turn-State")
	}
	q.Header.Set("Authorization", "Bearer "+a.Access)
	q.Header.Set("chatgpt-account-id", a.AccountID)
	if q.Header.Get("originator") == "" {
		q.Header.Set("originator", "codex_cli_rs")
	}
	if r.Method == "POST" {
		q.Header.Set("Content-Type", "application/json")
		q.Header.Set("Accept", "text/event-stream")
	}
	if q.Header.Get("User-Agent") == "" {
		q.Header.Set("User-Agent", "codex_cli_rs/0.165.0")
	}
	return q, nil
}

// The model catalog from the first account that answers; false when none did and nothing was written.
func (g *gateway) models(w http.ResponseWriter, r *http.Request, c config) bool {
	for _, a := range c.Accounts {
		if a.Access == "" || a.Expires <= float64(time.Now().Unix()) {
			continue
		}
		q, e := g.request(r, "/models", nil, a, false)
		if e != nil {
			continue
		}
		res, e := g.client.Do(q)
		if e != nil {
			continue
		}
		b, e := io.ReadAll(io.LimitReader(res.Body, 8<<20))
		res.Body.Close()
		// 304: the catalog Codex holds (its If-None-Match etag) is still current.
		if e == nil && (res.StatusCode == 200 || res.StatusCode == 304) {
			relay(w, res, b, a.ID)
			return true
		}
	}
	return false
}

type streamEvent struct {
	Type     string          `json:"type"`
	Code     string          `json:"code"`
	Error    json.RawMessage `json:"error"`
	Response struct {
		Error json.RawMessage `json:"error"`
		Usage struct {
			Input        int64 `json:"input_tokens"`
			InputDetails struct {
				Cached int64 `json:"cached_tokens"`
			} `json:"input_tokens_details"`
			Output int64 `json:"output_tokens"`
		} `json:"usage"`
	} `json:"response"`
}

// The failure's error object ("response.failed" carries it in the response, an "error" event at the top) and its code.
func (v streamEvent) failure() (json.RawMessage, string) {
	for _, raw := range []json.RawMessage{v.Response.Error, v.Error} {
		var e struct {
			Code string `json:"code"`
		}
		if len(raw) > 0 && json.Unmarshal(raw, &e) == nil {
			return raw, e.Code
		}
	}
	return nil, v.Code
}

// Buffer only the prelude, never replay a stream after text or a tool call escaped. Returns done once Codex has
// its answer (the reply, the service's own failure, or why it cannot be reached); otherwise why this account did
// not answer, and the next account may. last: no next account will be tried.
func (g *gateway) stream(w http.ResponseWriter, r *http.Request, reader *bufio.Reader, res *http.Response, a account, session string, last bool, started time.Time) (bool, fault) {
	var pre bytes.Buffer
	committed, ended := false, false
	commit := func() bool {
		committed = true
		copyHeader(w.Header(), res.Header, responseOwned)
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Cache-Control", "no-cache")
		w.Header().Set("X-Codex-Accounts-Slot", a.ID)
		w.WriteHeader(200)
		_, e := w.Write(pre.Bytes())
		pre.Reset()
		return e == nil
	}
	for {
		line, err := reader.ReadBytes('\n')
		if len(line) > 0 {
			content, failed := false, false
			var v streamEvent
			if data, ok := bytes.CutPrefix(line, []byte("data:")); ok && json.Unmarshal(bytes.TrimSpace(data), &v) == nil {
				failed = v.Type == "error" || v.Type == "response.failed"
				// An incomplete response (a content filter, an output cap) is the service's own answer, like a completed one.
				finished := v.Type == "response.completed" || v.Type == "response.incomplete"
				content = strings.Contains(v.Type, "delta") || strings.Contains(v.Type, "output_item") || finished
				if finished {
					g.emitRequest(r, event{Kind: "completed", Account: a.ID, Input: v.Response.Usage.Input, Cached: v.Response.Usage.InputDetails.Cached, Output: v.Response.Usage.Output})
				}
				ended = ended || finished || failed
			}
			if !committed {
				pre.Write(line)
				switch {
				case failed:
					raw, code := v.failure()
					f := codeFault(code)
					g.emitRequest(r, event{Kind: "refused", Account: a.ID, Status: 502, Reason: safeCode(code), MS: since(started)})
					if f == faultAccount {
						until := retryAt(nil, append(append([]byte(`{"error":`), raw...), '}'))
						g.cool(a.ID, until)
						if code == "usage_limit_reached" || code == "insufficient_quota" {
							g.limit(a, until)
						}
						return false, f
					}
					if f == faultUpstream {
						g.strike(a.ID, conversation(r))
						if !last {
							return false, f
						}
					}
					// About the request itself, or the last try: Codex gets the service's own failure and decides.
					if !commit() {
						return true, faultNone
					}
				case content || pre.Len() > 256<<10:
					g.remember(session, a.ID)
					if !commit() {
						return true, faultNone
					}
				}
			} else if _, e := w.Write(line); e != nil {
				return true, faultNone
			}
			if committed {
				if f, ok := w.(http.Flusher); ok {
					f.Flush()
				}
			}
		}
		if err == nil {
			continue
		}
		switch {
		case r.Context().Err() != nil:
			return true, faultNone
		case committed:
			if !ended {
				g.emitRequest(r, event{Kind: "interrupted", Account: a.ID, Reason: networkFault(err, g.proxied(res.Request))})
				io.WriteString(w, "event: error\ndata: {\"type\":\"error\",\"error\":{\"message\":\"Upstream stream interrupted; not replayed to avoid duplicate tool execution.\"}}\n\n")
			}
			return true, faultNone
		case err != io.EOF:
			return g.unreachable(w, r, res.Request, a.ID, err, started), faultNone
		}
		return g.closedEarly(w, r, a, last, started), faultUpstream
	}
}

// eventSink hands each event to the app (stdout) and to the private log, never on the request's own goroutine:
// when the app stops reading or the log stalls, events are dropped instead of freezing every Codex request
// (2026-10-31: one event write stalled under the old shared lock for an hour, and no request got past its first event).
func eventSink(app io.Writer, logPath string) func(event) {
	toApp, toLog := make(chan event, 512), make(chan event, 512)
	if app != nil {
		go func() {
			out := json.NewEncoder(app)
			for e := range toApp {
				out.Encode(e)
			}
		}()
	} else {
		toApp = nil // a nil channel is never ready: nothing is queued for nobody
	}
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
	if e != nil || net.ParseIP(host) == nil || !net.ParseIP(host).IsLoopback() || *path == "" {
		fmt.Fprintln(os.Stderr, "loopback address and configuration path required")
		os.Exit(1)
	}
	// launchd keeps the gateway running whether Tibot runs or not. A missing or unreadable pool is no reason
	// to stop: Codex's own login still goes straight through until Tibot writes the pool again.
	emit := eventSink(nil, filepath.Join(filepath.Dir(*path), "requests.jsonl"))
	g := newGateway(func() (config, error) { return readConfig(*path) }, upstream, emit)
	if *desktopAuth != "" {
		g.native = &nativeAuth{path: *desktopAuth, cache: filepath.Join(filepath.Dir(*path), "client-auth-hashes.json")}
	}
	g.keyFile = filepath.Join(filepath.Dir(*path), "local.key")
	g.stickyFile = filepath.Join(filepath.Dir(*path), "session-accounts.json")
	if st, err := os.Lstat(g.stickyFile); err == nil && st.Mode().IsRegular() && st.Mode().Perm()&0077 == 0 && st.Size() < 1<<20 {
		if data, err := os.ReadFile(g.stickyFile); err == nil {
			var saved map[string]binding
			if json.Unmarshal(data, &saved) == nil && saved != nil {
				g.sticky = saved
			}
		}
	}
	go g.keepSticky()
	ln, e := net.Listen("tcp", *addr)
	if e != nil {
		fmt.Fprintln(os.Stderr, "gateway port is already occupied")
		os.Exit(1)
	}
	s := &http.Server{Handler: g, ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 60 * time.Second}
	// Serve returns as soon as a shutdown begins; the process waits here until the replies in flight are done.
	stopped := make(chan struct{})
	var once sync.Once
	finish := func() { once.Do(func() { close(stopped) }) }
	var restart sync.Once
	g.onRestart = func() { restart.Do(func() { go func() { g.drain(s); finish() }() }) }
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		// launchd waits 20 s after SIGTERM (bootout, logout) before it kills the process.
		shutdown(s, g, 15*time.Second)
		finish()
	}()
	emit(event{Kind: "ready"})
	e = s.Serve(ln)
	if e == http.ErrServerClosed {
		<-stopped
	}
	g.saveSticky()
	if e != nil && e != http.ErrServerClosed {
		os.Exit(1)
	}
}
