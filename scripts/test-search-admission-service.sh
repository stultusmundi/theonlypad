#!/bin/sh
# Exact frozen package compiler/construction stages; no search helper or GUI.
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec python3 -B "$repo_root/Tests/SearchAdmissionServiceIntegration/run_harness.py" "$@"
