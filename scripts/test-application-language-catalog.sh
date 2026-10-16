#!/bin/sh
# Five fixed direct owned stages; no caller Source/build/helper/filter override.
set -eu
if [ "$#" -ne 0 ]; then
  echo 'Fixed application/catalog runner accepts no arguments.' >&2
  exit 125
fi
umask 077
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
exec python3 -B "$repo_root/Tests/NativeIntegration/run_application_language_catalog.py"
