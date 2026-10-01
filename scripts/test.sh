#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
developer_dir="$(xcode-select -p)"
if [[ "$developer_dir" == *CommandLineTools* ]]; then
  # This CLT ships Testing as a framework but omits its Foundation cross-import overlay.
  swift test --disable-xctest \
    -Xswiftc -F -Xswiftc "$developer_dir/Library/Developer/Frameworks" \
    -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
    -Xlinker -rpath -Xlinker "$developer_dir/Library/Developer/Frameworks"
else
  swift test
fi
swift build --target SleepiAudio
swift build --product SleepiPreview
python3 scripts/check_invariants.py
