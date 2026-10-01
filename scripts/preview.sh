#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product SleepiPreview
python3 - <<'PY'
from pathlib import Path
import plistlib, shutil
root=Path('.build/SleepiPreview.app/Contents')
(root/'MacOS').mkdir(parents=True,exist_ok=True)
shutil.copy2('.build/debug/SleepiPreview',root/'MacOS/SleepiPreview')
with (root/'Info.plist').open('wb') as f:
    plistlib.dump({'CFBundleIdentifier':'app.sleepi.preview','CFBundleName':'SleepiPreview','CFBundleDisplayName':'sleepi · Preview','CFBundleExecutable':'SleepiPreview','CFBundlePackageType':'APPL','LSMinimumSystemVersion':'15.0','NSHighResolutionCapable':True},f)
PY
open .build/SleepiPreview.app
