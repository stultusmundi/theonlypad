#!/bin/bash
set -euo pipefail
umask 077
if [ "$#" -ne 0 ]; then echo 'Usage: scripts/test-document-move-destination.sh' >&2; exit 2; fi
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
mkdir -p .local/document-move-destination-tests
run=$(mktemp -d "$PWD/.local/document-move-destination-tests/run.XXXXXXXX")
echo "Private document move chooser evidence: $run"
python3 - "$run" <<'PY'
from pathlib import Path
import hashlib,json,sys
run=Path(sys.argv[1]);package=run/'Package'
items=[(p,package/'Sources/PadCore'/p.name) for p in Path('Sources/PadCore').glob('*.swift')]
items += [(p,package/'Sources/SearchExecution'/p.name) for p in Path('Sources/SearchExecution').glob('*.swift')]
items += [(p,package/'Sources/NativeRouting'/p.name) for p in Path('Sources/TheOnlyPad').glob('*.swift') if p.name!='TheOnlyPadApplication.swift']
items += [(Path('Tests/NativeIntegration/DocumentMoveDestinationTests.swift'),package/'Tests/NativeRoutingTests/DocumentMoveDestinationTests.swift')]
manifest=[]
for source,target in items:
 target.parent.mkdir(parents=True,exist_ok=True);data=source.read_bytes();target.write_bytes(data);manifest.append({'source':str(source),'sha256':hashlib.sha256(data).hexdigest()})
access=Path('Tests/NativeIntegration/DocumentMoveAppDelegateAccess.swift')
target=package/'Sources/NativeRouting/AppDelegate.swift'
appText=target.read_text()
needle='\n    guard !preparingQuit, documentOwner === owner, movePresentationGeneration == generation else {'
# Observe entry to the actual terminal presentation path without replacing transfer behavior.
if appText.count(needle)!=1: raise SystemExit('Expected one terminal presentation entry')
appText=appText.replace(needle,'\n    movePresentationAttempts += 1'+needle)
target.write_text(appText+'\n'+access.read_text()+'\n@MainActor var movePresentationAttempts = 0\n')
factory=package/'Sources/NativeRouting/EditorDocumentFactory.swift'
factoryText=factory.read_text()
needle='    let document = EditorDocument(id: seed.id)'
if factoryText.count(needle)!=1: raise SystemExit('Expected one document factory observation')
factory.write_text(factoryText.replace(needle,'    moveFactoryCalls += 1\n'+needle)+'\n@MainActor var moveFactoryCalls = 0\n')
manifest.append({'source':'scripts/test-document-move-destination.sh','sha256':hashlib.sha256(Path('scripts/test-document-move-destination.sh').read_bytes()).hexdigest()})
(run/'frozen-sources.json').write_text(json.dumps([{'source':str(p.relative_to(package)),'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in sorted(package.rglob('*.swift'))],indent=2)+'\n')
manifest.append({'source':str(access),'sha256':hashlib.sha256(access.read_bytes()).hexdigest()})
(run/'sources.json').write_text(json.dumps(manifest,indent=2)+'\n')
(package/'Package.swift').write_text('// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name:"NativeRouting", platforms:[.macOS(.v14)], targets:[.target(name:"PadCore"),.target(name:"SearchExecution",dependencies:["PadCore"]),.target(name:"NativeRouting",dependencies:["PadCore","SearchExecution"]),.testTarget(name:"NativeRoutingTests",dependencies:["NativeRouting","PadCore"])],swiftLanguageModes:[.v5])\n')
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
