package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/klauspost/compress/zstd"
)

// What the service saw of one request.
type seen struct {
	path, query, auth, account, encoding string
	body                                 []byte
}

func recorder(t *testing.T, reply func(w http.ResponseWriter, r *http.Request)) (*httptest.Server, func() []seen) {
	t.Helper()
	var mu sync.Mutex
	var got []seen
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		mu.Lock()
		got = append(got, seen{r.URL.Path, r.URL.RawQuery, r.Header.Get("Authorization"), r.Header.Get("chatgpt-account-id"), r.Header.Get("Content-Encoding"), b})
		mu.Unlock()
		reply(w, r)
	}))
	t.Cleanup(up.Close)
	return up, func() []seen { mu.Lock(); defer mu.Unlock(); return append([]seen(nil), got...) }
}

func codexRequest(method, path, token, account string, body []byte) *http.Request {
	r := httptest.NewRequest(method, "http://127.0.0.1:18456"+path, bytes.NewReader(body))
	r.Header.Set("Authorization", "Bearer "+token)
	if account != "" {
		r.Header.Set("chatgpt-account-id", account)
	}
	return r
}

// Whenever the gateway cannot help, Codex's own login goes to the service untouched, as if Tibot were not
// there: Codex never stops because of Tibot.
func TestCodexsOwnLoginGoesStraightThroughWhenTheGatewayCannotHelp(t *testing.T) {
	up, got := recorder(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Set-Cookie", "cf=1")
		w.Header().Set("X-Codex-Primary-Used-Percent", "12")
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, good)
	})
	desktop := localToken("acct-two", "desktop", time.Now().Unix()+3600)
	stranger := localToken("acct-nine", "elsewhere", time.Now().Unix()+3600)
	var zbody bytes.Buffer
	zw, _ := zstd.NewWriter(&zbody)
	zw.Write([]byte(`{"input":"hi","stream":true}`))
	zw.Close()

	for _, tc := range []struct {
		name, method, path, token, account, reason string
		pool                                       func() (config, error)
		body                                       []byte
		encoding                                   string
	}{
		{"pool unreadable", "POST", "/backend-api/codex/responses", desktop, "acct-two", "pool_unavailable",
			func() (config, error) { return config{}, errors.New("missing") }, zbody.Bytes(), "zstd"},
		{"routing off", "POST", "/backend-api/codex/responses", desktop, "acct-two", "routing_off",
			func() (config, error) { c := pool(); c.Off = true; c.Accounts[1].Access = desktop; return c, nil }, []byte(`{"input":"hi"}`), ""},
		{"login Tibot does not know", "POST", "/backend-api/codex/responses", stranger, "acct-nine", "unknown_login",
			func() (config, error) { return pool(), nil }, []byte(`{"input":"hi"}`), ""},
		{"route the gateway does not handle", "POST", "/backend-api/codex/memories/trace_summarize?x=1", desktop, "acct-two", "route",
			func() (config, error) { c := pool(); c.Accounts[1].Access = desktop; return c, nil }, []byte(`{"traces":[]}`), ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var events []event
			g := newGateway(tc.pool, up.URL, func(e event) { events = append(events, e) })
			before := len(got())
			r := codexRequest(tc.method, tc.path, tc.token, tc.account, tc.body)
			if tc.encoding != "" {
				r.Header.Set("Content-Encoding", tc.encoding)
			}
			w := httptest.NewRecorder()
			g.ServeHTTP(w, r)
			all := got()
			if w.Code != 200 || len(all) != before+1 {
				t.Fatalf("status %d, upstream calls %d", w.Code, len(all)-before)
			}
			s := all[len(all)-1]
			wantPath, wantQuery, _ := strings.Cut(strings.TrimPrefix(tc.path, "/backend-api/codex"), "?")
			if s.auth != "Bearer "+tc.token || s.account != tc.account || s.path != wantPath || s.query != wantQuery {
				t.Fatalf("not Codex's own request: %+v", s)
			}
			if !bytes.Equal(s.body, tc.body) || s.encoding != tc.encoding {
				t.Fatalf("body changed: %q encoding %q", s.body, s.encoding)
			}
			if w.Body.String() != good || w.Header().Get("Set-Cookie") != "cf=1" || w.Header().Get("X-Codex-Primary-Used-Percent") != "12" {
				t.Fatalf("answer changed: %q %v", w.Body.String(), w.Header())
			}
			if len(events) != 1 || events[0].Kind != "direct" || events[0].Reason != tc.reason || events[0].Status != 200 {
				t.Fatalf("events %+v", events)
			}
		})
	}

	// Without a ChatGPT login of its own (Tibot's pool key, or a wrong key) there is nothing to pass on.
	g := newGateway(func() (config, error) { return config{}, errors.New("missing") }, up.URL, func(event) {})
	before := len(got())
	if w := ask(g, `{"input":"hi"}`); w.Code != 503 {
		t.Fatal("pool key without a pool:", w.Code)
	}
	g = newGateway(func() (config, error) { return pool(), nil }, up.URL, func(event) {})
	for _, token := range []string{"wrong", "a.b.c"} {
		w := httptest.NewRecorder()
		g.ServeHTTP(w, codexRequest("POST", "/v1/responses", token, "", []byte(`{}`)))
		if w.Code != 401 {
			t.Fatal(token, w.Code)
		}
	}
	// The gateway's own endpoints never pass a login on.
	if health(g, stranger, "acct-nine") != 401 {
		t.Fatal("health accepted an unknown login")
	}
	if len(got()) != before {
		t.Fatal("a request without its own login reached the service")
	}
}

// A connected login whose account is not in the pool (its quota checks paused) while no other account can
// sign in: Codex's own login still works.
func TestNoAccountInThePoolGoesOnCodexsOwnLogin(t *testing.T) {
	up, got := recorder(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, good)
	})
	n, c, token := nativeFixture(t)
	c.Accounts = c.Accounts[:1]
	c.Accounts[0].Expires = float64(time.Now().Unix() - 1)
	var events []event
	g := newGateway(func() (config, error) { return c, nil }, up.URL, func(e event) { events = append(events, e) })
	g.native = n
	w := httptest.NewRecorder()
	r := codexRequest("POST", "/backend-api/codex/responses", token, "acct-two", []byte(`{"input":"hi"}`))
	r.Header.Set("session-id", "s")
	g.ServeHTTP(w, r)
	if w.Code != 200 || len(got()) != 1 || got()[0].auth != "Bearer "+token {
		t.Fatal(w.Code, got())
	}
	if events[len(events)-2].Kind != "direct" || events[len(events)-2].Reason != "logins_expired" {
		t.Fatalf("%+v", events)
	}
}

// A reply the service breaks off reaches Codex as broken, not as a clean end it would take for complete.
func TestADirectReplyCutOffIsNotEndedCleanly(t *testing.T) {
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Content-Length", "1000")
		io.WriteString(w, "data: {\"type\":\"response.created\"}\n\n")
	}))
	defer up.Close()
	g := newGateway(func() (config, error) { return config{}, errors.New("missing") }, up.URL, func(event) {})
	front := httptest.NewServer(g)
	defer front.Close()
	q, _ := http.NewRequest("POST", front.URL+"/v1/responses", strings.NewReader(`{}`))
	q.Header.Set("Authorization", "Bearer "+localToken("acct-two", "d", time.Now().Unix()+60))
	res, err := http.DefaultClient.Do(q)
	if err != nil {
		t.Fatal(err)
	}
	_, err = io.ReadAll(res.Body)
	res.Body.Close()
	if err == nil {
		t.Fatal("a cut-off reply ended cleanly")
	}
}

// Tibot watches the gateway over GET /tibot/events: "ready" first, then every event, and a ping while idle.
func TestTibotSeesEventsLive(t *testing.T) {
	old := eventsPing
	eventsPing = 50 * time.Millisecond
	defer func() { eventsPing = old }()
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, good)
	}))
	defer up.Close()
	g := newGateway(func() (config, error) { return pool(), nil }, up.URL, func(event) {})
	front := httptest.NewServer(g)
	defer front.Close()

	q, _ := http.NewRequest("GET", front.URL+"/tibot/events", nil)
	q.Header.Set("Authorization", "Bearer "+localToken("acct-two", "d", time.Now().Unix()+60))
	if res, _ := http.DefaultClient.Do(q); res == nil || res.StatusCode != 401 {
		t.Fatal("events open to a Codex login")
	}
	q.Header.Set("Authorization", "Bearer "+pool().Key)
	res, err := http.DefaultClient.Do(q)
	if err != nil || res.StatusCode != 200 {
		t.Fatal(err)
	}
	defer res.Body.Close()
	lines := make(chan string, 64)
	go func() {
		sc := bufio.NewScanner(res.Body)
		for sc.Scan() {
			if sc.Text() != "" {
				lines <- sc.Text()
			}
		}
		close(lines)
	}()
	next := func() string {
		select {
		case l := <-lines:
			return l
		case <-time.After(2 * time.Second):
			t.Fatal("no event")
		}
		return ""
	}
	if l := next(); !strings.HasPrefix(l, `data: {`) || !strings.Contains(l, `"kind":"ready"`) {
		t.Fatal(l)
	}
	if l := next(); l != ": ping" {
		t.Fatal(l)
	}
	ask(g, `{"input":"hi"}`)
	var kinds []string
	for len(kinds) < 3 {
		if l := next(); strings.HasPrefix(l, "data: ") {
			kinds = append(kinds, l)
		}
	}
	if !strings.Contains(kinds[0], `"kind":"routing"`) || !strings.Contains(kinds[1], `"kind":"completed"`) || !strings.Contains(kinds[2], `"kind":"finished"`) {
		t.Fatal(kinds)
	}
	g.hub.close() // a shutting-down server is not held open by Tibot's stream
	for range lines {
	}
}

// An update asks the gateway to restart on its new binary: it waits for the reply in flight, then stops.
func TestRestartWaitsForTheReplyInFlight(t *testing.T) {
	release := make(chan struct{})
	started := make(chan struct{})
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, "data: {\"type\":\"response.output_text.delta\",\"delta\":\"ok\"}\n\n")
		w.(http.Flusher).Flush()
		close(started)
		<-release
		io.WriteString(w, "data: {\"type\":\"response.completed\",\"response\":{}}\n\n")
	}))
	defer up.Close()
	g := newGateway(func() (config, error) { return pool(), nil }, up.URL, func(event) {})
	front := httptest.NewServer(g)
	defer front.Close()
	g.onRestart = func() { go g.drain(front.Config) }

	reply := make(chan string, 1)
	go func() {
		q, _ := http.NewRequest("POST", front.URL+"/v1/responses", strings.NewReader(`{"input":"hi"}`))
		q.Header.Set("Authorization", "Bearer "+pool().Key)
		res, err := http.DefaultClient.Do(q)
		if err != nil {
			reply <- err.Error()
			return
		}
		b, _ := io.ReadAll(res.Body)
		res.Body.Close()
		reply <- string(b)
	}()
	<-started
	q, _ := http.NewRequest("POST", front.URL+"/tibot/restart", nil)
	q.Header.Set("Authorization", "Bearer "+pool().Key)
	if res, err := http.DefaultClient.Do(q); err != nil || res.StatusCode != 202 {
		t.Fatal(err)
	}
	time.Sleep(200 * time.Millisecond)
	if g.inflight.Load() != 1 {
		t.Fatal("the reply in flight was not waited for")
	}
	close(release)
	if b := <-reply; !strings.Contains(b, "response.completed") {
		t.Fatal("reply cut:", b)
	}
	deadline := time.Now().Add(2 * time.Second)
	for {
		if _, err := http.Get(front.URL + "/health"); err != nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("gateway did not stop for the restart")
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// A disk that stalls while the gateway records a conversation's owner must not stop other requests
// (2026-10-31: a stalled write under the shared lock froze every Codex request for an hour).
func TestAStalledDiskDoesNotHoldRequests(t *testing.T) {
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, good)
	}))
	defer up.Close()
	dir := t.TempDir()
	g := newGateway(func() (config, error) { return pool(), nil }, up.URL, func(event) {})
	g.stickyFile = filepath.Join(dir, "session-accounts.json")
	// A FIFO with no reader: writing the owners' file blocks for good, like a stalled disk.
	if err := syscall.Mkfifo(g.stickyFile+".tmp", 0600); err != nil {
		t.Skip(err)
	}
	go g.keepSticky()
	defer func() { // let the stuck writer finish
		if f, err := os.OpenFile(g.stickyFile+".tmp", os.O_RDONLY|syscall.O_NONBLOCK, 0); err == nil {
			time.Sleep(50 * time.Millisecond)
			f.Close()
		}
	}()
	if w := ask(g, `{"input":"hi"}`); w.Code != 200 {
		t.Fatal(w.Code)
	}
	time.Sleep(1500 * time.Millisecond) // the writer is now stuck
	done := make(chan int, 1)
	go func() { done <- ask(g, `{"input":"again"}`).Code }()
	select {
	case code := <-done:
		if code != 200 {
			t.Fatal(code)
		}
	case <-time.After(time.Second):
		t.Fatal("a request waited for the disk")
	}
}

// A login registry that cannot be written (a full or read-only disk) still recognizes the desktop's login.
func TestAnUnwritableRegistryStillRecognizesTheDesktop(t *testing.T) {
	n, c, token := nativeFixture(t)
	locked := filepath.Join(filepath.Dir(n.cache), "locked")
	os.Mkdir(locked, 0500)
	defer os.Chmod(locked, 0700)
	n.cache = filepath.Join(locked, "hashes.json")
	g := newGateway(func() (config, error) { return c, nil }, "", func(event) {})
	g.native = n
	if got := health(g, token, "acct-two"); got != 200 {
		t.Fatal(got)
	}
}

func TestCompactionWaitsLongerForItsFirstByte(t *testing.T) {
	g := newGateway(func() (config, error) { return pool(), nil }, "", func(event) {})
	if g.clientFor("/responses") != g.client || g.clientFor("/responses/compact") != g.slow {
		t.Fatal("wrong client")
	}
	if g.slow.Transport.(*http.Transport).ResponseHeaderTimeout <= g.client.Transport.(*http.Transport).ResponseHeaderTimeout {
		t.Fatal("compaction gets no more time")
	}
}

// Codex opens a WebSocket on every turn and falls back to HTTP on 426. Stripped to a plain GET and sent direct,
// it cost Codex 7 s of reconnect attempts per conversation (review of #36); it is refused before anything goes
// direct, and never reaches the service.
func TestAWebSocketIsRefusedBeforeAnythingGoesDirect(t *testing.T) {
	up, got := recorder(t, func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(405) })
	n, c, token := nativeFixture(t)
	stranger := localToken("acct-nine", "elsewhere", time.Now().Unix()+3600)
	off := config{Key: c.Key, Off: true, Clients: c.Clients} // as Tibot writes it with routing off
	for _, tc := range []struct {
		name  string
		pool  func() (config, error)
		token string
	}{
		{"pool unreadable", func() (config, error) { return config{}, errors.New("missing") }, token},
		{"login Tibot does not know", func() (config, error) { return c, nil }, stranger},
		{"routing off", func() (config, error) { return off, nil }, token},
	} {
		g := newGateway(tc.pool, up.URL, func(event) {})
		g.native = n
		r := codexRequest("GET", "/backend-api/codex/responses", tc.token, "", nil)
		r.Header.Set("Connection", "Upgrade")
		r.Header.Set("Upgrade", "websocket")
		w := httptest.NewRecorder()
		g.ServeHTTP(w, r)
		if w.Code != 426 {
			t.Fatal(tc.name, w.Code)
		}
	}
	if len(got()) != 0 {
		t.Fatal("a WebSocket attempt reached the service as a plain GET")
	}
}

// Routing off, with the pool exactly as Tibot writes it (no accounts, the connected identities kept): the desktop's
// login goes direct as routing_off, and the logins the gateway remembers survive for when routing is back.
func TestRoutingOffAsTibotWritesIt(t *testing.T) {
	up, got := recorder(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, good)
	})
	n, c, token := nativeFixture(t)
	if _, id := n.authenticate(c, token, "acct-two"); id != "two" {
		t.Fatal("fixture", id)
	}
	off := config{Key: c.Key, Off: true, Clients: c.Clients}
	var events []event
	g := newGateway(func() (config, error) { return off, nil }, up.URL, func(e event) { events = append(events, e) })
	g.native = n
	w := httptest.NewRecorder()
	g.ServeHTTP(w, codexRequest("POST", "/backend-api/codex/responses", token, "acct-two", []byte(`{"input":"hi"}`)))
	if w.Code != 200 || len(got()) != 1 || len(events) != 1 || events[0].Reason != "routing_off" {
		t.Fatal(w.Code, got(), events)
	}
	b, _ := os.ReadFile(n.cache)
	var kept []clientHash
	json.Unmarshal(b, &kept)
	if len(kept) == 0 || len(n.kept) == 0 {
		t.Fatal("turning routing off erased the remembered logins")
	}
}

// Tibot quit while both accounts were out; their windows have reset since and nobody wrote that down. An account
// whose spent windows are past their reset is tried again; and with Tibot gone for a while, a pool that still
// says every account is out does not keep Codex's own login from asking the service (review of #36).
func TestAPoolTibotNoLongerUpdatesDoesNotLockCodexOut(t *testing.T) {
	up, got := recorder(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, good)
	})
	n, c, token := nativeFixture(t)
	past := float64(time.Now().Add(-time.Hour).Unix())
	for i := range c.Accounts {
		c.Accounts[i].Available = false
		c.Accounts[i].Reset = float64(time.Now().Add(72 * time.Hour).Unix())
	}
	c.Accounts[0].Back = past // its five-hour window reset an hour ago
	var events []event
	g := newGateway(func() (config, error) { return c, nil }, up.URL, func(e event) { events = append(events, e) })
	g.native = n
	if w := ask(g, `{"input":"hi"}`); w.Code != 200 || w.Header().Get("X-Codex-Accounts-Slot") != "one" {
		t.Fatal("an account past its reset was not used:", w.Code)
	}

	c.Accounts[0].Back = float64(time.Now().Add(time.Hour).Unix())
	fresh := c
	fresh.written = time.Now()
	g = newGateway(func() (config, error) { return fresh, nil }, up.URL, func(e event) { events = append(events, e) })
	g.native = n
	before := len(got())
	w := httptest.NewRecorder()
	g.ServeHTTP(w, codexRequest("POST", "/backend-api/codex/responses", token, "acct-two", []byte(`{"input":"hi"}`)))
	if w.Code != 429 || len(got()) != before {
		t.Fatal("a fresh pool's usage limit was not answered by the gateway:", w.Code)
	}

	stale := c
	stale.written = time.Now().Add(-time.Hour)
	events = nil
	g = newGateway(func() (config, error) { return stale, nil }, up.URL, func(e event) { events = append(events, e) })
	g.native = n
	w = httptest.NewRecorder()
	g.ServeHTTP(w, codexRequest("POST", "/backend-api/codex/responses", token, "acct-two", []byte(`{"input":"hi"}`)))
	if w.Code != 200 || len(got()) != before+1 || got()[before].auth != "Bearer "+token {
		t.Fatal("Codex's own login was kept from the service by an old pool:", w.Code)
	}
	if e := events[len(events)-2]; e.Kind != "direct" || e.Reason != "pool_stale" {
		t.Fatalf("%+v", events)
	}
	// Tibot's own key never goes direct: it gets the gateway's answer.
	if w := ask(g, `{"input":"hi"}`); w.Code != 429 {
		t.Fatal(w.Code)
	}
}

// A conversation the gateway served on another account, continued direct: that account's turn state stays behind.
func TestADirectRequestDropsAnotherAccountsTurnState(t *testing.T) {
	var states []string
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		states = append(states, r.Header.Get("X-Codex-Turn-State"))
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, good)
	}))
	defer up.Close()
	n, c, token := nativeFixture(t)
	off := config{Key: c.Key, Off: true, Clients: c.Clients}
	g := newGateway(func() (config, error) { return off, nil }, up.URL, func(event) {})
	g.native = n
	g.remember("served-on-one", "one")
	g.remember("served-on-two", "two")
	for _, session := range []string{"served-on-one", "served-on-two", "never-routed"} {
		r := codexRequest("POST", "/backend-api/codex/responses", token, "acct-two", []byte(`{"input":"hi"}`))
		r.Header.Set("session-id", session)
		r.Header.Set("X-Codex-Turn-State", "state")
		g.ServeHTTP(httptest.NewRecorder(), r)
	}
	if strings.Join(states, ",") != ",state,state" {
		t.Fatal(states)
	}
}

// Tibot's event stream works when the pool cannot be read (the key file stands in), so Tibot does not restart a
// gateway that is serving Codex directly.
func TestTibotsEndpointsWorkWithoutAPool(t *testing.T) {
	dir, _ := filepath.EvalSymlinks(t.TempDir()) // the key file is trusted only at its real path
	key := strings.Repeat("c", 64)
	os.WriteFile(filepath.Join(dir, "local.key"), []byte(key), 0600)
	g := newGateway(func() (config, error) { return config{}, errors.New("missing") }, "", func(event) {})
	g.keyFile = filepath.Join(dir, "local.key")
	front := httptest.NewServer(g)
	defer front.Close()
	for token, want := range map[string]int{key: 200, strings.Repeat("d", 64): 401} {
		q, _ := http.NewRequest("GET", front.URL+"/tibot/events", nil)
		q.Header.Set("Authorization", "Bearer "+token)
		res, err := http.DefaultClient.Do(q)
		if err != nil || res.StatusCode != want {
			t.Fatal(token[:1], err, res)
		}
		res.Body.Close()
	}
}

// A gateway whose requests are stuck on the shared lock stops pinging, so Tibot notices and restarts it.
func TestPingsStopWhileRequestsAreStuck(t *testing.T) {
	old := eventsPing
	eventsPing = 30 * time.Millisecond
	defer func() { eventsPing = old }()
	g := newGateway(func() (config, error) { return pool(), nil }, "", func(event) {})
	front := httptest.NewServer(g)
	defer front.Close()
	q, _ := http.NewRequest("GET", front.URL+"/tibot/events", nil)
	q.Header.Set("Authorization", "Bearer "+pool().Key)
	res, err := http.DefaultClient.Do(q)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	pings := make(chan struct{}, 64)
	go func() {
		sc := bufio.NewScanner(res.Body)
		for sc.Scan() {
			if sc.Text() == ": ping" {
				pings <- struct{}{}
			}
		}
	}()
	<-pings
	g.mu.Lock()
	time.Sleep(60 * time.Millisecond)
	for len(pings) > 0 {
		<-pings
	}
	select {
	case <-pings:
		t.Fatal("pinged while the lock was stuck")
	case <-time.After(200 * time.Millisecond):
	}
	g.mu.Unlock()
	select {
	case <-pings:
	case <-time.After(time.Second):
		t.Fatal("no ping after the lock came back")
	}
	g.hub.close()
}

// launchd stops the agent with SIGTERM (a plist change, logout). The process waits for the request in flight
// instead of exiting at once (review of #36: it exited 3 ms after SIGTERM).
func TestSIGTERMWaitsForTheRequestInFlight(t *testing.T) {
	if testing.Short() {
		t.Skip("builds the gateway")
	}
	dir := t.TempDir()
	bin := filepath.Join(dir, "AccountsGateway")
	if out, err := exec.Command("go", "build", "-o", bin, ".").CombinedOutput(); err != nil {
		t.Fatal(string(out))
	}
	key := strings.Repeat("ab", 32)
	cfg := filepath.Join(dir, "pool.json")
	b, _ := json.Marshal(config{Key: key})
	os.WriteFile(cfg, b, 0600)
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	addr := "127.0.0.1:" + strconv.Itoa(ln.Addr().(*net.TCPAddr).Port)
	ln.Close()
	cmd := exec.Command(bin, "--config", cfg, "--listen", addr)
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	exited := make(chan time.Time, 1)
	go func() { cmd.Wait(); exited <- time.Now() }()
	defer cmd.Process.Kill()
	for i := 0; ; i++ {
		if c, err := net.Dial("tcp", addr); err == nil {
			c.Close()
			break
		}
		if i > 200 {
			t.Fatal("gateway did not listen")
		}
		time.Sleep(20 * time.Millisecond)
	}
	pr, pw := io.Pipe()
	q, _ := http.NewRequest("POST", "http://"+addr+"/backend-api/codex/responses", pr)
	q.Header.Set("Authorization", "Bearer "+key)
	answered := make(chan int, 1)
	go func() {
		res, err := http.DefaultClient.Do(q)
		if err != nil {
			answered <- 0
			return
		}
		io.ReadAll(res.Body)
		res.Body.Close()
		answered <- res.StatusCode
	}()
	pw.Write([]byte(`{"input":"still arriving`))
	time.Sleep(300 * time.Millisecond)
	cmd.Process.Signal(syscall.SIGTERM)
	select {
	case <-exited:
		t.Fatal("exited with a request in flight")
	case <-time.After(time.Second):
	}
	pw.Write([]byte(`"}`))
	pw.Close()
	if code := <-answered; code != 503 { // no account in this pool: the gateway's own answer, delivered whole
		t.Fatal("the request in flight got", code)
	}
	select {
	case <-exited:
	case <-time.After(5 * time.Second):
		t.Fatal("did not exit once the request was done")
	}
}
