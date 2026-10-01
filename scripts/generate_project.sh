#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if command -v xcodegen >/dev/null; then
  xcodegen generate
elif [[ -x .build/tools/xcodegen/bin/xcodegen ]]; then
  .build/tools/xcodegen/bin/xcodegen generate
else
  printf '%s\n' 'Install XcodeGen 2.46 or newer, then run this script again. The generated project is already checked in.'
  exit 1
fi
