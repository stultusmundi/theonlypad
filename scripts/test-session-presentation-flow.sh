#!/bin/bash
# Hidden AppKit/owner integration against current production source snapshots.
set -euo pipefail
umask 077
if [ "$#" -ne 0 ]; then
  echo 'Usage: scripts/test-session-presentation-flow.sh' >&2
  exit 2
fi
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
for file in Sources/TheOnlyPad/SessionCoordinator.swift Sources/TheOnlyPad/SessionRestorationController.swift Sources/TheOnlyPad/RecoveryCoordinator.swift Tests/NativeIntegration/SessionPresentationFlowTests.swift; do
  if [ ! -f "$file" ]; then echo "Required integration source is missing: $file" >&2; exit 2; fi
done
mkdir -p .local/session-presentation-flow-tests
run=$(mktemp -d "$PWD/.local/session-presentation-flow-tests/run.XXXXXXXX")
echo "Private session presentation flow evidence: $run"
python3 - "$run" <<'PY'
from pathlib import Path
import hashlib,json,sys
run=Path(sys.argv[1]); package=run/'Package'
core=package/'Sources/PadCore'; native=package/'Sources/SessionPresentationFlow'; tests=package/'Tests/SessionPresentationFlowTests'
for directory in [core,native,tests]: directory.mkdir(parents=True)
manifest=[]
def freeze(source,destination):
    contents=source.read_bytes(); destination.write_bytes(contents)
    manifest.append({'source':source.as_posix(),'destination':str(destination.relative_to(package)),'sha256':hashlib.sha256(contents).hexdigest()})
for source in sorted(Path('Sources/PadCore').glob('*.swift')):
    freeze(source,core/source.name)
for name in ['SessionCoordinator.swift','SessionRestorationController.swift','RecoveryCoordinator.swift']:
    freeze(Path('Sources/TheOnlyPad')/name,native/name)
freeze(Path('Tests/NativeIntegration/SessionPresentationFlowTests.swift'),tests/'SessionPresentationFlowTests.swift')
(package/'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(
  name: "SessionPresentationFlowRetained",
  platforms: [.macOS(.v14)],
  targets: [
    .target(name: "PadCore"),
    .target(name: "SessionPresentationFlow", dependencies: ["PadCore"]),
    .testTarget(name: "SessionPresentationFlowTests", dependencies: ["SessionPresentationFlow", "PadCore"]),
  ],
  swiftLanguageModes: [.v5]
)
''')
(run/'source-hashes.json').write_text(json.dumps(manifest,indent=2)+'\n')
(run/'frozen-source-hashes.json').write_text(json.dumps([
    {'path':str(path.relative_to(package)),'sha256':hashlib.sha256(path.read_bytes()).hexdigest()}
    for path in sorted(package.rglob('*.swift'))],indent=2)+'\n')
PY
python3 - "$run" <<'PY'
from pathlib import Path
import json,os,signal,subprocess,sys
run=Path(sys.argv[1])
command=['scripts/swift.sh','test','--package-path',str(run/'Package'),'--scratch-path',str(run/'Build')]
with (run/'toolchain.log').open('wb') as log:
    subprocess.run(['swift','--version'],stdout=log,stderr=subprocess.STDOUT,check=True)
with (run/'test.log').open('wb') as log:
    child=subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
    try:
        code=child.wait(timeout=180)
        status={'exit':code,'timedOut':False}
    except subprocess.TimeoutExpired:
        try:os.killpg(child.pid,signal.SIGKILL)
        except ProcessLookupError:pass
        child.wait();code=124
        status={'exit':code,'timedOut':True,'ownedProcessGroupKilledAndReaped':True}
(run/'status.json').write_text(json.dumps(status)+'\n')
print((run/'test.log').read_text(),end='')
raise SystemExit(code)
PY
