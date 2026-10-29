#!/bin/bash
# One-line install of Codex Accounts:
#   curl -fsSL https://raw.githubusercontent.com/ruanjianjian/codex-account-manager/main/scripts/get.sh | bash
# Downloads the newest release with curl and checks its SHA-256, moves an older copy in ~/Applications
# to the Trash (accounts and settings stay), installs the new one and opens it with --setup-routing, so
# file storage, the desktop account and routing are set up without clicks.
# CODEX_ACCOUNTS_SKIP_SETUP=1 only installs. CODEX_ACCOUNTS_VERSION picks a release tag.
set -euo pipefail

REPO="ruanjianjian/codex-account-manager"
APP_NAME="Codex Accounts Beta.app"
BUNDLE_ID="io.github.ruanjianjian.codex-accounts"
DEST="$HOME/Applications"

say() { printf '%s\n' "$*"; }
fail() { printf '安装未完成：%s\n' "$*" >&2; exit 1; }
running() { pgrep -f "$APP_NAME/Contents/MacOS/" >/dev/null; }

[[ "$(uname -s)" == "Darwin" ]] || fail "只支持 macOS。"
[[ "$(uname -m)" == "arm64" ]] || fail "安装包只支持 Apple 芯片的 Mac；Intel Mac 请从源码构建。"
(( $(sw_vers -productVersion | cut -d. -f1) >= 14 )) || fail "需要 macOS 14 或更新版本。"

tag="${CODEX_ACCOUNTS_VERSION:-}"
if [[ -z "${tag}" ]]; then
  # Releases are pre-releases, which /releases/latest skips; the newest one is listed first.
  tag="$(curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=1" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')" || true
fi
[[ -n "${tag}" ]] || fail "没有找到可下载的版本，请检查网络后重试。"
base="${CODEX_ACCOUNTS_BASE_URL:-https://github.com/$REPO/releases/download/${tag}}"
zip="Codex-Accounts-${tag}-macos-arm64.zip"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
say "下载 Codex Accounts ${tag} …"
curl -fsSL -o "$work/$zip" "$base/$zip" || fail "下载失败，请检查网络后重试。"
curl -fsSL -o "$work/SHA256SUMS.txt" "$base/SHA256SUMS.txt" || fail "校验文件下载失败。"
(cd "$work" && grep " $zip\$" SHA256SUMS.txt | shasum -a 256 -c - >/dev/null) || fail "SHA-256 校验不通过，没有改动任何东西。"
ditto -x -k "$work/$zip" "$work/out"
codesign --verify --deep --strict "$work/out/$APP_NAME" || fail "应用签名校验不通过，没有改动任何东西。"

if running; then
  say "退出正在运行的管家（Codex 会自动回到直连）…"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 40); do running || break; sleep 0.5; done
  running && fail "管家没有退出，请从菜单栏退出后重试。"
fi
mkdir -p "$DEST"
if [[ -e "$DEST/$APP_NAME" ]]; then
  mkdir -p "$HOME/.Trash"
  mv "$DEST/$APP_NAME" "$HOME/.Trash/Codex Accounts Beta $(date +%Y%m%d-%H%M%S).app"
  say "旧版已移到废纸篓，账号和设置保留。"
fi
ditto "$work/out/$APP_NAME" "$DEST/$APP_NAME"

if [[ "${CODEX_ACCOUNTS_SKIP_SETUP:-}" == "1" ]]; then
  open "$DEST/$APP_NAME"
  say "已安装 ${tag}。"
  exit 0
fi
envs=()
[[ -n "${CODEX_ACCOUNTS_DATA_DIR:-}" ]] && envs=(--env "CODEX_ACCOUNTS_DATA_DIR=$CODEX_ACCOUNTS_DATA_DIR")
open ${envs[@]+"${envs[@]}"} "$DEST/$APP_NAME" --args --setup-routing
say "已安装 ${tag}。管家正在自动设置：登录凭据改存本机私有目录（与 Codex 默认方式一致，文件不加密）、连接 Codex 桌面账号、开启路由…"

for _ in $(seq 1 45); do
  grep -q 'openai_base_url.*127\.0\.0\.1' "$HOME/.codex/config.toml" 2>/dev/null && break
  sleep 1
done
if grep -q 'openai_base_url.*127\.0\.0\.1' "$HOME/.codex/config.toml" 2>/dev/null; then
  say "完成：自动路由已开启。请重启一次 Codex，已打开的会话也会经过路由。"
else
  say "管家已打开，但路由还没开启：如果 Codex 桌面还没登录，登录后管家会自动完成；其他情况请看管家设置里的「自动账号路由」。"
fi
