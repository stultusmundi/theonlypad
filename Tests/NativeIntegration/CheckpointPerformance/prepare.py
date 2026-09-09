"""Prepare instrumented PRIVATE native sources; never mutate checkout sources."""
import pathlib,sys,shutil,json,hashlib,difflib
repo=pathlib.Path(sys.argv[1]).resolve()
out=pathlib.Path(sys.argv[2]).resolve()
if out.exists():raise SystemExit('Choose a new output directory; prior evidence is never overwritten')
out.mkdir(parents=True,mode=0o700)
(out/'Sources').mkdir(mode=0o700)
manifest={}
for source in sorted((repo/'Sources/TheOnlyPad').glob('*.swift')):
 if source.name=='TheOnlyPadApplication.swift':continue
 manifest[str(source.relative_to(repo))]=hashlib.sha256(source.read_bytes()).hexdigest()
 shutil.copyfile(source,out/'Sources'/source.name)
def replace(file,old,new):
 text=file.read_text()
 if text.count(old)!=1:raise SystemExit('Instrumentation anchor changed; inspect before adapting: '+file.name)
 file.write_text(text.replace(old,new,1))
bridge=out/'Sources/ApplicationSessionCheckpoints.swift'
replace(bridge,'        guard let self else { throw CancellationError() }\n        try EditorWindowController.assertNoPendingCloses()',
 '        guard let self else { throw CancellationError() }\n        CheckpointTrace.captureStarted(generation)\n        defer { CheckpointTrace.captureFinished(generation) }\n        try EditorWindowController.assertNoPendingCloses()')
replace(bridge,'      commit: { capture in','      commit: { capture in\n        CheckpointTrace.publicationStarted(capture)\n        defer { CheckpointTrace.publicationFinished(capture.generation) }')
replace(bridge,'  private func renderStatus() {','  private func renderStatus() {\n    CheckpointTrace.recordError(scheduler.lastError)\n    CheckpointTrace.acknowledgement(scheduler.lastAcknowledgedGeneration)')
recovery=out/'Sources/RecoveryCoordinator.swift'
replace(recovery,'      try $0.save($1)','      DiskTrace.shared.emit("recoveryWriteStart")\n      defer { DiskTrace.shared.emit("recoveryWriteEnd") }\n      try $0.save($1)')
replace(recovery,'      try SessionStore().save($0)','      DiskTrace.shared.emit("sessionWriteStart")\n      defer { DiskTrace.shared.emit("sessionWriteEnd") }\n      try SessionStore().save($0)')
sourceRoot=pathlib.Path(__file__).resolve().parent
for name in ['CheckpointEditProbe.swift','CheckpointTrace.swift','run.py','compile.sh']:
 shutil.copyfile(sourceRoot/name,out/name)
diffs=[]
for source in sorted((out/'Sources').glob('*.swift')):
 original=repo/'Sources/TheOnlyPad'/source.name
 diffs.extend(difflib.unified_diff(original.read_text().splitlines(keepends=True),source.read_text().splitlines(keepends=True),fromfile='original/'+source.name,tofile='instrumented/'+source.name))
(out/'instrumentation.diff').write_text(''.join(diffs))
assets=['CheckpointEditProbe.swift','CheckpointTrace.swift','run.py','compile.sh','prepare.py','README.md']
(out/'tool-hashes.json').write_text(json.dumps({name:hashlib.sha256((sourceRoot/name).read_bytes()).hexdigest()for name in assets},indent=2)+'\n')
(out/'source-hashes.json').write_text(json.dumps(manifest,indent=2)+'\n')
(out/'instrumented-source-hashes.json').write_text(json.dumps({p.name:hashlib.sha256(p.read_bytes()).hexdigest()for p in (out/'Sources').glob('*.swift')},indent=2)+'\n')
print('Prepared private copy; review source diff before compiling. No checkout files changed.')
