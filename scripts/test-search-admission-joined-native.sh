#!/bin/sh
# Complete hidden native suite. Invoke directly; never nest another watchdog.
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec python3 "$repo_root/Tests/SearchAdmissionJoinedNativeIntegration/run_harness.py" "$@"
