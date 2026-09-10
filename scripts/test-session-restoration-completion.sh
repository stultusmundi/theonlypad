#!/bin/bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
if [ "$#" -gt 1 ]; then
  echo 'Usage: scripts/test-session-restoration-completion.sh [existing-debug-build-path]' >&2
  exit 2
fi
mkdir -p .local/session-restoration-completion
run=$(mktemp -d .local/session-restoration-completion/run.XXXXXXXX)
echo "Private session completion evidence: $run"
if [ "$#" -eq 1 ]; then
  build_path=$1
else
  scripts/swift.sh build --scratch-path .build/session-restoration-completion -c debug > "$run/build.log" 2>&1
  build_path=$(scripts/swift.sh build --scratch-path .build/session-restoration-completion -c debug --show-bin-path)
fi
sources=(Sources/TheOnlyPad/NativeDocumentSeed.swift Sources/TheOnlyPad/SessionRestorationController.swift)
swiftc -target "$(uname -m)-apple-macosx14.0" -swift-version 5 \
  -module-cache-path .local/session-restoration-completion/module-cache -parse-as-library \
  -I "$build_path/Modules" "${sources[@]}" Tests/NativeIntegration/SessionRestorationCompletionHarness.swift \
  "$build_path"/PadCore.build/*.o -o "$run/probe" > "$run/compile.log" 2>&1
# Compatibility compilation only: the legacy harness displays windows and is not run here.
swiftc -target "$(uname -m)-apple-macosx14.0" -swift-version 5 \
  -module-cache-path .local/session-restoration-completion/module-cache -parse-as-library \
  -I "$build_path/Modules" "${sources[@]}" Tests/NativeIntegration/SessionRestorationHarness.swift \
  "$build_path"/PadCore.build/*.o -o "$run/legacy-compile-only" > "$run/legacy-compile.log" 2>&1
python3 - "$run" <<'PY'
import json,pathlib,subprocess,sys
run=pathlib.Path(sys.argv[1])
fixture=run/'fixture';fixture.mkdir()
with (run/'result.log').open('wb') as log:
    child=subprocess.Popen([str(run/'probe'),str(fixture)],stdout=log,stderr=subprocess.STDOUT)
    try:
        code=child.wait(timeout=60)
        result={'exit':code}
    except subprocess.TimeoutExpired:
        child.kill();child.wait();code=124
        result={'exit':code,'timeoutSeconds':60,'killedAndReaped':True}
(run/'status.json').write_text(json.dumps(result)+'\n')
print((run/'result.log').read_text(),end='')
raise SystemExit(code)
PY
