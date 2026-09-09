#!/bin/bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
python3 - "$@" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import sys
import tempfile

if len(sys.argv) > 2:
    raise SystemExit("Usage: scripts/test-native-monitor-lifecycle.sh [existing-debug-build-path]")
repo = Path.cwd()
folder = repo / ".local/native-monitor-lifecycle-retained"
folder.mkdir(parents=True, exist_ok=True)
run = Path(tempfile.mkdtemp(prefix="run.", dir=folder))
record = {"status": "started", "hidden": True, "timeoutSecondsPerStage": 120}
print("Private lifecycle evidence:", run.relative_to(repo), flush=True)

def bounded(command, stage):
    with (run / (stage + ".log")).open("wb") as out:
        child = subprocess.Popen(command, cwd=repo, stdout=out, stderr=subprocess.STDOUT,
                                 start_new_session=True)
        try:
            code = child.wait(timeout=120)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait()
            record[stage + "TimeoutOwnedProcessGroupKilled"] = True
            code = 124
    record[stage + "Exit"] = code
    (run / "status.json").write_text(json.dumps(record, indent=2) + "\n")
    if code:
        print((run / (stage + ".log")).read_text(errors="replace"), end="")
        raise SystemExit(code if code > 0 else 128 - code)

if len(sys.argv) == 2:
    build = Path(sys.argv[1]).resolve()
else:
    bounded(["scripts/swift.sh", "build", "--scratch-path", ".build/native-monitor-lifecycle"], "build")
    candidates = list((repo / ".build/native-monitor-lifecycle").glob("*/debug/Modules"))
    if len(candidates) != 1:
        raise SystemExit("Expected exactly one debug module directory")
    build = candidates[0].parent
objects = sorted((build / "PadCore.build").glob("*.o"))
if not (build / "Modules/PadCore.swiftmodule").exists() or not objects:
    raise SystemExit("Existing build must contain PadCore module and object files")

sources = run / "Sources"
sources.mkdir()
manifest = {}
access = {
    "EditorWindowController.swift": ("NativeMonitorControllerAccess.swift", [
        "private var documents: [EditorDocument]", "private var current: EditorDocument?",
        "private func display(_ document: EditorDocument)",
        "private func closeDocuments(ids: Set<UUID>)", "private func reopenClosed()",
        "private func save(_ document: EditorDocument, saveAs: Bool)",
        "private func renderDiskStatus()", "private func makeDiskConflict(_ document: EditorDocument)"]),
    "DocumentFileStateController.swift": ("NativeMonitorBridgeAccess.swift", [
        "private var registration: (any MonitorHandle)?", "private var invalidated = false"]),
}
for path in sorted((repo / "Sources/TheOnlyPad").glob("*.swift")):
    if path.name in {"TheOnlyPadApplication.swift", "AppDelegate.swift"}:
        continue
    original = path.read_bytes()
    text = original.decode()
    manifest[str(path.relative_to(repo))] = hashlib.sha256(original).hexdigest()
    if path.name in access:
        helper, guards = access[path.name]
        for guard in guards:
            if text.count(guard) != 1:
                raise SystemExit("Same-file access guard changed: " + path.name + ": " + guard)
        helper_path = repo / "Tests/NativeIntegration" / helper
        data = helper_path.read_bytes()
        manifest[str(helper_path.relative_to(repo))] = hashlib.sha256(data).hexdigest()
        text += "\n" + data.decode()
    (sources / path.name).write_text(text)
    manifest["augmented/" + path.name] = hashlib.sha256(text.encode()).hexdigest()
harnesses = [repo / "Tests/NativeIntegration" / name for name in (
    "NativeMonitorLifecycleHarness.swift", "NativeMonitorLocateScenarios.swift")]
for harness in harnesses:
    manifest[str(harness.relative_to(repo))] = hashlib.sha256(harness.read_bytes()).hexdigest()
for path in objects:
    manifest["PadCore.build/" + path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
(run / "source-sha256.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
cache = folder / "module-cache"
cache.mkdir(exist_ok=True)
binary = run / "lifecycle-test"
command = ["xcrun", "swiftc", "-target", platform.machine() + "-apple-macosx14.0",
           "-module-cache-path", str(cache), "-parse-as-library", "-I", str(build / "Modules")]
command += [str(path) for path in sorted(sources.glob("*.swift"))]
command += [str(harness) for harness in harnesses] + [str(path) for path in objects] + ["-o", str(binary)]
bounded(command, "compile")
bounded([str(binary)], "runtime")
record["status"] = "passed"
(run / "status.json").write_text(json.dumps(record, indent=2) + "\n")
print((run / "runtime.log").read_text(errors="replace"), end="")
PY
