#!/bin/bash
# Standalone visible adapter stress benchmark; never part of the native acceptance suite.
set -euo pipefail
cd "$(dirname "$0")/.."
mode=smoke
case "$#:${1:-}" in
  0:) ;;
  1:--full) mode=full ;;
  1:--help|1:-h) echo "Usage: scripts/benchmark-panes.sh [--full]"; exit 0 ;;
  *) echo "Usage: scripts/benchmark-panes.sh [--full]" >&2; exit 2 ;;
esac
umask 077
base="$PWD/.local/pane-benchmarks"
mkdir -p "$base"
run_directory=$(mktemp -d "$base/run.XXXXXX")
mkdir -p "$run_directory/native" "$run_directory/module-cache"
# Run only with exclusive build/GUI ownership. The children activate their synthetic window.
cp Sources/TheOnlyPad/*.swift "$run_directory/native/"
cp Tests/NativeIntegration/SharedPanePerformanceHarness.swift "$run_directory/SharedPanePerformanceHarness.swift"
git rev-parse HEAD > "$run_directory/source-commit.txt"
shasum -a 256 "$run_directory"/native/*.swift "$run_directory/SharedPanePerformanceHarness.swift" > "$run_directory/source-sha256.txt"
scripts/swift.sh build -c release --scratch-path "$base/build"
build_path=$(scripts/swift.sh build -c release --scratch-path "$base/build" --show-bin-path)
swift --version > "$run_directory/swift-version.txt"
native_sources=()
for source in "$run_directory"/native/*.swift; do
  [[ "$source" == */TheOnlyPadApplication.swift ]] || native_sources+=("$source")
done
swiftc -O -swift-version 5 -module-cache-path "$run_directory/module-cache" -parse-as-library \
  -I "$build_path/Modules" "${native_sources[@]}" "$run_directory/SharedPanePerformanceHarness.swift" \
  "$build_path"/PadCore.build/*.o -o "$run_directory/pane-performance"
python3 scripts/benchmark-panes.py "$run_directory" --mode "$mode"
