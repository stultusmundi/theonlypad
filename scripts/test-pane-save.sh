#!/bin/bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
if [ "$#" -ne 1 ]; then
  echo 'Usage: scripts/test-pane-save.sh existing-debug-build-path' >&2
  exit 2
fi
mkdir -p .local/pane-save
run=$(mktemp -d .local/pane-save/run.XXXXXXXX)
build_path=$1
python3 - "$run" "$build_path" <<'PY'
from pathlib import Path
import os, subprocess, signal, json, hashlib, platform, sys
root=Path.cwd(); run=Path(sys.argv[1]).resolve(); binary=Path(sys.argv[2]).resolve()
if not (binary/'Modules/PadCore.swiftmodule').exists() or not list((binary/'PadCore.build').glob('*.o')):
    raise SystemExit('Existing debug build must contain PadCore module and objects')
source=run/'Sources'; source.mkdir(); hashes={}
fixtures=root/'Tests/NativeIntegration/PaneSaveFixtures.inc'
for path in (root/'Sources/TheOnlyPad').glob('*.swift'):
    if path.name=='TheOnlyPadApplication.swift': continue
    data=path.read_bytes()
    hashes[str(path.relative_to(root))]=hashlib.sha256(data).hexdigest()
    if path.name=='EditorWindowController.swift':
        if data.count(b'final class EditorWindowController:') != 1:
            raise SystemExit('Expected exactly one native controller declaration for test-only access')
        data+=b'\n'+fixtures.read_bytes()
    (source/path.name).write_bytes(data)
    hashes['compiled/'+path.name]=hashlib.sha256(data).hexdigest()
harness=root/'Tests/NativeIntegration/PaneSaveHarness.swift'
(run/harness.name).write_bytes(harness.read_bytes())
for path in [harness,fixtures,*binary.glob('PadCore.build/*.o'),*binary.glob('Modules/PadCore.*')]:
    if path.is_file(): hashes[str(path.relative_to(root)) if path.is_relative_to(root) else path.name]=hashlib.sha256(path.read_bytes()).hexdigest()
(run/'source-hashes.json').write_text(json.dumps(hashes,indent=2)+'\n')
def execute(args,name,timeout):
    state=run/(name+'.state'); state.mkdir()
    env=os.environ.copy();env['THEONLYPAD_STATE_DIRECTORY']=str(state)
    with (run/(name+'.log')).open('wb') as log:
        child=subprocess.Popen(args,stdout=log,stderr=subprocess.STDOUT,start_new_session=True,env=env)
        try: return child.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid,signal.SIGKILL); child.wait(); return 124
command=['xcrun','swiftc','-swift-version','5','-target',platform.machine()+'-apple-macosx14.0','-module-cache-path',str(run/'cache'),'-parse-as-library','-I',str(binary/'Modules'),*map(str,source.glob('*.swift')),str(run/harness.name),*map(str,(binary/'PadCore.build').glob('*.o')),'-o',str(run/'probe')]
status={'compile':execute(command,'compile',120)}
if status['compile']==0:
    for mode in ['completed-save']:
        status[mode]=execute([str(run/'probe'),mode],mode,30)
        (run/'status.json').write_text(json.dumps(status,indent=2)+'\n')
(run/'status.json').write_text(json.dumps(status,indent=2)+'\n')
print('Private pane-save evidence:',run.relative_to(root)); print(json.dumps(status,sort_keys=True))
for name,code in status.items():
    if code: print((run/(name+'.log')).read_text())
raise SystemExit(0 if all(value==0 for value in status.values()) else 1)
PY
