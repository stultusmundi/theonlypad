#!/bin/bash
set -euo pipefail
umask 077
if [ "$#" -ne 0 ]; then echo 'Usage: scripts/test-native-new-window-transfer.sh' >&2; exit 2; fi
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
mkdir -p .local/native-new-window-transfer-tests
run=$(mktemp -d "$PWD/.local/native-new-window-transfer-tests/run.XXXXXXXX")
echo "Private native transfer integration evidence: $run"
python3 - "$run" <<'PY'
from pathlib import Path
import hashlib,json,sys
run=Path(sys.argv[1]);package=run/'Package'
items=[(p,package/'Sources/PadCore'/p.name) for p in Path('Sources/PadCore').glob('*.swift')]
items += [(p,package/'Sources/NativeRouting'/p.name) for p in Path('Sources/TheOnlyPad').glob('*.swift') if p.name!='TheOnlyPadApplication.swift']
items += [(Path('Tests/NativeIntegration/NativeNewWindowTransferTests.swift'),package/'Tests/NativeRoutingTests/NativeNewWindowTransferTests.swift')]
manifest=[]
for source,target in items:
 target.parent.mkdir(parents=True,exist_ok=True);data=source.read_bytes();target.write_bytes(data);manifest.append({'source':str(source),'sha256':hashlib.sha256(data).hexdigest()})
manifest.append({'source': 'scripts/test-native-new-window-transfer.sh', 'sha256': hashlib.sha256(Path('scripts/test-native-new-window-transfer.sh').read_bytes()).hexdigest()})
# Explicit test-only access, appended only to the frozen copies. No production test seams.
owner=package/'Sources/NativeRouting/NativeApplicationDocuments.swift'
text=owner.read_text()
needle='try await checkpoints.drainPause(pause)\n      value.pauseDrained = true'
if text.count(needle)!=1: raise SystemExit('Expected one preparation drain interception')
text=text.replace(needle, 'try await checkpoints.drainPause(pause)\n      try await newWindowDrainHook?()\n      value.pauseDrained = true')
needle='if let task = value.task { _ = await task.value }\n    do {'
if text.count(needle)!=1: raise SystemExit('Expected one owned cleanup interception')
text=text.replace(needle, 'if let task = value.task { _ = await task.value }\n    do {\n      try await newWindowCleanupHook?()')
owner.write_text(text+"""
@MainActor var newWindowDrainHook: (() async throws -> Void)?
@MainActor var newWindowCleanupHook: (() async throws -> Void)?
extension NativeApplicationDocuments {
  func testPreparePublisher() async throws { try await checkpoints.testPreparePublisher() }
  func testAcquirePause() throws -> CheckpointPauseToken { try checkpoints.acquirePause() }
  func testDrainPause(_ token: CheckpointPauseToken) async throws { try await checkpoints.drainPause(token) }
  func testReleasePause(_ token: CheckpointPauseToken) throws { try checkpoints.releasePause(token) }
  var testPreparationPending: Bool { preparingNewWindow != nil }
  var testExternalRequestID: UUID? { externalOpens.currentID }
  var testCleanupRunning: Bool { preparingNewWindow?.cleanupRunning == true }
  func testProject(_ windowID: UUID) throws { try project(windowID: windowID) }
  func testStartClose(_ documentID: UUID) throws {
    guard let assignment = registry.assignment(of: documentID) else { throw NativeWorkspaceError.staleEndpoint }
    _ = try closing.start(documentIDs: [documentID], sourceWindowID: assignment.windowID)
  }
}
""")
checkpoints=package/'Sources/NativeRouting/ApplicationSessionCheckpoints.swift'
checkpoints.write_text(checkpoints.read_text().replace('  private func renderStatus() {', '  private func renderStatus() {\n    newWindowStatusHook?()')+"""
@MainActor var newWindowStatusHook: (() -> Void)?
extension ApplicationSessionCheckpoints {
  func testPreparePublisher() async throws { try await scheduler.testPreparePublisher() }
}
""")
scheduler=package/'Sources/NativeRouting/SessionCheckpointCoordinator.swift'
scheduler.write_text(scheduler.read_text()+"""
extension SessionCheckpointCoordinator {
  func testPreparePublisher() async throws { try await prepareCapture() }
}
""")
factory=package/'Sources/NativeRouting/EditorDocumentFactory.swift'
factory.write_text(factory.read_text().replace('    let document = EditorDocument(id: seed.id)', '    newWindowFactoryCalls += 1\n    let document = EditorDocument(id: seed.id)')+'\n@MainActor var newWindowFactoryCalls = 0\n')
intake=package/'Sources/NativeRouting/NativeDocumentIntakeController.swift'
intake.write_text(intake.read_text().replace('        try model.installRecoveryAdoption(receipt, expectedOwnershipGeneration: generation)', '        newWindowAdoptionCalls += 1\n        try model.installRecoveryAdoption(receipt, expectedOwnershipGeneration: generation)')+'\n@MainActor var newWindowAdoptionCalls = 0\n')
(run/'frozen-sources.json').write_text(json.dumps([{'source':str(p.relative_to(package)), 'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in sorted(package.rglob('*.swift'))],indent=2)+'\n')
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
