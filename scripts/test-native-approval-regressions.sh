#!/bin/sh
# One fixed frozen build; Python directly owns each accepted watchdog stage.
set -eu
umask 077
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
exec python3 -B "$repo_root/Tests/NativeApprovalIntegration/run_native_approval_regressions.py" "$@"
