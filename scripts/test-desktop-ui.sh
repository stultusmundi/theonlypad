#!/bin/sh
# Actual local XCTest UI automation, using a private copy of the supplied app.
set -eu
cd "$(dirname "$0")/.."
source_app=${1:-dist/TheOnlyPad.app}
if [ ! -f "$source_app/Contents/MacOS/TheOnlyPad" ]; then
  echo 'A packaged TheOnlyPad.app is required. Run scripts/package.sh first.' >&2
  exit 2
fi
mkdir -p .local/desktop-ui
run_directory=$(mktemp -d "$PWD/.local/desktop-ui/run.XXXXXX")
ditto "$source_app" "$run_directory/TheOnlyPad.app"
shasum -a 256 "$run_directory/TheOnlyPad.app/Contents/MacOS/TheOnlyPad" > "$run_directory/app.sha256"
# Raw logs/results can contain local paths and UI snapshots; keep them ignored.
if xcodebuild test \
  -project Tests/DesktopUI/GUIProbe.xcodeproj \
  -scheme GUIProbe \
  -destination 'platform=macOS' \
  -derivedDataPath "$PWD/.local/desktop-ui/DerivedData" \
  -resultBundlePath "$run_directory/results.xcresult" \
  -parallel-testing-enabled NO \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 90 \
  -maximum-test-execution-time-allowance 120 \
  "GUI_PROBE_APP_PATH=$run_directory/TheOnlyPad.app" \
  > "$run_directory/test.log" 2>&1; then
  printf 'Desktop UI tests passed. Local results: %s\n' "$run_directory"
else
  result=$?
  printf 'Desktop UI tests failed (exit %s). Inspect local results: %s\n' "$result" "$run_directory" >&2
  exit "$result"
fi
