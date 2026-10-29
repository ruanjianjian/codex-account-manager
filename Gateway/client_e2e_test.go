//go:build e2e

// Opt-in: the real bundled Codex client -> this gateway -> a fake local upstream.
//
//	go test -tags e2e -run TestRealClient -v .
//
// Synthetic JWTs only, temporary CODEX_HOME/HOME, chatgpt_base_url and token refresh point at
// the fake upstream, and every proxy variable points at a dead local port, so no request can
// leave the machine and no real account or ~/.codex file is read or written.
package main

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"
)

func fakeJWT(claims map[string]any) string {
	b, _ := json.Marshal(claims)
	return "eyJhbGciOiJub25lIn0." + base64.RawURLEncoding.EncodeToString(b) + ".sig"
}
func fakeAccess(acct string) string {
	return fakeJWT(map[string]any{"exp": time.Now().Unix() + 7*86400, "https://api.openai.com/auth": map[string]any{"chatgpt_account_id": acct, "chatgpt_plan_type": "pro"}})
}
func fakeAuth(acct, access string) []byte {
	id := fakeJWT(map[string]any{"exp": time.Now().Unix() + 7*86400, "email": acct + "@example.invalid", "https://api.openai.com/auth": map[string]any{"chatgpt_account_id": acct, "chatgpt_plan_type": "pro", "chatgpt_user_id": "user-" + acct}})
	b, _ := json.Marshal(map[string]any{"OPENAI_API_KEY": nil, "tokens": map[string]any{"id_token": id, "access_token": access, "refresh_token": "fake-refresh-" + acct, "account_id": acct}, "last_refresh": time.Now().UTC().Format(time.RFC3339)})
	return b
}

var sealedRe = regexp.MustCompile(`SEALED-[a-z0-9-]+`)

// Models the server constraint the gateway protects: sealed reasoning only verifies on its own account.
type fakeBackend struct {
	mu     sync.Mutex
	tokens map[string]string
	sealed []string
	n      int
}

func (f *fakeBackend) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body)
	f.mu.Lock()
	acct := f.tokens[strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")]
	f.n++
	n := f.n
	f.mu.Unlock()
	if acct == "" || acct != r.Header.Get("chatgpt-account-id") {
		w.WriteHeader(401)
		return
	}
	switch {
	case r.Header.Get("Upgrade") != "":
		w.WriteHeader(426)
	case strings.HasSuffix(r.URL.Path, "/wham/accounts/check"):
		// A dead HTTPS origin: if a request were ever workspace-bound it would fail locally.
		fmt.Fprintf(w, `{"accounts":[{"id":%q,"plan_type":"pro","workspace_backend_origin":"https://127.0.0.1:9/","account_routing_override":"NO_CONSTRAINT","structure":"personal"}],"account_ordering":[%q]}`, acct, acct)
	case strings.HasSuffix(r.URL.Path, "/models"):
		io.WriteString(w, `{"models":[]}`)
	case strings.HasSuffix(r.URL.Path, "/responses"):
		seen := sealedRe.FindAllString(string(body), -1)
		f.mu.Lock()
		f.sealed = append(f.sealed, seen...)
		f.mu.Unlock()
		for _, s := range seen {
			if s != "SEALED-"+acct {
				w.WriteHeader(400)
				io.WriteString(w, `{"error":{"message":"The encrypted content could not be verified.","code":"invalid_encrypted_content"}}`)
				return
			}
		}
		w.Header().Set("Content-Type", "text/event-stream")
		id := fmt.Sprintf("resp_%d", n)
		ev := func(v any) { b, _ := json.Marshal(v); fmt.Fprintf(w, "data: %s\n\n", b) }
		ev(map[string]any{"type": "response.created", "response": map[string]any{"id": id}})
		ev(map[string]any{"type": "response.output_item.done", "item": map[string]any{"type": "reasoning", "id": "rs_" + id, "summary": []any{}, "encrypted_content": "SEALED-" + acct}})
		ev(map[string]any{"type": "response.output_item.done", "item": map[string]any{"type": "message", "role": "assistant", "id": "msg_" + id, "content": []any{map[string]any{"type": "output_text", "text": "reply-from-" + acct}}}})
		ev(map[string]any{"type": "response.completed", "response": map[string]any{"id": id, "usage": map[string]any{"input_tokens": 5, "output_tokens": 1, "total_tokens": 6}}})
	default:
		w.WriteHeader(404)
	}
}

func serve(t *testing.T, h http.Handler) string {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	s := &http.Server{Handler: h}
	go s.Serve(ln)
	t.Cleanup(func() { s.Close() })
	return "http://" + ln.Addr().String()
}

type clientRun struct{ thread, reply, failure string }

func TestRealClientRoutesSealedConversationsAfterSwitch(t *testing.T) {
	bin := os.Getenv("CODEX_BIN")
	if bin == "" {
		bin = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"
	}
	if _, err := os.Stat(bin); err != nil {
		t.Skip("Codex client not installed; set CODEX_BIN")
	}
	dir, _ := filepath.EvalSymlinks(t.TempDir())
	work, home, codexHome := filepath.Join(dir, "work"), filepath.Join(dir, "home"), filepath.Join(dir, "codex-home")
	for _, d := range []string{work, home, codexHome} {
		os.MkdirAll(d, 0700)
	}
	one, two, three := fakeAccess("acct-one"), fakeAccess("acct-two"), fakeAccess("acct-three")
	backend := &fakeBackend{tokens: map[string]string{one: "acct-one", two: "acct-two", three: "acct-three"}}
	chatgpt, model := serve(t, backend), serve(t, backend) // separate origins, like chatgpt.com vs a custom base URL
	authPath := filepath.Join(codexHome, "auth.json")
	os.WriteFile(authPath, fakeAuth("acct-one", one), 0600)
	os.WriteFile(filepath.Join(codexHome, "config.toml"), []byte("cli_auth_credentials_store = \"file\"\n"), 0600)

	var mu sync.Mutex
	exp := float64(time.Now().Unix() + 7*86400)
	pool := config{Key: strings.Repeat("ab", 32), Accounts: []account{
		{ID: "one", AccountID: "acct-one", Access: one, Expires: exp, Available: true, Reset: 1},
		{ID: "two", AccountID: "acct-two", Access: two, Expires: exp, Available: true, Reset: 2}},
		Clients: []clientIdentity{{"one", "acct-one"}, {"two", "acct-two"}}}
	var reasons []string
	authRejected := 0
	g := newGateway(func() (config, error) { mu.Lock(); defer mu.Unlock(); return pool, nil }, chatgpt, func(e event) {
		mu.Lock()
		defer mu.Unlock()
		switch e.Kind {
		case "rejected":
			reasons = append(reasons, e.Reason)
		case "local_auth_rejected":
			authRejected++
		}
	})
	g.native = &nativeAuth{path: authPath, cache: filepath.Join(dir, "client-auth-hashes.json")}
	gw := serve(t, g) + "/backend-api/codex"
	dead := "http://127.0.0.1:9"

	run := func(base string, args ...string) clientRun {
		t.Helper()
		opts := []string{"--skip-git-repo-check", "--json", "-c", `sandbox_mode="read-only"`, "-c", `model="gpt-5.5"`,
			"-c", `model_provider="openai"`, "-c", `openai_base_url="` + base + `"`, "-c", `chatgpt_base_url="` + chatgpt + `/backend-api/"`,
			"-c", "analytics.enabled=false", "-c", `model_reasoning_effort="low"`}
		full := append([]string{"exec"}, opts...)
		if args[0] == "resume" {
			full = append([]string{"exec", "resume"}, append(opts, args[1:]...)...)
		} else {
			full = append(full, args...)
		}
		cmd := exec.Command(bin, full...)
		cmd.Dir = work
		cmd.Env = []string{"HOME=" + home, "CODEX_HOME=" + codexHome, "PATH=/usr/bin:/bin", "TMPDIR=" + os.TempDir(), "RUST_LOG=error",
			"HTTPS_PROXY=" + dead, "HTTP_PROXY=" + dead, "ALL_PROXY=" + dead, "https_proxy=" + dead, "http_proxy=" + dead, "all_proxy=" + dead,
			"NO_PROXY=127.0.0.1,localhost", "no_proxy=127.0.0.1,localhost",
			"CODEX_REFRESH_TOKEN_URL_OVERRIDE=" + chatgpt + "/oauth/token", "CODEX_REVOKE_TOKEN_URL_OVERRIDE=" + chatgpt + "/oauth/revoke"}
		var out, stderr bytes.Buffer
		cmd.Stdout, cmd.Stderr = &out, &stderr
		cmd.Start()
		timer := time.AfterFunc(120*time.Second, func() { cmd.Process.Kill() })
		cmd.Wait()
		timer.Stop()
		var r clientRun
		sc := bufio.NewScanner(&out)
		sc.Buffer(make([]byte, 1<<20), 1<<20)
		for sc.Scan() {
			var v struct {
				Type   string `json:"type"`
				Thread string `json:"thread_id"`
				Item   struct {
					Text string `json:"text"`
				} `json:"item"`
				Error struct {
					Message string `json:"message"`
				} `json:"error"`
			}
			if json.Unmarshal(sc.Bytes(), &v) != nil {
				continue
			}
			if v.Thread != "" && r.thread == "" {
				r.thread = v.Thread
			}
			if strings.HasPrefix(v.Item.Text, "reply-from-") {
				r.reply = v.Item.Text
			}
			if v.Type == "turn.failed" {
				r.failure = v.Error.Message
			}
		}
		if r.thread == "" && r.reply == "" && r.failure == "" {
			r.failure = "client error: " + strings.TrimSpace(stderr.String())
		}
		return r
	}
	expect := func(step string, r clientRun, reply string) {
		t.Helper()
		if r.reply != reply {
			t.Fatalf("%s: want %s, got reply=%q failure=%q", step, reply, r.reply, r.failure)
		}
		t.Logf("%s: %s", step, r.reply)
	}
	setPool := func(f func(*config)) { mu.Lock(); f(&pool); mu.Unlock() }

	old := run(model, "first turn, direct")
	expect("direct conversation", old, "reply-from-acct-one")
	expect("old conversation via gateway", run(gw, "resume", old.thread, "second turn"), "reply-from-acct-one")
	fresh := run(gw, "new conversation via gateway")
	expect("new conversation via gateway", fresh, "reply-from-acct-one")

	// A menu-bar account click while routing only sets Preferred.
	setPool(func(c *config) { c.Preferred = "two" })
	expect("old conversation after switch keeps its owner", run(gw, "resume", old.thread, "after switch"), "reply-from-acct-one")
	expect("gateway conversation after switch keeps its owner", run(gw, "resume", fresh.thread, "after switch"), "reply-from-acct-one")
	newer := run(gw, "new conversation after switch")
	expect("new conversation uses preferred", newer, "reply-from-acct-two")
	expect("its next turn stays there", run(gw, "resume", newer.thread, "next turn"), "reply-from-acct-two")
	setPool(func(c *config) { c.Accounts[1].Available = false })
	expect("spent preferred falls back", run(gw, "new while preferred is spent"), "reply-from-acct-one")

	backend.mu.Lock()
	for _, s := range backend.sealed {
		if s == "SEALED-acct-two" || s == "SEALED-acct-one" {
			continue
		}
		t.Fatalf("unexpected sealed state %s", s)
	}
	backend.mu.Unlock()

	// Logged in inside Codex to an account the manager does not know: the gateway can only refuse.
	// The menu-bar app restores the direct provider for this case instead of leaving Codex on 401s.
	os.WriteFile(authPath, fakeAuth("acct-three", three), 0600)
	if r := run(gw, "unenrolled desktop login"); r.reply != "" || r.failure == "" {
		t.Fatalf("unenrolled desktop login was served: %+v", r)
	}
	mu.Lock()
	defer mu.Unlock()
	if authRejected == 0 {
		t.Fatal("unenrolled desktop was not refused by local auth")
	}
	if len(reasons) != 0 {
		t.Fatalf("unexpected gateway rejections: %v", reasons)
	}
}
