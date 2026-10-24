#!/bin/zsh
# Builds Visor in Release mode, installs it in /Applications and makes it the
# default app for every image type.
# Usage: ./scripts/install.sh
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen"; exit 1; }

# A stable signature keeps macOS from treating every update as a new app.
IDENTITY="${VISOR_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/"/ { print $2; exit }')
fi

xcodegen generate --quiet
xcodebuild -project Visor.xcodeproj -scheme Visor -configuration Release \
  -derivedDataPath build/DD -quiet build

APP="build/DD/Build/Products/Release/Visor.app"
if [[ -n "$IDENTITY" ]]; then
  echo "Signing with: $IDENTITY"
  codesign --force --options runtime --sign "$IDENTITY" "$APP"
fi
osascript -e 'quit app "Visor"' 2>/dev/null || true
while pgrep -xq Visor; do sleep 0.2; done
rm -rf /Applications/Visor.app
cp -R "$APP" /Applications/
echo "Installed /Applications/Visor.app"

# Register the copy in /Applications so Finder offers it for images.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Visor.app

# Becoming the default app needs your confirmation in macOS's own dialogs.
# Visor asks for as few as it can and quits when done. Skip with --no-default.
if [[ "${1:-}" != "--no-default" ]]; then
  open -a /Applications/Visor.app --args --make-default
fi
