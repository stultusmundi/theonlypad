#!/bin/sh
# Actual fixed-helper checks. This coordinator directly owns each watchdog stage.
# Do not wrap it in another process-group/session-owning watchdog.
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec python3 "$repo_root/Tests/SearchWorkerIntegration/run_harness.py" "$@"
