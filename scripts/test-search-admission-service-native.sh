#!/bin/sh
# Exact hidden native facade2. Invoke directly, without another watchdog.
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec python3 -B "$repo_root/Tests/SearchAdmissionServiceNativeIntegration/run_harness.py" "$@"
