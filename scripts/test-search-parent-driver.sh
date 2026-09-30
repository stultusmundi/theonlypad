#!/bin/sh
# Frozen parent driver ownership tests. No real child or GUI.
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec python3 "$repo_root/Tests/SearchParentDriverIntegration/run_harness.py" "$@"
