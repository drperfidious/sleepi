#!/bin/bash
# Compile all four native targets for the simulators without signing. This proves compilation and embedding only;
# it is not an installation, a signed device build, or any of the real-device gates.
# Uses DEVELOPER_DIR when set (e.g. a beta Xcode that isn't selected), otherwise xcode-select's Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${DEVELOPER_DIR:-$(xcode-select -p)}" == *CommandLineTools* ]]; then
  printf '%s\n' 'Xcode is required. Run: DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer scripts/build.sh'
  exit 1
fi
derived=.build/xcode
mkdir -p .build
run() { # label, xcodebuild arguments…
  local label=$1 log=".build/xcode-$1.log"; shift
  if ! xcodebuild -project Sleepi.xcodeproj CODE_SIGNING_ALLOWED=NO "$@" build >"$log" 2>&1; then
    grep -E ': error: ' "$log" | sort -u; echo "$label: build failed, full log in $log"; exit 1
  fi
  echo "$label: build succeeded"
}
run ios -scheme Sleepi -destination 'generic/platform=iOS Simulator' -derivedDataPath "$derived"
run watch -scheme SleepiWatch -destination 'generic/platform=watchOS Simulator' -derivedDataPath "$derived"
