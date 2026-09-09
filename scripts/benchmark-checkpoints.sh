#!/bin/bash
# Standalone cost probe; not part of test-native-integration.sh or desktop acceptance.
set -euo pipefail
cd "$(dirname "$0")/.."
umask 077
mkdir -p .local/checkpoint-benchmarks
run_directory=$(mktemp -d .local/checkpoint-benchmarks/run.XXXXXX)
build_directory="$PWD/.local/checkpoint-benchmarks/build"
scripts/swift.sh build -c release --scratch-path "$build_directory"
build_path=$(scripts/swift.sh build -c release --scratch-path "$build_directory" --show-bin-path)
swift --version > "$run_directory/swift-version.txt"
mkdir -p "$run_directory/module-cache"
native_sources=()
for source in Sources/TheOnlyPad/*.swift; do
  if [ "$source" != "Sources/TheOnlyPad/TheOnlyPadApplication.swift" ]; then
    native_sources+=("$source")
  fi
done
swiftc -O -swift-version 5 -module-cache-path "$run_directory/module-cache" -parse-as-library \
  -I "$build_path/Modules" "${native_sources[@]}" \
  Tests/NativeIntegration/CheckpointPerformanceHarness.swift "$build_path"/PadCore.build/*.o \
  -o "$run_directory/checkpoint-performance"
python3 - "$run_directory" <<'PY'
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1]).resolve()
for size in (1_000_000, 10_000_000, 100_000_000):
    # Fresh process per size limits the RSS high-water scope. A failed/expired size is not
    # replaced with a smaller target. Logs/results are ignored local artifacts only.
    with (root / f"{size}.json").open("wb") as output, (root / f"{size}.stderr").open("wb") as errors:
        subprocess.run(
            [str(root / "checkpoint-performance"), str(size),
             str(root / f"work-{size}"), str(root / "swift-version.txt")],
            stdout=output, stderr=errors, check=True, timeout=900,
        )
print(f"Raw checkpoint samples: {root}")
print("Hidden capture and filesystem cost only; not keystroke/end-to-end or desktop acceptance.")
PY
