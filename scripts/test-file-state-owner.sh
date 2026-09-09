#!/bin/bash
# Hidden native owner-authority tests. Uses an existing build; never launches the application.
set -euo pipefail
umask 077
repo=$(cd "$(dirname "$0")/.." && pwd)
build="$repo/.build/external-file-integration/arm64-apple-macosx/debug"
if [[ $# -gt 0 ]]; then
  [[ $# -eq 2 && "$1" == --build-path ]] || { echo "Usage: $0 [--build-path DEBUG_BIN_DIRECTORY]" >&2; exit 2; }
  build=$2
fi
[[ -d "$build/Modules" && -d "$build/PadCore.build" ]] || { echo "Build PadCore first, or supply --build-path." >&2; exit 2; }
output="$repo/.local/file-state-owner-tests"
mkdir -p "$output"
run=$(mktemp -d "$output/run.XXXXXXXX")
echo "$run"
python3 - "$repo" "$run" "$build" <<'PY'
import difflib,hashlib,json,os,pathlib,platform,subprocess,sys
repo,run,build=map(lambda p:pathlib.Path(p).resolve(),sys.argv[1:])
def digest(data): return hashlib.sha256(data).hexdigest()
def require(condition,message):
    if not condition: raise SystemExit(message)
native=run/'native';native.mkdir()
manifest={}
excluded={'AppDelegate.swift','TheOnlyPadApplication.swift'}
for source in sorted((repo/'Sources/TheOnlyPad').glob('*.swift')):
    if source.name in excluded: continue
    data=source.read_bytes();(native/source.name).write_bytes(data)
    manifest[str(source.relative_to(repo))]=digest(data)
tests=repo/'Tests/NativeIntegration'
for name in ['FileStateOwnerHarness.swift','FileStateOwnerControllerHarness.swift',
             'FileStateOwnerModelAccess.swift','FileStateOwnerControllerAccess.swift']:
    data=(tests/name).read_bytes();(run/name).write_bytes(data)
    manifest[str((tests/name).relative_to(repo))]=digest(data)
model=native/'EditorDocument.swift';controller=native/'EditorWindowController.swift'
original_model=model.read_text();original_controller=controller.read_text()
require(original_model.count('final class EditorDocument {')==1,'Expected exactly one model declaration')
require(original_model.count('private(set) var baselineRevision: UInt64 = 0')==1,'Expected exactly one private baseline revision')
require(original_controller.count('final class EditorWindowController:')==1,'Expected exactly one controller declaration')
marker='    guard let document, document.finishFileOperation(id) else { return }'
require(original_controller.count(marker)==1,'Expected exactly one operation completion instrumentation marker')
require('ownerTestCompletedOperations' not in original_controller,'Production already contains test instrumentation')
model.write_text(original_model+'\n'+(run/'FileStateOwnerModelAccess.swift').read_text())
controller.write_text(original_controller.replace(marker,'    ownerTestCompletedOperations.insert(id)\n'+marker)
                      +'\n'+(run/'FileStateOwnerControllerAccess.swift').read_text())
for name,original in [('EditorDocument.swift',original_model),('EditorWindowController.swift',original_controller)]:
    prepared=(native/name).read_text()
    (run/(name+'.diff')).write_text(''.join(difflib.unified_diff(original.splitlines(True),prepared.splitlines(True),fromfile='production/'+name,tofile='prepared/'+name)))
    manifest['prepared/'+name]=digest(prepared.encode())
objects=sorted((build/'PadCore.build').glob('*.o'))
require(bool(objects),'No PadCore object files')
manifest['buildObjects']={p.name:digest(p.read_bytes()) for p in objects}
manifest['toolchain']=subprocess.check_output(['xcrun','swiftc','--version'],text=True)
(run/'sources.json').write_text(json.dumps(manifest,indent=2)+'\n')
arch=platform.machine()
require(arch in ('arm64','x86_64'),'Unsupported host architecture')
common=['xcrun','swiftc','-module-cache-path',str(run/'module-cache'),'-target',arch+'-apple-macosx14.0',
        '-swift-version','5','-parse-as-library','-I',str(build/'Modules')]
results=[]
for label,harness in [('model','FileStateOwnerHarness.swift'),('controller','FileStateOwnerControllerHarness.swift')]:
    binary=run/label
    command=common+[str(p) for p in sorted(native.glob('*.swift'))]+[str(run/harness)]+[str(p) for p in objects]+['-o',str(binary)]
    with (run/(label+'-compile.log')).open('wb') as log:
        compilation=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT)
    if compilation.returncode:
        print((run/(label+'-compile.log')).read_text());raise SystemExit(compilation.returncode)
    state=run/(label+'-state');state.mkdir()
    with (run/(label+'-result.log')).open('wb') as log:
        child=subprocess.Popen([str(binary)],stdout=log,stderr=subprocess.STDOUT,
            env=dict(os.environ,THEONLYPAD_STATE_DIRECTORY=str(state)))
        try: result={'mode':label,'exit':child.wait(timeout=60)}
        except subprocess.TimeoutExpired:
            child.kill();child.wait();result={'mode':label,'timeout':60,'owned_child_killed_and_reaped':True}
    results.append(result)
    (run/'results.json').write_text(json.dumps(results,indent=2)+'\n')
    print((run/(label+'-result.log')).read_text(),end='')
    if result.get('exit')!=0: raise SystemExit(1)
PY
