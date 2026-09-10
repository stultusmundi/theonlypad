#!/bin/bash
set -euo pipefail
umask 077
if [ "$#" -ne 0 ]; then echo 'Usage: scripts/test-native-application-document-transfer.sh' >&2; exit 2; fi
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
mkdir -p .local/native-application-document-transfer-tests
run=$(mktemp -d "$PWD/.local/native-application-document-transfer-tests/run.XXXXXXXX")
echo "Private native transfer integration evidence: $run"
python3 - "$run" <<'PY'
from pathlib import Path
import hashlib,json,sys
run=Path(sys.argv[1]);package=run/'Package'
items=[(p,package/'Sources/PadCore'/p.name) for p in Path('Sources/PadCore').glob('*.swift')]
items += [(p,package/'Sources/NativeRouting'/p.name) for p in Path('Sources/TheOnlyPad').glob('*.swift') if p.name!='TheOnlyPadApplication.swift']
items += [(Path('Tests/NativeIntegration/NativeApplicationDocumentTransferTests.swift'),package/'Tests/NativeRoutingTests/NativeApplicationDocumentTransferTests.swift')]
manifest=[]
for source,target in items:
 target.parent.mkdir(parents=True,exist_ok=True);data=source.read_bytes();target.write_bytes(data);manifest.append({'source':str(source),'sha256':hashlib.sha256(data).hexdigest()})
access=Path('Tests/NativeIntegration/NativeApplicationDocumentTransferAccess.swift')
owner=package/'Sources/NativeRouting/NativeApplicationDocuments.swift'
text=owner.read_text();needle='native: makeTransferNative())'
if text.count(needle)!=1:raise SystemExit('Expected exactly one native transfer owner interception point')
owner.write_text(text.replace(needle,'native: interceptTransferNative(makeTransferNative()))')+'\n'+access.read_text())
manifest.append({'source':str(access),'sha256':hashlib.sha256(access.read_bytes()).hexdigest()})
(run/'sources.json').write_text(json.dumps(manifest,indent=2)+'\n')
(package/'Package.swift').write_text('// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name:"NativeRouting", platforms:[.macOS(.v14)], targets:[.target(name:"PadCore"),.target(name:"NativeRouting",dependencies:["PadCore"]),.testTarget(name:"NativeRoutingTests",dependencies:["NativeRouting","PadCore"])],swiftLanguageModes:[.v5])\n')
PY
python3 - "$run" <<'PY'
from pathlib import Path
import json,os,signal,subprocess,sys
run=Path(sys.argv[1])
state=run/'State';state.mkdir()
env=os.environ.copy();env['THEONLYPAD_STATE_DIRECTORY']=str(state)
with (run/'test.log').open('wb') as log:
 child=subprocess.Popen(['scripts/swift.sh','test','--package-path',str(run/'Package'),'--scratch-path',str(run/'Build')],stdout=log,stderr=subprocess.STDOUT,start_new_session=True,env=env)
 try:code=child.wait(timeout=180);timed_out=False
 except subprocess.TimeoutExpired:
  try:os.killpg(child.pid,signal.SIGKILL)
  except ProcessLookupError:pass
  child.wait();code=124;timed_out=True
 except BaseException:
  try:os.killpg(child.pid,signal.SIGKILL)
  except ProcessLookupError:pass
  child.wait();raise
(run/'status.json').write_text(json.dumps({'exit':code,'timedOut':timed_out})+'\n')
print((run/'test.log').read_text(),end='');raise SystemExit(code)
PY
