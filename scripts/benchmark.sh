#!/bin/zsh
# Stress test: builds a benchmark copy of Visor (never installed) and drives
# it through a folder of images, logging memory and latency.
# Usage: ./scripts/benchmark.sh /path/to/folder/with/images [loops]
set -euo pipefail
cd "$(dirname "$0")/.."
DIR="${1:?Usage: $0 /path/to/images [loops]}"
xcodegen generate --quiet
xcodebuild -project Visor.xcodeproj -scheme Visor -configuration Release \
  -derivedDataPath build/Bench -quiet build OTHER_SWIFT_FLAGS='-D VISOR_BENCH'
# Keep this build out of Finder's "Open With" menu.
./scripts/forget-builds.sh >/dev/null
VISOR_BENCH_DIR="$DIR" VISOR_BENCH_LOOPS="${2:-3}" \
  build/Bench/Build/Products/Release/Visor.app/Contents/MacOS/Visor 2>&1
