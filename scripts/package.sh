#!/bin/zsh
# Builds a signed Release copy of Visor and zips it for another Mac.
# Usage: ./scripts/package.sh   ->   dist/Visor-<version>.zip
# On the other Mac: unzip, move Visor.app to /Applications and open it once;
# it offers to become the default image viewer.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen"; exit 1; }

IDENTITY="${VISOR_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/"/ { print $2; exit }')
fi

xcodegen generate --quiet
xcodebuild -project Visor.xcodeproj -scheme Visor -configuration Release \
  -derivedDataPath build/DD -quiet build
# Keep this build out of Finder's "Open With" menu.
./scripts/forget-builds.sh >/dev/null

APP="build/DD/Build/Products/Release/Visor.app"
if [[ -n "$IDENTITY" ]]; then
  echo "Signing with: $IDENTITY"
  codesign --force --options runtime --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
mkdir -p dist
ZIP="dist/Visor-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Packaged $ZIP"
