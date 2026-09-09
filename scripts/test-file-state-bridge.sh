#!/bin/bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
if [ "$#" -gt 1 ]; then
  echo 'Usage: scripts/test-file-state-bridge.sh [existing-debug-build-path]' >&2
  exit 2
fi
mkdir -p .local/file-state-bridge
run=$(mktemp -d .local/file-state-bridge/run.XXXXXXXX)
echo "Private bridge evidence: $run"
if [ "$#" -eq 1 ]; then
  build_path=$1
else
  scripts/swift.sh build --scratch-path .build/file-state-bridge -c debug > "$run/build.log" 2>&1
  build_path=$(scripts/swift.sh build --scratch-path .build/file-state-bridge -c debug --show-bin-path)
fi
bridge_sources=(Sources/TheOnlyPad/FileMonitorClient.swift Sources/TheOnlyPad/DocumentFileStateController.swift Sources/TheOnlyPad/NativeFileMonitorClient.swift Sources/TheOnlyPad/ApplicationFileMonitoring.swift)
for harness in FileStateBridgeHarness FileStateBridgeServiceHarness ApplicationFileMonitoringHarness; do
  swiftc -target "$(uname -m)-apple-macosx14.0" -swift-version 6 -module-cache-path .local/file-state-bridge/module-cache \
    -parse-as-library -I "$build_path/Modules" "${bridge_sources[@]}" \
    "Tests/NativeIntegration/$harness.swift" "$build_path"/PadCore.build/*.o \
    -o "$run/$harness" > "$run/$harness.compile.log" 2>&1
  python3 - "$run" "$harness" <<'PY'
import json,pathlib,subprocess,sys
run=pathlib.Path(sys.argv[1]);name=sys.argv[2]
fixture=run/(name+'-fixture');fixture.mkdir()
with (run/(name+'.log')).open('wb') as log:
    child=subprocess.Popen([str(run/name),str(fixture)],stdout=log,stderr=subprocess.STDOUT)
    try:
        code=child.wait(timeout=60)
        result={'exit':code}
    except subprocess.TimeoutExpired:
        child.kill();child.wait();code=124
        result={'exit':code,'timeoutSeconds':60,'killedAndReaped':True}
(run/(name+'.status.json')).write_text(json.dumps(result)+'\n')
print((run/(name+'.log')).read_text(),end='')
raise SystemExit(code)
PY
done
