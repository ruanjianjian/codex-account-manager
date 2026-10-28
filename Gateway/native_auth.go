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
}

func (n *nativeAuth) validateDesktop(c config) error {
	a, err := desktopCredential(n.path)
	if err != nil {
		return err
	}
	for _, id := range c.Clients {
		if id.AccountID == a.AccountID && id.ID != "" {
			return nil
		}
	}
	return errors.New("desktop account not enrolled")
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

func (n *nativeAuth) authenticate(c config, bearer, headerAccount string) (config, string, error) {
	n.mu.Lock()
	defer n.mu.Unlock()
	allowed := map[string]string{}
	for _, id := range c.Clients {
		if id.ID != "" && id.AccountID != "" {
			allowed[id.AccountID] = id.ID
		}
	}
	var history []clientHash
	if b, err := readPrivate(n.cache); err == nil {
		if json.Unmarshal(b, &history) != nil {
			return c, "", errors.New("invalid client registry")
		}
	} else if !os.IsNotExist(err) {
		return c, "", err
	}
	now := float64(time.Now().Unix())
	kept := map[string]clientHash{}
	for _, h := range history {
		if h.Expires > now && allowed[h.AccountID] != "" && len(h.Digest) == 64 {
			kept[h.Digest] = h
		}
	}
	remember := func(a account) {
		if allowed[a.AccountID] != "" && a.Expires > now && a.Access != "" {
			d := digestToken(a.Access)
			kept[d] = clientHash{d, a.AccountID, a.Expires}
		}
	}
	for _, a := range c.Accounts {
		remember(a)
	}
	// Re-read on every request: no refresh timer gap and no stale selection.json.
	// Never write auth.json or refresh a token here. Codex remains its owner.
	if desktop, err := desktopCredential(n.path); err == nil && allowed[desktop.AccountID] != "" {
		remember(desktop)
		c.Accounts = append([]account(nil), c.Accounts...)
		for i := range c.Accounts {
			if c.Accounts[i].AccountID == desktop.AccountID {
				c.Accounts[i].Access = desktop.Access
				c.Accounts[i].Expires = desktop.Expires
			}
		}
	}
	var next []clientHash
	for _, h := range kept {
		next = append(next, h)
	}
	sort.Slice(next, func(i, j int) bool {
		if next[i].Expires == next[j].Expires {
			return next[i].Digest < next[j].Digest
		}
		return next[i].Expires > next[j].Expires
	})
	if len(next) > 256 {
		next = next[:256]
	}
	b, _ := json.Marshal(next)
	old, _ := json.Marshal(history)
	if string(b) != string(old) {
		f, err := os.CreateTemp(filepath.Dir(n.cache), ".client-auth-")
		if err != nil {
			return c, "", err
		}
		defer os.Remove(f.Name())
		if _, err = f.Write(b); err == nil {
			err = f.Sync()
		}
		closeErr := f.Close()
		if err == nil {
			err = closeErr
		}
		if err == nil {
			err = os.Rename(f.Name(), n.cache)
		}
		if err != nil {
			return c, "", err
		}
	}
	digest := digestToken(bearer)
	for _, h := range next {
		if (headerAccount == "" || headerAccount == h.AccountID) && subtle.ConstantTimeCompare([]byte(digest), []byte(h.Digest)) == 1 {
			return c, allowed[h.AccountID], nil
		}
	}
	return c, "", nil
}
