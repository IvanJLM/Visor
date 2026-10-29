#!/bin/zsh
# Takes every Visor build except /Applications/Visor.app out of
# Finder's "Open With" menu.
# Usage: ./scripts/forget-builds.sh
#
# Xcode registers each app it builds with LaunchServices, so every DerivedData
# copy (build/DD, build/Test, build/Bench or a scratch build) shows up in
# "Open With" as one more Visor. install.sh, package.sh, test.sh and
# benchmark.sh run this after building. The copies stay on disk; only their
# registration goes.
set -euo pipefail

BUNDLE_ID="com.ivanjlm.visor"
KEEP="/Applications/Visor.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

"$LSREGISTER" -dump 2>/dev/null | awk -v id="$BUNDLE_ID" '
  /^-+$/ { path = "" }
  /^path:/ { sub(/^path: +/, ""); sub(/ \(0x[0-9a-f]+\)$/, ""); path = $0 }
  /^identifier:/ && $2 == id && path != "" { print path; path = "" }
' | sort -u | while IFS= read -r app; do
  [[ "$app" == "$KEEP" ]] && continue
  "$LSREGISTER" -u "$app" 2>/dev/null || true
  echo "Forgot $app"
done
