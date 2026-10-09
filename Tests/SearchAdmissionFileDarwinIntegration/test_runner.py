# SPDX-License-Identifier: MIT
"""Pure contracts only: synthetic files/records, never a Swift or watchdog run.

Root must freeze this file as Tests/SearchAdmissionFileDarwinIntegration/test_runner.py.
The absent adjacent run_harness.py is genuine API RED, before any fixture creation.
Synthetic source/object/binary data below is never compiled, imported or executed.
"""
import contextlib
import copy
import errno
import hashlib
import json
import os
from pathlib import Path
import platform
import signal
import struct
import subprocess
import tempfile
import types
import unittest
from unittest import mock


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
PRODUCTION = (
    "SearchPreparedUTF8Decoder.swift",
    "SearchAdmissionFileInput.swift",
    "SearchAdmissionFileIO.swift",
    "SearchAdmissionFileReader.swift",
    "SearchAdmissionFileDarwinIO.swift",
)
NATIVE = ("SearchAdmissionFileDarwinTests.swift", "SearchAdmissionFileDarwinFixture.swift")
UUID_TEXT = "7F4AA520-D1DE-4E92-A7CE-1FD395E27D69"
PRODUCT = "PreparedFileDarwinComponentPackageTests"
MODULE = "SearchAdmissionFileDarwinIntegration.SearchAdmissionFileDarwinTests"
MANIFEST_BYTES = b'''// swift-tools-version: 6.0
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
MIXED_BYTES = b"\xef\xbb\xbf// PURE byte fixture \xf0\x9f\x98\x80\r\n// CR\r// no final LF"
BINARY_BYTES = struct.pack("<IiiIIIII", 0xFEEDFACF, 0x0100000C, 0, 8, 0, 0, 0, 0) + b"PURE-NOT-EXECUTABLE"
SIGNALS = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)


class MissingRunnerAPIError(RuntimeError):
    """Only absent adjacent module or absent selected callable API qualifies."""


def forbidden_process(*_args, **_kwargs):
    raise AssertionError("Pure suite forbids an actual process, signal, or reaper")


def write_owned(path, data, mode=0o644):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.write_bytes(data)
    path.chmod(mode)


def literal_output(failed=None):
    """Independent exact nine identities; no candidate-generated oracle."""
    lines = [
        "Test Suite 'Selected tests' started at 2026-10-09 00:00:00.000.",
        "Test Suite 'PreparedFileDarwinComponentPackageTests.xctest' started at 2026-10-09 00:00:00.000.",
        "Test Suite 'SearchAdmissionFileDarwinTests' started at 2026-10-09 00:00:00.000.",
    ]
    for name in METHODS:
        identity = "-[" + MODULE + " " + name + "]"
        lines.append("Test Case '" + identity + "' started.")
        if name == failed:
            lines.append("/synthetic/SearchAdmissionFileDarwinTests.swift:1: error: " + identity + " : XCTAssertEqual failed: (\"0\") is not equal to (\"1\") - PURE assertion fixture")
            lines.append("Test Case '" + identity + "' failed (0.001 seconds).")
        else:
            lines.append("Test Case '" + identity + "' passed (0.001 seconds).")
    state, count = ("failed", 1) if failed else ("passed", 0)
    for suite in ("SearchAdmissionFileDarwinTests", PRODUCT + ".xctest", "Selected tests"):
        lines.append("Test Suite '" + suite + "' " + state + " at 2026-10-09 00:00:00.010.")
        lines.append("\t Executed 9 tests, with " + str(count) + " failures (0 unexpected) in 0.010 (0.010) seconds")
    lines.extend(("◇ Test run started.", "↳ Testing Library Version: 1902", "↳ Target Platform: arm64e-apple-macos14.0", "✔ Test run with 0 tests in 0 suites passed after 0.001 seconds."))
    return ("\n".join(lines) + "\n").encode("utf-8")


class Archive:
    """Only this TemporaryDirectory's files are written/removed by the tests."""
    def __init__(self, owner, candidate_bytes):
        temporary = tempfile.TemporaryDirectory(prefix="native-file-runner-pure-")
        owner.addCleanup(temporary.cleanup)  # Before any subsequent setup/throw.
        self.base = Path(temporary.name)
        self.repo = self.base / "source archive with spaces $literal;"
        self.repo.mkdir(mode=0o700)
        self.origin_bytes = {}
        for index, name in enumerate(PRODUCTION):
            data = MIXED_BYTES if index == 0 else ("// PURE source data " + name + "\n").encode()
            self.add("Sources/SearchExecution/" + name, data)
        # Structural source-archive data only; no fake runner implementation/module.
        native_text = "import XCTest\nfinal class SearchAdmissionFileDarwinTests: XCTestCase {\n"
        native_text += "".join("  func " + name + "() {}\n" for name in METHODS) + "}\n"
        self.add("Tests/SearchAdmissionFileDarwinIntegration/" + NATIVE[0], native_text.encode())
        self.add("Tests/SearchAdmissionFileDarwinIntegration/" + NATIVE[1], b"// PURE support data; no native resources\n")
        self.add("scripts/swift.sh", b"# PURE frozen wrapper data; never executed\n", 0o755)
        self.add("scripts/run-owned-search-tests.py", b"# PURE watchdog coordinate data; never imported or executed\n")
        self.add("scripts/test-search-admission-file-darwin.sh", b"# PURE coordinator provenance data; never executed\n", 0o755)
        self.add("Tests/SearchAdmissionFileDarwinIntegration/run_harness.py", candidate_bytes)
        self.add("Package.swift", b"// PURE public-manifest provenance; never compiled\n")
        self.namespace = self.repo / ".local/search-admission-file-darwin"
        self.namespace.mkdir(parents=True, mode=0o700)
        self.namespace.chmod(0o700)
        self.run = self.namespace / ("run." + UUID_TEXT)
        self.run.mkdir(mode=0o700)
        self.fixtures = self.run / "Fixtures"
        self.fixtures.mkdir(mode=0o700)
        self.scratch = self.repo / ".build/search-admission-file-darwin" / self.run.name
        self.output = self.run / "owned"

    def add(self, relative, data, mode=0o644):
        write_owned(self.repo / relative, data, mode)
        self.origin_bytes[relative] = data

    def command(self):
        return ["/usr/bin/python3", "-B", str(self.run / "Runner/scripts/run-owned-search-tests.py"), "--timeout", "180", "--output", str(self.output), "--", "/usr/bin/env", "THEONLYPAD_FILE_DARWIN_FIXTURE_ROOT=" + str(self.fixtures), str(self.run / "Runner/scripts/swift.sh"), "test", "--package-path", str(self.run / "Package"), "--scratch-path", str(self.scratch), "--filter", "SearchAdmissionFileDarwinTests"]

    def capture_record(self, code=0, stdout=None, stderr=b"Build complete! (0.01s)\n"):
        stdout = literal_output() if stdout is None else stdout
        self.output.mkdir(mode=0o700, exist_ok=True)
        write_owned(self.output / "stdout.log", stdout)
        write_owned(self.output / "stderr.log", stderr)
        record = {"command": self.command()[8:], "pid": 73, "processGroup": 73, "exitObserved": True, "registrationError": None, "groupSignalAttempted": True, "groupSignalError": errno.EPERM, "groupCleanup": "exitedLeaderOnly", "groupQuery": {"processGroup": 73, "returnedBytes": 4, "bufferBytes": 1024, "members": [73], "errorNumber": None}, "waitCompleted": True, "returnCode": code, "waitError": None, "timedOut": False, "interruptedSignal": None, "truncated": False, "captureComplete": True, "captured": {"stdout": {"received": len(stdout), "stored": len(stdout), "discarded": 0}, "stderr": {"received": len(stderr), "stored": len(stderr), "discarded": 0}}, "failure": None, "exit": code, "seconds": 0.01}
        self.save_record(record)
        return record

    def save_record(self, record):
        write_owned(self.output / "status.json", (json.dumps(record, indent=2) + "\n").encode())

    def synthetic_build(self):
        """Minimal genuine files modelling inspected SwiftPM fields, not a build."""
        debug = self.scratch / "arm64-apple-macosx/debug"
        binary = debug / (PRODUCT + ".xctest/Contents/MacOS/" + PRODUCT)
        write_owned(binary, BINARY_BYTES, 0o755)
        generated = debug / (PRODUCT + ".derived/runner.swift")
        write_owned(generated, b"// PURE generated runner data\n")
        commands, objects = {}, []
        for target, folder, names in (("SearchExecution", "Sources/SearchExecution", PRODUCTION), ("SearchAdmissionFileDarwinIntegration", "Tests/SearchAdmissionFileDarwinIntegration", NATIVE), (PRODUCT, None, ("runner.swift",))):
            sources = [str(self.run / "Package" / folder / name) for name in names] if folder else [str(generated)]
            obj = [str(debug / (target + ".build") / (name + ".o")) for name in names]
            for name in obj:
                write_owned(Path(name), b"PURE object data, not linked\n")
            objects.extend(obj)
            file_list = debug / (target + ".build/sources")
            write_owned(file_list, ("\n".join(sources) + "\n").encode())
            arguments = ["-target", "arm64-apple-macosx14.0"]
            if target != PRODUCT:
                arguments += ["-swift-version", "5"]
            module_path = debug / "Modules" / (target + ".swiftmodule")
            write_owned(module_path, b"PURE module data, not imported\n")
            commands["C." + target + "-arm64-apple-macosx-debug.module"] = {"executable": "/synthetic/tool-coordinate/swiftc", "moduleName": target, "sources": sources, "inputs": [{"kind": "file", "name": name} for name in sources], "objects": obj, "outputs": [{"kind": "file", "name": name} for name in obj + [str(module_path)]], "fileList": str(file_list), "otherArguments": arguments, "outputFileMapPath": str(debug / (target + ".build/output-file-map.json")), "importPath": str(debug / "Modules"), "moduleOutputPath": str(module_path), "tempsPath": str(debug / (target + ".build")), "isLibrary": True, "prepareForIndexing": False, "wholeModuleOptimization": False}
            write_owned(Path(commands["C." + target + "-arm64-apple-macosx-debug.module"]["outputFileMapPath"]), json.dumps({src: {"object": out} for src, out in zip(sources, obj)}).encode())
        link_list = debug / (PRODUCT + ".product/Objects.LinkFileList")
        write_owned(link_list, ("\n".join(objects) + "\n").encode())
        self.description_path = debug / "description.json"
        self.description = {"builtTestProducts": [{"binaryPath": str(binary), "packagePath": str(self.run / "Package"), "productName": PRODUCT}], "swiftCommands": commands, "writeCommands": {str(link_list): {"inputs": [{"kind": "virtual", "name": "<link-file-list>"}] + [{"kind": "file", "name": name} for name in objects], "outputFilePath": str(link_list)}}}
        self.save_description()
        link_args = ["/synthetic/tool-coordinate/swiftc", "-o", str(binary), "-Xlinker", "-bundle", "-target", "arm64-apple-macosx14.0", "@" + str(link_list)]
        yaml = 'client:\n  name: basic\n  file-system: device-agnostic\ncommands:\n  "C.' + PRODUCT + '-arm64-apple-macosx-debug.test":\n    tool: shell\n    inputs: ' + json.dumps(objects + [str(link_list)]) + '\n    outputs: ' + json.dumps([str(binary)]) + '\n    description: "Linking ' + str(binary) + '"\n    args: ' + json.dumps(link_args) + '\n'
        write_owned(self.scratch / "debug.yaml", yaml.encode())
        self.binary, self.debug, self.link_list = binary, debug, link_list
        # Independent retained bytes/pin, made before any candidate binder call.
        self.binary_baseline = {"path": str(binary), "bytes": len(BINARY_BYTES), "mode": 0o755, "sha256": hashlib.sha256(BINARY_BYTES).hexdigest()}
        return binary

    def save_description(self):
        write_owned(self.description_path, (json.dumps(self.description, indent=2) + "\n").encode())


class FakeSignals:
    """No real signal policy is inspected/changed; functions are identity tokens."""
    def __init__(self, install_failure=None, restore_failure=None, installation_error=OSError):
        self.original = {number: (lambda *_args: None) for number in SIGNALS}
        self.current = dict(self.original)
        self.calls = []
        self.install_failure, self.restore_failure = install_failure, restore_failure
        self.installation_error = installation_error
        self.callback_errors = []

    def signal(self, number, handler):
        self.calls.append((number, handler))
        restoring = handler is self.original[number]
        if not restoring and number == self.install_failure:
            raise self.installation_error("PURE injected signal-installation refusal")
        if restoring and number == self.restore_failure:
            raise OSError("PURE injected signal-operation refusal")
        previous = self.current[number]
        self.current[number] = handler
        return previous

    def callback(self, number):
        try:
            self.current[number](number, None)
        except BaseException as error:
            # Do not let a bad candidate KeyboardInterrupt abort the pure suite.
            self.callback_errors.append(type(error).__name__)


class FakeLaunch:
    """Returns data only; no Popen object/PID/wait/kill/terminate capability."""
    def __init__(self, archive, signals, code=0, stdout=None, stderr=b"Build complete! (0.01s)\n", failure=None, mutate_receipt=None, stop_signals=(), build_artifacts=True):
        self.archive, self.signals = archive, signals
        self.code, self.stdout, self.stderr = code, stdout, stderr
        self.failure, self.mutate_receipt = failure, mutate_receipt
        self.stop_signals, self.calls = stop_signals, []
        self.build_artifacts = build_artifacts

    def __call__(self, command, **kwargs):
        self.calls.append((list(command), dict(kwargs)))
        if self.failure:
            raise OSError("PURE launch refusal before child ownership")
        for number in self.stop_signals:
            self.signals.callback(number)
        record = self.archive.capture_record(self.code, self.stdout, self.stderr)
        if self.mutate_receipt:
            self.mutate_receipt(record)
            self.archive.save_record(record)
        if self.build_artifacts:
            self.archive.synthetic_build()
        return subprocess.CompletedProcess(command, self.code)


class NativeFileRunnerPureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = Path(__file__).absolute()
        if path.parent.name != "SearchAdmissionFileDarwinIntegration" or path.parent.parent.name != "Tests":
            raise RuntimeError("Root must freeze the pure suite in its reviewed public relative layout")
        cls.candidate_path = path.with_name("run_harness.py")
        if cls.candidate_path.is_symlink():
            raise RuntimeError("Unexpected candidate symlink; not missing-API RED")
        if not cls.candidate_path.exists():
            raise MissingRunnerAPIError("Missing adjacent public native-file runner module: run_harness.py")
        if not cls.candidate_path.is_file():
            raise RuntimeError("Unexpected candidate source type; not missing-API RED")
        cls.candidate_bytes = cls.candidate_path.read_bytes()
        stack = contextlib.ExitStack()
        cls.addClassCleanup(stack.close)
        # Import and every pure method fail loudly if an actual process is reached.
        for target, names in ((subprocess, ("Popen", "run", "call", "check_call", "check_output")), (os, ("system", "fork", "posix_spawn", "posix_spawnp", "kill", "killpg", "wait", "waitpid", "wait3", "wait4", "execv", "execve", "execvp", "execvpe", "execl", "execlp", "execle")), (signal, ("signal", "getsignal"))):
            for name in names:
                if hasattr(target, name):
                    stack.enter_context(mock.patch.object(target, name, forbidden_process))
        stack.enter_context(mock.patch.object(platform, "machine", return_value="arm64"))
        cls.runner = types.ModuleType("native_file_runner_pure_candidate")
        cls.runner.__file__ = str(cls.candidate_path)
        # No loader cache, candidate bytecode or watchdog import. Unknown import/
        # syntax failures propagate as infrastructure, never MissingRunnerAPIError.
        exec(compile(cls.candidate_bytes, str(cls.candidate_path), "exec"), cls.runner.__dict__)
        required = ("parse_args", "read_source", "capture_inputs", "verify_inputs", "stage_command", "validate_receipt", "validate_tests", "bind_artifacts", "execute", "main")
        missing = [name for name in required if not callable(getattr(cls.runner, name, None))]
        if missing:
            raise MissingRunnerAPIError("Missing selected native-file runner API: " + ", ".join(missing))

    def archive(self):
        return Archive(self, self.candidate_bytes)

    def captured(self):
        archive = self.archive()
        manifest = self.runner.capture_inputs(archive.repo, archive.run)
        return archive, manifest

    def run_fake(self, archive, manifest, fake):
        with mock.patch.object(signal, "signal", fake.signals.signal), mock.patch.object(signal, "getsignal", side_effect=lambda number: fake.signals.current[number]):
            result = self.runner.execute(archive.repo, archive.run, manifest, fake)
        self.assertIsInstance(result, dict)
        self.assertEqual(fake.signals.callback_errors, [])
        return result

    def assert_handlers_restored(self, signals):
        for number in SIGNALS:
            self.assertIs(signals.current[number], signals.original[number])

    def test_fixed_arguments_refuse_user_selection(self):
        for arguments in (["--filter", "Other"], ["--root", "/synthetic"], ["--build-only"]):
            with self.subTest(arguments=arguments), self.assertRaises(SystemExit) as refusal:
                self.runner.parse_args(arguments)
            self.assertEqual(refusal.exception.code, 2)
        self.runner.parse_args([])

    def test_main_invalid_arguments_refuse_before_layout_or_launch(self):
        for arguments in (["--filter", "Other"], ["--root", "/synthetic"], ["--build-only"]):
            with self.subTest(arguments=arguments), mock.patch.object(Path, "mkdir", forbidden_process), mock.patch.object(os, "mkdir", forbidden_process), mock.patch.object(self.runner, "capture_inputs", forbidden_process), mock.patch.object(self.runner, "execute", forbidden_process):
                try:
                    result = self.runner.main(arguments)
                except SystemExit as refusal:
                    result = refusal.code
                self.assertEqual(result, 2)

    def test_capture_preserves_literal_bytes_without_git_or_private_sources(self):
        archive, manifest = self.captured()
        self.assertFalse((archive.repo / ".git").exists())
        self.assertFalse((archive.repo / ".superpowers").exists())
        self.assertEqual((archive.run / "Package/Sources/SearchExecution/SearchPreparedUTF8Decoder.swift").read_bytes(), MIXED_BYTES)
        self.assertEqual((archive.run / "Package/Package.swift").read_bytes(), MANIFEST_BYTES)
        self.runner.verify_inputs(archive.repo, archive.run, manifest)

    def test_capture_rejects_same_length_moving_origin(self):
        archive = self.archive()
        target = archive.repo / "Sources/SearchExecution/SearchPreparedUTF8Decoder.swift"
        original_reader = self.runner.read_source
        changed = []

        def moving_read(repo, path):
            data = original_reader(repo, path)
            if Path(path) == target and not changed:
                changed.append(True)
                target.write_bytes(b"!" + data[1:])
            return data

        with mock.patch.object(self.runner, "read_source", moving_read):
            with self.assertRaises(ValueError):
                self.runner.capture_inputs(archive.repo, archive.run)
        self.assertEqual(changed, [True])
        self.assertNotEqual(target.read_bytes(), MIXED_BYTES)

    def test_extra_versioned_manifest_is_not_hidden_by_valid_selected_hashes(self):
        archive, manifest = self.captured()
        marker = archive.run / "Package/Package@swift-6.0.swift"
        write_owned(marker, b"// PURE additional compiler input\n", 0o400)
        with self.assertRaises(ValueError):
            self.runner.verify_inputs(archive.repo, archive.run, manifest)
        self.assertTrue(marker.exists())

    def test_frozen_mode_and_source_final_symlink_refuse(self):
        archive, manifest = self.captured()
        frozen = archive.run / "Package/Sources/SearchExecution/SearchAdmissionFileIO.swift"
        frozen.chmod(0o600)
        with self.assertRaises(ValueError):
            self.runner.verify_inputs(archive.repo, archive.run, manifest)
        other = self.archive()
        source = other.repo / "Sources/SearchExecution/SearchAdmissionFileIO.swift"
        outside = other.base / "owned-other-source"
        write_owned(outside, source.read_bytes())
        source.unlink()
        source.symlink_to(outside)
        with self.assertRaises(ValueError):
            self.runner.capture_inputs(other.repo, other.run)

    def test_intermediate_source_symlink_refuses(self):
        archive = self.archive()
        folder = archive.repo / "Sources/SearchExecution"
        moved = archive.base / "owned-moved-target"
        folder.rename(moved)
        folder.symlink_to(moved, target_is_directory=True)
        with self.assertRaises(ValueError):
            self.runner.capture_inputs(archive.repo, archive.run)

    def test_oversized_origin_refuses_bounded_capture(self):
        archive = self.archive()
        source = archive.repo / "Sources/SearchExecution/SearchAdmissionFileIO.swift"
        source.write_bytes(b"x" * (1024 * 1024 + 1))
        with self.assertRaises(ValueError):
            self.runner.capture_inputs(archive.repo, archive.run)

    def test_fixed_inner_environment_and_argv_preserve_spaces(self):
        archive, _manifest = self.captured()
        self.assertEqual(self.runner.stage_command(archive.repo, archive.run), archive.command())
        self.assertIn("source archive with spaces $literal;", archive.command()[9])
        self.assertEqual(archive.command()[8:10], ["/usr/bin/env", "THEONLYPAD_FILE_DARWIN_FIXTURE_ROOT=" + str(archive.fixtures)])

    def test_valid_structural_receipt_and_bool_integer_controls(self):
        archive = self.archive()
        baseline = archive.capture_record()
        self.runner.validate_receipt(archive.output, archive.command()[8:], 0)
        for key, value in (("pid", True), ("processGroup", True), ("returnCode", False), ("exit", False), ("waitCompleted", 1)):
            record = copy.deepcopy(baseline)
            record[key] = value
            archive.save_record(record)
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.runner.validate_receipt(archive.output, archive.command()[8:], 0)

    def test_eperm_requires_complete_exact_singleton_query(self):
        archive = self.archive()
        baseline = archive.capture_record()
        controls = [None]
        for key, value in (("members", [73, 74]), ("returnedBytes", 0), ("returnedBytes", True), ("bufferBytes", 4), ("processGroup", 74), ("errorNumber", errno.EPERM)):
            query = copy.deepcopy(baseline["groupQuery"])
            query[key] = value
            controls.append(query)
        for query in controls:
            record = copy.deepcopy(baseline)
            record["groupQuery"] = query
            archive.save_record(record)
            with self.subTest(query=query), self.assertRaises(ValueError):
                self.runner.validate_receipt(archive.output, archive.command()[8:], 0)

    def test_capture_loss_and_actual_length_mismatch_refuse(self):
        archive = self.archive()
        baseline = archive.capture_record()
        for change in ("discarded", "truncated", "actualLength"):
            record = copy.deepcopy(baseline)
            if change == "discarded":
                record["captured"]["stdout"]["discarded"] = 1
            elif change == "truncated":
                record["truncated"] = True
            else:
                (archive.output / "stdout.log").write_bytes(literal_output() + b"extra\n")
            archive.save_record(record)
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.runner.validate_receipt(archive.output, archive.command()[8:], 0)

    def test_oversized_complete_capture_refuses_limit(self):
        archive = self.archive()
        archive.capture_record(stdout=b"x" * (1024 * 1024 + 1))
        with self.assertRaises(ValueError):
            self.runner.validate_receipt(archive.output, archive.command()[8:], 0)

    def test_nine_summary_does_not_cover_duplicate_missing_or_extra_identity(self):
        self.runner.validate_tests(literal_output(), b"Build complete! (0.01s)\n")
        for text in (literal_output().replace(METHODS[0].encode(), METHODS[1].encode()), literal_output().replace(("Test Case '-[" + MODULE + " " + METHODS[0] + "]' passed (0.001 seconds).\n").encode(), b""), literal_output() + b"Test Case '-[OtherSuite testOther]' started.\nTest Case '-[OtherSuite testOther]' passed (0.001 seconds).\n"):
            with self.subTest(text=text[-120:]), self.assertRaises(ValueError):
                self.runner.validate_tests(text, b"Build complete! (0.01s)\n")

    def test_named_failure_is_structured_but_never_success(self):
        result = self.runner.validate_tests(literal_output(METHODS[1]), b"Build complete! (0.01s)\n")
        self.assertEqual(result["classification"], "testFailure")
        self.assertEqual(result["testCount"], 9)
        self.assertEqual(result["failedMethods"], [METHODS[1]])

    def test_invalid_utf8_or_skipped_terminal_refuses(self):
        skipped = literal_output().replace(("Test Case '-[" + MODULE + " " + METHODS[0] + "]' passed (0.001 seconds).").encode(), ("Test Case '-[" + MODULE + " " + METHODS[0] + "]' skipped (0.001 seconds).").encode())
        for text in (literal_output() + b"\xff", skipped):
            with self.subTest(text=text[-100:]), self.assertRaises(ValueError):
                self.runner.validate_tests(text, b"Build complete! (0.01s)\n")

    def test_anchored_compiler_diagnostics_and_unknown_output_refuse(self):
        for error in (b"warning: PURE compiler warning\n", b"/synthetic/source.swift:1:1: error: PURE compiler error\n", b"unknown tool diagnostic\n"):
            with self.subTest(error=error), self.assertRaises(ValueError):
                self.runner.validate_tests(literal_output(), error)

    def test_artifact_record_binds_actual_bytes_and_retained_independent_baseline(self):
        archive, manifest = self.captured()
        archive.synthetic_build()
        result = self.runner.bind_artifacts(archive.run, archive.scratch, manifest)
        self.assertIn(archive.binary_baseline, result["files"])
        retained = copy.deepcopy(manifest)
        retained["artifactBaseline"] = copy.deepcopy(result)
        # Retain actual source/object/link records before the sole payload write.
        binding_paths = [archive.description_path, archive.scratch / "debug.yaml", archive.link_list]
        for command in archive.description["swiftCommands"].values():
            binding_paths.extend(Path(path) for path in command["sources"] + command["objects"])
            binding_paths.extend((Path(command["fileList"]), Path(command["outputFileMapPath"])))
        bindings_before = {path: path.read_bytes() for path in binding_paths}
        # Offset33 is strictly beyond the full32-byte literal modeled header.
        archive.binary.write_bytes(BINARY_BYTES[:33] + b"!" + BINARY_BYTES[34:])
        changed = archive.binary.read_bytes()
        self.assertEqual(changed[:32], BINARY_BYTES[:32])
        self.assertEqual(len(changed), len(BINARY_BYTES))
        self.assertEqual(archive.binary, Path(archive.binary_baseline["path"]))
        self.assertEqual(archive.binary.stat().st_mode & 0o777, 0o755)
        self.assertNotEqual(hashlib.sha256(changed).hexdigest(), hashlib.sha256(BINARY_BYTES).hexdigest())
        self.assertEqual(retained["artifactBaseline"], result)
        self.assertIn(archive.binary_baseline, retained["artifactBaseline"]["files"])
        self.assertEqual({path: path.read_bytes() for path in binding_paths}, bindings_before)
        with self.assertRaises(ValueError):
            self.runner.bind_artifacts(archive.run, archive.scratch, retained)

    def test_artifact_description_escape_refuses_without_touching_other_file(self):
        archive, manifest = self.captured()
        archive.synthetic_build()
        external = archive.base / "owned-external-pure-binary"
        write_owned(external, BINARY_BYTES, 0o755)
        archive.description["builtTestProducts"][0]["binaryPath"] = str(external)
        archive.save_description()
        with self.assertRaises(ValueError):
            self.runner.bind_artifacts(archive.run, archive.scratch, manifest)
        self.assertEqual(external.read_bytes(), BINARY_BYTES)

    def test_artifact_source_object_and_link_bindings_are_independent(self):
        for fault in ("source", "object", "link"):
            archive, manifest = self.captured()
            archive.synthetic_build()
            if fault == "source":
                command = archive.description["swiftCommands"]["C.SearchExecution-arm64-apple-macosx-debug.module"]
                command["sources"][0] = str(archive.repo / "Sources/SearchExecution/SearchPreparedUTF8Decoder.swift")
                archive.save_description()
            elif fault == "object":
                command = archive.description["swiftCommands"]["C.SearchExecution-arm64-apple-macosx-debug.module"]
                wrong = archive.debug / "SearchExecution.build/owned-unbound-object.swift.o"
                write_owned(wrong, b"PURE existing unbound object data\n")
                command["objects"][0] = str(wrong)
                archive.save_description()
                self.assertTrue(wrong.is_file())
            else:
                wrong = archive.debug / "SearchExecution.build/owned-unbound-link.swift.o"
                write_owned(wrong, b"PURE existing unbound link object data\n")
                linked = archive.link_list.read_text().splitlines()
                self.assertEqual(len(linked), 8)
                linked[0] = str(wrong)
                archive.link_list.write_bytes(("\n".join(linked) + "\n").encode())
                self.assertTrue(wrong.is_file())
                self.assertEqual(len(archive.link_list.read_text().splitlines()), 8)
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                self.runner.bind_artifacts(archive.run, archive.scratch, manifest)

    def test_artifact_bind_rejects_changed_frozen_source_bytes(self):
        archive, manifest = self.captured()
        archive.synthetic_build()
        source = archive.run / "Package/Sources/SearchExecution/SearchPreparedUTF8Decoder.swift"
        source.chmod(0o600)
        source.write_bytes(b"!" + MIXED_BYTES[1:])
        source.chmod(0o400)
        with self.assertRaises(ValueError):
            self.runner.bind_artifacts(archive.run, archive.scratch, manifest)

    def test_artifact_member_and_file_bounds_refuse(self):
        for fault in ("members", "fileBytes"):
            archive, manifest = self.captured()
            archive.synthetic_build()
            if fault == "members":
                for index in range(257):
                    write_owned(archive.binary.parent / ("owned-pure-extra-" + str(index)), b"x")
            else:
                # Owned sparse file; no 64MiB allocation or execution.
                with archive.binary.open("r+b") as file:
                    file.truncate(64 * 1024 * 1024 + 1)
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                self.runner.bind_artifacts(archive.run, archive.scratch, manifest)

    def test_root_identity_change_and_fixture_marker_are_retained(self):
        archive, manifest = self.captured()
        previous = archive.run / "previous-owned-Fixtures"
        archive.fixtures.rename(previous)
        archive.fixtures.mkdir(mode=0o700)
        with self.assertRaises(ValueError):
            self.runner.verify_inputs(archive.repo, archive.run, manifest)
        second, second_manifest = self.captured()
        marker = second.fixtures / "owned-pure-marker"
        write_owned(marker, b"keep this evidence\n")
        signals = FakeSignals()
        fake = FakeLaunch(second, signals)
        result = self.run_fake(second, second_manifest, fake)
        self.assertEqual(result["exit"], 125)
        self.assertEqual(marker.read_bytes(), b"keep this evidence\n")
        self.assert_handlers_restored(signals)

    def test_success_waits_only_own_watchdog_without_parent_timeout(self):
        archive, manifest = self.captured()
        signals = FakeSignals()
        fake = FakeLaunch(archive, signals)
        result = self.run_fake(archive, manifest, fake)
        self.assertEqual(result["exit"], 0)
        self.assertEqual(result["rawWatchdogExit"], 0)
        self.assertEqual(len(fake.calls), 1)
        command, arguments = fake.calls[0]
        self.assertEqual(command, archive.command())
        self.assertIs(arguments.get("stdin"), subprocess.DEVNULL)
        self.assertIs(arguments.get("shell"), False)
        self.assertIs(arguments.get("check"), False)
        self.assertIs(arguments.get("close_fds"), True)
        for name in ("timeout", "process_group", "preexec_fn", "start_new_session", "capture_output", "stdout", "stderr"):
            self.assertNotIn(name, arguments)
        self.assert_handlers_restored(signals)

    def test_valid_named_failure_raw_one_is_preserved_one(self):
        archive, manifest = self.captured()
        signals = FakeSignals()
        fake = FakeLaunch(archive, signals, code=1, stdout=literal_output(METHODS[1]))
        result = self.run_fake(archive, manifest, fake)
        self.assertEqual(result["rawWatchdogExit"], 1)
        self.assertEqual(result["exit"], 1)
        self.assertEqual(result["classification"], "testFailure")
        self.assert_handlers_restored(signals)

    def test_compiler_raw_one_without_tests_is_infrastructure_125(self):
        archive, manifest = self.captured()
        signals = FakeSignals()
        fake = FakeLaunch(archive, signals, code=1, stdout=b"", stderr=b"/synthetic/source.swift:1:1: error: PURE missing API\n", build_artifacts=False)
        result = self.run_fake(archive, manifest, fake)
        self.assertEqual(result["rawWatchdogExit"], 1)
        self.assertEqual(result["exit"], 125)
        self.assertEqual(result["classification"], "infrastructure")
        self.assert_handlers_restored(signals)

    def test_malformed_receipt_raw_one_is_infrastructure_125(self):
        archive, manifest = self.captured()
        signals = FakeSignals()
        fake = FakeLaunch(archive, signals, code=1, stdout=literal_output(METHODS[1]), mutate_receipt=lambda record: record.update(waitCompleted=False))
        result = self.run_fake(archive, manifest, fake)
        self.assertEqual(result["rawWatchdogExit"], 1)
        self.assertEqual(result["exit"], 125)
        self.assertEqual(result["classification"], "infrastructure")
        self.assert_handlers_restored(signals)

    def test_zero_raw_exit_with_named_failure_is_infrastructure_125(self):
        archive, manifest = self.captured()
        signals = FakeSignals()
        fake = FakeLaunch(archive, signals, stdout=literal_output(METHODS[1]))
        result = self.run_fake(archive, manifest, fake)
        self.assertEqual(result["rawWatchdogExit"], 0)
        self.assertEqual(result["exit"], 125)
        self.assert_handlers_restored(signals)

    def test_parent_first_intent_refuses_success_and_restores_handlers(self):
        archive, manifest = self.captured()
        signals = FakeSignals()
        fake = FakeLaunch(archive, signals, stop_signals=(signal.SIGTERM, signal.SIGINT, signal.SIGHUP))
        result = self.run_fake(archive, manifest, fake)
        self.assertEqual(result["exit"], 125)
        self.assertEqual(result["parentSignal"], int(signal.SIGTERM))
        self.assertEqual(len(fake.calls), 1)
        self.assert_handlers_restored(signals)

    def test_launch_oserror_restores_exact_handlers_and_retains_inputs(self):
        archive, manifest = self.captured()
        signals = FakeSignals()
        fake = FakeLaunch(archive, signals, failure=True)
        result = self.run_fake(archive, manifest, fake)
        self.assertEqual(result["exit"], 125)
        self.assertIsNone(result["rawWatchdogExit"])
        self.assertEqual(len(fake.calls), 1)
        self.assertFalse((archive.output / "status.json").exists())
        self.assertTrue((archive.run / "Package/Package.swift").exists())
        self.assert_handlers_restored(signals)

    def test_partial_signal_installation_refuses_before_launch_and_restores(self):
        archive, manifest = self.captured()
        signals = FakeSignals(install_failure=signal.SIGHUP)
        fake = FakeLaunch(archive, signals)
        result = self.run_fake(archive, manifest, fake)
        self.assertEqual(result["exit"], 125)
        self.assertEqual(fake.calls, [])
        self.assert_handlers_restored(signals)
        self.assertGreaterEqual(len(signals.calls), 5)

    def test_unavailable_signal_installation_refuses_before_launch(self):
        archive, manifest = self.captured()
        signals = FakeSignals(install_failure=signal.SIGINT, installation_error=ValueError)
        fake = FakeLaunch(archive, signals)
        result = self.run_fake(archive, manifest, fake)
        self.assertEqual(result["exit"], 125)
        self.assertEqual(fake.calls, [])
        self.assertIsNone(result["rawWatchdogExit"])
        self.assert_handlers_restored(signals)

    def test_handler_restoration_failure_cannot_qualify_success(self):
        archive, manifest = self.captured()
        signals = FakeSignals(restore_failure=signal.SIGINT)
        fake = FakeLaunch(archive, signals)
        result = self.run_fake(archive, manifest, fake)
        self.assertEqual(result["rawWatchdogExit"], 0)
        self.assertEqual(result["exit"], 125)
        self.assertIsNot(signals.current[signal.SIGINT], signals.original[signal.SIGINT])
        for number in (signal.SIGTERM, signal.SIGHUP):
            self.assertIs(signals.current[number], signals.original[number])

    def test_oversized_integer_duration_refuses_as_valueerror_and_infrastructure(self):
        archive = self.archive()
        record = archive.capture_record()
        self.runner.validate_receipt(archive.output, archive.command()[8:], 0)
        # 1001 decimal digits: bounded owned JSON, no allocation/proc experiment.
        record["seconds"] = 10 ** 1000
        archive.save_record(record)
        self.assertLess((archive.output / "status.json").stat().st_size, 1024 * 1024)
        try:
            with self.assertRaises(ValueError):
                self.runner.validate_receipt(archive.output, archive.command()[8:], 0)
        except OverflowError:
            # Only this reviewed known exception becomes an ordinary failure.
            self.fail("duration must refuse as ValueError")

        # This public classification path is reached only after proper refusal.
        second, manifest = self.captured()
        signals = FakeSignals()
        fake = FakeLaunch(second, signals, mutate_receipt=lambda receipt: receipt.update(seconds=10 ** 1000))
        result = self.run_fake(second, manifest, fake)
        self.assertEqual(result["exit"], 125)
        self.assertEqual(result["rawWatchdogExit"], 0)
        self.assertEqual(result["classification"], "infrastructure")
        self.assertEqual(len(fake.calls), 1)
        self.assertTrue((second.output / "status.json").is_file())
        self.assert_handlers_restored(signals)

    def test_final_header_open_is_nonblocking_and_refuses_nonregular_before_read(self):
        archive, manifest = self.captured()
        archive.synthetic_build()
        original_info = archive.binary.stat()
        # Complete stat fields from an owned regular fixture, changing type only.
        nonregular = types.SimpleNamespace(**{name: getattr(original_info, name) for name in dir(original_info) if name.startswith("st_")})
        nonregular.st_mode = (original_info.st_mode & 0o7777) | 0o010000  # S_IFIFO
        sentinel = -173  # Impossible genuine FD; never opened, read or closed.
        original_open, original_fstat = os.open, os.fstat
        original_read, original_close = os.read, os.close
        binary_opens, sentinel_stats, sentinel_reads, sentinel_closes = [], [], [], []

        def guarded_open(path, flags, *arguments, **keywords):
            if Path(path) == archive.binary:
                binary_opens.append(flags)
                if len(binary_opens) == 2:
                    # Assert BEFORE any real second open, even against bad source.
                    self.assertEqual(flags & os.O_NONBLOCK, os.O_NONBLOCK, "final header open must be nonblocking")
                    self.assertEqual(flags & os.O_NOFOLLOW, os.O_NOFOLLOW)
                    self.assertEqual(flags & os.O_CLOEXEC, os.O_CLOEXEC)
                    self.assertEqual(flags & os.O_ACCMODE, os.O_RDONLY)
                    return sentinel
                self.assertEqual(len(binary_opens), 1, "unexpected additional main binary open")
            return original_open(path, flags, *arguments, **keywords)

        def guarded_fstat(descriptor):
            if descriptor == sentinel:
                sentinel_stats.append(descriptor)
                return nonregular
            return original_fstat(descriptor)

        def guarded_read(descriptor, count):
            if descriptor == sentinel:
                sentinel_reads.append(count)
                self.fail("nonregular final header descriptor must refuse before read")
            return original_read(descriptor, count)

        def guarded_close(descriptor):
            if descriptor == sentinel:
                sentinel_closes.append(descriptor)
                self.assertEqual(sentinel_closes, [sentinel], "synthetic header descriptor may close only once")
                return None
            return original_close(descriptor)

        # Actual artifact hash and all other source/object reads stay genuine.
        # Context exit restores every OS boundary before owned fixture cleanup.
        with mock.patch.object(os, "open", guarded_open), mock.patch.object(os, "fstat", guarded_fstat), mock.patch.object(os, "read", guarded_read), mock.patch.object(os, "close", guarded_close):
            with self.assertRaises(ValueError):
                self.runner.bind_artifacts(archive.run, archive.scratch, manifest)
        self.assertEqual(len(binary_opens), 2)
        self.assertEqual(sentinel_stats, [sentinel])
        self.assertEqual(sentinel_reads, [])
        self.assertEqual(sentinel_closes, [sentinel])
        self.assertEqual(archive.binary.read_bytes(), BINARY_BYTES)


if __name__ == "__main__":
    unittest.main()
