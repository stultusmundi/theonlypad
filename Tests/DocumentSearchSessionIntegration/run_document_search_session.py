# SPDX-License-Identifier: MIT
"""Freeze actual Foundation session sources, preflight, then become one watchdog.

No caller-selected paths, filters or prebuilt artifacts. No compiler subprocess
is started by this copier. Retained status/captures require independent review;
a watchdog exit alone does not establish component or application acceptance.
"""
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import stat
import sys
import uuid

SOURCE_LIMIT = 1024 * 1024
MEMBER_LIMIT = 4096
SOURCE_TOTAL_LIMIT = 64 * SOURCE_LIMIT
NAMESPACE = "document-search-session-integration"
TEST_CLASS = "DocumentSearchSessionTests"
METHODS = (
    "testAttachAndQueuedStartNeverCaptureText",
    "testSynchronousCompletionBuffersUntilReturnedRequestAdoption",
    "testSynchronousFailureCannotOverrideThrownSubmission",
    "testRejectedStartPublishesTypedFailureWithoutCapture",
    "testLateCompletionCannotReplaceNewSearchAndReleasesExactLease",
    "testNavigationWrapsBothDirectionsAndNeverCopiesResults",
    "testEmptyReplacementResultNeverRequestsApprovalOrNavigation",
    "testApprovalIsHeldWithoutBorrowAndAppliesOnce",
    "testDeniedApprovalConsumesTokenAndReleasesLease",
    "testLateApprovalAfterNewStartCannotTouchNewResult",
    "testApprovalRevalidatesIndependentCredentialAndCompositionChanges",
    "testMissingLeaseNavigationFailsClosed",
    "testNavigationCallbackReentrantCancelCannotRepublishResults",
    "testSearchingCallbackReentrantClosePreventsSubmission",
    "testApprovalPublicationCanReenterCloseWithoutBorrowOrMutation",
    "testCancelAndRepeatedCloseRetireOnlyOwnConsumer",
    "testCancelCalloutNewStartWinsForExactReleaseAndJobCancellation",
    "testSubmittedMatchCeilingRejectsResultAndRetiresLease",
    "testForeignApprovalTokenCannotConsumeOwnApproval",
    "testApprovalPublicationCanResolveSynchronouslyWithoutOverwritingReplacement",
    "testReplacementCallbackNewIntentWinsAfterActualMutation",
)
MANIFEST = b'''// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "DocumentSearchSessionComponent",
  platforms: [.macOS(.v14)],
  targets: [
    .target(name: "PadCore"),
    .target(name: "SearchExecution", dependencies: ["PadCore"]),
    .target(name: "DocumentSearchSessionComponent", dependencies: ["PadCore", "SearchExecution"]),
    .testTarget(name: "DocumentSearchSessionIntegration", dependencies: ["DocumentSearchSessionComponent", "PadCore", "SearchExecution"]),
  ],
  swiftLanguageModes: [.v5]
)
'''
WRAPPER_SHA = "0fa0d91e2c57c03a4f74b6cd605676e274c1a4d69cd55edd9da2589c0bad74c0"
WATCHDOG_SHA = "d5bd867e4a65b4ee053209fe0a5822867b8d0878fd6d059f474c9b28a0f6286d"
OVERRIDES = (
    "SWIFT_EXEC", "DEVELOPER_DIR", "TOOLCHAINS", "PYTHONOPTIMIZE",
    "PYTHONPATH", "PYTHONHOME", "DYLD_INSERT_LIBRARIES",
    "CLANG_MODULE_CACHE_PATH", "SWIFTPM_MODULECACHE_OVERRIDE",
)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def checked_path(path):
    """Check every absolute component before access, without resolving symlinks."""
    path = Path(path)
    require(path.is_absolute() and ".." not in path.parts, "Noncanonical path")
    require("\0" not in str(path), "NUL path")
    str(path).encode("utf-8", "strict")
    for item in reversed((path, *path.parents)):
        if os.path.lexists(item):
            require(not stat.S_ISLNK(item.lstat().st_mode), "Symlink path")
    return path


def read_file(path):
    path = checked_path(path)
    preliminary = path.lstat()
    require(stat.S_ISREG(preliminary.st_mode) and preliminary.st_size <= SOURCE_LIMIT,
            "Nonregular or oversized source")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and before.st_size <= SOURCE_LIMIT,
                "Source kind or size changed")
        chunks, remaining = [], SOURCE_LIMIT + 1
        while remaining:
            chunk = os.read(fd, min(65536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
        after = os.fstat(fd)
        identity = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mode, s.st_mtime_ns)
        require(identity(preliminary) == identity(before) == identity(after)
                and len(data) == before.st_size and len(data) <= SOURCE_LIMIT,
                "Source changed during read")
        return data, before
    finally:
        os.close(fd)


def pin(path):
    data, info = read_file(path)
    return {"path": str(path), "bytes": len(data),
            "mode": stat.S_IMODE(info.st_mode),
            "sha256": hashlib.sha256(data).hexdigest()}


def identity(path):
    info = checked_path(path).lstat()
    return {"device": info.st_dev, "inode": info.st_ino, "owner": info.st_uid}


def directory(path, private=False):
    info = checked_path(path).lstat()
    require(stat.S_ISDIR(info.st_mode), "Non-directory parent")
    if private:
        require(info.st_uid == os.geteuid() and stat.S_IMODE(info.st_mode) == 0o700,
                "Private directory ownership/mode")
    return {"path": str(path), **identity(path), "mode": stat.S_IMODE(info.st_mode)}


def make_directory(path):
    checked_path(path)
    require(not os.path.lexists(path), "Fresh directory already exists")
    path.mkdir(mode=0o700)
    return directory(path, True)


def ensure_parent(path, private=False):
    checked_path(path)
    if not os.path.lexists(path):
        path.mkdir(mode=0o700)
    return directory(path, private)


def write_new(path, data, mode=0o400):
    checked_path(path)
    with path.open("xb") as stream:
        stream.write(data)
    path.chmod(mode)
    require(path.stat().st_uid == os.geteuid(), "Copied file owner")


def json_bytes(record):
    return (json.dumps(record, indent=2, allow_nan=False) + "\n").encode("utf-8")


def swift_inventory(repo):
    """Recursive actual Swift inputs; refuse symlinks and filename collisions."""
    rows, directories, total, visited = [], [], 0, 0
    for module in ("PadCore", "SearchExecution"):
        top = repo / "Sources" / module
        pending, names = [top], set()
        while pending:
            parent = pending.pop()
            directories.append(directory(parent))
            for child in sorted(parent.iterdir()):
                visited += 1
                require(visited <= MEMBER_LIMIT, "Source traversal bound")
                checked_path(child)
                info = child.lstat()
                if stat.S_ISDIR(info.st_mode):
                    pending.append(child)
                else:
                    require(stat.S_ISREG(info.st_mode), "Unexpected source file kind")
                    if child.suffix == ".swift":
                        require(child.name.casefold() not in names, "Source-name collision")
                        names.add(child.name.casefold())
                        total += info.st_size
                        rows.append((child, "Package/Sources/" + module + "/"
                                     + child.relative_to(top).as_posix(), 0o400))
                require(len(rows) + len(directories) + len(pending) <= MEMBER_LIMIT
                        and total <= SOURCE_TOTAL_LIMIT, "Source inventory bound")
        require(names, "Empty required source module")
    rows.sort(key=lambda row: str(row[0]))
    directories.sort(key=lambda row: row["path"])
    return rows, directories


def source_map(repo):
    rows, directories = swift_inventory(repo)
    rows += [
        (repo / "Sources/TheOnlyPad" / name,
         "Package/Sources/DocumentSearchSessionComponent/" + name, 0o400)
        for name in ("ApplicationSearchOwner.swift", "EditorDocumentSearchSource.swift",
                     "DocumentSearchSession.swift")
    ]
    rows += [
        (repo / "Tests/DocumentSearchSessionIntegration/DocumentSearchSessionTests.swift",
         "Package/Tests/DocumentSearchSessionIntegration/DocumentSearchSessionTests.swift", 0o400),
        (repo / "scripts/swift.sh", "Runner/scripts/swift.sh", 0o755),
        (repo / "scripts/run-owned-search-tests.py", "Runner/scripts/run-owned-search-tests.py", 0o400),
    ]
    destinations = [row[1].casefold() for row in rows]
    require(len(destinations) == len(set(destinations)), "Destination collision")
    return rows, directories


def check_roster(data):
    text = data.decode("utf-8", "strict")
    require(re.findall(r"\bclass\s+(\w+)\s*:\s*XCTestCase\b", text) == [TEST_CLASS],
            "Unexpected test class")
    require(tuple(re.findall(r"\bfunc\s+(test\w+)\s*\(", text)) == METHODS,
            "Original twenty-one-test roster changed")


def environment():
    require(sys.flags.optimize == 0, "Python optimization is unsupported")
    require(all(name not in os.environ for name in OVERRIDES), "Tool/cache environment override")
    require(shutil.which("swift") == "/usr/bin/swift", "Swift selection must be /usr/bin/swift")
    # The selected /usr/bin/python3 Xcode shim may supply SDKROOT. Preserve and
    # record it as an observation; artifact review must verify the actual SDK.
    return {"python": sys.executable, "pythonOptimize": sys.flags.optimize,
            "swift": "/usr/bin/swift", "SDKROOT": os.environ.get("SDKROOT"),
            "absentOverrides": list(OVERRIDES)}


def stage_command(run, scratch):
    return ["/usr/bin/python3", "-B", str(run / "Runner/scripts/run-owned-search-tests.py"),
            "--timeout", "180", "--output", str(run / "owned"), "--",
            str(run / "Runner/scripts/swift.sh"), "test", "--package-path", str(run / "Package"),
            "--scratch-path", str(scratch), "--filter", TEST_CLASS]


def membership(run):
    result, pending = [], [run / "Package", run / "Runner", run / "Evidence"]
    while pending:
        path = pending.pop()
        info = checked_path(path).lstat()
        if stat.S_ISDIR(info.st_mode):
            result.append({"kind": "directory", **directory(path, True)})
            pending.extend(sorted(path.iterdir()))
        else:
            require(stat.S_ISREG(info.st_mode), "Unexpected frozen member kind")
            result.append({"kind": "file", **pin(path), **identity(path)})
        require(len(result) + len(pending) <= MEMBER_LIMIT, "Frozen membership bound")
    return sorted(result, key=lambda row: row["path"])


def prepare(repo, run, scratch):
    rows, source_directories = source_map(repo)
    directories = {"Package", "Package/Sources", "Package/Tests", "Runner", "Runner/scripts", "Evidence"}
    for _, name, _ in rows:
        parent = Path(name).parent
        while parent != Path("."):
            directories.add(parent.as_posix())
            parent = parent.parent
    for name in sorted(directories, key=lambda item: (len(Path(item).parts), item)):
        make_directory(run / name)
    record = {"scope": "Foundation scripted session original21 only; no native/helper/app activation",
              "repo": str(repo), "run": str(run), "scratch": str(scratch),
              "roots": [directory(run.parent, True), directory(run, True), directory(scratch.parent, True)],
              "sourceDirectories": source_directories, "adopted": [], "provenance": [],
              "generated": [], "environment": environment(),
              "command": stage_command(run, scratch), "testMethods": list(METHODS)}
    total = 0
    for origin, name, mode in rows:
        data, _ = read_file(origin)
        total += len(data)
        require(total <= SOURCE_TOTAL_LIMIT, "Combined source bound")
        original = pin(origin)
        require(original["sha256"] == hashlib.sha256(data).hexdigest(), "Source changed before copy")
        target = run / name
        write_new(target, data, mode)
        record["adopted"].append({"original": original, "originalIdentity": identity(origin),
                                  "frozen": pin(target), "frozenIdentity": identity(target)})
    write_new(run / "Package/Package.swift", MANIFEST)
    record["generated"].append(pin(run / "Package/Package.swift"))
    for index, name in enumerate(("scripts/test-document-search-session.sh",
                                 "Tests/DocumentSearchSessionIntegration/run_document_search_session.py",
                                 "Package.swift")):
        origin = repo / name
        data, _ = read_file(origin)
        target = run / "Evidence" / (str(index) + "-" + origin.name)
        write_new(target, data)
        record["provenance"].append({"original": pin(origin), "originalIdentity": identity(origin),
                                     "frozen": pin(target), "frozenIdentity": identity(target)})
    record["members"] = membership(run)
    record["absent"] = [str(path) for path in (
        scratch, run / "owned", run / "preflight.json", run / "Runner/.cache",
        run / "Package/.build", run / "Package/.swiftpm", run / "Package/Package.resolved",
    )]
    write_new(run / "inputs.json", json_bytes(record))
    return record


def preflight(repo, run, scratch, record):
    require(read_file(run / "inputs.json")[0] == json_bytes(record)
            and pin(run / "inputs.json")["mode"] == 0o400
            and identity(run / "inputs.json")["owner"] == os.geteuid(), "Input manifest changed")
    require(record["repo"] == str(repo) and record["run"] == str(run)
            and record["scratch"] == str(scratch), "Root binding changed")
    for row in record["roots"]:
        require(directory(Path(row["path"]), True) == row, "Root identity changed")
    rows, source_directories = source_map(repo)
    require(source_directories == record["sourceDirectories"], "Source directory drift")
    require([(str(a), str(run / b), c) for a, b, c in rows]
            == [(r["original"]["path"], r["frozen"]["path"], r["frozen"]["mode"])
                for r in record["adopted"]], "Source inventory drift")
    for row in record["adopted"] + record["provenance"]:
        for side in ("original", "frozen"):
            path = Path(row[side]["path"])
            require(pin(path) == row[side] and identity(path) == row[side + "Identity"],
                    "Source/provenance drift")
        require(row["original"]["sha256"] == row["frozen"]["sha256"]
                and row["original"]["bytes"] == row["frozen"]["bytes"], "Copy differs")
        require((row["originalIdentity"]["device"], row["originalIdentity"]["inode"])
                != (row["frozenIdentity"]["device"], row["frozenIdentity"]["inode"]),
                "Copy aliases original")
        require(row["frozenIdentity"]["owner"] == os.geteuid(), "Frozen ownership changed")
    require(membership(run) == record["members"], "Frozen membership drift")
    require(record["generated"] == [pin(run / "Package/Package.swift")]
            and read_file(run / "Package/Package.swift")[0] == MANIFEST, "Manifest drift")
    require(pin(run / "Runner/scripts/swift.sh")["sha256"] == WRAPPER_SHA
            and pin(run / "Runner/scripts/run-owned-search-tests.py")["sha256"] == WATCHDOG_SHA,
            "Wrapper/watchdog must remain reviewed public bytes")
    check_roster(read_file(run / "Package/Tests/DocumentSearchSessionIntegration/DocumentSearchSessionTests.swift")[0])
    require(record["testMethods"] == list(METHODS)
            and record["command"] == stage_command(run, scratch), "Closed selection/argv changed")
    require(environment() == record["environment"], "Environment selection drift")
    for name in record["absent"]:
        path = checked_path(Path(name))
        require(not os.path.lexists(path), "Fresh output/cache already exists")
    require(set(child.name for child in run.iterdir()) == {"Package", "Runner", "Evidence", "inputs.json"},
            "Unexpected run member")
    write_new(run / "preflight.json", json_bytes({"scope": record["scope"],
              "inputs": pin(run / "inputs.json"), "command": record["command"],
              "testMethods": list(METHODS), "environment": record["environment"],
              "verifiedOriginalFrozenPairs": len(record["adopted"]),
              "verifiedMembers": len(record["members"])}))


def main(argv):
    require(not argv, "This runner accepts no arguments")
    require(sys.platform == "darwin" and platform.machine() == "arm64", "Darwin ARM64 required")
    environment()
    os.umask(0o077)
    script = checked_path(Path(os.path.abspath(__file__)))
    repo = script.parents[2]
    require(script == repo / "Tests/DocumentSearchSessionIntegration/run_document_search_session.py",
            "Runner location mismatch")
    directory(repo)
    for parent in (repo / ".local", repo / ".build"):
        ensure_parent(parent)
    local = repo / ".local" / NAMESPACE
    build = repo / ".build" / NAMESPACE
    ensure_parent(local, True)
    ensure_parent(build, True)
    name = "run." + str(uuid.uuid4()).upper()
    run, scratch = local / name, build / name
    require(not os.path.lexists(checked_path(scratch)), "Fresh scratch collision")
    make_directory(run)
    record = prepare(repo, run, scratch)
    preflight(repo, run, scratch, record)
    print("Private document search session evidence: " + str(run), flush=True)
    os.chdir(run / "Runner")
    os.execv("/usr/bin/python3", record["command"])


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (ValueError, OSError, UnicodeError) as error:
        print("Document search session runner refused: " + type(error).__name__, file=sys.stderr)
        raise SystemExit(2)
