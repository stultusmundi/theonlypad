"""Pure fixed document-text-storage coordinator contracts; no native process.

Run from Root's isolated repository test layout. No productive coordinator included.
"""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path.cwd()
INTEGRATION = ROOT / 'Tests/NativeIntegration'


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


RUNNER = load('document_text_storage_coordinator', INTEGRATION / 'run_native_regressions.py')
OLD = load('document_text_storage_accepted_helpers', INTEGRATION / 'test_native_regressions.py')
MODE = 'document-text-storage'
CLASS = 'DocumentTextStorageTests'
TEST_FILE = CLASS + '.swift'
METHODS = (
    'testSameLengthMutationABAAndNoOp',
    'testRetainedOldSnapshotImmutability',
    'testMutableStringAdapterInvalidatesSnapshot',
    'testAttributedReplacementInvalidatesSnapshot',
    'testAttributeOnlyChangesPreserveText',
    'testDeleteReinsertUnicode',
    'testRepeated32NSStringReadsRetainAtMostOneIdentity',
)
PAIRS = tuple((CLASS, method) for method in METHODS)


class DocumentTextStorageRunnerTests(unittest.TestCase):
    def require_mode(self):
        self.assertIn(MODE, RUNNER.SUITES, 'Fixed storage mode is missing')
        self.assertEqual(RUNNER.SUITES[MODE], (CLASS, 'document-text-storage-integration'))

    @staticmethod
    def declarations():
        return ('import XCTest\n@testable import NativeRouting\nfinal class ' + CLASS
                + ': XCTestCase {\n' + ''.join('  func ' + method + '() {}\n' for method in METHODS) + '}\n')

    @staticmethod
    def success():
        return ''.join("Test Case '-[NativeRoutingTests." + CLASS + ' ' + method
                       + "]' passed (0.001 seconds).\n" for method in METHODS) + (
            "Test Suite '" + CLASS + "' passed at synthetic.\n"
            'Executed 7 tests, with 0 failures (0 unexpected)\n')

    def fixture(self, declarations=None):
        helper = OLD.NativeRunnerTests()
        helper.setUp()
        self.addCleanup(helper.doCleanups)
        root, run = helper.fixture()
        files = {
            'scripts/test-document-text-storage.sh': '# fixed synthetic storage entry\n',
            'Tests/NativeIntegration/test_document_text_storage_runner.py': Path(__file__).read_text(),
            'Tests/NativeIntegration/' + TEST_FILE: declarations or self.declarations(),
            'Sources/TheOnlyPad/DocumentCommitTextStorage.swift': '// exact current raw storage\n',
            'Sources/TheOnlyPad/EditorWindowController.swift': '// exact current raw controller\n',
            'Sources/TheOnlyPad/AppDelegate.swift': '// exact current raw app declarations\n',
            'Sources/TheOnlyPad/NativeApplicationSearches.swift': 'import SearchExecution\n',
            'Sources/PadSearchWorkerRuntime/Unrelated.swift': '// not in this graph\n',
        }
        for name in ('DocumentSearchPanelAccess.swift', 'DocumentSearchEditorBindingAccess.swift',
                     'DocumentSearchAppNativeOwnerAccess.swift', 'DocumentSearchNativeCloseAccess.swift',
                     'NativeMacroChronologyAccess.swift', 'DocumentSearchAppRoutingAccess.swift'):
            files['Tests/NativeIntegration/' + name] = '// forbidden storage-mode tail\n'
        for name, data in files.items():
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(data)
        return helper, root, run

    def test_storage_mode_cli_is_fixed_without_caller_override(self):
        self.require_mode()
        args = RUNNER.parse_args([MODE])
        self.assertEqual(args.suite, MODE)
        self.assertIsNone(args.build_path)
        for extra in (['/synthetic/debug'], ['--filter', CLASS], ['--skip-build'],
                      ['--source', '/synthetic/private']):
            with self.subTest(extra=extra), self.assertRaises(SystemExit):
                RUNNER.parse_args([MODE, *extra])

    def test_storage_mode_result_requires_exact_seven_unique_named_cases(self):
        self.require_mode()
        text = self.success()
        self.assertEqual(RUNNER.parse_success(MODE, text), {'tests': 7, 'failures': 0})
        first = text.splitlines(keepends=True)[0]
        wrong = [text.replace(first, '', 1), first + text,
                 text.replace(METHODS[0], 'testUnknown', 1),
                 text.replace('NativeRoutingTests.' + CLASS, 'NativeRoutingTests.ForeignClass', 1),
                 text.replace('passed (0.001 seconds).', 'failed (0.001 seconds).', 1),
                 text.replace('passed (0.001 seconds).', 'skipped (0.001 seconds).', 1),
                 text.replace('Executed 7 tests', 'Executed 6 tests'),
                 text.replace("Test Suite '" + CLASS + "' passed at synthetic.\n", ''),
                 text + 'error: hidden assertion\n', text + 'caught error: native failure\n']
        for value in wrong:
            with self.subTest(value=value), self.assertRaises(ValueError):
                RUNNER.parse_success(MODE, value)

    def test_storage_mode_freezes_raw_three_module_sources_and_no_access_tails(self):
        self.require_mode()
        _, root, run = self.fixture()
        manifest = RUNNER.freeze(root, run, MODE)
        for source in (root / 'Sources/TheOnlyPad').glob('*.swift'):
            if source.name != 'TheOnlyPadApplication.swift':
                self.assertEqual((run / 'Package/Sources/NativeRouting' / source.name).read_bytes(),
                                 source.read_bytes(), source.name)
        for module in ('PadCore', 'SearchExecution'):
            for source in (root / 'Sources' / module).glob('*.swift'):
                self.assertEqual((run / 'Package/Sources' / module / source.name).read_bytes(), source.read_bytes())
        self.assertEqual((run / 'Package/Tests/NativeRoutingTests' / TEST_FILE).read_bytes(),
                         (root / 'Tests/NativeIntegration' / TEST_FILE).read_bytes())
        captured = {row['source'] for row in manifest['sources']}
        tests = {name for name in captured if name.startswith('Tests/NativeIntegration/') and name.endswith('.swift')}
        self.assertEqual(tests, {'Tests/NativeIntegration/' + TEST_FILE})
        self.assertFalse(any(name.startswith('Sources/PadSearchWorkerRuntime/') for name in captured))
        self.assertFalse(any(name.endswith('Access.swift') or name.endswith('.inc') for name in captured))
        self.assertFalse((run / 'Package/Sources/NativeRouting/TheOnlyPadApplication.swift').exists())
        self.assertFalse((run / 'Package/Sources/PadSearchWorkerRuntime').exists())
        self.assertEqual({tuple(row) for row in manifest['documentTextStorageMethods']}, set(PAIRS))
        package = (run / 'Package/Package.swift').read_text()
        self.assertIn('.target(name:"SearchExecution",dependencies:["PadCore"])', package)
        self.assertIn('.target(name:"NativeRouting",dependencies:["PadCore","SearchExecution"])', package)
        RUNNER.verify(run, manifest)

    def test_storage_mode_freeze_rejects_changed_seven_method_roster(self):
        self.require_mode()
        text = self.declarations()
        first = '  func ' + METHODS[0] + '() {}\n'
        for value in (text.replace(first, '', 1), text.replace(first, first + first, 1),
                      text.replace('class ' + CLASS, 'class ForeignClass', 1),
                      text + '\nfinal class ExtraTests: XCTestCase { func testExtra() {} }\n'):
            _, root, run = self.fixture(value)
            with self.subTest(value=value), self.assertRaises(ValueError):
                RUNNER.freeze(root, run, MODE)

    def test_storage_mode_owns_cold_werror_fixed_filter_and_private_state(self):
        self.require_mode()
        helper, root, run = self.fixture()
        RUNNER.freeze(root, run, MODE)
        self.assertEqual(RUNNER.execute(run, RUNNER.parse_args([MODE]), helper.watchdog(self.success())), 0)
        self.assertEqual(len(helper.calls), 2)
        for call in helper.calls:
            argv = call[call.index('--') + 1:]
            self.assertEqual(argv[0], '/usr/bin/env')
            assignment = [arg for arg in argv if arg.startswith('THEONLYPAD_STATE_DIRECTORY=')]
            self.assertEqual(len(assignment), 1)
            state = Path(assignment[0].split('=', 1)[1])
            self.assertTrue(state.is_relative_to(run / 'State'))
            self.assertEqual(state.stat().st_mode & 0o777, 0o700)
            self.assertEqual(state.parent.stat().st_mode & 0o777, 0o700)
        argv = helper.calls[1][helper.calls[1].index('--') + 1:]
        self.assertIn('-warnings-as-errors', argv)
        self.assertEqual(argv[argv.index('--filter') + 1], CLASS)
        self.assertNotIn('--skip-build', argv)

    def test_storage_mode_stale_generated_files_or_capture_substitution_are_refused(self):
        self.require_mode()
        for changed in ('extra-native', 'extra-test', 'frozen-storage', 'original-storage'):
            _, root, run = self.fixture()
            manifest = RUNNER.freeze(root, run, MODE)
            if changed == 'extra-native':
                target = run / 'Package/Sources/NativeRouting/Stale.swift'
            elif changed == 'extra-test':
                target = run / 'Package/Tests/NativeRoutingTests/StaleTests.swift'
            elif changed == 'frozen-storage':
                target = run / 'Package/Sources/NativeRouting/DocumentCommitTextStorage.swift'
            else:
                target = run / 'Original/Sources/TheOnlyPad/DocumentCommitTextStorage.swift'
            target.write_bytes(target.read_bytes() + b'// substitution\n' if target.exists() else b'// stale\n')
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                RUNNER.verify(run, manifest)

    def test_storage_mode_missing_receipt_or_post_stage_drift_stops_before_test_child(self):
        self.require_mode()
        for failure in ('missing-receipt', 'capture-drift'):
            helper, root, run = self.fixture()
            RUNNER.freeze(root, run, MODE)
            mutate = None
            if failure == 'capture-drift':
                def mutate():
                    target = run / 'Original/Sources/TheOnlyPad/DocumentCommitTextStorage.swift'
                    target.write_bytes(target.read_bytes() + b'// post-stage drift\n')
            code = RUNNER.execute(run, RUNNER.parse_args([MODE]), helper.watchdog(
                self.success(), missing=failure == 'missing-receipt', mutate=mutate))
            with self.subTest(failure=failure):
                self.assertEqual(code, 125)
                self.assertEqual(len(helper.calls), 1)


if __name__ == '__main__':
    unittest.main()
