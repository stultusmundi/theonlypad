#!/bin/bash
# Hidden native model tests; no application/controller adoption is performed.
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
if [ "$#" -gt 1 ]; then
  echo 'Usage: scripts/test-native-endpoint-bindings.sh [existing-debug-build-path]' >&2
  exit 2
fi
mkdir -p .local/native-endpoint-bindings
run=$(mktemp -d .local/native-endpoint-bindings/run.XXXXXXXX)
if [ "$#" -eq 1 ]; then
  build_path=$1
else
  scripts/swift.sh build --scratch-path .build/native-endpoint-bindings -c debug > "$run/build.log" 2>&1
  build_path=$(scripts/swift.sh build --scratch-path .build/native-endpoint-bindings -c debug --show-bin-path)
fi
python3 - "$run" "$build_path" <<'PY'
from pathlib import Path
import os, subprocess, signal, json, hashlib, platform, sys
root=Path.cwd(); run=Path(sys.argv[1]).resolve(); binary=Path(sys.argv[2]).resolve()
if not (binary/'Modules/PadCore.swiftmodule').exists() or not list((binary/'PadCore.build').glob('*.o')):
    raise SystemExit('Required existing PadCore module/objects are missing')
source=run/'Sources'; source.mkdir(); hashes={}
names=['NativeDocumentEndpointBindings','NativeFileMonitorClient','EditorDocument','EditorDocumentCloseAdapter','EditorDocumentFactory','NativeDocumentSeed','EditorDocumentWorkspaceAdapter','ApplicationDocuments','DocumentTransferBoundary','WorkspaceDocumentRegistryTypes','EditorPane','DocumentTextView','DocumentPanePresentation','EditorPaneHost','NativeSyntaxHighlighter','LineNumberRuler','DocumentFileStateController','FileMonitorClient']
for name in names:
    path=root/'Sources/TheOnlyPad'/(name+'.swift'); data=path.read_bytes()
    (source/path.name).write_bytes(data); hashes[str(path.relative_to(root))]=hashlib.sha256(data).hexdigest()
for name in ['NativeEndpointBindingsHarness']:
    path=root/'Tests/NativeIntegration'/(name+'.swift'); data=path.read_bytes()
    (run/path.name).write_bytes(data); hashes[str(path.relative_to(root))]=hashlib.sha256(data).hexdigest()
for path in [*binary.glob('PadCore.build/*.o'),*binary.glob('Modules/PadCore.*')]:
    if path.is_file(): hashes[str(path.relative_to(root)) if path.is_relative_to(root) else path.name]=hashlib.sha256(path.read_bytes()).hexdigest()
(run/'source-hashes.json').write_text(json.dumps(hashes,indent=2)+'\n')
def execute(args,name,timeout):
    state=run/(name+'.state'); state.mkdir()
    env=os.environ.copy();env['THEONLYPAD_STATE_DIRECTORY']=str(state)
    with (run/(name+'.log')).open('wb') as log:
        child=subprocess.Popen(args,stdout=log,stderr=subprocess.STDOUT,start_new_session=True,env=env)
        try: return child.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            try: os.killpg(child.pid,signal.SIGKILL)
            except ProcessLookupError: pass
            child.wait(); return 124
status={}
for name in ['NativeEndpointBindingsHarness']:
    command=['xcrun','swiftc','-swift-version','5','-target',platform.machine()+'-apple-macosx14.0','-module-cache-path',str(run/'cache'),'-parse-as-library','-I',str(binary/'Modules'),*map(str,source.glob('*.swift')),str(run/(name+'.swift')),*map(str,(binary/'PadCore.build').glob('*.o')),'-o',str(run/name)]
    status[name+'.compile']=execute(command,name+'.compile',120)
    if status[name+'.compile']==0: status[name]=execute([str(run/name)],name,30)
    (run/'status.json').write_text(json.dumps(status,indent=2)+'\n')
print('Private native endpoint binding evidence:',run.relative_to(root)); print(json.dumps(status,sort_keys=True))
for name,code in status.items():
    if code: print((run/(name+'.log')).read_text())
raise SystemExit(0 if all(value==0 for value in status.values()) else 1)
PY
