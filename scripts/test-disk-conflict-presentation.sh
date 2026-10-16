#!/bin/sh
# Fixed retained managed Locate presentation regression; synthetic isolated state.
set -eu
cd "$(dirname "$0")/.."
exec python3 -B Tests/NativeIntegration/run_disk_conflict_presentation.py "$@"
