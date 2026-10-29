package main

import (
	"net"
	"net/http"
	"net/url"
	"os/exec"
	"strings"
	"sync"
	"time"
)

// systemProxy routes upstream requests the way Codex and browsers do on this Mac: proxy environment
// variables first, else the macOS network proxy settings. A helper started by the app has no proxy
// variables, so without this the gateway connects directly and fails on networks that need a proxy,
// while Codex on its own works. Settings are re-read every 30 seconds, so switching a proxy app on
// or off applies without restarting.
type systemProxy struct {
	read func() string
	mu   sync.Mutex
	at   time.Time
	url  *url.URL
}

func newSystemProxy() *systemProxy {
	return &systemProxy{read: func() string {
		out, err := exec.Command("/usr/sbin/scutil", "--proxy").Output()
		if err != nil {
			return ""
		}
		return string(out)
	}}
}

func (p *systemProxy) For(r *http.Request) (*url.URL, error) {
	if host := r.URL.Hostname(); host == "localhost" || net.ParseIP(host).IsLoopback() {
		return nil, nil
	}
	if u, err := http.ProxyFromEnvironment(r); u != nil || err != nil {
		return u, err
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.at.IsZero() || time.Since(p.at) > 30*time.Second {
		p.url, p.at = parseSystemProxy(p.read()), time.Now()
	}
	return p.url, nil
}

// parseSystemProxy reads `scutil --proxy`: an HTTPS proxy if enabled, else a SOCKS one.
// Automatic proxy configuration (PAC) is not evaluated.
func parseSystemProxy(text string) *url.URL {
	values := map[string]string{}
	for _, line := range strings.Split(text, "\n") {
		if key, value, ok := strings.Cut(line, " : "); ok {
			values[strings.TrimSpace(key)] = strings.TrimSpace(value)
		}
	}
	for _, kind := range []struct{ prefix, scheme string }{{"HTTPS", "http"}, {"SOCKS", "socks5"}} {
		host, port := values[kind.prefix+"Proxy"], values[kind.prefix+"Port"]
		if values[kind.prefix+"Enable"] == "1" && host != "" && port != "" {
			return &url.URL{Scheme: kind.scheme, Host: host + ":" + port}
		}
	}
	return nil
}
