#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu
if [ "$#" -ne 0 ]; then
  echo 'This runner accepts no arguments.' >&2
  exit 2
fi
if [ -L "$0" ]; then
  echo 'A symlink launcher is not supported.' >&2
  exit 2
fi
exec /usr/bin/python3 -B "$(dirname -- "$0")/../Tests/FolderReplacementPreviewIntegration/run_folder_replacement_preview.py"
