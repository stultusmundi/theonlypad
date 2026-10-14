# SPDX-License-Identifier: MIT
"""Freeze fixed public NativeApplicationSearches ten-case component.
No caller-selected paths, filters, access tails or prebuilt artifacts. The child
is owned directly by the exact accepted watchdog; never nest this coordinator.
"""
import errno
import hashlib
import importlib.util
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
ARTIFACT_LIMIT = 512 * SOURCE_LIMIT
NAMESPACE = "native-application-searches-integration"
LOCATION = "Tests/NativeApplicationSearchesIntegration"
ENTRY_PATH = "scripts/test-native-application-searches.sh"
WRAPPER_SHA = "0fa0d91e2c57c03a4f74b6cd605676e274c1a4d69cd55edd9da2589c0bad74c0"
WATCHDOG_SHA = "d5bd867e4a65b4ee053209fe0a5822867b8d0878fd6d059f474c9b28a0f6286d"
OVERRIDES = ("SWIFT_EXEC", "DEVELOPER_DIR", "TOOLCHAINS", "PYTHONOPTIMIZE", "PYTHONPATH",
             "PYTHONHOME", "DYLD_INSERT_LIBRARIES", "CLANG_MODULE_CACHE_PATH", "SWIFTPM_MODULECACHE_OVERRIDE")
COMPONENTS = {
    "NativeApplicationSearchesComponent": ("ApplicationSearchOwner.swift", "EditorDocumentSearchSource.swift", "DocumentSearchSession.swift", "NativeApplicationSearches.swift"),
}
TEST_TARGETS = {
    "NativeApplicationSearchesComponentTests": ("NativeApplicationSearchesComponent", "NativeApplicationSearchesTests", "NativeApplicationSearchesTests.swift"),
}
STAGES = (("bridge10", "NativeApplicationSearchesTests"),)
ROSTERS = {'NativeApplicationSearchesTests': ('testLazyFindOwnerIsSharedAcrossTwoActualWindowTickets', 'testFactoryReservationRefusesReentryAndRetriesOnlyThrownPreCreation', 'testQuitWithoutCreatedOwnerNeverInvokesFactory', 'testPreparationConsumesRealRequestResultAndApprovalBeforeCallbacks', 'testVetoResumesOnlyExactPreparationWithoutRestoringOldRights', 'testManagedPreparationReturnPrecedesAdmissionAndVetoLeavesExactPreparedState', 'testHeldTerminalObservationCannotReturnOrCancelActualOwnerJoinEarly', 'testLaterExplicitQuitReusesOriginalJoinAndCanonicalParentWithFreshNativePreparation', 'testCallbackAndStaleRefusalsDoNotAdmitOrReopen', 'testFixedNestedSettlementRequiresEveryRealFieldAndProductionResident')}
MANIFEST = b'// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(\n  name: "NativeApplicationSearchesAcceptance",\n  platforms: [.macOS(.v14)],\n  targets: [\n    .target(name: "PadCore"),\n    .target(name: "SearchExecution", dependencies: ["PadCore"]),\n    .target(name: "NativeApplicationSearchesComponent", dependencies: ["PadCore", "SearchExecution"]),\n    .testTarget(name: "NativeApplicationSearchesComponentTests", dependencies: ["NativeApplicationSearchesComponent", "PadCore", "SearchExecution"])\n  ],\n  swiftLanguageModes: [.v5]\n)\n'

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

def environment():
    require(sys.flags.optimize == 0, "Python optimization is unsupported")
    require(all(name not in os.environ for name in OVERRIDES), "Tool/cache environment override")
    require(shutil.which("swift") == "/usr/bin/swift", "Swift selection must be /usr/bin/swift")
    # The selected /usr/bin/python3 Xcode shim may supply SDKROOT. Preserve and
    # record it as an observation; artifact review must verify the actual SDK.
    return {"python": sys.executable, "pythonOptimize": sys.flags.optimize,
            "swift": "/usr/bin/swift", "SDKROOT": os.environ.get("SDKROOT"),
            "absentOverrides": list(OVERRIDES)}

def receipt_success(output,command,expected_code=0):
    try:
        value=json.loads((output/'status.json').read_text())
        required={'command','pid','processGroup','exitObserved','registrationError','groupSignalAttempted',
            'groupSignalError','groupCleanup','groupQuery','waitCompleted','returnCode','waitError',
            'timedOut','interruptedSignal','truncated','captureComplete','failure','exit','captured'}
        if not isinstance(value,dict) or not required.issubset(value): return False
        if type(expected_code) is not int or not 0<=expected_code<256: return False
        if not isinstance(command,list) or not command or any(type(word) is not str or '\0' in word for word in command): return False
        if any(value[key] is not True for key in ('waitCompleted','captureComplete','groupSignalAttempted')): return False
        if any(value[key] is not False for key in ('timedOut','truncated')): return False
        if any(value[key] is not None for key in ('failure','interruptedSignal','waitError')): return False
        if any(type(value[key]) is not int or value[key]!=expected_code for key in ('exit','returnCode')): return False
        if value['command']!=command: return False
        pid=value['pid']
        if type(pid) is not int or pid<=0 or type(value['processGroup']) is not int or value['processGroup']!=pid: return False
        observed,registration=value['exitObserved'],value['registrationError']
        if type(observed) is not bool: return False
        if registration is not None and (type(registration) is not int or registration!=errno.ESRCH): return False
        if not observed and registration!=errno.ESRCH: return False
        cleanup,error=value['groupCleanup'],value['groupSignalError']
        if cleanup=='signaled':
            if error is not None or value['groupQuery'] is not None: return False
        elif cleanup=='absent':
            if type(error) is not int or error!=errno.ESRCH or value['groupQuery'] is not None: return False
        elif cleanup=='exitedLeaderOnly':
            query=value['groupQuery'];fields={'processGroup','errorNumber','bufferBytes','returnedBytes','members'}
            if type(error) is not int or error!=errno.EPERM or not observed: return False
            if not isinstance(query,dict) or not fields.issubset(query) or query['errorNumber'] is not None: return False
            if any(type(query[key]) is not int or query[key]!=expected for key,expected in
                   [('processGroup',pid),('bufferBytes',1024),('returnedBytes',4)]): return False
            if not isinstance(query['members'],list) or len(query['members'])!=1: return False
            if type(query['members'][0]) is not int or query['members'][0]!=pid: return False
        else: return False
        if not isinstance(value['captured'],dict): return False
        for name in ('stdout','stderr'):
            counts=value['captured'].get(name)
            if not isinstance(counts,dict) or not {'stored','received','discarded'}.issubset(counts): return False
            if any(type(counts[key]) is not int for key in ('stored','received','discarded')): return False
            stored=counts['stored']
            if (not 0<=stored<=1_048_576 or counts['received']!=stored
                or counts['discarded']!=0 or (output/(name+'.log')).stat().st_size!=stored): return False
        return True
    except (OSError,ValueError,TypeError,KeyError,AttributeError): return False


def read_json(path):
    return json.loads(read_file(path)[0])


def check_roster(data, name):
    text = data.decode("utf-8", "strict")
    require(re.findall(r"\bclass\s+(\w+)\s*:\s*XCTestCase\b", text) == [name], "Test class changed")
    require(tuple(re.findall(r"\bfunc\s+(test\w+)\s*\(", text)) == ROSTERS[name], "Fixed test roster changed")


def source_map(repo):
    rows, dirs = swift_inventory(repo)
    for module, names in COMPONENTS.items():
        rows += [(repo / "Sources/TheOnlyPad" / name, "Package/Sources/" + module + "/" + name, 0o400)
                 for name in names]
    for target, (_, _, filename) in TEST_TARGETS.items():
        rows.append((repo / LOCATION / filename, "Package/Tests/" + target + "/" + filename, 0o400))
    rows += [(repo / "scripts/swift.sh", "Toolchain/scripts/swift.sh", 0o755),
             (repo / "scripts/run-owned-search-tests.py", "Runner/scripts/run-owned-search-tests.py", 0o400),
             (repo / LOCATION / "run_native_application_searches.py", "Runner/run_native_application_searches.py", 0o400)]
    names = [b.casefold() for _, b, _ in rows]
    require(len(names) == len(set(names)), "Destination collision")
    return rows, dirs





def contract_preflight(repo):
    rows, dirs = source_map(repo)
    read_file(repo / ENTRY_PATH)
    require(pin(repo / "scripts/swift.sh")["sha256"] == WRAPPER_SHA
            and pin(repo / "scripts/run-owned-search-tests.py")["sha256"] == WATCHDOG_SHA, "Unreviewed execution driver")
    for target, (_, name, filename) in TEST_TARGETS.items():
        check_roster(read_file(repo / LOCATION / filename)[0], name)
    return rows, dirs


def provenance_map(repo):
    return [repo / "Package.swift", repo / ENTRY_PATH]





def child_command(run, scratch, index):
    require(type(index) is int and 0 <= index < len(STAGES), "Unknown fixed stage")
    label, name = STAGES[index]
    command = ["/usr/bin/env", "THEONLYPAD_STATE_DIRECTORY=" + str(run / "State" / label),
               str(run / "Toolchain/scripts/swift.sh"), "test", "--package-path", str(run / "Package"),
               "--scratch-path", str(scratch), "-Xswiftc", "-warnings-as-errors"]
    return command + ["--filter", name]


def tree_members(root):
    result, pending = [], [root]
    while pending:
        p = pending.pop()
        info = checked_path(p).lstat()
        if stat.S_ISDIR(info.st_mode):
            result.append({"kind": "directory", **directory(p, True)})
            pending.extend(sorted(p.iterdir()))
        else:
            require(stat.S_ISREG(info.st_mode), "Unexpected frozen member")
            result.append({"kind": "file", **pin(p), **identity(p)})
        require(len(result) + len(pending) <= MEMBER_LIMIT, "Membership bound")
    return sorted(result, key=lambda r: r["path"])


def freeze(repo, run, scratch):
    rows, source_dirs = contract_preflight(repo)
    paths = {"Package", "Runner", "Runner/scripts", "Evidence", "State", "Stages",
             "Toolchain", "Toolchain/scripts", "Toolchain/.cache", "Toolchain/.cache/clang", "Toolchain/.cache/swift"}
    for _, dest, _ in rows:
        parent = Path(dest).parent
        while parent != Path("."):
            paths.add(parent.as_posix()); parent = parent.parent
    for label, _ in STAGES:
        paths.add("State/" + label)
    for name in sorted(paths, key=lambda n: (len(Path(n).parts), n)):
        make_directory(run / name)
    record = {"schema": "native-application-searches-integration.v1", "repo": str(repo), "run": str(run),
              "scratch": str(scratch), "environment": environment(), "sources": [], "provenance": [],
              "sourceDirectories": source_dirs, "roots": [directory(run, True), directory(run.parent, True), directory(scratch.parent, True)],
              "stages": [{"name": name, "class": cls, "command": child_command(run, scratch, i)} for i, (name, cls) in enumerate(STAGES)]}
    total = 0
    for origin, dest, mode in rows:
        data, _ = read_file(origin)
        original = pin(origin); original_identity = identity(origin)
        require(hashlib.sha256(data).hexdigest() == original["sha256"], "Copy read changed")
        total += len(data)
        require(total <= SOURCE_TOTAL_LIMIT, "Combined source bound")
        write_new(run / dest, data, mode)
        record["sources"].append({"destination": dest, "original": original, "originalIdentity": original_identity,
                                  "frozen": pin(run / dest), "frozenIdentity": identity(run / dest)})
    provenance = provenance_map(repo)
    for i, origin in enumerate(provenance):
        data, _ = read_file(origin); target = run / "Evidence" / (str(i) + "-" + origin.name)
        write_new(target, data)
        record["provenance"].append({"original": pin(origin), "originalIdentity": identity(origin),
                                     "frozen": pin(target), "frozenIdentity": identity(target)})
    write_new(run / "Package/Package.swift", MANIFEST)
    record["generated"] = [pin(run / "Package/Package.swift")]
    record["frozenMembership"] = {name: tree_members(run / name) for name in ("Package", "Runner", "Evidence", "Toolchain/scripts")}
    record["toolchainRoots"] = [directory(run / name, True) for name in
                                ("Toolchain", "Toolchain/.cache", "Toolchain/.cache/clang", "Toolchain/.cache/swift")]
    record["stateRoots"] = [directory(run / "State", True)] + [directory(run / "State" / name, True) for name, _ in STAGES]
    write_new(run / "inputs.json", json_bytes(record))
    return record


def verify_toolchain(run, record):
    """Mutable compiler caches cannot enlarge or replace the frozen script boundary."""
    root = run / "Toolchain"
    for row in record["toolchainRoots"]:
        require(directory(Path(row["path"]), True) == row, "Toolchain/cache root identity changed")
    require({p.name for p in root.iterdir()} == {"scripts", ".cache"}, "Unexpected Toolchain entry")
    cache = root / ".cache"
    require({p.name for p in cache.iterdir()} == {"clang", "swift"}, "Unexpected cache root")
    require(tree_members(root / "scripts") == record["frozenMembership"]["Toolchain/scripts"], "Toolchain scripts changed")
    pending, visited = [cache], 0
    while pending:
        path = checked_path(pending.pop()); info = path.lstat(); visited += 1
        require(visited + len(pending) <= MEMBER_LIMIT, "Compiler cache traversal bound")
        require(info.st_uid == os.geteuid(), "Compiler cache owner changed")
        if stat.S_ISDIR(info.st_mode):
            pending.extend(path.iterdir())
        else:
            require(stat.S_ISREG(info.st_mode) and not info.st_mode & 0o111, "Unexpected compiler cache member")


def verify_frozen(repo, run, scratch, record):
    require(read_file(run / "inputs.json")[0] == json_bytes(record)
            and pin(run / "inputs.json")["mode"] == 0o400
            and identity(run / "inputs.json")["owner"] == os.geteuid(), "Input record changed")
    require(record["repo"] == str(repo) and record["run"] == str(run) and record["scratch"] == str(scratch), "Root binding changed")
    for row in record["roots"] + record["stateRoots"]:
        require(directory(Path(row["path"]), True) == row, "Owned directory identity changed")
    verify_toolchain(run, record)
    rows, dirs = contract_preflight(repo)
    require(dirs == record["sourceDirectories"], "Source directory drift")
    require([(str(p), dest, mode) for p, dest, mode in rows] == [(x["original"]["path"], x["destination"], x["frozen"]["mode"]) for x in record["sources"]], "Source map drift")
    require([row["original"]["path"] for row in record["provenance"]]
            == [str(path) for path in provenance_map(repo)], "Provenance map drift")
    for row in record["sources"] + record["provenance"]:
        for side in ("original", "frozen"):
            p = Path(row[side]["path"])
            require(pin(p) == row[side] and identity(p) == row[side + "Identity"], "Source/provenance drift")
        require(row["original"]["sha256"] == row["frozen"]["sha256"] and row["original"]["bytes"] == row["frozen"]["bytes"], "Copy differs")
        require((row["originalIdentity"]["device"], row["originalIdentity"]["inode"]) != (row["frozenIdentity"]["device"], row["frozenIdentity"]["inode"]), "Source copy aliases")
    require(record["generated"] == [pin(run / "Package/Package.swift")] and read_file(run / "Package/Package.swift")[0] == MANIFEST, "Package drift")
    for name, members in record["frozenMembership"].items():
        require(tree_members(run / name) == members, "Frozen tree drift")
    require(record["stages"] == [{"name": name, "class": cls, "command": child_command(run, scratch, i)} for i, (name, cls) in enumerate(STAGES)], "Fixed stage drift")
    require(environment() == record["environment"], "Environment drift")


def artifact_pin(build, path):
    path = checked_path(Path(path))
    require(path.is_relative_to(build), "Artifact outside owned build")
    before = path.lstat()
    require(stat.S_ISREG(before.st_mode) and before.st_size <= ARTIFACT_LIMIT, "Artifact kind/size")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
    try:
        opened = os.fstat(fd); h = hashlib.sha256(); count = 0
        while True:
            data = os.read(fd, 65536)
            if not data: break
            count += len(data); require(count <= ARTIFACT_LIMIT, "Artifact grew")
            h.update(data)
        after = os.fstat(fd)
        key = lambda x: (x.st_dev, x.st_ino, x.st_size, x.st_mode, x.st_mtime_ns)
        require(key(before) == key(opened) == key(after) and count == before.st_size, "Artifact changed")
        return {"path": str(path), "bytes": count, "sha256": h.hexdigest()}
    finally:
        os.close(fd)


def parse_cases(text, expected_class):
    started = re.findall(r"Test Case '-\[(\w+)\.(\w+) (\w+)\]' started\.", text)
    completed = re.findall(r"Test Case '-\[(\w+)\.(\w+) (\w+)\]' (passed|failed|skipped)", text)
    expected = {(expected_class, name) for name in ROSTERS[expected_class]}
    require(len(started) == len(completed) == len(expected), "Incomplete case census")
    require(len(set(started)) == len(started) and {(c, m) for _, c, m in started} == expected, "Started case selection changed")
    require([(a, b, c) for a, b, c, _ in completed] == started, "Case completion/order changed")
    require(all(state != "skipped" for _, _, _, state in completed), "Skipped case")
    failures = [line for line in text.splitlines() if ": error:" in line]
    return {"cases": completed, "passed": sum(x[3] == "passed" for x in completed),
            "failed": sum(x[3] == "failed" for x in completed), "errorRecordHeads": failures}


def audit_build(run, scratch, record):
    build = checked_path(scratch / "arm64-apple-macosx/debug")
    desc_path = build / "description.json"; desc = read_json(desc_path)
    groups = desc.get("swiftCommands"); require(isinstance(groups, dict), "No compiler descriptions")
    expected = {}
    for row in record["sources"]:
        dest = Path(row["destination"])
        if dest.suffix == ".swift" and dest.parts[1] in ("Sources", "Tests"):
            expected.setdefault(dest.parts[2], []).append(row["frozen"]["path"])
    require(set(expected) == {"PadCore", "SearchExecution", *COMPONENTS, *TEST_TARGETS}, "Unexpected authored modules")
    require(len(groups) == len(expected) + 1, "Unexpected compiler module count")
    seen, objects, artifacts, facts, package_names = set(), [], {str(desc_path)}, [], set()
    for group in groups.values():
        name = group.get("moduleName"); require(isinstance(name, str) and name not in seen, "Duplicate module")
        seen.add(name); sources = group.get("sources"); objs = group.get("objects"); args = group.get("otherArguments")
        require(isinstance(sources, list) and isinstance(objs, list) and isinstance(args, list), "Compiler lists missing")
        require(len(sources) == len(set(sources)) == len(objs) == len(set(objs)), "Ambiguous source/object list")
        require("-warnings-as-errors" in args and "arm64-apple-macosx14.0" in args, "Compiler mode/target differs")
        require(args.count("-package-name") == 1, "Package identity missing")
        package_index = args.index("-package-name") + 1
        require(package_index < len(args) and isinstance(args[package_index], str)
                and re.fullmatch(r"[A-Za-z0-9_]{1,128}", args[package_index]) is not None, "Invalid package identity")
        package_names.add(args[package_index])
        require(args.count("-swift-version") <= 1, "Duplicate Swift language mode")
        mode_index = args.index("-swift-version") + 1 if "-swift-version" in args else None
        require(mode_index is None or mode_index < len(args), "Missing Swift mode value")
        mode = args[mode_index] if mode_index is not None else None
        if name in expected:
            require(sorted(sources) == sorted(expected[name]) and mode == "5", "Authored source/mode mismatch")
        else:
            require(name == "NativeApplicationSearchesAcceptancePackageTests" and len(sources) == 1
                    and Path(sources[0]) == build / (name + ".derived/runner.swift"), "Unexpected generated source")
            artifacts.add(sources[0])
        files = Path(group["fileList"]); output_map = Path(group["outputFileMapPath"])
        artifact_pin(build, files); artifact_pin(build, output_map)
        require(read_file(files)[0].decode().splitlines() == sources, "Compiler source filelist differs")
        mapping = read_json(output_map)
        require({mapping[s]["object"] for s in sources} == set(objs), "Output map/object mismatch")
        module = str(build / "Modules" / (name + ".swiftmodule"))
        require(group.get("moduleOutputPath") == module, "Module output mismatch")
        modules = [p for p in (build / "Modules").iterdir() if p.name.startswith(name + ".")]
        require(Path(module) in modules and len(modules) <= 16, "Missing/broad module artifacts")
        artifacts.update(map(str, modules)); artifacts.update(objs); artifacts.update((str(files), str(output_map)))
        objects.extend(objs); facts.append({"module": name, "sources": len(sources), "objects": len(objs), "swiftMode": mode})
    require(set(expected) <= seen and len(package_names) == 1, "Module/package identities differ")
    require(len(objects) == len(set(objects)), "Duplicate objects")
    links = list(build.glob("*.product/Objects.LinkFileList")); require(len(links) == 1, "Link roster count")
    linked = read_file(links[0])[0].decode().splitlines()
    require(len(linked) == len(set(linked)) and set(linked) == set(objects), "Link union differs")
    artifacts.add(str(links[0]))
    products = desc.get("builtTestProducts"); require(isinstance(products, list) and len(products) == 1, "Test product count")
    bundles = list(build.glob("*.xctest")); require(len(bundles) == 1, "Test bundle count")
    product_name = "NativeApplicationSearchesAcceptancePackageTests"
    executable = bundles[0] / "Contents/MacOS" / product_name
    require(products == [{"binaryPath": str(executable), "packagePath": str(run / "Package"),
                          "productName": product_name}], "Test product identity differs")
    artifact_pin(build, executable)
    require(executable.stat().st_mode & 0o111, "Test product is not executable")
    leaves = []
    for parent, dirs, files in os.walk(bundles[0], followlinks=False):
        checked_path(Path(parent))
        for name in dirs + files: checked_path(Path(parent) / name)
        leaves += [Path(parent) / name for name in files]
        require(len(leaves) <= 32, "Bundle leaf bound")
    require(len(leaves) == 4, "Expected exact four bundle leaves")
    artifacts.update(map(str, leaves)); require(len(artifacts) <= MEMBER_LIMIT, "Artifact count bound")
    bindings = [artifact_pin(build, Path(p)) for p in sorted(artifacts)]
    return {"build": str(build), "modules": facts, "objects": len(objects), "bundleLeaves": len(leaves),
            "packageName": next(iter(package_names)), "artifacts": bindings}


def recheck_artifacts(proof):
    build = Path(proof["build"])
    require(all(artifact_pin(build, Path(row["path"])) == row for row in proof["artifacts"]), "Compiled artifact drift")


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    require(spec is not None and spec.loader is not None, "Cannot load frozen coordinator")
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


def execute(repo, run, scratch, record):
    result = {"scope": "Fixed Foundation bridge10; no editor/helper/AppDelegate activation", "stages": [], "exit": 125}
    proof = None
    try:
        verify_frozen(repo, run, scratch, record)
        require(pin(run / "Runner/scripts/run-owned-search-tests.py")["sha256"] == WATCHDOG_SHA, "Watchdog drift")
        watchdog = load_module("owned_native_application_searches_watchdog", run / "Runner/scripts/run-owned-search-tests.py")
        overall = 0
        for index, (label, cls) in enumerate(STAGES):
            verify_frozen(repo, run, scratch, record)
            if proof is not None:
                require(read_file(run / "artifact-proof.json")[0] == json_bytes(proof), "Artifact proof changed")
                recheck_artifacts(proof)
            command = child_command(run, scratch, index); output = run / "Stages" / label
            require(not os.path.lexists(output), "Stage output already exists")
            code = watchdog.main(["--timeout", "180", "--output", str(output), "--", *command])
            require(type(code) is int and 0 <= code < 256 and receipt_success(output, command, code), "Incomplete direct watchdog receipt")
            stage = {"name": label, "naturalExit": code, "receipt": pin(output / "status.json"),
                     "stdout": pin(output / "stdout.log"), "stderr": pin(output / "stderr.log")}
            result["stages"].append(stage)
            verify_frozen(repo, run, scratch, record)
            if proof is None:
                proof = audit_build(run, scratch, record)
                write_new(run / "artifact-proof.json", json_bytes(proof))
            else:
                recheck_artifacts(proof)
            require(read_file(run / "artifact-proof.json")[0] == json_bytes(proof), "Artifact proof changed")
            stage["artifactProof"] = pin(run / "artifact-proof.json")
            text = read_file(output / "stdout.log")[0].decode("utf-8", "strict") + read_file(output / "stderr.log")[0].decode("utf-8", "strict")
            stage["outcome"] = parse_cases(text, cls)
            require(code in (0, 1), "Unexpected test process return")
            if code == 0:
                require(stage["outcome"]["failed"] == 0 and not stage["outcome"]["errorRecordHeads"], "Contradictory success")
                require(re.search(r"Executed " + str(len(ROSTERS[cls])) + r" tests?, with 0 failures \(0 unexpected\)", text) is not None, "Missing exact success summary")
            else:
                require(stage["outcome"]["failed"] > 0, "Nonzero without completed failing test")
                overall = 1
            require("warning:" not in text, "Compiler warning")
        result["exit"] = overall
    except (OSError, ValueError, TypeError, KeyError, AttributeError, ImportError) as error:
        result["infrastructureFailure"] = type(error).__name__ + ": " + str(error)
    write_new(run / "result.json", json_bytes(result))
    print(json.dumps(result), flush=True)
    return result["exit"]


def main(argv):
    require(not argv, "No arguments, paths, filters or prebuilt selections accepted")
    require(sys.platform == "darwin" and platform.machine() == "arm64", "Darwin ARM64 required")
    environment(); os.umask(0o077)
    script = checked_path(Path(os.path.abspath(__file__))); repo = script.parents[len(Path(LOCATION).parts)]
    require(script == repo / LOCATION / "run_native_application_searches.py", "Fixed public runner location mismatch")
    contract_preflight(repo)
    for parent in (repo / ".local", repo / ".build"): ensure_parent(parent)
    local = repo / ".local" / NAMESPACE; builds = repo / ".build" / NAMESPACE
    ensure_parent(local, True); ensure_parent(builds, True)
    name = "run." + str(uuid.uuid4()).upper(); run = local / name; scratch = builds / name
    require(not os.path.lexists(checked_path(scratch)), "Scratch already exists")
    make_directory(run)
    record = freeze(repo, run, scratch)
    verify_frozen(repo, run, scratch, record)
    require(not os.path.lexists(scratch) and not any((run / "Stages").iterdir()), "Nonfresh execution output")
    frozen = load_module("frozen_native_application_searches_coordinator", run / "Runner/run_native_application_searches.py")
    print("Native application searches evidence: " + str(run), flush=True)
    os.chdir(run / "Runner")
    return frozen.execute(repo, run, scratch, record)


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (OSError, ValueError, UnicodeError) as error:
        print("Native application searches refused: " + type(error).__name__, file=sys.stderr)
        raise SystemExit(125)
