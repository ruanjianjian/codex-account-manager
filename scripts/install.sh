#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
SOURCE="${PUBLIC_DIST_DIR:-$PROJECT_DIR/dist}/Tibot.app"
DESTINATION="$HOME/Applications/Tibot.app"
if [[ ! -d "$SOURCE" ]]; then
  "$PROJECT_DIR/scripts/build.sh"
fi
if [[ -e "$DESTINATION" ]]; then
  print -u2 "Refusing to replace an existing app: $DESTINATION"
  print -u2 "Quit the public beta and move its old app bundle to Trash before installing this build. Your data will remain."
  exit 1
fi
mkdir -p "$HOME/Applications"
ditto "$SOURCE" "$DESTINATION"
codesign --verify --deep --strict "$DESTINATION"
print "Installed: $DESTINATION"
print "Open the app from Finder. No other app or login data was changed."
