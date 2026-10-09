#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu
if [ "$#" -ne 0 ]; then
  echo 'This runner accepts no arguments.' >&2
  exit 2
fi
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec /usr/bin/python3 -B "$ROOT/Tests/SearchAdmissionFileDarwinIntegration/run_harness.py"
