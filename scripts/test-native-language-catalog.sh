#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
exec python3 -B Tests/NativeIntegration/run_native_language_catalog.py "$@"
