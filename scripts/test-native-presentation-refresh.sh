#!/bin/bash
# Hidden native controller presentation-refresh regressions, no shown windows or activation.
set -euo pipefail
umask 077
if [ "$#" -gt 1 ]; then
  echo 'Usage: scripts/test-native-presentation-refresh.sh [existing-PadCore-bin-directory]' >&2
  exit 2
fi
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
mkdir -p .local/presentation-refresh-tests
run=$(mktemp -d "$PWD/.local/presentation-refresh-tests/run.XXXXXXXX")
echo "Private presentation refresh evidence: $run"
python3 - "$run" "${1:-}" <<'PY'
import hashlib, json, os, pathlib, signal, subprocess, sys
root=pathlib.Path.cwd(); run=pathlib.Path(sys.argv[1]); supplied=sys.argv[2]
manifest=[]
def hashed(path):
    data=path.read_bytes()
    manifest.append({'source':path.relative_to(root).as_posix(),'sha256':hashlib.sha256(data).hexdigest()})
    return data
for name,suffix in [('RecentFilesController','Recent'),('SessionRestorationController','Session')]:
    source=root/'Sources/TheOnlyPad'/f'{name}.swift'
    text=hashed(source).decode()
    if suffix=='Session':
        anchor='  @objc private func confirmRemoval()'
        if text.count(anchor)!=1: raise SystemExit('Expected one removal method; inspect fixture boundary before updating.')
        prefix,tail=text.split(anchor,1)
        boundary='alert.beginSheetModal(for: window) { [weak self] response in'
        if tail.count(boundary)!=1: raise SystemExit('Expected one removal confirmation boundary; refusing broad replacement.')
        text=prefix+anchor+tail.replace(boundary,'fixtureConfirmRemoval(window: window) { [weak self] response in',1)
    access=root/'Tests/NativeIntegration'/f'PresentationRefresh{suffix}Access.swift'
    text+='\n'+hashed(access).decode()
    target=run/f'{name}.swift'; target.write_text(text)
    manifest.append({'testCopy':target.name,'sha256':hashlib.sha256(target.read_bytes()).hexdigest()})
fixture=root/'Tests/NativeIntegration/PresentationRefreshHarness.swift'
(run/'Harness.swift').write_bytes(hashed(fixture))
statuses={}
def execute(label,command,timeout):
    with (run/(label+'.log')).open('wb') as output:
        child=subprocess.Popen(command,stdout=output,stderr=subprocess.STDOUT,start_new_session=True)
        try:
            code=child.wait(timeout=timeout); expired=False
        except subprocess.TimeoutExpired:
            os.killpg(child.pid,signal.SIGKILL); child.wait(); code=124; expired=True
    statuses[label]={'exit':code,'timedOut':expired}
    (run/'status.json').write_text(json.dumps(statuses,indent=2)+'\n')
    return code
if supplied:
    binary=pathlib.Path(supplied).resolve()
else:
    scratch=run/'Build'
    if execute('core-build',['scripts/swift.sh','build','--target','PadCore','--scratch-path',str(scratch)],180):
        raise SystemExit('PadCore build failed; see retained log.')
    if execute('bin-path',['scripts/swift.sh','build','--show-bin-path','--scratch-path',str(scratch)],30):
        raise SystemExit('Cannot determine build bin path; see retained log.')
    binary=pathlib.Path((run/'bin-path.log').read_text().strip())
objects=sorted((binary/'PadCore.build').glob('*.o'))
if not objects or not (binary/'Modules/PadCore.swiftmodule').exists(): raise SystemExit('Missing stable PadCore module/objects.')
for obj in objects:
    manifest.append({'linkedObject':obj.name,'sha256':hashlib.sha256(obj.read_bytes()).hexdigest()})
(run/'source-hashes.json').write_text(json.dumps(manifest,indent=2)+'\n')
command=['xcrun','swiftc','-swift-version','5','-target',os.uname().machine+'-apple-macosx14.0','-module-cache-path',str(run/'Cache'),'-parse-as-library','-I',str(binary/'Modules'),*[str(p) for p in sorted(run.glob('*.swift'))],*[str(p) for p in objects],'-o',str(run/'probe')]
if execute('compile',command,90): raise SystemExit('Native compile failed; see retained log.')
cases=[('recent',v) for v in ['control','presentation','reorder','opened','selection','remove','update','suspend','close']]+[('remove',v) for v in ['control','presentation','status','unrelated','change','metadata','recovery','remove','update','close']]+[('retry','presentation'),('recent','presentation-success'),('recent','reorder-success'),('retry','presentation-success'),('retry','unrelated-success'),('remove','presentation-success'),('remove','unrelated-success')]
failed=False
for mode,variant in cases:
    label=mode+'-'+variant
    code=execute(label,[str(run/'probe'),mode,variant],10)
    print((run/(label+'.log')).read_text(),end='')
    failed=failed or code!=0
raise SystemExit(1 if failed else 0)
PY
