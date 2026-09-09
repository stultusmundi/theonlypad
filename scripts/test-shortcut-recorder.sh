#!/bin/bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
if [ "$#" -gt 1 ]; then
  echo 'Usage: scripts/test-shortcut-recorder.sh [existing-debug-build-path]' >&2
  exit 2
fi
mkdir -p .local/shortcut-recorder-retained
run=$(mktemp -d .local/shortcut-recorder-retained/run.XXXXXXXX)
echo "Private shortcut recorder evidence: $run"
if [ "$#" -eq 1 ]; then
  build_path=$1
else
  scripts/swift.sh build --scratch-path .build/shortcut-recorder -c debug > "$run/build.log" 2>&1
  build_path=$(scripts/swift.sh build --scratch-path .build/shortcut-recorder -c debug --show-bin-path)
fi
cp Sources/TheOnlyPad/NativeKeyboardShortcut.swift Sources/TheOnlyPad/ShortcutRecorderView.swift Tests/NativeIntegration/ShortcutRecorderHarness.swift "$run/"
swiftc -target "$(uname -m)-apple-macosx14.0" -swift-version 5 \
  -module-cache-path .local/shortcut-recorder-retained/module-cache -parse-as-library \
  -I "$build_path/Modules" "$run"/*.swift \
  "$build_path"/PadCore.build/*.o -o "$run/probe" > "$run/compile.log" 2>&1
python3 - "$run" <<'PY'
import hashlib,json,pathlib,subprocess,sys
run=pathlib.Path(sys.argv[1])
sources={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in run.glob('*.swift')}
with (run/'result.log').open('wb') as log:
    child=subprocess.Popen([str(run/'probe')],stdout=log,stderr=subprocess.STDOUT)
    try:
        code=child.wait(timeout=30)
        result={'exit':code,'sources':sources}
    except subprocess.TimeoutExpired:
        child.kill();child.wait();code=124
        result={'exit':code,'sources':sources,'timeoutSeconds':30,'killedAndReaped':True}
(run/'status.json').write_text(json.dumps(result)+'\n')
print((run/'result.log').read_text(),end='')
raise SystemExit(code)
PY
