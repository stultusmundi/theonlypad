# SPDX-License-Identifier: MIT
"""Pure coordinator contracts only: no compiler, watchdog child or native test."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("panel_runner_contract", HERE / "run_document_search_panel.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class PanelRunnerTests(unittest.TestCase):
    def test_fixed_rosters_are_eight_twentyone_sixteen_without_editor_app_scope(self):
        self.assertEqual([len(runner.ROSTERS[c]) for _, c in runner.STAGES], [8, 21, 16])
        self.assertEqual(len(set(n for v in runner.ROSTERS.values() for n in v)), 45)
        self.assertNotIn(b"AppDelegate", runner.MANIFEST)
        self.assertNotIn(b"EditorWindowController", runner.MANIFEST)
        self.assertNotIn(b"executableTarget", runner.MANIFEST)
        for target in runner.TEST_TARGETS:
            self.assertIn(target.encode(), runner.MANIFEST)

    def test_source_map_preserves_original_import_modules_and_full_test_origins(self):
        root = Path("/synthetic-repo")
        with mock.patch.object(runner, "swift_inventory", return_value=([], [])):
            rows, _ = runner.source_map(root)
        pairs = {(str(a.relative_to(root)), b) for a, b, _ in rows}
        self.assertIn(("Tests/DocumentSearchSessionIntegration/DocumentSearchSessionTests.swift",
                       "Package/Tests/DocumentSearchSessionIntegration/DocumentSearchSessionTests.swift"), pairs)
        self.assertIn(("Tests/ApplicationSearchOwnerIntegration/ApplicationSearchOwnerTests.swift",
                       "Package/Tests/ApplicationSearchOwnerIntegration/ApplicationSearchOwnerTests.swift"), pairs)
        self.assertEqual(sum(a.name == "ApplicationSearchOwner.swift" for a, _, _ in rows), 3)
        self.assertEqual(sum(a.name == "DocumentSearchSession.swift" for a, _, _ in rows), 2)
        self.assertFalse(any(a.name in ("AppDelegate.swift", "EditorWindowController.swift") for a, _, _ in rows))
        self.assertTrue(any(a.name == "DocumentSearchPanelController.swift" for a, _, _ in rows))

    def test_no_cli_source_filter_or_build_overrides(self):
        for argv in (["--filter", "Anything"], ["--source", "/tmp/other.swift"], ["--skip-build"], ["--help"]):
            with self.assertRaises(ValueError):
                runner.main(argv)

    def test_child_argv_passes_owned_state_after_sanitizer_and_fixed_reuse(self):
        run, scratch = Path("/owned/run"), Path("/owned/build")
        for i, (label, cls) in enumerate(runner.STAGES):
            command = runner.child_command(run, scratch, i)
            self.assertEqual(command[:2], ["/usr/bin/env", "THEONLYPAD_STATE_DIRECTORY=/owned/run/State/" + label])
            self.assertEqual(command[-2:], ["--filter", cls])
            self.assertEqual(command.count("--skip-build"), int(i != 0))
            self.assertEqual(command.count("-warnings-as-errors"), 1)
            self.assertNotIn("run-owned-search-tests.py", " ".join(command))
        for bad in (-1, 3, True, "0"):
            with self.assertRaises(ValueError): runner.child_command(run, scratch, bad)

    def test_roster_rejects_added_renamed_or_missing_case(self):
        cls = "DocumentSearchPanelControllerTests"
        text = "class " + cls + ": XCTestCase {\n" + "\n".join("func " + n + "() {}" for n in runner.ROSTERS[cls]) + "\n}"
        runner.check_roster(text.encode(), cls)
        for bad in (text.replace(runner.ROSTERS[cls][0], "testChanged"), text + "\nfunc testExtra() {}", text.replace("func " + runner.ROSTERS[cls][0] + "() {}", "")):
            with self.assertRaises(ValueError): runner.check_roster(bad.encode(), cls)

    def _case_log(self, cls, states=None):
        states = states or ["passed"] * len(runner.ROSTERS[cls])
        lines = []
        for name, state in zip(runner.ROSTERS[cls], states):
            lines += ["Test Case '-[PanelTests." + cls + " " + name + "]' started.",
                      "Test Case '-[PanelTests." + cls + " " + name + "]' " + state + " (0.001 seconds)."]
        return "\n".join(lines)

    def test_case_parser_requires_every_exact_case_without_skip_or_unknown(self):
        cls = "DocumentSearchPanelControllerTests"; text = self._case_log(cls)
        self.assertEqual(runner.parse_cases(text, cls)["passed"], 8)
        for bad in (text.replace("passed", "skipped", 1), text + "\n" + text,
                    text.replace(runner.ROSTERS[cls][0], "testUnknown"), "\n".join(text.splitlines()[:-1])):
            with self.assertRaises(ValueError): runner.parse_cases(bad, cls)

    def test_completed_red_preserves_failed_case_and_literal_error_head(self):
        cls = "DocumentSearchPanelControllerTests"
        line = 'file.swift:9: error: case : failed: caught error: "synthetic"'
        value = runner.parse_cases(self._case_log(cls, ["failed"] + ["passed"] * 7) + "\n" + line, cls)
        self.assertEqual((value["passed"], value["failed"]), (7, 1))
        self.assertEqual(value["errorRecordHeads"], [line])

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

    def test_panel_derivative_refuses_changed_prefix_omitted_or_duplicated_access(self):
        original, tail = b"// original panel\n", b"// FROZEN TEST ACCESS ONLY: synthetic exact access\n"
        frozen = original + b"\n" + tail
        runner.check_panel_derivative(original, tail, frozen)
        for changed in (frozen.replace(b"original", b"changed"), original, original + tail, frozen + tail):
            with self.assertRaises(ValueError): runner.check_panel_derivative(original, tail, changed)

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
        authored = ["PadCore", "SearchExecution", *runner.COMPONENTS, *runner.TEST_TARGETS]
        for i, name in enumerate(authored + ["DocumentSearchPanelAcceptancePackageTests"]):
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
        name = "DocumentSearchPanelAcceptancePackageTests"; bundle = build / (name + ".xctest")
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
            self.assertEqual((proof["objects"], proof["bundleLeaves"]), (9, 4))
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


    def test_public_graph_uses_fixed_repository_origins_without_private_packets(self):
        root = Path("/synthetic-repo")
        with mock.patch.object(runner, "swift_inventory", return_value=([], [])):
            rows, _ = runner.source_map(root)
        pairs = {(str(a.relative_to(root)), b) for a, b, _ in rows}
        self.assertIn(("Sources/TheOnlyPad/DocumentSearchPanelController.swift",
                       "Package/Sources/DocumentSearchPanelComponent/DocumentSearchPanelController.swift"), pairs)
        self.assertIn(("Tests/DocumentSearchPanelIntegration/DocumentSearchPanelControllerTests.swift",
                       "Package/Tests/DocumentSearchPanelComponentTests/DocumentSearchPanelControllerTests.swift"), pairs)
        self.assertTrue(all(not str(a.relative_to(root)).startswith(".local/") for a, _, _ in rows))
        self.assertFalse(any(a.name.endswith("manifest.json") for a, _, _ in rows))

    def test_derivative_refuses_missing_duplicate_or_orphan_access_markers(self):
        marker = b"// FROZEN TEST ACCESS ONLY:"
        original, tail = b"// actual source\n", marker + b" exact test tail\n"
        runner.check_panel_derivative(original, tail, original + b"\n" + tail)
        for bad_tail in (b"// marker removed\n", tail + marker + b" duplicate\n"):
            with self.assertRaises(ValueError):
                runner.check_panel_derivative(original, bad_tail, original + b"\n" + bad_tail)
        orphan_original = original + marker + b" orphaned tail already in Source\n"
        with self.assertRaises(ValueError):
            runner.check_panel_derivative(orphan_original, tail, orphan_original + b"\n" + tail)


    def test_derivation_record_requires_one_exact_source_access_and_frozen_destination(self):
        repo, run = Path("/synthetic-repo"), Path("/owned-run")
        destination = "Package/Sources/DocumentSearchPanelComponent/DocumentSearchPanelController.swift"
        source = {"path": str(repo / "Sources/TheOnlyPad/DocumentSearchPanelController.swift"), "bytes": 8, "sha256": "source"}
        access = {"path": str(repo / "Tests/DocumentSearchPanelIntegration/DocumentSearchPanelTestAccess.swift"), "bytes": 4, "sha256": "access"}
        frozen = {"path": str(run / destination), "bytes": 13, "sha256": "frozen"}
        expected = {"destination": destination, "source": source, "access": access, "frozen": frozen}
        record = {"sources": [{"destination": destination, "original": source, "frozen": frozen}],
                  "provenance": [{"original": access}], "panelDerivation": expected}
        self.assertEqual(runner.panel_derivation_record(repo, run, record), expected)
        for failure in ("missing-source", "duplicate-source", "orphan-source", "wrong-frozen", "missing-access", "duplicate-access"):
            bad = copy.deepcopy(record)
            if failure == "missing-source": bad["sources"] = []
            elif failure == "duplicate-source": bad["sources"].append(copy.deepcopy(bad["sources"][0]))
            elif failure == "orphan-source": bad["sources"][0]["original"]["path"] = "/different/Panel.swift"
            elif failure == "wrong-frozen": bad["sources"][0]["frozen"]["path"] = "/different/Frozen.swift"
            elif failure == "missing-access": bad["provenance"] = []
            elif failure == "duplicate-access": bad["provenance"].append(copy.deepcopy(bad["provenance"][0]))
            with self.subTest(failure=failure):
                with self.assertRaises(ValueError): runner.panel_derivation_record(repo, run, bad)



    def test_public_freeze_derives_current_source_and_refuses_later_drift(self):
        with tempfile.TemporaryDirectory() as tmp:
            top = Path(tmp).resolve(); repo = top / "repo"; repo.mkdir(mode=0o700)
            def fixture(relative, data):
                path = repo / relative; path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data); return path
            fixture("Sources/PadCore/Synthetic.swift", b"// synthetic core, never compiled\n")
            fixture("Sources/SearchExecution/Synthetic.swift", b"// synthetic search, never compiled\n")
            for name in {n for names in runner.COMPONENTS.values() for n in names}:
                fixture("Sources/TheOnlyPad/" + name, b"// synthetic component, never compiled\n")
            source = fixture(runner.PANEL_SOURCE, b"// initial actual fixture source\n")
            tail = fixture(runner.ACCESS_PATH, b"// FROZEN TEST ACCESS ONLY: synthetic tail\n")
            for target, (_, cls, name) in runner.TEST_TARGETS.items():
                relative = runner.LOCATION + "/" + name if target == "DocumentSearchPanelComponentTests" else "Tests/" + target + "/" + name
                text = "class " + cls + ": XCTestCase {\n" + "\n".join("func " + method + "() {}" for method in runner.ROSTERS[cls]) + "\n}\n"
                fixture(relative, text.encode())
            fixture(runner.LOCATION + "/run_document_search_panel.py", (HERE / "run_document_search_panel.py").read_bytes())
            wrapper = fixture("scripts/swift.sh", b"# synthetic driver, never executed\n")
            watchdog = fixture("scripts/run-owned-search-tests.py", b"# synthetic watchdog, never imported\n")
            fixture(runner.ENTRY_PATH, b"# synthetic entry, never executed\n")
            fixture("Package.swift", b"// synthetic public manifest provenance\n")
            fixture("Tests/DocumentSearchSessionIntegration/run_document_search_session.py", b"# synthetic provenance\n")
            fixture("Tests/ApplicationSearchOwnerIntegration/run_application_search_owner.py", b"# synthetic provenance\n")
            build_parent = top / "build"; build_parent.mkdir(mode=0o700)
            run = top / "run-one"; run.mkdir(mode=0o700); scratch = build_parent / "one"
            with mock.patch.object(runner, "WRAPPER_SHA", hashlib.sha256(wrapper.read_bytes()).hexdigest()), \
                 mock.patch.object(runner, "WATCHDOG_SHA", hashlib.sha256(watchdog.read_bytes()).hexdigest()), \
                 mock.patch.object(runner, "environment", return_value={}):
                record = runner.freeze(repo, run, scratch)
                runner.verify_frozen(repo, run, scratch, record)
                derived = run / runner.PANEL_DESTINATION
                self.assertEqual(derived.read_bytes(), source.read_bytes() + b"\n" + tail.read_bytes())
                self.assertEqual(record["panelDerivation"]["source"], runner.pin(source))
                self.assertEqual(record["panelDerivation"]["access"], runner.pin(tail))
                self.assertEqual(record["panelDerivation"]["frozen"], runner.pin(derived))
                source.write_bytes(source.read_bytes() + b"// next public revision\n")
                with self.assertRaises(ValueError): runner.verify_frozen(repo, run, scratch, record)
                run2 = top / "run-two"; run2.mkdir(mode=0o700); scratch2 = build_parent / "two"
                record2 = runner.freeze(repo, run2, scratch2)
                runner.verify_frozen(repo, run2, scratch2, record2)
                self.assertEqual((run2 / runner.PANEL_DESTINATION).read_bytes(), source.read_bytes() + b"\n" + tail.read_bytes())
                self.assertNotEqual(record["panelDerivation"]["source"]["sha256"], record2["panelDerivation"]["source"]["sha256"])


if __name__ == "__main__":
    unittest.main()
