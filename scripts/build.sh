#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
OUTPUT_DIR="${PUBLIC_DIST_DIR:-$PROJECT_DIR/dist}"
APP_DIR="$OUTPUT_DIR/Codex Accounts Beta.app"
cd "$PROJECT_DIR"
if [[ -e "$APP_DIR" ]]; then
  print -u2 "Output already exists: $APP_DIR. Choose a new PUBLIC_DIST_DIR or move the previous build."
  exit 1
fi
mkdir -p .build/gateway
(cd Gateway && go build -trimpath -ldflags='-s -w' -o ../.build/gateway/AccountsGateway .)
swift build -c release -Xswiftc -file-prefix-map -Xswiftc "$PROJECT_DIR=." -Xswiftc -debug-prefix-map -Xswiftc "$PROJECT_DIR=."
BIN_DIR="$(swift build -c release --show-bin-path)"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Helpers"
cp "$BIN_DIR/CodexAccounts" "$APP_DIR/Contents/MacOS/CodexAccounts"
strip -S "$APP_DIR/Contents/MacOS/CodexAccounts"
cp .build/gateway/AccountsGateway "$APP_DIR/Contents/Helpers/AccountsGateway"
cp Gateway/README.md "$APP_DIR/Contents/Resources/Gateway-NOTICE.md"
cp LICENSE "$APP_DIR/Contents/Resources/LICENSE"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.ruanjianjian.codex-accounts</string>
<key>CFBundleName</key><string>Codex Accounts Beta</string>
<key>CFBundleDisplayName</key><string>Codex Accounts Beta</string>
<key>CFBundleExecutable</key><string>CodexAccounts</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>CFBundleVersion</key><string>3</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSMultipleInstancesProhibited</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
# Signing is explicit: never pick a developer identity from the local Keychain.
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
  codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp "$APP_DIR/Contents/Helpers/AccountsGateway"
  codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp "$APP_DIR"
else
  codesign --force --sign - --options runtime "$APP_DIR/Contents/Helpers/AccountsGateway"
  codesign --force --sign - --options runtime "$APP_DIR"
fi
codesign --verify --deep --strict "$APP_DIR"
print "Built: $APP_DIR"
