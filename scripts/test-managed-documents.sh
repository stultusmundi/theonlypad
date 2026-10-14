#!/bin/sh
# Hidden native checks; the shared coordinator directly owns each accepted watchdog stage.
set -eu
umask 077
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
exec python3 "$repo_root/Tests/NativeIntegration/run_native_regressions.py" managed-documents "$@"
