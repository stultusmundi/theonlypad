# SPDX-License-Identifier: MIT
"""Fixed hidden file-adapter verification. Run only with exclusive test ownership.

The immediate child is the unchanged watchdog. It alone owns the Swift/test
session and consuming wait. This parent retains evidence and never removes runs.
"""
import errno
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import signal
import stat
import struct
import subprocess
import sys
import uuid

LIMIT = 1024 * 1024
ARTIFACT_LIMIT = 64 * LIMIT
PRODUCT = "PreparedFileDarwinComponentPackageTests"
NATIVE_MODULE = "SearchAdmissionFileDarwinIntegration"
TEST_CLASS = "SearchAdmissionFileDarwinTests"
PRODUCTION = (
    "SearchPreparedUTF8Decoder.swift", "SearchAdmissionFileInput.swift",
    "SearchAdmissionFileIO.swift", "SearchAdmissionFileReader.swift",
    "SearchAdmissionFileDarwinIO.swift",
)
NATIVE = ("SearchAdmissionFileDarwinTests.swift", "SearchAdmissionFileDarwinFixture.swift")
METHODS = (
    "testRegularUnicodeFileMatchesDescriptorAndPathMetadata",
    "testOpenFlagsAreReadOnlyNonblockingAndCloseOnExec",
    "testBoundedPreadPreservesOffsetsAndGuardBytes",
    "testMissingPathPreservesENOENTWithoutDescriptor",
    "testFinalSymlinkIsNotFollowed",
    "testFIFOOpensWithoutPeerAndSamplesNonregular",
    "testObservedGrowthAboveAdmissionLimitRemainsSampleable",
    "testReaderAndConcreteAdapterPreserveBOMAndSupplementaryText",
    "testNativeStatNormalizationPreservesBitsAndRejectsInvalidMetadata",
)
MANIFEST = b'''// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "PreparedFileDarwinComponent",
  platforms: [.macOS(.v14)],
  targets: [
    .target(name: "SearchExecution"),
    .testTarget(name: "SearchAdmissionFileDarwinIntegration", dependencies: ["SearchExecution"]),
  ],
  swiftLanguageModes: [.v5]
)
'''
DIRECTORIES = (
    "Package", "Package/Sources", "Package/Sources/SearchExecution",
    "Package/Tests", "Package/Tests/SearchAdmissionFileDarwinIntegration",
    "Runner", "Runner/scripts",
)
PROVENANCE = (
    "scripts/test-search-admission-file-darwin.sh",
    "Tests/SearchAdmissionFileDarwinIntegration/run_harness.py", "Package.swift",
)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def parse_args(argv):
    if argv:
        raise SystemExit(2)


def checked_path(root, path):
    """Reject within-root symlinks before resolution; not an adversarial jail."""
    root, path = Path(root), Path(path)
    require(root.is_absolute() and path.is_absolute(), "Absolute paths required")
    require(".." not in path.parts and ".." not in root.parts, "Parent traversal")
    try:
        relative = path.relative_to(root)
        for part in (root, *[root.joinpath(*relative.parts[:n])
                             for n in range(1, len(relative.parts) + 1)]):
            if os.path.lexists(part):
                require(not stat.S_ISLNK(part.lstat().st_mode), "Symlink: " + str(part))
        str(path).encode("utf-8", "strict")
        require("\0" not in str(path), "NUL path")
    except (OSError, UnicodeError) as error:
        raise ValueError("Invalid path: " + str(path)) from error
    return path


def read_bounded(root, path, limit):
    path = checked_path(root, path)
    try:
        preliminary = path.lstat()
        require(stat.S_ISREG(preliminary.st_mode) and preliminary.st_size <= limit,
                "Nonregular or oversized input: " + str(path))
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
        try:
            before = os.fstat(fd)
            require(stat.S_ISREG(before.st_mode) and before.st_size <= limit,
                    "Nonregular or oversized input: " + str(path))
            chunks, remaining = [], limit + 1
            while remaining:
                chunk = os.read(fd, min(65536, remaining))
                if not chunk:
                    break
                chunks.append(chunk)
                remaining -= len(chunk)
            data = b"".join(chunks)
            after = os.fstat(fd)
            require(len(data) <= limit and len(data) == before.st_size,
                    "Input extent changed: " + str(path))
            require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns,
                     before.st_mode) == (after.st_dev, after.st_ino, after.st_size,
                                        after.st_mtime_ns, after.st_mode), "Input changed during read")
            return data
        finally:
            os.close(fd)
    except OSError as error:
        raise ValueError("Cannot read: " + str(path)) from error


def read_source(repo, path):
    return read_bounded(repo, path, LIMIT)


def byte_pin(path, data):
    return {"path": str(path), "bytes": len(data),
            "mode": stat.S_IMODE(Path(path).stat().st_mode),
            "sha256": hashlib.sha256(data).hexdigest()}


def file_pin(root, path):
    return byte_pin(path, read_source(root, path))


def directory_fact(repo, path):
    path = checked_path(repo, path)
    try:
        info = path.stat()
        require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.geteuid()
                and stat.S_IMODE(info.st_mode) == 0o700, "Directory ownership/mode: " + str(path))
        return {"path": str(path), "device": info.st_dev, "inode": info.st_ino,
                "owner": info.st_uid, "mode": stat.S_IMODE(info.st_mode)}
    except OSError as error:
        raise ValueError("Missing owned directory: " + str(path)) from error


def layout(repo, run):
    repo, run = Path(repo), Path(run)
    checked_path(repo, run)
    require(run.parent == repo / ".local/search-admission-file-darwin", "Wrong run namespace")
    require(re.fullmatch(r"run\.[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}", run.name),
            "Noncanonical run UUID")
    value = str(run / "Fixtures").encode("utf-8")
    require(len(value) + len("/case." + "0" * 36 + "/entry") <= 4096,
            "Fixture path exceeds bound")
    scratch = repo / ".build/search-admission-file-darwin" / run.name
    checked_path(repo, scratch)
    return scratch


def source_map():
    rows = [("Sources/SearchExecution/" + name,
             "Package/Sources/SearchExecution/" + name, 0o400) for name in PRODUCTION]
    rows += [("Tests/" + NATIVE_MODULE + "/" + name,
              "Package/Tests/" + NATIVE_MODULE + "/" + name, 0o400) for name in NATIVE]
    rows += [("scripts/swift.sh", "Runner/scripts/swift.sh", 0o755),
             ("scripts/run-owned-search-tests.py", "Runner/scripts/run-owned-search-tests.py", 0o644)]
    return rows


def write_new(path, data, mode=0o400):
    with Path(path).open("xb") as stream:
        stream.write(data)
    Path(path).chmod(mode)


def atomic_record(run, name, record):
    """Fresh record only; never replace an old result or delete evidence."""
    destination = run / name
    require(not os.path.lexists(destination), "Record already exists")
    temporary = run / (name + ".partial")
    write_new(temporary, (json.dumps(record, indent=2, allow_nan=False) + "\n").encode())
    require(not os.path.lexists(destination), "Record appeared")
    os.replace(temporary, destination)


def capture_inputs(repo, run):
    repo, run = Path(repo), Path(run)
    layout(repo, run)
    roots = [directory_fact(repo, p) for p in (run.parent, run, run / "Fixtures")]
    require(not any((run / "Fixtures").iterdir()), "Fixtures must start empty")
    manifest = {"repo": str(repo), "run": str(run), "roots": roots,
                "adopted": [], "provenance": [], "generated": [], "members": []}
    try:
        for name in DIRECTORIES:
            (run / name).mkdir(mode=0o700)
        for source, destination, mode in source_map():
            origin, target = repo / source, run / destination
            data = read_source(repo, origin)
            original = byte_pin(origin, data)
            write_new(target, data, mode)
            manifest["adopted"].append({"original": original, "frozen": byte_pin(target, data)})
        write_new(run / "Package/Package.swift", MANIFEST)
        manifest["generated"].append(file_pin(repo, run / "Package/Package.swift"))
        (run / "Evidence").mkdir(mode=0o700)
        (run / "Evidence/Provenance").mkdir(mode=0o700)
        for index, name in enumerate(PROVENANCE):
            origin = repo / name
            data = read_source(repo, origin)
            original = byte_pin(origin, data)
            target = run / "Evidence/Provenance" / (str(index) + "-" + origin.name)
            write_new(target, data)
            manifest["provenance"].append({"original": original, "frozen": byte_pin(target, data)})
        manifest["manifestGenerator"] = manifest["provenance"][1]["original"]
        for name in DIRECTORIES:
            manifest["members"].append({"path": str(run / name), "kind": "directory", "mode": 0o700})
        for row in manifest["adopted"]:
            manifest["members"].append(dict(row["frozen"], kind="file"))
        manifest["members"].append(dict(manifest["generated"][0], kind="file"))
        verify_inputs(repo, run, manifest)
        atomic_record(run, "inputs.json", manifest)
        return manifest
    except OSError as error:
        raise ValueError("Capture setup failed") from error


def verify_inputs(repo, run, manifest):
    repo, run = Path(repo), Path(run)
    layout(repo, run)
    require(manifest["repo"] == str(repo) and manifest["run"] == str(run), "Manifest root mismatch")
    for row in manifest["roots"]:
        require(directory_fact(repo, Path(row["path"])) == row, "Root identity changed")
    require(not any((run / "Fixtures").iterdir()), "Fixture entries remain; evidence retained")
    for row in manifest["adopted"] + manifest["provenance"]:
        for side in ("original", "frozen"):
            require(file_pin(repo, Path(row[side]["path"])) == row[side], "Source/provenance drift")
        require(row["original"]["sha256"] == row["frozen"]["sha256"], "Copy differs")
    for row in manifest["generated"]:
        require(file_pin(repo, Path(row["path"])) == row, "Generated source drift")
    require(read_source(repo, run / "Package/Package.swift") == MANIFEST, "Manifest changed")
    actual = {}
    for top in (run / "Package", run / "Runner"):
        pending = [top]
        while pending:
            path = pending.pop()
            checked_path(repo, path)
            if path == run / "Runner/.cache":
                info = path.stat()
                require(path.is_dir() and info.st_uid == os.geteuid(), "Unsafe cache root")
                continue
            info = path.lstat()
            mode = stat.S_IMODE(info.st_mode)
            if stat.S_ISDIR(info.st_mode):
                actual[str(path)] = {"path": str(path), "kind": "directory", "mode": mode}
                with os.scandir(path) as entries:
                    for child in entries:
                        pending.append(Path(child.path))
                        require(len(actual) + len(pending) <= 18, "Additional immutable member")
            else:
                actual[str(path)] = dict(file_pin(repo, path), kind="file")
            require(len(actual) <= 17, "Additional immutable member")
    require(actual == {row["path"]: row for row in manifest["members"]}, "Immutable membership drift")


def stage_command(repo, run):
    repo, run = Path(repo), Path(run)
    scratch = layout(repo, run)
    return ["/usr/bin/python3", "-B", str(run / "Runner/scripts/run-owned-search-tests.py"),
            "--timeout", "180", "--output", str(run / "owned"), "--", "/usr/bin/env",
            "THEONLYPAD_FILE_DARWIN_FIXTURE_ROOT=" + str(run / "Fixtures"),
            str(run / "Runner/scripts/swift.sh"), "test", "--package-path", str(run / "Package"),
            "--scratch-path", str(scratch), "--filter", TEST_CLASS]


def decode_json(data):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, "Duplicate JSON field")
            result[key] = value
        return result
    try:
        return json.loads(data.decode("utf-8", "strict"), object_pairs_hook=pairs,
                          parse_constant=lambda value: (_ for _ in ()).throw(ValueError("Nonfinite JSON")))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise ValueError("Invalid JSON") from error


def integer(value):
    return type(value) is int


def validate_receipt(output, child_command, watchdog_return):
    output = Path(output)
    record = decode_json(read_source(output, output / "status.json"))
    try:
        require(isinstance(record, dict) and record["command"] == child_command, "Receipt command")
        require(integer(watchdog_return) and watchdog_return in (0, 1), "Watchdog infrastructure exit")
        require(integer(record["pid"]) and record["pid"] > 0 and integer(record["processGroup"])
                and record["processGroup"] == record["pid"], "Receipt PID/group")
        for name in ("exitObserved", "waitCompleted", "captureComplete", "groupSignalAttempted"):
            require(record[name] is True, "Incomplete " + name)
        for name in ("timedOut", "truncated"):
            require(record[name] is False, "Incomplete " + name)
        for name in ("registrationError", "waitError", "failure", "interruptedSignal"):
            require(record[name] is None, "Failure " + name)
        for name in ("returnCode", "exit"):
            require(integer(record[name]) and record[name] == watchdog_return, "Receipt exit mismatch")
        try:
            require(type(record["seconds"]) in (int, float) and math.isfinite(record["seconds"])
                    and record["seconds"] > 0, "Receipt duration")
        except OverflowError as error:
            raise ValueError("Receipt duration") from error
        cleanup, error, query = record["groupCleanup"], record["groupSignalError"], record["groupQuery"]
        if cleanup == "signaled":
            require(error is None and query is None, "Signaled receipt")
        elif cleanup == "absent":
            require(integer(error) and error == errno.ESRCH and query is None, "Absent receipt")
        elif cleanup == "exitedLeaderOnly":
            require(integer(error) and error == errno.EPERM and isinstance(query, dict), "EPERM receipt")
            for key, expected in (("processGroup", record["pid"]), ("returnedBytes", 4), ("bufferBytes", 1024)):
                require(integer(query[key]) and query[key] == expected, "Singleton query " + key)
            require(query["errorNumber"] is None and type(query["members"]) is list
                    and len(query["members"]) == 1 and integer(query["members"][0])
                    and query["members"][0] == record["pid"], "Incomplete singleton query")
        else:
            raise ValueError("Unconfirmed group cleanup")
        for stream in ("stdout", "stderr"):
            data = read_source(output, output / (stream + ".log"))
            fields = record["captured"][stream]
            for key, value in (("received", len(data)), ("stored", len(data)), ("discarded", 0)):
                require(integer(fields[key]) and fields[key] == value, "Capture loss/extent")
        return record
    except (KeyError, TypeError, IndexError) as error:
        raise ValueError("Malformed receipt") from error


def progress_line(line):
    if line == "Building for debugging..." or re.fullmatch(r"Build complete! \([0-9]+\.[0-9]+s\)", line):
        return True
    match = re.fullmatch(r"\[([0-9]+)/([0-9]+)\] (.+)", line)
    if not match or int(match[1]) > int(match[2]):
        return False
    text = match[3]
    if text in ("Write sources", "Write Objects.LinkFileList", "Linking " + PRODUCT):
        return True
    if re.fullmatch(r"Write swift-version--[0-9A-Fa-f]+\.txt", text):
        return True
    if text.startswith("/") and text.endswith("/" + PRODUCT + ".derived/runner.swift"):
        return "\0" not in text
    for module, names in (("SearchExecution", PRODUCTION), (NATIVE_MODULE, NATIVE), (PRODUCT, ("runner.swift",))):
        if text == "Emitting module " + module or text in {"Compiling " + module + " " + name for name in names}:
            return True
    return False


def validate_tests(stdout_bytes, stderr_bytes):
    require(type(stdout_bytes) is bytes and type(stderr_bytes) is bytes
            and len(stdout_bytes) <= LIMIT and len(stderr_bytes) <= LIMIT, "Capture bound/type")
    try:
        streams = [data.decode("utf-8", "strict").splitlines() for data in (stdout_bytes, stderr_bytes)]
    except UnicodeError as error:
        raise ValueError("Capture UTF8") from error
    identities = {NATIVE_MODULE + "." + TEST_CLASS + " " + name: name for name in METHODS}
    starts, terminals, failed, assertions, suites, counters = [], [], [], [], [], []
    stack, active, awaiting_counter, footer = [], None, None, 0
    suite_order = ["Selected tests", PRODUCT + ".xctest", TEST_CLASS]
    footer_patterns = (r"◇ Test run started\.", r"↳ Testing Library Version: [0-9]+(?:\.[0-9]+)*",
                       r"↳ Target Platform: (?:arm64e?|x86_64)-apple-macos[0-9.]+",
                       r"✔ Test run with 0 tests in 0 suites passed after [0-9.]+ seconds\.")
    for stream in streams:
        for line in stream:
            if progress_line(line):
                continue
            match = re.fullmatch(r"Test Suite '([^']+)' (started|passed|failed) at [0-9-]+ [0-9:.]+\.", line)
            if match:
                require(footer == 0 and active is None and awaiting_counter is None, "Suite ordering")
                name, state = match.groups()
                if state == "started":
                    require(len(stack) < 3 and name == suite_order[len(stack)] and (name, state) not in suites,
                            "Unexpected/duplicate suite")
                    stack.append(name)
                else:
                    require(stack and stack.pop() == name and len(terminals) == 9, "Incomplete suite")
                    require(state == ("failed" if failed else "passed"), "Suite terminal mismatch")
                    awaiting_counter = name
                suites.append((name, state))
                continue
            match = re.fullmatch(r"Test Case '-\[(.+)\]' (started\.|(passed|failed) \([0-9.]+ seconds\)\.)", line)
            if match:
                identity, terminal = match[1], match[3]
                require(identity in identities and stack == suite_order and awaiting_counter is None and footer == 0,
                        "Unexpected test identity/scope")
                if terminal is None:
                    require(active is None and identity not in starts, "Duplicate/overlapping test")
                    active = identity
                    starts.append(identity)
                else:
                    require(active == identity and identity not in terminals, "Unpaired terminal")
                    terminals.append(identity)
                    active = None
                    if terminal == "failed":
                        require(identity in assertions, "Failed test without named assertion")
                        failed.append(identities[identity])
                    else:
                        require(identity not in assertions, "Passed test with assertion")
                continue
            match = re.fullmatch(r"/.+/SearchAdmissionFileDarwin(?:Tests|Fixture)\.swift:[0-9]+(?::[0-9]+)?: error: -\[(.+)\] : (XCTAssert[A-Za-z]* failed(?::| -).+|XCTUnwrap failed(?::| -).+|failed - .+)", line)
            if match:
                require(match[1] == active and active in identities, "Unbound assertion")
                assertions.append(active)
                continue
            match = re.fullmatch(r"\s+Executed 9 tests, with ([0-9]+) failures \(0 unexpected\) in [0-9.]+ \([0-9.]+\) seconds", line)
            if match:
                require(awaiting_counter is not None and int(match[1]) == len(assertions), "Counter mismatch")
                counters.append((awaiting_counter, int(match[1])))
                awaiting_counter = None
                continue
            if footer < 4 and re.fullmatch(footer_patterns[footer], line):
                require(not stack and len(counters) == 3 and len(terminals) == 9, "Premature footer")
                footer += 1
                continue
            raise ValueError("Unrecognized test/build output: " + line[:240])
    require(set(starts) == set(identities) and starts == terminals and len(starts) == 9,
            "Incomplete nine-test identity set")
    require(active is None and not stack and awaiting_counter is None and len(suites) == 6
            and len(counters) == 3 and footer in (0, 4), "Incomplete suite/footer")
    return {"classification": "testFailure" if failed else "success", "testCount": 9,
            "failedMethods": failed, "started": starts, "terminals": terminals,
            "assertionCount": len(assertions), "suiteCounters": counters}


def artifact_pin(root, path):
    path = checked_path(root, path)
    try:
        preliminary = path.lstat()
        require(stat.S_ISREG(preliminary.st_mode) and preliminary.st_size <= ARTIFACT_LIMIT,
                "Artifact file bound/type")
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
        try:
            before = os.fstat(fd)
            require(stat.S_ISREG(before.st_mode) and before.st_size <= ARTIFACT_LIMIT,
                    "Artifact file bound/type")
            digest, total = hashlib.sha256(), 0
            while True:
                chunk = os.read(fd, 65536)
                if not chunk:
                    break
                total += len(chunk)
                require(total <= ARTIFACT_LIMIT, "Growing artifact")
                digest.update(chunk)
            after = os.fstat(fd)
            require(total == before.st_size and
                    (before.st_dev, before.st_ino, before.st_mtime_ns, before.st_mode, before.st_size) ==
                    (after.st_dev, after.st_ino, after.st_mtime_ns, after.st_mode, after.st_size),
                    "Artifact changed while hashing")
            return {"path": str(path), "bytes": total, "mode": stat.S_IMODE(before.st_mode),
                    "sha256": digest.hexdigest()}
        finally:
            os.close(fd)
    except OSError as error:
        raise ValueError("Unreadable artifact: " + str(path)) from error


def option(arguments, name):
    require(type(arguments) is list and all(type(x) is str for x in arguments), "Argument vector")
    require(arguments.count(name) == 1, "Missing/duplicate option " + name)
    index = arguments.index(name)
    require(index + 1 < len(arguments), "Missing option value")
    return arguments[index + 1]


def link_block(yaml_text, key):
    """Only the inspected SwiftPM JSON-valued .test block, not a YAML loader."""
    header = "  " + json.dumps(key) + ":"
    lines = yaml_text.splitlines()
    require(lines.count(header) == 1, "Missing/duplicate test link command")
    block = {}
    for line in lines[lines.index(header) + 1:]:
        if not line or not line.startswith("    "):
            break
        match = re.fullmatch(r"    ([A-Za-z]+): (.+)", line)
        require(match is not None and match[1] not in block, "Link block syntax")
        block[match[1]] = match[2]
    require(block.get("tool") == "shell", "Link block tool")
    for field in ("inputs", "outputs", "description", "args"):
        require(field in block, "Missing link field")
        block[field] = decode_json(block[field].encode("utf-8"))
    return block


def bind_artifacts(run, scratch, manifest):
    run, scratch = Path(run), Path(scratch)
    repo = Path(manifest["repo"])
    verify_inputs(repo, run, manifest)
    require(scratch == layout(repo, run), "Foreign scratch")
    checked_path(repo, scratch)
    architecture = platform.machine()
    require(architecture in ("arm64", "x86_64"), "Unsupported architecture")
    triple = architecture + "-apple-macosx"
    debug = scratch / triple / "debug"
    bundle = debug / (PRODUCT + ".xctest")
    binary = bundle / "Contents/MacOS" / PRODUCT
    # Reject an additional bundle for another architecture/configuration.
    candidates = list(scratch.glob("*-apple-macosx/debug/" + PRODUCT + ".xctest"))
    require(candidates == [bundle], "Ambiguous/missing test bundle")
    description_path = debug / "description.json"
    description = decode_json(read_source(repo, description_path))
    bindings = [file_pin(repo, description_path)]
    try:
        require(description["builtTestProducts"] == [{"binaryPath": str(binary),
                "packagePath": str(run / "Package"), "productName": PRODUCT}], "Product escape/mismatch")
        commands = description["swiftCommands"]
        expected_keys = {"C." + module + "-" + triple + "-debug.module"
                         for module in ("SearchExecution", NATIVE_MODULE, PRODUCT)}
        require(set(commands) == expected_keys, "Unexpected Swift target closure")
        generated = debug / (PRODUCT + ".derived/runner.swift")
        groups = (("SearchExecution", [str(run / "Package/Sources/SearchExecution" / n) for n in PRODUCTION]),
                  (NATIVE_MODULE, [str(run / "Package/Tests" / NATIVE_MODULE / n) for n in NATIVE]),
                  (PRODUCT, [str(generated)]))
        all_objects = []
        for module, expected_sources in groups:
            command = commands["C." + module + "-" + triple + "-debug.module"]
            sources, objects = command["sources"], command["objects"]
            require(type(sources) is list and len(sources) == len(set(sources))
                    and set(sources) == set(expected_sources), "Wrong compiled source set")
            expected_objects = [str(debug / (module + ".build") / (Path(src).name + ".o")) for src in sources]
            require(objects == expected_objects, "Source/object correspondence")
            require(command["moduleName"] == module, "Module mismatch")
            require(option(command["otherArguments"], "-target") == architecture + "-apple-macosx14.0",
                    "Wrong deployment target")
            if module != PRODUCT:
                require(option(command["otherArguments"], "-swift-version") == "5", "Wrong Swift mode")
            file_list = debug / (module + ".build/sources")
            map_path = debug / (module + ".build/output-file-map.json")
            module_path = debug / "Modules" / (module + ".swiftmodule")
            require(command["fileList"] == str(file_list) and command["outputFileMapPath"] == str(map_path)
                    and command["moduleOutputPath"] == str(module_path), "Foreign build metadata")
            require(read_source(repo, file_list).decode("utf-8").splitlines() == sources, "Source list mismatch")
            mapping = decode_json(read_source(repo, map_path))
            require(set(mapping) - {""} == set(sources), "Output map source closure")
            for src, obj in zip(sources, objects):
                require(mapping[src].get("object") == obj, "Output map object mismatch")
            input_names = [row["name"] for row in command["inputs"] if row["kind"] == "file"]
            require({name for name in input_names if name.endswith(".swift")} == set(sources), "Input source mismatch")
            output_names = [row["name"] for row in command["outputs"] if row["kind"] == "file"]
            require([name for name in output_names if name.endswith(".o")] == objects
                    and str(module_path) in output_names, "Output object mismatch")
            for name in input_names + output_names:
                path = Path(name)
                checked_path(repo, path)
                require(name in sources or path.is_relative_to(scratch), "Unbound build input/output")
            for path in (file_list, map_path, *[Path(src) for src in sources]):
                bindings.append(file_pin(repo, path))
            for path in (*[Path(obj) for obj in objects], module_path):
                bindings.append(artifact_pin(repo, path))
            all_objects.extend(objects)
        require(len(all_objects) == len(set(all_objects)) == 8, "Object closure count")
        link_list = debug / (PRODUCT + ".product/Objects.LinkFileList")
        linked = read_source(repo, link_list).decode("utf-8").splitlines()
        require(len(linked) == 8 and len(set(linked)) == 8 and set(linked) == set(all_objects),
                "Link object closure")
        write = description["writeCommands"][str(link_list)]
        require(write["outputFilePath"] == str(link_list), "Link-list writer output")
        require(write["inputs"] == [{"kind": "virtual", "name": "<link-file-list>"}]
                + [{"kind": "file", "name": obj} for obj in linked], "Link-list writer inputs")
        yaml_path = scratch / "debug.yaml"
        yaml_text = read_source(repo, yaml_path).decode("utf-8", "strict")
        block = link_block(yaml_text, "C." + PRODUCT + "-" + triple + "-debug.test")
        require(block["inputs"] == linked + [str(link_list)] and block["outputs"] == [str(binary)]
                and block["description"] == "Linking " + str(binary), "Actual test-link core")
        args = block["args"]
        require(args and Path(args[0]).is_absolute() and Path(args[0]).name == "swiftc", "Link driver")
        require(option(args, "-o") == str(binary)
                and option(args, "-target") == architecture + "-apple-macosx14.0"
                and args.count("@" + str(link_list)) == 1, "Link output/target/list")
        require(any(args[n:n + 2] == ["-Xlinker", "-bundle"] for n in range(len(args) - 1)),
                "Link is not a test bundle")
        require(not any(x.startswith("@") and x not in ("@" + str(link_list), "@loader_path/../../../")
                        for x in args) and not any(x.endswith(".o") for x in args),
                "Additional response-file/object input")
        bindings += [file_pin(repo, link_list), file_pin(repo, yaml_path)]
    except (KeyError, TypeError, IndexError, UnicodeError) as error:
        raise ValueError("Malformed build binding") from error
    files, members, pending = [], [], [bundle]
    while pending:
        path = pending.pop()
        checked_path(repo, path)
        info = path.lstat()
        members.append({"path": str(path), "mode": stat.S_IMODE(info.st_mode),
                        "kind": "directory" if stat.S_ISDIR(info.st_mode) else "file"})
        require(len(members) <= 256, "Artifact membership bound")
        if stat.S_ISDIR(info.st_mode):
            with os.scandir(path) as entries:
                for child in entries:
                    pending.append(Path(child.path))
                    require(len(members) + len(pending) <= 256, "Artifact membership bound")
        else:
            files.append(artifact_pin(repo, path))
    require(str(binary) in {row["path"] for row in files}, "Missing main executable")
    # Fixed-size header read only; artifact payload was already hashed streaming.
    main_file = next(row for row in files if row["path"] == str(binary))
    try:
        fd = os.open(checked_path(repo, binary), os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
        try:
            before = os.fstat(fd)
            require(stat.S_ISREG(before.st_mode) and 32 <= before.st_size <= ARTIFACT_LIMIT
                    and before.st_size == main_file["bytes"]
                    and stat.S_IMODE(before.st_mode) == main_file["mode"] == 0o755,
                    "Mach header descriptor type/extent/mode")
            header = os.read(fd, 32)
            after = os.fstat(fd)
            require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns,
                     before.st_mode) == (after.st_dev, after.st_ino, after.st_size,
                                        after.st_mtime_ns, after.st_mode), "Mach header changed during read")
        finally:
            os.close(fd)
    except OSError as error:
        raise ValueError("Unreadable Mach header") from error
    require(len(header) == 32, "Short Mach header")
    fields = struct.unpack("<8I", header)
    require(fields[0] == 0xFEEDFACF and fields[1] == {"arm64": 0x0100000C, "x86_64": 0x01000007}[architecture]
            and fields[3] == 8, "Wrong Mach bundle/architecture")
    require(stat.S_IMODE(binary.stat().st_mode) == 0o755, "Main executable mode")
    result = {"files": sorted(files, key=lambda row: row["path"]),
              "members": sorted(members, key=lambda row: row["path"]),
              "bindings": sorted(bindings, key=lambda row: row["path"]), "main": str(binary)}
    if "artifactBaseline" in manifest:
        require(result == manifest["artifactBaseline"], "Artifact/binding changed since retained baseline")
    return result


def execute(repo, run, manifest, launch=None):
    """Normal subprocess.run reaps its own WD child, never the Swift group."""
    repo, run = Path(repo), Path(run)
    result = {"exit": 125, "classification": "infrastructure", "rawWatchdogExit": None,
              "parentSignal": None, "errors": []}
    saved = []
    def note_signal(number, _frame):
        if result["parentSignal"] is None:
            result["parentSignal"] = int(number)
    try:
        verify_inputs(repo, run, manifest)
        scratch = layout(repo, run)
        require(not os.path.lexists(scratch) and not os.path.lexists(run / "owned"), "Reused stage output/scratch")
        command = stage_command(repo, run)
        result["command"] = command
        for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            previous = signal.getsignal(number)
            signal.signal(number, note_signal)
            saved.append((number, previous))
        if launch is None:
            launch = subprocess.run
        completed = launch(command, stdin=subprocess.DEVNULL, check=False, shell=False, close_fds=True)
        result["rawWatchdogExit"] = completed.returncode
        result["receipt"] = validate_receipt(run / "owned", command[8:], completed.returncode)
        stdout = read_source(repo, run / "owned/stdout.log")
        stderr = read_source(repo, run / "owned/stderr.log")
        result["captures"] = [byte_pin(run / "owned/stdout.log", stdout), byte_pin(run / "owned/stderr.log", stderr)]
        tests = validate_tests(stdout, stderr)
        expected = 1 if tests["classification"] == "testFailure" else 0
        require(completed.returncode == expected, "Raw exit/test classification disagreement")
        result["tests"] = tests
        result["artifacts"] = bind_artifacts(run, scratch, manifest)
        manifest_with_baseline = dict(manifest, artifactBaseline=result["artifacts"])
        bind_artifacts(run, scratch, manifest_with_baseline)
        verify_inputs(repo, run, manifest)
        result["exit"], result["classification"] = expected, tests["classification"]
    except (OSError, ValueError, KeyError, TypeError) as error:
        # These are all infrastructure, never relabeled missing API or test RED.
        result["errors"].append(type(error).__name__ + ": " + str(error))
    finally:
        for number, previous in reversed(saved):
            try:
                signal.signal(number, previous)
            except (OSError, ValueError) as error:
                result["errors"].append("Signal restoration: " + str(error))
        try:
            verify_inputs(repo, run, manifest)
        except (OSError, ValueError, KeyError, TypeError) as error:
            result["errors"].append("Postflight: " + str(error))
        if result["errors"] or result["parentSignal"] is not None:
            result["exit"], result["classification"] = 125, "infrastructure"
        try:
            atomic_record(run, "observation.json", result)
        except (OSError, ValueError) as error:
            result["exit"], result["classification"] = 125, "infrastructure"
            result["errors"].append("Observation persistence: " + str(error))
    return result


def main(argv=None):
    parse_args(sys.argv[1:] if argv is None else argv)
    run = None
    try:
        entry = Path(__file__).absolute()
        repo = entry.parents[2]
        require(entry == repo / "Tests/SearchAdmissionFileDarwinIntegration/run_harness.py", "Wrong entry layout")
        checked_path(repo, entry)
        namespace = repo / ".local/search-admission-file-darwin"
        checked_path(repo, namespace)
        (repo / ".local").mkdir(mode=0o700, exist_ok=True)
        if not os.path.lexists(namespace):
            namespace.mkdir(mode=0o700)
        directory_fact(repo, namespace)
        run = namespace / ("run." + str(uuid.uuid4()).upper())
        run.mkdir(mode=0o700)
        (run / "Fixtures").mkdir(mode=0o700)
        manifest = capture_inputs(repo, run)
        atomic_record(run, "environment.json", {"python": sys.executable, "system": platform.system(),
                      "release": platform.release(), "architecture": platform.machine(),
                      "target": "macOS14", "language": "Swift5", "source": "current public checkout"})
        result = execute(repo, run, manifest)
        print("File-adapter verification " + result["classification"] + "; retained evidence: " + str(run))
        return result["exit"]
    except (OSError, ValueError, KeyError, TypeError) as error:
        if run is not None:
            try:
                atomic_record(run, "setup-failure.json", {"exit": 125, "classification": "infrastructure",
                              "error": type(error).__name__ + ": " + str(error)})
            except (OSError, ValueError):
                pass
        print("File-adapter verification infrastructure refusal: " + str(error), file=sys.stderr)
        return 125


if __name__ == "__main__":
    raise SystemExit(main())
