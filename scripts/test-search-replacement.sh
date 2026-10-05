#!/bin/sh
# Hidden actual search replacement checks; coordinator directly owns each watchdog stage.
set -eu
umask 077
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
exec python3 "$repo_root/Tests/NativeIntegration/run_native_regressions.py" search-replacement "$@"
