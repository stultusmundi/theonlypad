#!/bin/bash
set -euo pipefail
umask 077
repo=$(cd "$(dirname "$0")/.." && pwd)
[[ $# -eq 0 ]] || { echo "Usage: $0" >&2; exit 2; }
mkdir -p "$repo/.local/disk-conflict-panel"
run=$(mktemp -d "$repo/.local/disk-conflict-panel/run.XXXXXXXX")
echo "$run"
cp "$repo/Sources/TheOnlyPad/DocumentDiskConflictController.swift" "$repo/Tests/NativeIntegration/DocumentDiskConflictHarness.swift" "$run/"
shasum -a 256 "$run"/*.swift > "$run/source-hashes.txt"
xcrun swiftc -target "$(uname -m)-apple-macosx14.0" -swift-version 5 -parse-as-library -module-cache-path "$run/module-cache" "$run"/*.swift -o "$run/probe" > "$run/compile.log" 2>&1
python3 - "$run" <<'PY'
import pathlib,subprocess,sys,json
run=pathlib.Path(sys.argv[1])
with (run/'result.log').open('wb') as log:
 child=subprocess.Popen([str(run/'probe')],stdout=log,stderr=subprocess.STDOUT)
 try: result={'exit':child.wait(timeout=30)}
 except subprocess.TimeoutExpired: child.kill();child.wait();result={'timeout':30,'owned_child_killed_and_reaped':True}
(run/'result.json').write_text(json.dumps(result)+'\n')
print((run/'result.log').read_text())
sys.exit(0 if result.get('exit')==0 else 1)
PY
