#!/bin/zsh
# Packages a built Tibot.app for a GitHub release: the zip and SHA256SUMS.txt the installer and the
# auto-updater download. Usage: scripts/package-release.sh v0.4.9-beta.1 path/to/Tibot.app out-dir
# The folder inside the zip keeps the pre-0.4.9 name "Codex Accounts Beta.app": 0.4.8's auto-updater
# looks for it, and the app renames itself to Tibot.app on first launch. Renaming the bundle folder
# does not touch its signature.
set -euo pipefail
tag="$1" app="$2" out="$3"
zip="Codex-Accounts-${tag}-macos-arm64.zip"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$out"
ditto "$app" "$stage/Codex Accounts Beta.app"
codesign --verify --deep --strict "$stage/Codex Accounts Beta.app"
(cd "$stage" && ditto -c -k --norsrc --keepParent "Codex Accounts Beta.app" "$out/$zip")
(cd "$out" && shasum -a 256 "$zip" > SHA256SUMS.txt && cat SHA256SUMS.txt)
