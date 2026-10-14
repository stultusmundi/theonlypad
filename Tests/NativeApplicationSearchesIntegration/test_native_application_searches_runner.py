# SPDX-License-Identifier: MIT
"""Pure fixed-ten public coordinator contracts: never call compiler/watchdog/native.
The initial adjacent runner is the unchanged accepted public45 baseline.
Desired mapping assertions are ordinary RED; guarded future freeze horizons
are not credited until the new mapping reaches them. No Swift Test rewrite.
"""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import tempfile
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("native_searches_runner_contract", HERE / "run_native_application_searches.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
CLASS = "NativeApplicationSearchesTests"
COMPONENT = "NativeApplicationSearchesComponent"
TARGET = "NativeApplicationSearchesComponentTests"
LOCATION = "Tests/NativeApplicationSearchesIntegration"
FILENAME = "run_native_application_searches.py"
SOURCES = ("ApplicationSearchOwner.swift", "EditorDocumentSearchSource.swift", "DocumentSearchSession.swift", "NativeApplicationSearches.swift")
EXPECTED_MANIFEST = (HERE / "Package.swift.expected").read_bytes()
ROSTER = ('testLazyFindOwnerIsSharedAcrossTwoActualWindowTickets', 'testFactoryReservationRefusesReentryAndRetriesOnlyThrownPreCreation', 'testQuitWithoutCreatedOwnerNeverInvokesFactory', 'testPreparationConsumesRealRequestResultAndApprovalBeforeCallbacks', 'testVetoResumesOnlyExactPreparationWithoutRestoringOldRights', 'testManagedPreparationReturnPrecedesAdmissionAndVetoLeavesExactPreparedState', 'testHeldTerminalObservationCannotReturnOrCancelActualOwnerJoinEarly', 'testLaterExplicitQuitReusesOriginalJoinAndCanonicalParentWithFreshNativePreparation', 'testCallbackAndStaleRefusalsDoNotAdmitOrReopen', 'testFixedNestedSettlementRequiresEveryRealFieldAndProductionResident')

class NativeSearchesRunnerTests(unittest.TestCase):
    def test_fixed_one_component_ten_roster_and_original_package_identity(self):
        self.assertEqual(runner.STAGES, (("bridge10", CLASS),))
        self.assertEqual(runner.COMPONENTS, {COMPONENT: SOURCES})
        self.assertEqual(runner.TEST_TARGETS, {TARGET: (COMPONENT, CLASS, "NativeApplicationSearchesTests.swift")})
        self.assertEqual(runner.ROSTERS, {CLASS: ROSTER})
        self.assertEqual(runner.MANIFEST, EXPECTED_MANIFEST)
        self.assertEqual(runner.LOCATION, LOCATION)
        self.assertEqual(runner.ENTRY_PATH, "scripts/test-native-application-searches.sh")
        self.assertEqual(runner.NAMESPACE, "native-application-searches-integration")
        for excluded in (b"AppDelegate", b"EditorWindowController", b"DocumentSearchPanel", b"executableTarget"):
            self.assertNotIn(excluded, runner.MANIFEST)

    def test_public_source_map_is_exact_four_sources_one_test_and_three_drivers(self):
        root = Path("/synthetic-repo")
        with mock.patch.object(runner, "swift_inventory", return_value=([], [])):
            rows, directories = runner.source_map(root)
        expected = [(root / "Sources/TheOnlyPad" / name, "Package/Sources/" + COMPONENT + "/" + name, 0o400) for name in SOURCES]
        expected += [(root / LOCATION / "NativeApplicationSearchesTests.swift", "Package/Tests/" + TARGET + "/NativeApplicationSearchesTests.swift", 0o400),
                     (root / "scripts/swift.sh", "Toolchain/scripts/swift.sh", 0o755),
                     (root / "scripts/run-owned-search-tests.py", "Runner/scripts/run-owned-search-tests.py", 0o400),
                     (root / LOCATION / FILENAME, "Runner/" + FILENAME, 0o400)]
        self.assertEqual(rows, expected)
        self.assertEqual(directories, [])
        self.assertEqual(runner.provenance_map(root), [root / "Package.swift", root / "scripts/test-native-application-searches.sh"])
        self.assertTrue(all(not str(a.relative_to(root)).startswith(".local/") for a, _, _ in rows))

    def test_owned_state_argv_has_only_one_cold_fixed_ten_stage(self):
        run, scratch = Path("/owned/run"), Path("/owned/build")
        expected = ["/usr/bin/env", "THEONLYPAD_STATE_DIRECTORY=/owned/run/State/bridge10",
                    "/owned/run/Toolchain/scripts/swift.sh", "test", "--package-path", "/owned/run/Package",
                    "--scratch-path", "/owned/build", "-Xswiftc", "-warnings-as-errors", "--filter", CLASS]
        self.assertEqual(runner.child_command(run, scratch, 0), expected)
        for bad in (-1, 1, True, "0"):
            with self.assertRaises(ValueError): runner.child_command(run, scratch, bad)
        self.assertNotIn("run-owned-search-tests.py", " ".join(expected))

    def test_exact_ten_roster_rejects_added_renamed_missing_and_foreign_class(self):
        self.assertEqual(runner.ROSTERS, {CLASS: ROSTER})
        text = "class " + CLASS + ": XCTestCase {\n" + "\n".join("func " + name + "() {}" for name in ROSTER) + "\n}"
        runner.check_roster(text.encode(), CLASS)
        for bad in (text.replace(ROSTER[0], "testChanged"), text + "\nfunc testExtra() {}", text.replace("func " + ROSTER[0] + "() {}", ""), text.replace(CLASS, "ForeignTests")):
            with self.assertRaises(ValueError): runner.check_roster(bad.encode(), CLASS)

    def _ten_case_log(self, states=None):
        states = states or ["passed"] * len(ROSTER)
        lines = []
        for name, state in zip(ROSTER, states):
            lines += ["Test Case '-[" + TARGET + "." + CLASS + " " + name + "]' started.",
                      "Test Case '-[" + TARGET + "." + CLASS + " " + name + "]' " + state + " (0.001 seconds)."]
        return "\n".join(lines)

    def test_ten_case_parser_requires_every_exact_case_without_skip_or_unknown(self):
        self.assertEqual(runner.ROSTERS, {CLASS: ROSTER})
        text = self._ten_case_log()
        self.assertEqual(runner.parse_cases(text, CLASS)["passed"], 10)
        for bad in (text.replace("passed", "skipped", 1), text + "\n" + text, text.replace(ROSTER[0], "testUnknown"), "\n".join(text.splitlines()[:-1])):
            with self.assertRaises(ValueError): runner.parse_cases(bad, CLASS)

    def test_completed_ten_red_preserves_all_failure_records(self):
        self.assertEqual(runner.ROSTERS, {CLASS: ROSTER})
        line = 'file.swift:9: error: case : failed: caught error: "synthetic"'
        value = runner.parse_cases(self._ten_case_log(["failed"] + ["passed"] * 9) + "\n" + line, CLASS)
        self.assertEqual((value["passed"], value["failed"]), (9, 1))
        self.assertEqual(value["errorRecordHeads"], [line])

    def test_artifact_graph_uses_four_authored_modules_and_one_generated_entry(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve(); run, scratch, record, _, _ = self._build_fixture(root)
            proof = runner.audit_build(run, scratch, record)
            self.assertEqual({row["module"] for row in proof["modules"]}, {"PadCore", "SearchExecution", COMPONENT, TARGET, "NativeApplicationSearchesAcceptancePackageTests"})
            self.assertEqual((proof["objects"], proof["bundleLeaves"]), (5, 4))
            self.assertEqual([row["swiftMode"] for row in proof["modules"] if row["module"] == "NativeApplicationSearchesAcceptancePackageTests"], [None])

    def test_current_source_freeze_is_plain_copy_and_refuses_all_later_drift(self):
        # Honest finite RED horizon: old45 lacks the required mapping; assert it
        # ordinarily before constructing a synthetic future public repository.
        self.assertEqual(runner.STAGES, (("bridge10", CLASS),))
        self.assertEqual(runner.COMPONENTS, {COMPONENT: SOURCES})
        with tempfile.TemporaryDirectory() as tmp:
            top = Path(tmp).resolve(); repo = top / "repo"; repo.mkdir(mode=0o700)
            def fixture(relative, data):
                path = repo / relative; path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data); return path
            fixture("Sources/PadCore/Synthetic.swift", b"// synthetic core, never compiled\n")
            fixture("Sources/SearchExecution/Synthetic.swift", b"// synthetic search, never compiled\n")
            for name in SOURCES: fixture("Sources/TheOnlyPad/" + name, b"// synthetic component, never compiled\n")
            source = repo / "Sources/TheOnlyPad/NativeApplicationSearches.swift"
            test_text = "class " + CLASS + ": XCTestCase {\n" + "\n".join("func " + name + "() {}" for name in ROSTER) + "\n}\n"
            fixture(LOCATION + "/NativeApplicationSearchesTests.swift", test_text.encode())
            fixture(LOCATION + "/" + FILENAME, (HERE / FILENAME).read_bytes())
            wrapper = fixture("scripts/swift.sh", b"# synthetic driver, never executed\n")
            watchdog = fixture("scripts/run-owned-search-tests.py", b"# synthetic watchdog, never imported\n")
            fixture("scripts/test-native-application-searches.sh", b"# synthetic entry, never executed\n")
            fixture("Package.swift", b"// synthetic public manifest provenance\n")
            build_parent = top / "build"; build_parent.mkdir(mode=0o700)
            run = top / "run-one"; run.mkdir(mode=0o700); scratch = build_parent / "one"
            with mock.patch.object(runner, "WRAPPER_SHA", hashlib.sha256(wrapper.read_bytes()).hexdigest()), mock.patch.object(runner, "WATCHDOG_SHA", hashlib.sha256(watchdog.read_bytes()).hexdigest()), mock.patch.object(runner, "environment", return_value={}):
                record = runner.freeze(repo, run, scratch)
                runner.verify_frozen(repo, run, scratch, record)
                self.assertEqual(len(record["sources"]), 10)  # two Core/Search fixtures + eight fixed rows
                self.assertEqual(len(record["provenance"]), 2)
                self.assertNotIn("panelDerivation", record)
                self.assertEqual((run / "Package/Package.swift").read_bytes(), EXPECTED_MANIFEST)
                for row in record["sources"]:
                    self.assertEqual(Path(row["original"]["path"]).read_bytes(), Path(row["frozen"]["path"]).read_bytes())
                    self.assertNotEqual(row["originalIdentity"], row["frozenIdentity"])
                for relative in ("Package/extra.swift", "Runner/extra.py", "Toolchain/scripts/extra.sh", "Evidence/extra.json"):
                    extra = run / relative; extra.write_bytes(b"unexpected member")
                    with self.assertRaises(ValueError): runner.verify_frozen(repo, run, scratch, record)
                    extra.unlink()
                source.write_bytes(source.read_bytes() + b"// fresh public revision\n")
                with self.assertRaises(ValueError): runner.verify_frozen(repo, run, scratch, record)
                run2 = top / "run-two"; run2.mkdir(mode=0o700); scratch2 = build_parent / "two"
                record2 = runner.freeze(repo, run2, scratch2)
                runner.verify_frozen(repo, run2, scratch2, record2)
                destination = "Package/Sources/" + COMPONENT + "/NativeApplicationSearches.swift"
                self.assertEqual((run2 / destination).read_bytes(), source.read_bytes())
                first = next(row for row in record["sources"] if row["destination"] == destination)
                second = next(row for row in record2["sources"] if row["destination"] == destination)
                self.assertNotEqual(first["original"]["sha256"], second["original"]["sha256"])

    def test_no_cli_source_filter_or_build_overrides(self):
        for argv in (["--filter", "Anything"], ["--source", "/tmp/other.swift"], ["--skip-build"], ["--help"]):
            with self.assertRaises(ValueError):
                runner.main(argv)


    def _receipt(self, output, code=0):
        command = ["/usr/bin/env", "THEONLYPAD_STATE_DIRECTORY=/owned/State", "/owned/swift.sh", "test"]
        value = {"command": command, "pid": 123, "processGroup": 123, "exitObserved": True,
                 "registrationError": None, "groupSignalAttempted": True, "groupSignalError": 3,
                 "groupCleanup": "absent", "groupQuery": None, "waitCompleted": True,
                 "returnCode": code, "waitError": None, "timedOut": False, "interruptedSignal": None,
                 "truncated": False, "captureComplete": True, "failure": None, "exit": code,
                 "captured": {k: {"stored": 0, "received": 0, "discarded": 0} for k in ("stdout", "stderr")}}
        for k in ("stdout", "stderr"): (output / (k + ".log")).write_bytes(b"")
        (output / "status.json").write_text(json.dumps(value))
        return command, value


    def test_strict_receipt_accepts_natural_red_but_rejects_every_missing_field(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp); command, value = self._receipt(output, 1)
            self.assertTrue(runner.receipt_success(output, command, 1))
            self.assertFalse(runner.receipt_success(output, command, 0))
            for key in value:
                changed = dict(value); del changed[key]
                (output / "status.json").write_text(json.dumps(changed))
                self.assertFalse(runner.receipt_success(output, command, 1), key)


    def test_receipt_rejects_timeout_truncation_wrong_command_and_incomplete_capture(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp); command, value = self._receipt(output)
            for key, bad in (("timedOut", True), ("truncated", True), ("captureComplete", False), ("waitCompleted", False), ("command", ["other"]), ("groupSignalAttempted", False), ("exit", True)):
                changed = dict(value); changed[key] = bad
                (output / "status.json").write_text(json.dumps(changed))
                self.assertFalse(runner.receipt_success(output, command), key)
            (output / "status.json").write_text(json.dumps(value)); (output / "stdout.log").write_bytes(b"unbound")
            self.assertFalse(runner.receipt_success(output, command))


    def test_read_source_refuses_symlink_and_oversized_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve(); original = root / "source.swift"; original.write_bytes(b"small")
            link = root / "link.swift"; link.symlink_to(original)
            with self.assertRaises(ValueError): runner.read_file(link)
            original.write_bytes(b"x" * (runner.SOURCE_LIMIT + 1))
            with self.assertRaises(ValueError): runner.read_file(original)


    def _build_fixture(self, root):
        run = root / "run"; build = root / "scratch/arm64-apple-macosx/debug"
        run.mkdir(); build.mkdir(parents=True); (build / "Modules").mkdir()
        record = {"sources": []}; groups = {}; objects = []
        generated_name = re.search(rb'name:\s*"([A-Za-z0-9]+)"', runner.MANIFEST).group(1).decode() + "PackageTests"
        authored = ["PadCore", "SearchExecution", *runner.COMPONENTS, *runner.TEST_TARGETS]
        for i, name in enumerate(authored + [generated_name]):
            generated = name not in authored
            source = (build / (name + ".derived/runner.swift")) if generated else run / ("Package/" + ("Tests" if name in runner.TEST_TARGETS else "Sources") + "/" + name + "/Source.swift")
            source.parent.mkdir(parents=True, exist_ok=True); source.write_text("// pure synthetic fixture only\n")
            if not generated: record["sources"].append({"destination": str(source.relative_to(run)), "frozen": {"path": str(source)}})
            group = build / (name + ".build"); group.mkdir()
            obj = group / "Source.swift.o"; obj.write_bytes(b"synthetic-object"); objects.append(str(obj))
            filelist = group / "sources"; filelist.write_text(str(source) + "\n")
            outputmap = group / "output-file-map.json"; outputmap.write_text(json.dumps({str(source): {"object": str(obj)}}))
            module = build / "Modules" / (name + ".swiftmodule"); module.write_bytes(b"synthetic-module")
            args = ["-warnings-as-errors", "-target", "arm64-apple-macosx14.0", "-package-name", "synthetic"]
            if not generated: args += ["-swift-version", "5"]
            groups[name] = {"moduleName": name, "sources": [str(source)], "objects": [str(obj)], "otherArguments": args,
                            "fileList": str(filelist), "outputFileMapPath": str(outputmap), "moduleOutputPath": str(module)}
        name = generated_name; bundle = build / (name + ".xctest")
        executable = bundle / "Contents/MacOS" / name; executable.parent.mkdir(parents=True); executable.write_bytes(b"synthetic-not-an-executable-image"); executable.chmod(0o700)
        for leaf in ("Contents/Info.plist", "Contents/Resources/a", "Contents/Resources/b"):
            p = bundle / leaf; p.parent.mkdir(exist_ok=True, parents=True); p.write_bytes(b"synthetic")
        link = build / (name + ".product/Objects.LinkFileList"); link.parent.mkdir(); link.write_text("\n".join(objects) + "\n")
        desc = {"swiftCommands": groups, "builtTestProducts": [{"binaryPath": str(executable), "packagePath": str(run / "Package"), "productName": name}]}
        (build / "description.json").write_text(json.dumps(desc))
        return run, root / "scratch", record, desc, link


    def test_artifact_map_rejects_wrong_source_object_link_or_mode(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve(); run, scratch, record, desc, link = self._build_fixture(root)
            proof = runner.audit_build(run, scratch, record)
            self.assertEqual((proof["objects"], proof["bundleLeaves"]), (len(runner.COMPONENTS) + len(runner.TEST_TARGETS) + 3, 4))
            path = scratch / "arm64-apple-macosx/debug/description.json"
            for change in ("source", "object", "mode", "product"):
                bad = copy.deepcopy(desc); group = bad["swiftCommands"]["PadCore"]
                if change == "source": group["sources"] = ["/unowned/Source.swift"]
                elif change == "object": group["objects"] = ["/unowned/Source.swift.o"]
                elif change == "mode": group["otherArguments"].remove("-warnings-as-errors")
                else: bad["builtTestProducts"][0]["packagePath"] = "/different/Package"
                path.write_text(json.dumps(bad))
                with self.assertRaises((ValueError, KeyError)): runner.audit_build(run, scratch, record)
            path.write_text(json.dumps(desc)); link.write_text("")
            with self.assertRaises(ValueError): runner.audit_build(run, scratch, record)


    def test_reuse_refuses_changed_built_artifact(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve(); run, scratch, record, _, _ = self._build_fixture(root)
            proof = runner.audit_build(run, scratch, record)
            runner.recheck_artifacts(proof)
            object_path = next(Path(x["path"]) for x in proof["artifacts"] if x["path"].endswith(".o"))
            object_path.write_bytes(b"changed")
            with self.assertRaises(ValueError): runner.recheck_artifacts(proof)


    def test_owned_cache_growth_preserves_exact_scripts_but_rejects_other_entries(self):
        with tempfile.TemporaryDirectory() as tmp:
            run = Path(tmp).resolve(); root = run / "Toolchain"
            for name in ("Toolchain", "Toolchain/scripts", "Toolchain/.cache", "Toolchain/.cache/clang", "Toolchain/.cache/swift"):
                (run / name).mkdir(mode=0o700)
            script = root / "scripts/swift.sh"; script.write_bytes(b"original wrapper"); script.chmod(0o755)
            record = {"toolchainRoots": [runner.directory(run / name, True) for name in
                      ("Toolchain", "Toolchain/.cache", "Toolchain/.cache/clang", "Toolchain/.cache/swift")],
                      "frozenMembership": {"Toolchain/scripts": runner.tree_members(root / "scripts")}}
            runner.verify_toolchain(run, record)
            cache = root / ".cache/clang/generated"; cache.mkdir(mode=0o700)
            (cache / "module.pcm").write_bytes(b"synthetic mutable module cache")
            runner.verify_toolchain(run, record)
            (cache / "module.pcm").write_bytes(b"changed generated cache")
            runner.verify_toolchain(run, record)
            for extra in (root / "unexpected.swift", root / "unexpected.py", root / "scripts/extra.sh"):
                extra.write_bytes(b"unexpected source")
                with self.assertRaises(ValueError): runner.verify_toolchain(run, record)
                extra.unlink()
            script.write_bytes(b"altered wrapper")
            with self.assertRaises(ValueError): runner.verify_toolchain(run, record)
            script.write_bytes(b"original wrapper")
            # Script timestamps are part of no snapshot; tree pin/identity and content are restored.
            runner.verify_toolchain(run, record)
            link = cache / "unowned-link"; link.symlink_to(script)
            with self.assertRaises(ValueError): runner.verify_toolchain(run, record)
            link.unlink()
            executable = cache / "unexpected-executable"; executable.write_bytes(b"not executed"); executable.chmod(0o700)
            with self.assertRaises(ValueError): runner.verify_toolchain(run, record)


if __name__ == "__main__":
    unittest.main()
