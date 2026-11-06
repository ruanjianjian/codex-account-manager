# Codex Accounts local gateway

Codex-only HTTP/SSE routing helper, implemented in Go with klauspost/compress for native zstd requests. It pools the connected accounts, keeps each session on the account that served it and falls back to another account before any content is emitted.

The app exports short-lived access tokens only to a 0600 pool file within its private 0700 directory. OAuth refresh tokens stay with the existing credential owner. The helper never calls Keychain, discovers other applications' accounts, refreshes OAuth tokens, edits Codex files or consumes reset credits.

Only loopback clients with a per-install random bearer key or an exact, unexpired connected-account token may connect. Browser requests are refused. The only production upstream is `https://chatgpt.com/backend-api/codex`; redirects are never followed. Private bounded logs contain timestamps, session IDs, slot IDs/status/token counts only. Only an account's own refusals (401/403/429, or a quota or rate-limit failure in the stream) pause it. A service error is tried on one more account at most and pauses nobody, unless three different conversations fail on that account within a minute with no success in between (then it rests 30 s). A network or proxy failure ends the request at once with what failed (a fixed category in the log) and changes no account. Failures about the request itself, and all response headers (rate limits, models etag, turn state), reach Codex as the service sent them; request headers pass through except the ones the gateway owns. Text/tool output is never automatically replayed. Account-bound encrypted history cannot move between accounts; unknown sealed history requires explicitly choosing its original account or a new conversation. Session affinity is saved in a private file and reused after restart. Native legacy conversations with sealed history initially retain the authenticated original account.

Requests to both `/responses` and `/responses/compact` allow up to 128 MiB on the wire and after decoding (identity, gzip, or zstd). This accommodates inline screenshot histories that exceed the former 32 MiB limit before token-based compaction. Larger requests still receive HTTP 413; upstream limits remain independent.

Request-size regression coverage (`request_size_test.go`):

| Case | Expected result |
|---|---|
| 33 MiB request, identity/gzip/zstd, responses or compaction | Reaches upstream with the input and service tier intact |
| More than 128 MiB decoded input, identity/gzip/zstd | HTTP 413 before upstream routing |

The body limit is not a process memory limit: buffering, decoding and JSON handling can hold multiple copies of a request, and concurrent large requests add to that cost. Small requests do not preallocate the limit. This change does not compact, resize or discard conversation content.

`go test -race ./...` and `go build -trimpath -o ../.build/gateway/AccountsGateway .`. The app retains the built-in OpenAI provider and sets openai_base_url, so native old and new conversations use the gateway after restarting Codex. It preserves service_tier (Fast). The first beta provider table remains for conversations created on that version. Official client-side quota blocking still applies to native mode; sealed history cannot be moved to a different account to bypass it. Keep the app running while using the gateway. No claim of seamless recovery in an already-streaming turn.
