"""Pure managed-admission runner contracts; injected receipts only, no native launch."""
import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location(
    'managed_admission_original_contracts', Path(__file__).with_name('test_native_regressions.py'))
OLD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(OLD)
RUNNER = OLD.RUNNER

class ManagedAdmissionRunnerTests(unittest.TestCase):
    setUp = OLD.NativeRunnerTests.setUp
    fixture = OLD.NativeRunnerTests.fixture
    receipt = OLD.NativeRunnerTests.receipt
    watchdog = OLD.NativeRunnerTests.watchdog

    def admission_fixture(self):
        root, run = self.fixture()
        files = {
            'Sources/TheOnlyPad/EditorWindowController.swift':
                'class EditorWindowController {}\n',
            'Tests/NativeIntegration/NativeManagedAdmissionStartupTests.swift':
                '// synthetic actual-owner startup assertions\n',
            'Tests/NativeIntegration/EditorApplicationRoutingTests.swift':
                '// original routing32 plus callback2 assertions\n',
            'Tests/NativeIntegration/ManagedAdmissionControllerAccess.swift':
                '// stored map observation and original public32 construction forwarder\n'
                '  func monitorHarnessDiskConflict(_ document: EditorDocument) -> DocumentDiskConflictController? {\n'
                '    makeDiskConflict(document)\n'
                '  }\n',
            'Tests/NativeIntegration/ManagedAdmissionHistoryAccess.swift':
                '// readonly stored history weak owner and association\n',
            'scripts/test-managed-admission.sh': '# fixed managed-admission wrapper\n',
        }
        for relative, text in files.items():
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        return root, run

    def positive_result(self):
        methods = {
            'NativeManagedAdmissionStartupTests': [
                'testActualEmptyOwnerStartupRetainsViewAndHistoryRouting',
                'testActualPlainFileOwnerStartupRetainsViewAndHistoryRouting'],
            'NativeManagedAdmissionCallbackTests': [
                'testActualEndpointCallbackSuccessorSurvivesOuterAdmissionRefusal',
                'testActualPostPreservationCloseTicketRevokesRoutingOnOuterRefusal'],
        }
        text = ''
        for name, cases in methods.items():
            for case in cases:
                text += "Test Case '-[NativeRoutingTests." + name + ' ' + case + "]' passed\n"
            text += "Test Suite '" + name + "' passed at synthetic.\n"
            text += 'Executed 2 tests, with 0 failures\n'
        return text + 'Executed 4 tests, with 0 failures\n'

    def test_admission_discovery_requires_both_clients_and_readonly_inputs(self):
        self.assertIn('managed-admission', RUNNER.SUITES)
        if 'managed-admission' not in RUNNER.SUITES:
            return
        root, run = self.admission_fixture()
        required = [
            root / 'Tests/NativeIntegration' / name for name in [
                'NativeManagedAdmissionStartupTests.swift',
                'EditorApplicationRoutingTests.swift',
                'ManagedAdmissionControllerAccess.swift',
                'ManagedAdmissionHistoryAccess.swift']]
        found = RUNNER.discover(root, 'managed-admission', False)
        self.assertTrue(set(required).issubset(found))
        self.assertIn(root / 'scripts/test-managed-admission.sh', found)
        for path in required:
            original = path.read_bytes()
            path.unlink()
            with self.subTest(missing=path.name), self.assertRaises((ValueError, FileNotFoundError)):
                RUNNER.discover(root, 'managed-admission', False)
            target = root / 'replacement-input'
            target.write_bytes(original)
            path.symlink_to(target)
            with self.subTest(symlink=path.name), self.assertRaises(ValueError):
                RUNNER.discover(root, 'managed-admission', False)
            path.unlink()
            path.write_bytes(original)
            target.unlink()
        RUNNER.freeze(root, run, 'managed-admission')
        frozen = run / 'Original/Tests/NativeIntegration/ManagedAdmissionControllerAccess.swift'
        frozen.write_text('// changed declared readonly input\n')
        import json
        with self.assertRaises(ValueError):
            RUNNER.verify(run, json.loads((run / 'sources.json').read_text()))

    def test_admission_freeze_is_exact_public_prefix_plus_declared_access(self):
        self.assertIn('managed-admission', RUNNER.SUITES)
        if 'managed-admission' not in RUNNER.SUITES:
            return
        root, run = self.admission_fixture()
        manifest = RUNNER.freeze(root, run, 'managed-admission')
        targets = {
            'EditorWindowController.swift': 'ManagedAdmissionControllerAccess.swift',
            'EditorDocument.swift': 'ManagedAdmissionHistoryAccess.swift',
        }
        for original in sorted((root / 'Sources/TheOnlyPad').glob('*.swift')):
            generated = run / 'Package/Sources/NativeRouting' / original.name
            if original.name == 'TheOnlyPadApplication.swift':
                self.assertFalse(generated.exists())
                continue
            expected = original.read_bytes()
            if original.name in targets:
                expected += b'\n' + (root / 'Tests/NativeIntegration' / targets[original.name]).read_bytes()
            self.assertEqual(generated.read_bytes(), expected, original.name)
        document = run / 'Package/Sources/NativeRouting/EditorDocument.swift'
        self.assertNotIn(b'transferHarnessDirtyReads', document.read_bytes())
        for module in ['PadCore', 'SearchExecution']:
            for original in (root / 'Sources' / module).glob('*.swift'):
                self.assertEqual((run / 'Package/Sources' / module / original.name).read_bytes(),
                                 original.read_bytes())
        for name in ['NativeManagedAdmissionStartupTests.swift', 'EditorApplicationRoutingTests.swift']:
            self.assertEqual((run / 'Package/Tests/NativeRoutingTests' / name).read_bytes(),
                             (root / 'Tests/NativeIntegration' / name).read_bytes())
        self.assertEqual(sorted(p.name for p in (run / 'Package/Tests/NativeRoutingTests').iterdir()),
                         ['EditorApplicationRoutingTests.swift', 'NativeManagedAdmissionStartupTests.swift'])
        RUNNER.verify(run, manifest)
        original = document.read_bytes()
        document.write_bytes(original + b'// undeclared product substitution\n')
        with self.assertRaises(ValueError):
            RUNNER.verify(run, manifest)
        document.write_bytes(original)
        extra = run / 'Package/Sources/NativeRouting/Undeclared.swift'
        extra.write_text('// extra compiler input\n')
        with self.assertRaises(ValueError):
            RUNNER.verify(run, manifest)

    def test_admission_parser_requires_exact_four_unique_named_passes(self):
        self.assertIn('managed-admission', RUNNER.SUITES)
        if 'managed-admission' not in RUNNER.SUITES:
            return
        text = self.positive_result()
        self.assertEqual(RUNNER.parse_success('managed-admission', text), {'tests': 4, 'failures': 0})
        case = "Test Case '-[NativeRoutingTests.NativeManagedAdmissionStartupTests testActualEmptyOwnerStartupRetainsViewAndHistoryRouting]' passed\n"
        header = "Test Suite 'NativeManagedAdmissionStartupTests' passed at synthetic.\n"
        bad = [
            '', text.replace(case, ''), text + case,
            text.replace('testActualEmptyOwnerStartupRetainsViewAndHistoryRouting', 'testForeignSameClass'),
            text.replace('NativeManagedAdmissionCallbackTests', 'ForeignTests'),
            text.replace(header, ''), text + header,
            text.replace('Executed 4 tests', 'Executed 0 tests'),
            text.replace('Executed 4 tests', 'Executed 3 tests'),
            text.replace('0 failures', '1 failures', 1),
            text.replace(case, case.replace("' passed", "' skipped")),
            text + case.replace("' passed", "' failed"),
        ]
        for changed in bad:
            with self.subTest(result=changed), self.assertRaises(ValueError):
                RUNNER.parse_success('managed-admission', changed)
        self.assertEqual(RUNNER.parse_success('transfer',
            "Test Suite 'EditorDocumentTransferTests' passed\nExecuted 12 tests, with 0 failures\n"),
            {'tests': 12, 'failures': 0})

    def test_admission_stage_uses_exact_four_selector_and_direct_owned_state(self):
        self.assertIn('managed-admission', RUNNER.SUITES)
        if 'managed-admission' not in RUNNER.SUITES:
            return
        root, run = self.admission_fixture()
        RUNNER.freeze(root, run, 'managed-admission')
        code = RUNNER.execute(run, RUNNER.parse_args(['managed-admission']),
                              self.watchdog(self.positive_result()))
        self.assertEqual(code, 0)
        self.assertEqual(len(self.calls), 2)
        for argv in self.calls:
            self.assertEqual(argv[:2], ['--timeout', '30' if argv is self.calls[0] else '180'])
            command = argv[argv.index('--') + 1:]
            self.assertEqual(command[:2], ['/usr/bin/env',
                'THEONLYPAD_STATE_DIRECTORY=' + str(run / 'State' /
                    ('toolchain' if argv is self.calls[0] else 'test'))])
            self.assertNotIn('run-owned-search-tests.py', ' '.join(command))
        command = self.calls[-1][self.calls[-1].index('--') + 1:]
        self.assertIn('-warnings-as-errors', command)
        self.assertEqual(command[command.index('--filter') + 1],
            'NativeManagedAdmissionStartupTests|NativeManagedAdmissionCallbackTests')
        changed = run / 'Package/Tests/NativeRoutingTests/NativeManagedAdmissionStartupTests.swift'
        changed.write_text('// substituted after freeze, before any stage\n')
        code = RUNNER.execute(run, RUNNER.parse_args(['managed-admission']),
                              self.watchdog(self.positive_result()))
        self.assertEqual(code, 125)
        self.assertEqual(self.calls, [], 'Changed frozen inputs must launch no child stage')
        with self.assertRaises(SystemExit):
            RUNNER.parse_args(['managed-admission', '/synthetic/debug'])

if __name__ == '__main__':
    unittest.main()
