package main

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Membership is independent of routing eligibility: a depleted/paused account
// can identify a local client without becoming an upstream candidate.
type clientIdentity struct {
	ID        string `json:"id"`
	AccountID string `json:"accountID"`
}
type clientHash struct {
	Digest    string  `json:"digest"`
	AccountID string  `json:"accountID"`
	Expires   float64 `json:"expires"`
}
type nativeAuth struct {
	mu          sync.Mutex
	path, cache string
	// Digests of the logins seen (pool accounts and the desktop's), kept in memory and copied to cache, so a
	// Codex window still holding a token from before a refresh, or from before a gateway restart, is recognized.
	kept   map[string]clientHash
	loaded bool
	write  sync.Mutex
}

// Trust only owner-private regular files at the launch-time configured path.
// A JWT received over HTTP is never parsed to grant access.
func readPrivate(path string) ([]byte, error) {
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		return nil, err
	}
	if resolved != filepath.Clean(path) {
		return nil, errors.New("symlink credential path")
	}
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return nil, err
	}
	owner, ok := st.Sys().(*syscall.Stat_t)
	if !ok || owner.Uid != uint32(os.Geteuid()) || !st.Mode().IsRegular() || st.Mode().Perm()&0077 != 0 || st.Size() > 2<<20 {
		return nil, errors.New("insecure credential file")
	}
	data, err := io.ReadAll(io.LimitReader(f, (2<<20)+1))
	if len(data) > 2<<20 {
		return nil, errors.New("credential too large")
	}
	return data, err
}

func desktopCredential(path string) (account, error) {
	b, err := readPrivate(path)
	if err != nil {
		return account{}, err
	}
	var v struct {
		APIKey *string `json:"OPENAI_API_KEY"`
		Tokens struct {
			Access    string `json:"access_token"`
			AccountID string `json:"account_id"`
		} `json:"tokens"`
	}
	if json.Unmarshal(b, &v) != nil || v.APIKey != nil || v.Tokens.Access == "" || v.Tokens.AccountID == "" {
		return account{}, errors.New("invalid desktop credential")
	}
	parts := strings.Split(v.Tokens.Access, ".")
	if len(parts) != 3 {
		return account{}, errors.New("invalid local token")
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return account{}, errors.New("invalid local token")
	}
	var claims struct {
		Exp  float64 `json:"exp"`
		Auth struct {
			AccountID string `json:"chatgpt_account_id"`
		} `json:"https://api.openai.com/auth"`
	}
	if json.Unmarshal(payload, &claims) != nil || claims.Exp <= float64(time.Now().Unix()) || claims.Auth.AccountID != v.Tokens.AccountID {
		return account{}, errors.New("expired or mismatched local token")
	}
	return account{AccountID: v.Tokens.AccountID, Access: v.Tokens.Access, Expires: claims.Exp}, nil
}
func digestToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

// authenticate names the connected account a bearer belongs to ("" when none) and puts the desktop's current
// login in place of that account's older token. Files are read and written outside the lock, so a slow disk
// holds up only the request that reads it; an unreadable or unwritable registry only means fewer logins are
// recognized, and those go straight through on their own login.
func (n *nativeAuth) authenticate(c config, bearer, headerAccount string) (config, string) {
	allowed := map[string]string{}
	for _, id := range c.Clients {
		if id.ID != "" && id.AccountID != "" {
			allowed[id.AccountID] = id.ID
		}
	}
	// Re-read on every request: no refresh timer gap and no stale selection.json.
	// Never write auth.json or refresh a token here. Codex remains its owner.
	desktop, desktopErr := desktopCredential(n.path)
	var history []clientHash
	if !n.isLoaded() {
		if b, err := readPrivate(n.cache); err == nil {
			json.Unmarshal(b, &history)
		}
	}
	now := float64(time.Now().Unix())
	n.mu.Lock()
	if !n.loaded {
		n.loaded, n.kept = true, map[string]clientHash{}
		for _, h := range history {
			if len(h.Digest) == 64 {
				n.kept[h.Digest] = h
			}
		}
	}
	changed := false
	for d, h := range n.kept {
		if h.Expires <= now || allowed[h.AccountID] == "" {
			delete(n.kept, d)
			changed = true
		}
	}
	remember := func(a account) {
		if allowed[a.AccountID] != "" && a.Expires > now && a.Access != "" {
			d := digestToken(a.Access)
			if old, ok := n.kept[d]; !ok || old.Expires != a.Expires {
				changed = true
			}
			n.kept[d] = clientHash{d, a.AccountID, a.Expires}
		}
	}
	for _, a := range c.Accounts {
		remember(a)
	}
	if desktopErr == nil && allowed[desktop.AccountID] != "" {
		remember(desktop)
		c.Accounts = append([]account(nil), c.Accounts...)
		for i := range c.Accounts {
			if c.Accounts[i].AccountID == desktop.AccountID {
				c.Accounts[i].Access = desktop.Access
				c.Accounts[i].Expires = desktop.Expires
			}
		}
	}
	if len(n.kept) > 256 {
		for _, h := range n.sortedLocked()[256:] {
			delete(n.kept, h.Digest)
		}
	}
	match := ""
	if bearer != "" {
		digest := digestToken(bearer)
		for _, h := range n.kept {
			if (headerAccount == "" || headerAccount == h.AccountID) && subtle.ConstantTimeCompare([]byte(digest), []byte(h.Digest)) == 1 {
				match = allowed[h.AccountID]
			}
		}
	}
	n.mu.Unlock()
	if changed {
		n.save()
	}
	return c, match
}
func (n *nativeAuth) isLoaded() bool {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.loaded
}

// Newest expiry first. Caller holds mu.
func (n *nativeAuth) sortedLocked() []clientHash {
	out := make([]clientHash, 0, len(n.kept))
	for _, h := range n.kept {
		out = append(out, h)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Expires == out[j].Expires {
			return out[i].Digest < out[j].Digest
		}
		return out[i].Expires > out[j].Expires
	})
	return out
}

// Copies the digests to the private cache file; one writer at a time, each writing the latest set.
func (n *nativeAuth) save() {
	n.write.Lock()
	defer n.write.Unlock()
	n.mu.Lock()
	b, _ := json.Marshal(n.sortedLocked())
	n.mu.Unlock()
	f, err := os.CreateTemp(filepath.Dir(n.cache), ".client-auth-")
	if err != nil {
		return
	}
	defer os.Remove(f.Name())
	if _, err = f.Write(b); err == nil {
		err = f.Sync()
	}
	if closeErr := f.Close(); err == nil && closeErr == nil {
		os.Rename(f.Name(), n.cache)
	}
}
