#!/bin/sh
# Frozen infrastructure checks; no helper/fault fixture is built or launched.
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec python3 "$repo_root/Tests/SearchChildIntegration/run_harness.py" "$@"
