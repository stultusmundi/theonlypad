#!/bin/bash
# Hidden AppKit/owner integration against current production source snapshots.
set -euo pipefail
umask 077
if [ "$#" -ne 0 ]; then
  echo 'Usage: scripts/test-shortcut-application.sh' >&2
  exit 2
fi
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
for file in Sources/TheOnlyPad/ApplicationShortcutController.swift Sources/TheOnlyPad/KeyboardShortcutController.swift Tests/NativeIntegration/ShortcutApplicationTests.swift Tests/NativeIntegration/ShortcutAppDelegateAccess.swift Tests/NativeIntegration/ShortcutControllerAccess.swift; do
  if [ ! -f "$file" ]; then echo "Required integration source is missing: $file" >&2; exit 2; fi
done
mkdir -p .local/shortcut-application-tests
run=$(mktemp -d "$PWD/.local/shortcut-application-tests/run.XXXXXXXX")
echo "Private shortcut application evidence: $run"
python3 - "$run" <<'PY'
from pathlib import Path
import hashlib,json,sys
run=Path(sys.argv[1]); package=run/'Package'
core=package/'Sources/PadCore'; native=package/'Sources/ShortcutApplication'; tests=package/'Tests/ShortcutApplicationTests'
for directory in [core,native,tests]: directory.mkdir(parents=True)
manifest=[]
def freeze(source,destination):
    contents=source.read_bytes(); destination.write_bytes(contents)
    manifest.append({'source':source.as_posix(),'destination':str(destination.relative_to(package)),'sha256':hashlib.sha256(contents).hexdigest()})
for source in sorted(Path('Sources/PadCore').glob('*.swift')):
    freeze(source,core/source.name)
for source in sorted(Path('Sources/TheOnlyPad').glob('*.swift')):
    if source.name!='TheOnlyPadApplication.swift': freeze(source,native/source.name)
for name,access,marker,private_marker in [
    ('AppDelegate.swift','ShortcutAppDelegateAccess.swift','final class AppDelegate:','private var shortcutRegistryReady'),
    ('ApplicationShortcutController.swift','ShortcutControllerAccess.swift','final class ApplicationShortcutController','private var windowGeneration')]:
    target=native/name; original=target.read_text(); extension=Path('Tests/NativeIntegration')/access
    if original.count(marker)!=1 or original.count(private_marker)!=1:
        raise SystemExit('Expected exactly one reviewed owner/access marker in '+name)
    contents=extension.read_text()
    if contents.count('extension '+('AppDelegate' if name=='AppDelegate.swift' else 'ApplicationShortcutController')+' {')!=1:
        raise SystemExit('Expected exactly one explicit test-access extension in '+access)
    target.write_text(original+'\n'+contents)
    (run/(name+'.test-access.txt')).write_text(contents)
    manifest.append({'source':extension.as_posix(),'appendedTo':str(target.relative_to(package)),'sha256':hashlib.sha256(contents.encode()).hexdigest()})
freeze(Path('Tests/NativeIntegration/ShortcutApplicationTests.swift'),tests/'ShortcutApplicationTests.swift')
(package/'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(
  name: "ShortcutApplicationRetained",
  platforms: [.macOS(.v14)],
  targets: [
    .target(name: "PadCore"),
    .target(name: "ShortcutApplication", dependencies: ["PadCore"]),
    .testTarget(name: "ShortcutApplicationTests", dependencies: ["ShortcutApplication", "PadCore"]),
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
