#!/bin/bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
if [ "$#" -gt 1 ]; then
  echo 'Usage: scripts/test-shortcut-editor.sh [existing-debug-build-path]' >&2
  exit 2
fi
mkdir -p .local/shortcut-editor-native
run=$(mktemp -d .local/shortcut-editor-native/run.XXXXXXXX)
echo "Private shortcut editor evidence: $run"
if [ "$#" -eq 1 ]; then
  build_path=$1
else
  scripts/swift.sh build --scratch-path .build/shortcut-editor-native -c debug > "$run/build.log" 2>&1
  build_path=$(scripts/swift.sh build --scratch-path .build/shortcut-editor-native -c debug --show-bin-path)
fi
python3 - "$run" <<'PY'
import hashlib,json,pathlib,sys
run=pathlib.Path(sys.argv[1]);copied=run/'Sources';copied.mkdir()
paths=[pathlib.Path('Sources/TheOnlyPad')/name for name in (
 'KeyboardShortcutController.swift','ShortcutEditorBoundary.swift',
 'NativeKeyboardShortcut.swift','ShortcutRecorderView.swift')]
hashes={}
for source in paths:
    data=source.read_bytes();(copied/source.name).write_bytes(data)
    hashes[str(source)]=hashlib.sha256(data).hexdigest()
fixture=pathlib.Path('Tests/NativeIntegration/ShortcutEditorFixtures.inc')
harness=pathlib.Path('Tests/NativeIntegration/ShortcutEditorHarness.swift')
for source in (fixture,harness):
    data=source.read_bytes();(run/source.name).write_bytes(data)
    hashes[str(source)]=hashlib.sha256(data).hexdigest()
# The only source transformation: append the documented test-only extension.
controller=copied/'KeyboardShortcutController.swift'
combined=controller.read_bytes()+b'\n'+fixture.read_bytes()
controller.write_bytes(combined)
hashes['combined-controller-with-test-extension']=hashlib.sha256(combined).hexdigest()
(run/'source-hashes.json').write_text(json.dumps(hashes,indent=2)+'\n')
PY
swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" \
  -module-cache-path .local/shortcut-editor-native/module-cache -parse-as-library \
  -I "$build_path/Modules" "$run"/Sources/*.swift "$run/ShortcutEditorHarness.swift" \
  "$build_path"/PadCore.build/*.o -o "$run/probe" > "$run/compile.log" 2>&1
python3 - "$run" <<'PY'
import json,pathlib,subprocess,sys
run=pathlib.Path(sys.argv[1])
with (run/'result.log').open('wb') as log:
    child=subprocess.Popen([str(run/'probe')],stdout=log,stderr=subprocess.STDOUT)
    try:
        code=child.wait(timeout=30);result={'exit':code}
    except subprocess.TimeoutExpired:
        child.kill();child.wait();code=124
        result={'exit':code,'timeoutSeconds':30,'killedAndReaped':True}
(run/'status.json').write_text(json.dumps(result)+'\n')
print((run/'result.log').read_text(),end='')
raise SystemExit(code)
PY
