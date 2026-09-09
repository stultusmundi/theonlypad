#!/usr/bin/env python3
"""Instrument a private copy of the document model; never modify application sources."""
from pathlib import Path
import difflib
import hashlib
import json
import os
import tempfile

repo = Path(__file__).resolve().parent.parent
os.umask(0o077)
base = repo / ".local" / "native-integration" / "dirty-proof"
base.mkdir(parents=True, exist_ok=True)
run = Path(tempfile.mkdtemp(prefix="run.", dir=base))
model_path = repo / "Sources" / "TheOnlyPad" / "EditorDocument.swift"
model = model_path.read_text()
instrumented = model
for marker, counter in (
    ("  private func exactDirtyTextEqual() -> Bool {\n", "DirtyProofMetrics.full(storage.length)"),
    ("  private func dirtyRangeEqual(_ range: NSRange) -> Bool {\n", "DirtyProofMetrics.range(range.length)"),
):
    if instrumented.count(marker) != 1:
        raise SystemExit("Expected exactly one document comparator instrumentation boundary")
    instrumented = instrumented.replace(marker, marker + "    " + counter + "\n", 1)
helper = repo / "Tests" / "NativeIntegration" / "DirtyProofTesting.swift"
instrumented += "\n" + helper.read_text()
combined = run / "DirtyDocumentCombined.swift"
combined.write_text(instrumented)
(run / "instrumentation.diff").write_text("".join(difflib.unified_diff(
    model.splitlines(keepends=True), instrumented.splitlines(keepends=True),
    fromfile="production/EditorDocument.swift", tofile="temporary/DirtyDocumentCombined.swift")))
(run / "source-hashes.json").write_text(json.dumps({
    "productionModel": hashlib.sha256(model.encode()).hexdigest(),
    "temporaryModel": hashlib.sha256(instrumented.encode()).hexdigest(),
    "testHelper": hashlib.sha256(helper.read_bytes()).hexdigest(),
    "harness": hashlib.sha256((repo / "Tests" / "NativeIntegration" /
                               "DirtyDifferentialHarness.swift").read_bytes()).hexdigest(),
}, indent=2) + "\n")
print(combined)
