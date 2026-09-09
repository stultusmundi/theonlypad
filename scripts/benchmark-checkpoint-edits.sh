#!/bin/bash
set -euo pipefail
umask 077
repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"
case "${1:-}" in
  "") pairs=1 ;;
  --full) pairs=3 ;;
  *) echo "Usage: scripts/benchmark-checkpoint-edits.sh [--full]" >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then echo "Only --full is accepted" >&2; exit 2; fi
assets="$repo/Tests/NativeIntegration/CheckpointPerformance"
mkdir -p "$repo/.local/checkpoint-performance"
run=$(mktemp -d "$repo/.local/checkpoint-performance/run.XXXXXXXX")
shasum -a 256 "$repo/scripts/benchmark-checkpoint-edits.sh" > "$run/wrapper-sha256.txt"
echo "Private evidence: .local/checkpoint-performance/$(basename "$run")"
# This must execute successfully: --show-bin-path by itself does not build PadCore.
if ! scripts/swift.sh build -c debug > "$run/padcore-build.log" 2>&1; then
  echo "Debug build failed; inspect the private padcore-build.log" >&2
  exit 1
fi
build_path=$(scripts/swift.sh build -c debug --show-bin-path)
python3 "$assets/prepare.py" "$repo" "$run/private-copy" > "$run/prepare.log" 2>&1
bash "$run/private-copy/compile.sh" "$repo" "$build_path"
python3 "$run/private-copy/run.py" "$pairs"
