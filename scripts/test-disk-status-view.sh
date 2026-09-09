#!/bin/bash
set -euo pipefail
umask 077
repo=$(cd "$(dirname "$0")/.." && pwd)
build=${1:-"$repo/.build/external-action-service/arm64-apple-macosx/debug"}
[[ $# -le 1 && -d "$build/Modules" && -d "$build/PadCore.build" ]] || { echo "Usage: $0 [existing-debug-build-directory]" >&2; exit 2; }
mkdir -p "$repo/.local/disk-status-view"
run=$(mktemp -d "$repo/.local/disk-status-view/run.XXXXXXXX")
echo "$run"
cp "$repo/Sources/TheOnlyPad/DocumentDiskStatusView.swift" "$repo/Sources/TheOnlyPad/FileMonitorClient.swift" "$repo/Tests/NativeIntegration/DocumentDiskStatusHarness.swift" "$run/"
shasum -a 256 "$run"/*.swift > "$run/source-hashes.txt"
xcrun swiftc -target "$(uname -m)-apple-macosx14.0" -swift-version 5 -parse-as-library -module-cache-path "$run/module-cache" -I "$build/Modules" "$run"/*.swift "$build"/PadCore.build/*.o -o "$run/probe" > "$run/compile.log" 2>&1
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
