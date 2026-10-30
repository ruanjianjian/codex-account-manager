#!/bin/bash
# One-line install of Tibot (the Codex multi-account manager):
#   curl -fsSL https://raw.githubusercontent.com/ruanjianjian/codex-account-manager/main/scripts/get.sh | bash
# Downloads the newest release with curl and checks its SHA-256, moves an older copy in ~/Applications
# to the Trash (accounts and settings stay), installs the new one and opens it with --setup-routing, so
# file storage, the desktop account and routing are set up without clicks.
# CODEX_ACCOUNTS_SKIP_SETUP=1 only installs. CODEX_ACCOUNTS_VERSION picks a release tag.
set -euo pipefail

# Bump with every release: this script is served from main, and asking api.github.com for the newest
# release fails on networks that reach github.com but not the API.
LATEST="v0.4.18-beta.1"
REPO="ruanjianjian/codex-account-manager"
APP_NAME="Tibot.app"
OLD_APP="Codex Accounts Beta.app"   # before 0.4.9; the zip still uses this folder name for older updaters
BUNDLE_ID="io.github.ruanjianjian.codex-accounts"
DEST="$HOME/Applications"

say() { printf '%s\n' "$*"; }
fail() { printf '安装未完成：%s\n' "$*" >&2; exit 1; }
running() { pgrep -f "\.app/Contents/MacOS/CodexAccounts" >/dev/null; }
fetch() { curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 20 "$@"; }
# Terminal curl ignores the macOS system proxy that browsers use; pick it up when none is set.
use_system_proxy() {
  [[ -n "${https_proxy:-}${HTTPS_PROXY:-}${all_proxy:-}${ALL_PROXY:-}" ]] && return 0
  local info host port
  info="$(scutil --proxy 2>/dev/null)" || return 0
  value() { printf '%s\n' "$info" | awk -v key="$1" '$1 == key { print $3; exit }'; }
  if [[ "$(value HTTPSEnable)" == "1" ]]; then
    host="$(value HTTPSProxy)"; port="$(value HTTPSPort)"
    if [[ -n "$host" && -n "$port" ]]; then export https_proxy="http://$host:$port"; say "使用系统代理 $host:$port"; return 0; fi
  fi
  if [[ "$(value SOCKSEnable)" == "1" ]]; then
    host="$(value SOCKSProxy)"; port="$(value SOCKSPort)"
    if [[ -n "$host" && -n "$port" ]]; then export all_proxy="socks5h://$host:$port"; say "使用系统代理 socks5 $host:$port"; fi
  fi
  return 0
}

[[ "$(uname -s)" == "Darwin" ]] || fail "只支持 macOS。"
[[ "$(uname -m)" == "arm64" ]] || fail "安装包只支持 Apple 芯片的 Mac；Intel Mac 请从源码构建。"
(( $(sw_vers -productVersion | cut -d. -f1) >= 14 )) || fail "需要 macOS 14 或更新版本。"

use_system_proxy
# Conversations Codex already has open keep the gateway address they loaded; only a first setup needs a restart.
routing_before=""
grep -q 'openai_base_url.*127\.0\.0\.1' "$HOME/.codex/config.toml" 2>/dev/null && routing_before=1
tag="${CODEX_ACCOUNTS_VERSION:-$LATEST}"
base="${CODEX_ACCOUNTS_BASE_URL:-https://github.com/$REPO/releases/download/${tag}}"
zip="Codex-Accounts-${tag}-macos-arm64.zip"
offline="连不上 GitHub。如果平时要开代理才能上 GitHub，先打开代理（或在终端设置 https_proxy）再重试。"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
say "下载 Tibot ${tag} …"
fetch -o "$work/$zip" "$base/$zip" || fail "安装包下载失败：$offline"
fetch -o "$work/SHA256SUMS.txt" "$base/SHA256SUMS.txt" || fail "校验文件下载失败：$offline"
(cd "$work" && grep " $zip\$" SHA256SUMS.txt | shasum -a 256 -c - >/dev/null) || fail "SHA-256 校验不通过，没有改动任何东西。"
ditto -x -k "$work/$zip" "$work/out"
src="$(find "$work/out" -maxdepth 1 -name '*.app' | head -1)"
[[ -n "$src" ]] || fail "安装包里没有找到 App，没有改动任何东西。"
codesign --verify --deep --strict "$src" || fail "应用签名校验不通过，没有改动任何东西。"

if running; then
  say "退出正在运行的 Tibot（Codex 会自动回到直连）…"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 40); do running || break; sleep 0.5; done
  running && fail "Tibot 没有退出，请从菜单栏退出后重试。"
fi
mkdir -p "$DEST"
for old in "$APP_NAME" "$OLD_APP"; do
  if [[ -e "$DEST/$old" ]]; then
    mkdir -p "$HOME/.Trash"
    mv "$DEST/$old" "$HOME/.Trash/${old%.app} $(date +%Y%m%d-%H%M%S).app"
    say "旧版已移到废纸篓，账号和设置保留。"
  fi
done
ditto "$src" "$DEST/$APP_NAME"

if [[ "${CODEX_ACCOUNTS_SKIP_SETUP:-}" == "1" ]]; then
  open "$DEST/$APP_NAME"
  say "已安装 ${tag}。"
  exit 0
fi
envs=()
[[ -n "${CODEX_ACCOUNTS_DATA_DIR:-}" ]] && envs=(--env "CODEX_ACCOUNTS_DATA_DIR=$CODEX_ACCOUNTS_DATA_DIR")
open ${envs[@]+"${envs[@]}"} "$DEST/$APP_NAME" --args --setup-routing
if [[ -n "$routing_before" ]]; then
  say "已安装 ${tag}，Tibot 正在重新接管路由…"
else
  say "已安装 ${tag}。Tibot 正在自动设置：登录凭据改存本机私有目录（与 Codex 默认方式一致，文件不加密）、连接 Codex 桌面账号、开启路由…"
fi

for _ in $(seq 1 45); do
  grep -q 'openai_base_url.*127\.0\.0\.1' "$HOME/.codex/config.toml" 2>/dev/null && break
  sleep 1
done
if grep -q 'openai_base_url.*127\.0\.0\.1' "$HOME/.codex/config.toml" 2>/dev/null; then
  if [[ -n "$routing_before" ]]; then
    say "完成：已更新到 ${tag}，自动路由保持开启，不用重启 Codex。"
  else
    say "完成：自动路由已开启。新开的 Codex 会话直接生效；已经开着的会话重启一次 Codex 后也会经过路由。以后更新不用再重启。"
  fi
else
  say "Tibot 已打开，但路由还没开启：如果 Codex 桌面还没登录，登录后 Tibot 会自动完成；其他情况请看 Tibot 设置里的「自动账号路由」。"
fi
