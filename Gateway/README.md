# Codex Accounts local gateway

Codex-only HTTP/SSE routing helper, built from Go standard-library source. Design inspired by [yetone/Magpie](https://github.com/yetone/magpie) (MIT): account pools, session affinity and fallback before content is emitted. This helper is independently implemented; it does not vendor Magpie source or its multi-provider desktop integration.

The app exports short-lived access tokens only to a 0600 pool file within its private 0700 directory. OAuth refresh tokens stay with the existing credential owner. The helper never calls Keychain, discovers other applications' accounts, refreshes OAuth tokens, edits Codex files or consumes reset credits.

Only loopback clients with a per-install random bearer key may connect. Browser requests are refused. The only production upstream is `https://chatgpt.com/backend-api/codex`; redirects are never followed. Logs contain slot IDs/status/token counts only. Quota failures cool accounts down; text/tool output is never automatically replayed. Account-bound encrypted history cannot move between accounts; unknown sealed history requires explicitly choosing its original account or a new conversation. Session affinity is in memory in this first beta; a helper restart may require selecting the original account for a sealed conversation.

`go test -race ./...` and `go build -trimpath -o ../.build/gateway/AccountsGateway .`. The app uses a custom Responses provider: first activation/deactivation requires restarting Codex and using a new conversation. Cloud/remote features may differ in provider mode. Keep the app running while using the gateway. No claim of seamless recovery in an already-streaming turn.
