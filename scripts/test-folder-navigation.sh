#!/bin/sh
# Hidden native navigation checks with the direct owned-process watchdog.
set -eu
umask 077
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
exec python3 -B "$repo_root/Tests/NativeIntegration/run_native_regressions.py" folder-navigation "$@"
