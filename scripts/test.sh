#!/bin/zsh
# Runs Visor's tests on a Debug build.
# Usage: ./scripts/test.sh
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen"; exit 1; }
xcodegen generate --quiet
# The test run launches a Debug build; keep it out of Finder's "Open With".
trap './scripts/forget-builds.sh >/dev/null' EXIT
xcodebuild -project Visor.xcodeproj -scheme Visor -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/Test -quiet test
