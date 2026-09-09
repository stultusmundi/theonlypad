#!/bin/bash
# Foundation owner tests against frozen production sources, without importing the executable.
set -euo pipefail
umask 077
if [ "$#" -ne 0 ]; then
  echo 'Usage: scripts/test-application-shortcuts.sh' >&2
  exit 2
fi
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
owner=Sources/TheOnlyPad/ApplicationShortcuts.swift
fixture=Tests/NativeIntegration/ApplicationShortcutsTests.swift
if [ ! -f "$owner" ] || [ ! -f "$fixture" ]; then
  echo 'The production shortcut owner and retained test fixture are required.' >&2
  exit 2
fi
mkdir -p .local/application-shortcuts-tests
run=$(mktemp -d "$PWD/.local/application-shortcuts-tests/run.XXXXXXXX")
python3 - "$run" "$owner" "$fixture" <<'PY'
import hashlib, json, pathlib, shutil, sys
run=pathlib.Path(sys.argv[1]); owner=pathlib.Path(sys.argv[2]); fixture=pathlib.Path(sys.argv[3])
package=run/'Package'; (package/'Sources'/'PadCore').mkdir(parents=True)
(package/'Sources'/'ShortcutOwner').mkdir(); (package/'Tests'/'ShortcutOwnerTests').mkdir(parents=True)
manifest=[]
def freeze(source,destination):
    contents=source.read_bytes(); destination.write_bytes(contents)
    manifest.append({'source':source.as_posix(),'sha256':hashlib.sha256(contents).hexdigest()})
for source in sorted(pathlib.Path('Sources/PadCore').glob('*.swift')):
    freeze(source,package/'Sources'/'PadCore'/source.name)
freeze(owner,package/'Sources'/'ShortcutOwner'/'ApplicationShortcuts.swift')
freeze(fixture,package/'Tests'/'ShortcutOwnerTests'/'ApplicationShortcutsTests.swift')
(package/'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(
  name: "ApplicationShortcutsRetained",
  platforms: [.macOS(.v14)],
  targets: [
    .target(name: "PadCore"),
    .target(name: "ShortcutOwner", dependencies: ["PadCore"]),
    .testTarget(name: "ShortcutOwnerTests", dependencies: ["ShortcutOwner", "PadCore"]),
  ],
  swiftLanguageModes: [.v5]
)
''')
(run/'source-hashes.json').write_text(json.dumps(manifest,indent=2)+'\n')
PY
echo "Private shortcut owner evidence: $run"
python3 - "$run" <<'PY'
import json, os, pathlib, signal, subprocess, sys
run=pathlib.Path(sys.argv[1])
command=['scripts/swift.sh','test','--package-path',str(run/'Package'),'--scratch-path',str(run/'Build')]
with (run/'test.log').open('wb') as log:
    child=subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
    try:
        code=child.wait(timeout=180)
        status={'exit':code,'timedOut':False}
    except subprocess.TimeoutExpired:
        os.killpg(child.pid,signal.SIGKILL); child.wait(); code=124
        status={'exit':code,'timedOut':True,'ownedProcessGroupKilledAndReaped':True}
(run/'status.json').write_text(json.dumps(status)+'\n')
print((run/'test.log').read_text(),end='')
raise SystemExit(code)
PY
