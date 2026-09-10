#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$#" -eq 0 ]; then
  scripts/swift.sh build --scratch-path .build/search-engine-error-panels
  build_path=$(scripts/swift.sh build --scratch-path .build/search-engine-error-panels --show-bin-path)
elif [ "$#" -eq 1 ]; then
  build_path=$1
else
  echo "usage: $0 [verified-swift-build-path]" >&2
  exit 2
fi
run_directory=.local/search-engine-error-panels
mkdir -p "$run_directory/search-module-cache" "$run_directory/folder-module-cache"
if [ ! -d "$build_path/Modules" ] || [ ! -d "$build_path/PadCore.build" ]; then
  echo "missing verified PadCore build at $build_path" >&2
  exit 2
fi

shasum -a 256 \
  Sources/PadCore/SearchService.swift \
  Sources/PadCore/FolderSearch.swift \
  Sources/TheOnlyPad/SearchPanelController.swift \
  Sources/TheOnlyPad/FolderSearchController.swift \
  Tests/NativeIntegration/SearchHarness.swift \
  Tests/NativeIntegration/FolderSearchHarness.swift \
  > "$run_directory/source-sha256.txt"

xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" \
  -module-cache-path "$run_directory/search-module-cache" -parse-as-library \
  -I "$build_path/Modules" Sources/TheOnlyPad/SearchPanelController.swift \
  Tests/NativeIntegration/SearchHarness.swift "$build_path"/PadCore.build/*.o \
  -o "$run_directory/search-test"

xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" \
  -module-cache-path "$run_directory/folder-module-cache" -parse-as-library \
  -I "$build_path/Modules" Sources/TheOnlyPad/FolderSearchController.swift \
  Tests/NativeIntegration/FolderSearchHarness.swift "$build_path"/PadCore.build/*.o \
  -o "$run_directory/folder-test"

# These harnesses create controls without showing windows, activating the app, or posting input.
python3 - "$run_directory/search-test" "$run_directory/folder-test" <<'PY'
import subprocess
import sys

for executable in sys.argv[1:]:
    subprocess.run([executable], check=True, timeout=20)
PY
