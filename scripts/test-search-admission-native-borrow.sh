#!/bin/sh
# Explicit hidden AppKit borrow tests. No shown window, posted input, or helper.
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec python3 "$repo_root/Tests/SearchAdmissionNativeIntegration/run_harness.py" "$@"
