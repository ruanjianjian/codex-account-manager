package main

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/klauspost/compress/zstd"
)

func encodedRequest(t *testing.T, body []byte, encoding string) []byte {
	t.Helper()
	switch encoding {
	case "identity":
		return body
	case "gzip":
		var b bytes.Buffer
		w := gzip.NewWriter(&b)
		if _, err := w.Write(body); err != nil {
			t.Fatal(err)
		}
		if err := w.Close(); err != nil {
			t.Fatal(err)
		}
		return b.Bytes()
	case "zstd":
		w, err := zstd.NewWriter(nil, zstd.WithEncoderConcurrency(1))
		if err != nil {
			t.Fatal(err)
		}
		defer w.Close()
		return w.EncodeAll(body, nil)
	default:
		t.Fatal("unknown encoding")
		return nil
	}
}

// Screenshot-heavy histories can exceed 32 MiB before token-based compaction.
// Both normal requests and compaction must reach upstream with their data intact.
func TestScreenshotHistoryAbove32MiB(t *testing.T) {
	input := "begin-" + strings.Repeat("a", 33<<20) + "-end"
	body, err := json.Marshal(map[string]any{"input": input, "service_tier": "priority"})
	if err != nil {
		t.Fatal(err)
	}
	for _, route := range []string{"/responses", "/responses/compact"} {
		for _, encoding := range []string{"identity", "gzip", "zstd"} {
			t.Run(route+"/"+encoding, func(t *testing.T) {
				seen := false
				up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					seen = true
					var got struct {
						Input       string
						ServiceTier string `json:"service_tier"`
					}
					if err := json.NewDecoder(r.Body).Decode(&got); err != nil {
						t.Error(err)
					}
					if got.Input != input || got.ServiceTier != "priority" {
						t.Error("request data changed")
					}
					if route == "/responses" {
						w.Header().Set("Content-Type", "text/event-stream")
						io.WriteString(w, good)
					} else {
						io.WriteString(w, `{"output":[]}`)
					}
				}))
				defer up.Close()
				g := newGateway(func() (config, error) { return pool(), nil }, up.URL, func(event) {})
				r := httptest.NewRequest("POST", "http://127.0.0.1:18456/backend-api/codex"+route, bytes.NewReader(encodedRequest(t, body, encoding)))
				r.Header.Set("Authorization", "Bearer token-one")
				r.Header.Set("Content-Encoding", encoding)
				w := httptest.NewRecorder()
				g.ServeHTTP(w, r)
				if w.Code != 200 || !seen {
					t.Fatalf("status=%d reached_upstream=%v response=%s", w.Code, seen, w.Body.String())
				}
			})
		}
	}
}

func TestRequestAbove128MiBStillRejected(t *testing.T) {
	body := bytes.Repeat([]byte("a"), (128<<20)+1)
	for _, encoding := range []string{"identity", "gzip", "zstd"} {
		t.Run(encoding, func(t *testing.T) {
			g := newGateway(func() (config, error) { return pool(), nil }, "http://127.0.0.1:1", func(event) {})
			r := httptest.NewRequest("POST", "http://127.0.0.1:18456/v1/responses", bytes.NewReader(encodedRequest(t, body, encoding)))
			r.Header.Set("Authorization", "Bearer token-one")
			r.Header.Set("Content-Encoding", encoding)
			w := httptest.NewRecorder()
			g.ServeHTTP(w, r)
			if w.Code != 413 {
				t.Fatalf("status=%d", w.Code)
			}
		})
	}
}
