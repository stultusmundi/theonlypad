#!/bin/bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
python3 -B - "$@" <<'PY'
import hashlib
import importlib.util
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

# Use the existing shared artifact capture/package validator unchanged. Retain
# the exact helper bytes used for this invocation beside its source inventory.
helper_origin = repo / "Tests/NativeIntegration/run_native_regressions.py"
helper_copy = run / "Original/Tests/NativeIntegration/run_native_regressions.py"
helper_copy.parent.mkdir(parents=True)
helper_bytes = helper_origin.read_bytes()
helper_copy.write_bytes(helper_bytes)
spec = importlib.util.spec_from_file_location("native_monitor_artifact_capture", helper_copy)
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)

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
# Current native Sources consume package-scoped SearchExecution. Capture the
# current Core/Search source originals so the accepted compiler-description
# validator can compare the actual compiled Source operands and bytes.
for module in ("PadCore", "SearchExecution"):
    for path in sorted((repo / "Sources" / module).glob("*.swift")):
        target = run / "Original" / path.relative_to(repo)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(native.read_real(repo, path))
core_objects = sorted((build / "PadCore.build").glob("*.o"))
search_objects = sorted((build / "SearchExecution.build").glob("*.o"))
# Unlike the helper's optional Core-only lane, this caller is a two-module
# package consumer. Invoke its existing two-module identity guard explicitly.
native.build_package_identity(build, run, core_objects, search_objects)
dependencies = native.freeze_core(build, run)
core_objects = native.manifest_inputs(run, dependencies, "Core/PadCore.build/", ".o")
search_objects = native.manifest_inputs(run, dependencies, "Core/SearchExecution.build/", ".o")
objects = [*core_objects, *search_objects]

sources = run / "Sources"
sources.mkdir()
manifest = {str(helper_origin.relative_to(repo)): hashlib.sha256(helper_bytes).hexdigest()}
for path in sorted((run / "Original/Sources").rglob("*.swift")):
    manifest[str(path.relative_to(run / "Original"))] = hashlib.sha256(path.read_bytes()).hexdigest()
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
    original_copy = run / "Original" / path.relative_to(repo)
    original_copy.parent.mkdir(parents=True, exist_ok=True)
    original_copy.write_bytes(original)
    text = original.decode()
    manifest[str(path.relative_to(repo))] = hashlib.sha256(original).hexdigest()
    if path.name in access:
        helper, guards = access[path.name]
        for guard in guards:
            if text.count(guard) != 1:
                raise SystemExit("Same-file access guard changed: " + path.name + ": " + guard)
        helper_path = repo / "Tests/NativeIntegration" / helper
        data = helper_path.read_bytes()
        helper_snapshot = run / "Original" / helper_path.relative_to(repo)
        helper_snapshot.parent.mkdir(parents=True, exist_ok=True)
        helper_snapshot.write_bytes(data)
        manifest[str(helper_path.relative_to(repo))] = hashlib.sha256(data).hexdigest()
        text += "\n" + data.decode()
    (sources / path.name).write_text(text)
    manifest["augmented/" + path.name] = hashlib.sha256(text.encode()).hexdigest()
harnesses = [repo / "Tests/NativeIntegration" / name for name in (
    "NativeMonitorLifecycleHarness.swift", "NativeMonitorLocateScenarios.swift")]
frozen_harnesses = []
for harness in harnesses:
    data = harness.read_bytes()
    snapshot = run / "Original" / harness.relative_to(repo)
    snapshot.parent.mkdir(parents=True, exist_ok=True)
    snapshot.write_bytes(data)
    frozen_harnesses.append(snapshot)
    manifest[str(harness.relative_to(repo))] = hashlib.sha256(data).hexdigest()
for row in dependencies["sources"]:
    manifest[row["frozen"]] = row["sha256"]
(run / "source-sha256.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
cache = folder / "module-cache"
cache.mkdir(exist_ok=True)
binary = run / "lifecycle-test"
command = ["xcrun", "swiftc", "-swift-version", "5", "-package-name", dependencies["packageName"],
           "-target", platform.machine() + "-apple-macosx14.0",
           "-module-cache-path", str(cache), "-parse-as-library", "-I", str(run / "Core/Modules")]
command += [str(path) for path in sorted(sources.glob("*.swift"))]
command += [str(harness) for harness in frozen_harnesses] + [str(path) for path in objects] + ["-o", str(binary)]
native.verify(run, dependencies)
bounded(command, "compile")
native.verify(run, dependencies)
bounded([str(binary)], "runtime")
native.verify(run, dependencies)
record["status"] = "passed"
(run / "status.json").write_text(json.dumps(record, indent=2) + "\n")
print((run / "runtime.log").read_text(errors="replace"), end="")
PY
