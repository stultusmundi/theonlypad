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
for file in scripts/run-owned-search-tests.py Sources/TheOnlyPad/ApplicationShortcutController.swift Sources/TheOnlyPad/KeyboardShortcutController.swift Tests/NativeIntegration/ShortcutApplicationTests.swift Tests/NativeIntegration/NativeCommandKeyAdmissionTests.swift Tests/NativeIntegration/NativeCommandPublicationTests.swift Tests/NativeIntegration/ShortcutAppDelegateAccess.swift Tests/NativeIntegration/ShortcutControllerAccess.swift; do
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
for name in ['ShortcutApplicationTests.swift', 'NativeCommandKeyAdmissionTests.swift', 'NativeCommandPublicationTests.swift']:
    freeze(Path('Tests/NativeIntegration')/name,tests/name)
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
watchdog_source=Path('scripts/run-owned-search-tests.py')
watchdog_bytes=watchdog_source.read_bytes()
(run/'run-owned-search-tests.py').write_bytes(watchdog_bytes)
manifest.append({'source':str(watchdog_source),'destination':'run-owned-search-tests.py',
                 'sha256':hashlib.sha256(watchdog_bytes).hexdigest()})
(run/'source-hashes.json').write_text(json.dumps(manifest,indent=2)+'\n')
(run/'frozen-source-hashes.json').write_text(json.dumps([
    {'path':str(path.relative_to(package)),'sha256':hashlib.sha256(path.read_bytes()).hexdigest()}
    for path in sorted(package.rglob('*.swift'))],indent=2)+'\n')
PY
exec python3 - "$run" <<'PY'
from pathlib import Path
import importlib.util,json,re,sys
run=Path(sys.argv[1])
spec=importlib.util.spec_from_file_location('shortcut_test_watchdog',run/'run-owned-search-tests.py')
watchdog=importlib.util.module_from_spec(spec)
sys.modules[spec.name]=watchdog
spec.loader.exec_module(watchdog)
# The imported watchdog is the sole process owner. Never wrap this coordinator
# in another process-group watchdog or add Popen/poll/wait/session logic here.
def execute(command,name,timeout):
    output=run/name
    code=watchdog.main(['--timeout',str(timeout),'--output',str(output),'--',*command])
    try:
        receipt=json.loads((output/'status.json').read_text())
    except (OSError,ValueError):
        receipt=None
    text=''.join((output/stream).read_text(errors='replace')
                 for stream in ['stdout.log','stderr.log'] if (output/stream).is_file())
    valid_success=(isinstance(receipt,dict) and 'failure' in receipt and 'interruptedSignal' in receipt
                   and receipt.get('exit')==0
                   and receipt.get('waitCompleted') is True and receipt.get('returnCode')==0
                   and receipt.get('captureComplete') is True and receipt.get('truncated') is False
                   and receipt.get('timedOut') is False and receipt.get('failure') is None
                   and receipt.get('interruptedSignal') is None
                   and receipt.get('groupSignalAttempted') is True
                   and receipt.get('groupCleanup') in ('signaled','absent','exitedLeaderOnly'))
    if receipt is None or (code==0 and not valid_success):
        code=125
    return code,receipt,text
code,toolchain_receipt,toolchain=execute(['swift','--version'],'toolchain-watchdog',30)
(run/'toolchain.log').write_text(toolchain)
receipt=None; output=''; count=0; suites_present=False
if code==0:
    command=['scripts/swift.sh','test','--package-path',str(run/'Package'),'--scratch-path',str(run/'Build')]
    code,receipt,output=execute(command,'test-watchdog',180)
    (run/'test.log').write_text(output)
    summaries=[(int(count),int(failures)) for count,failures in
               re.findall(r'Executed (\d+) tests?, with (\d+) failures',output)]
    count=max((count for count,_ in summaries),default=0)
    suites_present=all("Test Suite '"+name+"' passed" in output for name in
                       ['NativeCommandKeyAdmissionTests','NativeCommandPublicationTests','ShortcutApplicationTests'])
    if code==0 and (count==0 or any(failures for _,failures in summaries) or not suites_present):
        code=125
status={'exit':code,'testCount':count,'requiredSuitesPassed':suites_present,
        'toolchainWatchdog':toolchain_receipt,'testWatchdog':receipt}
(run/'status.json').write_text(json.dumps(status,indent=2)+'\n')
print(output,end='')
print(json.dumps({'exit':code,'testCount':count,'requiredSuitesPassed':suites_present}))
raise SystemExit(code)
PY
