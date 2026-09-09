#!/bin/bash
set -euo pipefail
umask 077
if [ "$#" -ne 0 ]; then echo 'Usage: scripts/test-application-documents.sh' >&2; exit 2; fi
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
mkdir -p .local/application-documents-tests
run=$(mktemp -d "$PWD/.local/application-documents-tests/run.XXXXXXXX")
echo "Private registry test evidence: $run"
python3 - "$run" <<'PY'
from pathlib import Path
import hashlib,json,sys
run=Path(sys.argv[1]); package=run/'Package'
source=package/'Sources/DocumentRegistry'; tests=package/'Tests/DocumentRegistryTests'
source.mkdir(parents=True); tests.mkdir(parents=True)
manifest=[]
for path,destination in [(Path('Sources/TheOnlyPad')/name,source/name) for name in ['WorkspaceDocumentRegistryTypes.swift','ApplicationDocuments.swift']]+[(Path('Tests/NativeIntegration')/name,tests/name) for name in ['ApplicationDocumentsTests.swift','ApplicationDocumentCloseTests.swift']]:
    data=path.read_bytes(); destination.write_bytes(data)
    manifest.append({'source':str(path),'sha256':hashlib.sha256(data).hexdigest()})
(run/'sources.json').write_text(json.dumps(manifest,indent=2)+'\n')
(package/'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "DocumentRegistryTests", platforms: [.macOS(.v14)], targets: [.target(name: "DocumentRegistry"), .testTarget(name: "DocumentRegistryTests", dependencies: ["DocumentRegistry"])], swiftLanguageModes: [.v5])
''')
PY
python3 - "$run" <<'PY'
from pathlib import Path
import json,os,signal,subprocess,sys
run=Path(sys.argv[1])
with (run/'test.log').open('wb') as log:
    child=subprocess.Popen(['scripts/swift.sh','test','--package-path',str(run/'Package'),'--scratch-path',str(run/'Build')],stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
    try: code=child.wait(timeout=120); timed_out=False
    except subprocess.TimeoutExpired:
        try: os.killpg(child.pid,signal.SIGKILL)
        except ProcessLookupError: pass
        child.wait();code=124;timed_out=True
(run/'status.json').write_text(json.dumps({'exit':code,'timedOut':timed_out})+'\n')
print((run/'test.log').read_text(),end='')
raise SystemExit(code)
PY
