#!/bin/bash
set -euo pipefail
umask 077
if [ "$#" -ne 0 ]; then echo 'Usage: scripts/test-document-history.sh' >&2; exit 2; fi
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
mkdir -p .local/document-history-tests
run=$(mktemp -d "$PWD/.local/document-history-tests/run.XXXXXXXX")
echo "Private document history evidence: $run"
python3 - "$run" <<'PY'
from pathlib import Path
import hashlib,json,sys
run=Path(sys.argv[1]);package=run/'Package'
items=[(p,package/'Sources/PadCore'/p.name) for p in Path('Sources/PadCore').glob('*.swift')]
items += [(Path('Sources/TheOnlyPad')/n,package/'Sources/DocumentRegistry'/n) for n in ['RecoveryCoordinator.swift','WorkspaceDocumentRegistryTypes.swift','ApplicationDocuments.swift','DocumentTransferBoundary.swift']]
items += [(Path('Tests/NativeIntegration')/n,package/'Tests/DocumentRegistryTests'/n) for n in ['ApplicationDocumentsTests.swift','ApplicationDocumentCloseTests.swift','DocumentAdoptionTests.swift','DocumentHistoryTests.swift']]
manifest=[]
for source,target in items:
 target.parent.mkdir(parents=True,exist_ok=True);data=source.read_bytes();target.write_bytes(data);manifest.append({'source':str(source),'sha256':hashlib.sha256(data).hexdigest()})
(run/'sources.json').write_text(json.dumps(manifest,indent=2)+'\n')
(package/'Package.swift').write_text('// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name:"DocumentAdoption", platforms:[.macOS(.v14)], targets:[.target(name:"PadCore"),.target(name:"DocumentRegistry",dependencies:["PadCore"]),.testTarget(name:"DocumentRegistryTests",dependencies:["DocumentRegistry","PadCore"])],swiftLanguageModes:[.v5])\n')
PY
python3 - "$run" <<'PY'
from pathlib import Path
import json,os,signal,subprocess,sys
run=Path(sys.argv[1])
with (run/'test.log').open('wb') as log:
 child=subprocess.Popen(['scripts/swift.sh','test','--package-path',str(run/'Package'),'--scratch-path',str(run/'Build')],stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
 try:code=child.wait(timeout=180);timed_out=False
 except subprocess.TimeoutExpired:
  try:os.killpg(child.pid,signal.SIGKILL)
  except ProcessLookupError:pass
  child.wait();code=124;timed_out=True
(run/'status.json').write_text(json.dumps({'exit':code,'timedOut':timed_out})+'\n')
print((run/'test.log').read_text(),end='');raise SystemExit(code)
PY
