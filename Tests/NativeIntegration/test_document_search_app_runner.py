"""Pure document-search-app coordinator contract; no native process is launched.

Run from repository root. Production coordinator remains unchanged until Root RED.
"""
import hashlib
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path.cwd()
INTEGRATION = ROOT / 'Tests/NativeIntegration'

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

RUNNER = load('document_search_app_production_coordinator', INTEGRATION / 'run_native_regressions.py')
OLD = load('document_search_app_accepted_pure_helpers', INTEGRATION / 'test_native_regressions.py')
MODE = 'document-search-app'
TEST_FILE = 'DocumentSearchAppRoutingTests.swift'
ACCESS = {
    'AppDelegate.swift': 'DocumentSearchAppRoutingAccess.swift',
    'EditorWindowController.swift': 'DocumentSearchEditorBindingAccess.swift',
    'NativeApplicationDocuments.swift': 'DocumentSearchAppNativeOwnerAccess.swift',
    'DocumentSearchPanelController.swift': 'DocumentSearchPanelAccess.swift',
}
METHODS = (
    ('DocumentSearchAppRoutingTests', 'testCapturedSearchPanelClaimsOnlyCloseAndSixNativeEditingSelectors'),
    ('DocumentSearchAppRoutingTests', 'testCapturedSearchAvailabilityAndDispatchShareIdentityAndRefusalPolicy'),
    ('DocumentSearchAppRoutingTests', 'testActualManagedConfigurationStaysSearchLazyAndAppGuardsPrecedeScope'),
    ('DocumentSearchAppRoutingTests', 'testActualQuitPublishesNativeReceiptThenJoinsSearchAndExternalExactlyOnceAcrossVetoAndRetry'),
)
CLASSES = tuple(dict.fromkeys(owner for owner, _ in METHODS))
SELECTOR = '|'.join(CLASSES)

class DocumentSearchAppRunnerTests(unittest.TestCase):
    def require_mode(self):
        self.assertIn(MODE, RUNNER.SUITES, 'Required bounded document-search-app mode is missing')

    def fixture(self, changed_test=None):
        # Reuse only existing synthetic filesystem/receipt helpers; do not inherit their Test roster.
        helper = OLD.NativeRunnerTests()
        helper.setUp()
        self.addCleanup(helper.doCleanups)
        root, run = helper.fixture()
        files = {
            'scripts/test-document-search-app.sh': '# fixed synthetic document-search-app entry\n',
            'Tests/NativeIntegration/test_document_search_app_runner.py': Path(__file__).read_text(),
            'Tests/NativeIntegration/' + TEST_FILE: changed_test or self.declarations(),
            'Sources/TheOnlyPad/AppDelegate.swift': '// exact current AppDelegate\n',
            'Sources/TheOnlyPad/EditorWindowController.swift': '// exact current controller\n',
            'Sources/TheOnlyPad/NativeApplicationDocuments.swift': '// exact native owner\n',
            'Sources/TheOnlyPad/NativeApplicationCloseCoordinator.swift': '// exact raw native close\n',
            'Tests/NativeIntegration/DocumentSearchNativeCloseAccess.swift': '// excluded742 repair observer\n',
            'Tests/NativeIntegration/DocumentSearchNativeOwnerAccess.swift': '// excluded305 repair observer\n',
            'Sources/TheOnlyPad/DocumentSearchPanelController.swift': '// exact actual panel\n',
            'Sources/TheOnlyPad/NativeApplicationSearches.swift': 'import SearchExecution\n// actual bridge\n',
            'Sources/PadSearchWorkerRuntime/Unrelated.swift': '// outside native three-module graph\n',
        }
        for target, name in ACCESS.items():
            files['Tests/NativeIntegration/' + name] = '// exact synthetic declaring suffix: ' + target + '\n'
        for name, value in files.items():
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(value)
        return helper, root, run

    @staticmethod
    def declarations():
        return 'import XCTest\n@testable import NativeRouting\n@testable import SearchExecution\n' + ''.join(
            'final class ' + owner + ': XCTestCase {\n' + ''.join(
                '  func ' + method + '() {}\n' for actual, method in METHODS if actual == owner
            ) + '}\n' for owner in CLASSES)

    @staticmethod
    def success():
        return ''.join("Test Case '-[NativeRoutingTests." + owner + ' ' + method + "]' passed (0.001 seconds).\n"
                       for owner, method in METHODS) + ''.join(
            "Test Suite '" + owner + "' passed at synthetic.\n" for owner in CLASSES
        ) + 'Executed 4 tests, with 0 failures (0 unexpected)\n'

    def test_document_search_app_cli_is_fixed_and_rejects_caller_override(self):
        self.require_mode()
        args = RUNNER.parse_args([MODE])
        self.assertEqual(args.suite, MODE)
        self.assertIsNone(args.build_path)
        for extra in [['/synthetic/debug'], ['--filter', CLASSES[0]], ['--skip-build'], ['--source', '/synthetic/private']]:
            with self.subTest(extra=extra), self.assertRaises(SystemExit):
                RUNNER.parse_args([MODE, *extra])

    def test_document_search_app_result_requires_exact_four_unique_named_cases(self):
        self.require_mode()
        text = self.success()
        self.assertEqual(RUNNER.parse_success(MODE, text), {'tests': 4, 'failures': 0})
        first = text.splitlines(keepends=True)[0]
        changed = [text.replace(first, '', 1), first + text,
                   text.replace(METHODS[0][1], 'testUnknownMethod', 1),
                   text.replace('NativeRoutingTests.' + CLASSES[0], 'NativeRoutingTests.ForeignClass', 1),
                   text.replace("passed (0.001 seconds).", "skipped (0.001 seconds).", 1),
                   text.replace("passed (0.001 seconds).", "failed (0.001 seconds).", 1),
                   text.replace('Executed 4 tests', 'Executed 3 tests'),
                   text.replace("Test Suite '" + CLASSES[0] + "' passed at synthetic.\n", ''),
                   text + 'error: hidden assertion failure\n', text + 'caught error: real native failure\n']
        for value in changed:
            with self.subTest(value=value), self.assertRaises(ValueError):
                RUNNER.parse_success(MODE, value)

    def test_document_search_app_freezes_exact_raw_sources_without_dirty_or_presentation_hooks(self):
        self.require_mode()
        _, root, run = self.fixture()
        manifest = RUNNER.freeze(root, run, MODE)
        for name in ['EditorDocument.swift', 'NativeApplicationSearches.swift', 'NativeApplicationCloseCoordinator.swift']:
            self.assertEqual((run / 'Package/Sources/NativeRouting' / name).read_bytes(),
                             (root / 'Sources/TheOnlyPad' / name).read_bytes())
        self.assertFalse((run / 'Package/Sources/NativeRouting/TheOnlyPadApplication.swift').exists())
        self.assertFalse((run / 'Package/Sources/PadSearchWorkerRuntime').exists())
        self.assertEqual((run / 'Package/Tests/NativeRoutingTests' / TEST_FILE).read_bytes(),
                         (root / 'Tests/NativeIntegration' / TEST_FILE).read_bytes())
        package = (run / 'Package/Package.swift').read_text()
        self.assertIn('.testTarget(name:"NativeRoutingTests",dependencies:["NativeRouting","PadCore","SearchExecution"])', package)
        captured = {row['source'] for row in manifest['sources']}
        self.assertFalse(any(name.startswith('Sources/PadSearchWorkerRuntime/') for name in captured))
        self.assertNotIn('Tests/NativeIntegration/DocumentSearchNativeCloseAccess.swift', captured)
        self.assertNotIn('Tests/NativeIntegration/DocumentSearchNativeOwnerAccess.swift', captured)
        self.assertFalse((run / 'Original/Tests/NativeIntegration/DocumentSearchNativeCloseAccess.swift').exists())
        RUNNER.verify(run, manifest)

    def test_document_search_app_declaring_tails_manifest_and_capture_are_exact(self):
        self.require_mode()
        _, root, run = self.fixture()
        manifest = RUNNER.freeze(root, run, MODE)
        rows = manifest['documentSearchAppAccess']
        self.assertEqual({row['target'] for row in rows}, set(ACCESS))
        self.assertEqual(len(rows), 4)
        for row in rows:
            target = row['target']
            original = (root / 'Sources/TheOnlyPad' / target).read_bytes()
            access = (root / 'Tests/NativeIntegration' / ACCESS[target]).read_bytes()
            generated = (run / 'Package/Sources/NativeRouting' / target).read_bytes()
            self.assertEqual(generated, original + b'\n' + access)
            self.assertEqual(row['source'], 'Tests/NativeIntegration/' + ACCESS[target])
            self.assertEqual(row['bytes'], len(access))
            self.assertEqual(row['join'], 'LF')
            self.assertEqual(row['sha256'], hashlib.sha256(access).hexdigest())
            self.assertEqual(row['originalSHA256'], hashlib.sha256(original).hexdigest())
            self.assertEqual(row['generatedSHA256'], hashlib.sha256(generated).hexdigest())
        self.assertEqual({tuple(x) for x in manifest['documentSearchAppMethods']}, set(METHODS))
        RUNNER.verify(run, manifest)
        target = run / 'Original/Tests/NativeIntegration' / ACCESS['NativeApplicationDocuments.swift']
        target.write_bytes(target.read_bytes() + b'// substitution\n')
        with self.assertRaises(ValueError):
            RUNNER.verify(run, manifest)

    def test_document_search_app_freeze_refuses_missing_duplicate_or_wrong_class_declarations(self):
        self.require_mode()
        text = self.declarations()
        first = '  func ' + METHODS[0][1] + '() {}\n'
        wrong = [text.replace(first, '', 1), text.replace(first, first + first, 1),
                 text.replace('class ' + CLASSES[0], 'class ForeignClass', 1),
                 text + '\nfinal class ExtraTests: XCTestCase { func testExtra() {} }\n']
        for value in wrong:
            helper, root, run = self.fixture(value)
            with self.subTest(value=value), self.assertRaises(ValueError):
                RUNNER.freeze(root, run, MODE)

    def test_document_search_app_stage_has_werror_fixed_filter_and_owned_private_state(self):
        self.require_mode()
        helper, root, run = self.fixture()
        RUNNER.freeze(root, run, MODE)
        code = RUNNER.execute(run, RUNNER.parse_args([MODE]), helper.watchdog(self.success()))
        self.assertEqual(code, 0)
        self.assertEqual(len(helper.calls), 2, 'Original coordinator owns toolchain and test stages once')
        command = helper.calls[1][helper.calls[1].index('--') + 1:]
        self.assertIn('-warnings-as-errors', command)
        self.assertEqual(command[command.index('--filter') + 1], SELECTOR)
        self.assertNotIn('--skip-build', command)
        for call in helper.calls:
            command = call[call.index('--') + 1:]
            self.assertEqual(command[0], '/usr/bin/env')
            assignments = [part for part in command if part.startswith('THEONLYPAD_STATE_DIRECTORY=')]
            self.assertEqual(len(assignments), 1)
            state = Path(assignments[0].split('=', 1)[1])
            self.assertTrue(state.is_relative_to(run / 'State'))
            self.assertEqual(state.stat().st_mode & 0o777, 0o700)
            self.assertEqual(state.parent.stat().st_mode & 0o777, 0o700)

    def test_document_search_app_frozen_extra_file_or_any_tail_substitution_is_refused(self):
        self.require_mode()
        for substitution in ('extra-native', 'extra-test', 'original-tail', 'generated-controller'):
            with self.subTest(substitution=substitution):
                _, root, run = self.fixture()
                manifest = RUNNER.freeze(root, run, MODE)
                if substitution == 'extra-native':
                    (run / 'Package/Sources/NativeRouting/Stale.swift').write_text('// stale native source\n')
                elif substitution == 'extra-test':
                    (run / 'Package/Tests/NativeRoutingTests/StaleTests.swift').write_text('// stale test\n')
                elif substitution == 'original-tail':
                    target = run / 'Original/Tests/NativeIntegration' / ACCESS['AppDelegate.swift']
                    target.write_bytes(target.read_bytes() + b'// wrong App access\n')
                else:
                    target = run / 'Package/Sources/NativeRouting/EditorWindowController.swift'
                    target.write_bytes(target.read_bytes() + b'// wrong controller suffix\n')
                with self.assertRaises(ValueError):
                    RUNNER.verify(run, manifest)

    def test_document_search_app_missing_receipt_or_capture_drift_stops_before_next_child(self):
        self.require_mode()
        for failure in ('missing-receipt', 'capture-drift'):
            with self.subTest(failure=failure):
                helper, root, run = self.fixture()
                RUNNER.freeze(root, run, MODE)
                mutate = None
                if failure == 'capture-drift':
                    def mutate():
                        target = run / 'Original/Tests/NativeIntegration' / ACCESS['AppDelegate.swift']
                        target.write_bytes(target.read_bytes() + b'// post-stage drift\n')
                code = RUNNER.execute(run, RUNNER.parse_args([MODE]),
                    helper.watchdog(self.success(), missing=failure == 'missing-receipt', mutate=mutate))
                self.assertEqual(code, 125)
                self.assertEqual(len(helper.calls), 1, 'No test child may follow unowned or changed toolchain capture')

if __name__ == '__main__':
    unittest.main()
