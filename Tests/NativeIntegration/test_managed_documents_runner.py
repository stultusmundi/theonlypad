"""Pure fixed managed-document runner contracts; injected receipts, no child processes."""
import importlib.util
import json
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location('managed_documents_prior_contracts',
    Path(__file__).with_name('test_native_regressions.py'))
OLD = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(OLD)
RUNNER = OLD.RUNNER

class ManagedDocumentsRunnerTests(unittest.TestCase):
    setUp = OLD.NativeRunnerTests.setUp
    fixture = OLD.NativeRunnerTests.fixture
    receipt = OLD.NativeRunnerTests.receipt
    watchdog = OLD.NativeRunnerTests.watchdog

    def managed_fixture(self):
        root, run = self.fixture()
        files = {'scripts/test-managed-documents.sh': '# fixed wrapper\n',
                 'Tests/NativeIntegration/test_managed_documents_runner.py': '# fixed contracts\n'}
        for target, access in RUNNER.MANAGED_DOCUMENT_ACCESS.items():
            files['Sources/TheOnlyPad/' + target] = '// original ' + target + '\n'
            files['Tests/NativeIntegration/' + access] = '// exact tail ' + access + '\n'
        for filename, methods in RUNNER.MANAGED_DOCUMENT_FILE_METHODS.items():
            lines = []
            for cls in sorted({cls for cls, _ in methods}):
                lines.append('@MainActor final class ' + cls + ': XCTestCase {')
                lines.extend('  func ' + method + '() {}' for owner, method in methods if owner == cls)
                lines.append('}')
            files['Tests/NativeIntegration/' + filename] = '\n'.join(lines) + '\n'
        for relative, data in files.items():
            path = root / relative; path.parent.mkdir(parents=True, exist_ok=True); path.write_text(data)
        return root, run

    def positive(self):
        text = ''
        for cls in sorted({cls for cls, _ in RUNNER.MANAGED_DOCUMENT_METHODS}):
            methods = sorted(method for owner, method in RUNNER.MANAGED_DOCUMENT_METHODS if owner == cls)
            for method in methods:
                text += "Test Case '-[NativeRoutingTests." + cls + ' ' + method + "]' passed (0.001 seconds).\n"
            text += "Test Suite '" + cls + "' passed at synthetic.\n"
            text += 'Executed ' + str(len(methods)) + ' tests, with 0 failures (0 unexpected)\n'
        return text + 'Executed 73 tests, with 0 failures (0 unexpected)\n'

    def test_fixed_six_files_and_seventy_three_methods(self):
        self.assertEqual(set(RUNNER.MANAGED_DOCUMENT_FILE_METHODS), {
            'AppDelegateDocumentsTests.swift','NativeApplicationDocumentsTests.swift',
            'EditorApplicationRoutingTests.swift','NativeDocumentIntakeTests.swift',
            'NativeApplicationOpenTests.swift','NativeApplicationCloseTests.swift'})
        self.assertEqual(len(RUNNER.MANAGED_DOCUMENT_METHODS), 73)
        self.assertEqual(len({cls for cls, _ in RUNNER.MANAGED_DOCUMENT_METHODS}), 7)
        self.assertEqual(RUNNER.parse_args(['managed-documents']).suite, 'managed-documents')
        for arguments in [['managed-documents','/caller/build'], ['managed-documents','--filter','x'],
                          ['managed-documents','--source','x'], ['managed-documents','--skip-build']]:
            with self.subTest(arguments=arguments), self.assertRaises(SystemExit): RUNNER.parse_args(arguments)

    def test_exact_originals_tails_and_six_tests_without_dirty_hook(self):
        root, run = self.managed_fixture(); manifest = RUNNER.freeze(root, run, 'managed-documents')
        for original in (root / 'Sources/TheOnlyPad').glob('*.swift'):
            target = run / 'Package/Sources/NativeRouting' / original.name
            if original.name == 'TheOnlyPadApplication.swift':
                self.assertFalse(target.exists()); continue
            expected = original.read_bytes()
            if original.name in RUNNER.MANAGED_DOCUMENT_ACCESS:
                expected += b'\n' + (root / 'Tests/NativeIntegration' /
                    RUNNER.MANAGED_DOCUMENT_ACCESS[original.name]).read_bytes()
            self.assertEqual(target.read_bytes(), expected)
        tests = run / 'Package/Tests/NativeRoutingTests'
        self.assertEqual(set(p.name for p in tests.iterdir()), set(RUNNER.MANAGED_DOCUMENT_FILE_METHODS))
        for path in tests.iterdir():
            self.assertEqual(path.read_bytes(), (root / 'Tests/NativeIntegration' / path.name).read_bytes())
        self.assertNotIn(b'transferHarnessDirtyReads', (run / 'Package/Sources/NativeRouting/EditorDocument.swift').read_bytes())
        self.assertEqual(len(manifest['managedDocumentsAccess']), 4)
        self.assertEqual(manifest['managedDocumentsMethods'], [list(x) for x in sorted(RUNNER.MANAGED_DOCUMENT_METHODS)])
        RUNNER.verify(run, manifest)

    def test_missing_and_symlink_access_are_refused(self):
        root, _ = self.managed_fixture()
        for access in RUNNER.MANAGED_DOCUMENT_ACCESS.values():
            path = root / 'Tests/NativeIntegration' / access; data = path.read_bytes(); path.unlink()
            with self.subTest(missing=access), self.assertRaises(FileNotFoundError): RUNNER.discover(root, 'managed-documents', False)
            target = root / 'replacement'; target.write_bytes(data); path.symlink_to(target)
            with self.subTest(symlink=access), self.assertRaises(ValueError): RUNNER.discover(root, 'managed-documents', False)
            path.unlink(); path.write_bytes(data); target.unlink()

    def test_census_rejects_missing_added_or_reclassified_methods(self):
        root, run = self.managed_fixture()
        path = root / 'Tests/NativeIntegration/EditorApplicationRoutingTests.swift'; original = path.read_text()
        changed = original.replace('func test', 'func changed', 1)
        path.write_text(changed)
        with self.assertRaises(ValueError): RUNNER.freeze(root, run, 'managed-documents')
        for text in [original + '\nfunc testForeign() {}\n', original.replace('NativeManagedAdmissionCallbackTests:', 'WrongClass:')]:
            with self.assertRaises(ValueError): RUNNER.managed_document_methods(text.encode(), path.name)

    def test_parser_requires_all_exact_unique_successes(self):
        text = self.positive(); self.assertEqual(RUNNER.parse_success('managed-documents', text), {'tests':73,'failures':0})
        line = next(x + '\n' for x in text.splitlines() if x.startswith('Test Case'))
        header = next(x + '\n' for x in text.splitlines() if x.startswith('Test Suite'))
        for broken in ['', text.replace(line, ''), text + line, text.replace(line, line.replace(' passed ', ' skipped ')),
                       text.replace(line, line.replace(' passed ', ' failed ')), text.replace('Executed 73', 'Executed 71'),
                       text.replace('0 failures', '1 failures', 1), text.replace(header, ''), text + header,
                       text.replace('NativeRoutingTests.', 'ForeignModule.', 1), text.replace('0 unexpected', '1 unexpected', 1),
                       text + 'file.swift:1: error: synthetic failure\n']:
            with self.subTest(broken=broken), self.assertRaises(ValueError): RUNNER.parse_success('managed-documents', broken)

    def test_direct_watchdog_explicit_private_state_and_no_filter(self):
        root, run = self.managed_fixture(); RUNNER.freeze(root, run, 'managed-documents')
        self.assertEqual(RUNNER.execute(run, RUNNER.parse_args(['managed-documents']), self.watchdog(self.positive())), 0)
        self.assertEqual(len(self.calls), 2)
        for argv in self.calls:
            command = argv[argv.index('--') + 1:]
            self.assertEqual(command[:2], ['/usr/bin/env', 'THEONLYPAD_STATE_DIRECTORY=' +
                str(run/'State'/('toolchain' if argv is self.calls[0] else 'test'))])
            self.assertEqual((Path(command[1].split('=',1)[1]).stat().st_mode & 0o777), 0o700)
            self.assertNotIn('run-owned-search-tests.py', ' '.join(command))
        command = self.calls[-1][self.calls[-1].index('--') + 1:]
        self.assertIn('-warnings-as-errors', command); self.assertNotIn('--filter', command); self.assertNotIn('--skip-build', command)

    def test_postfreeze_mutation_launches_no_stage(self):
        root, run = self.managed_fixture(); RUNNER.freeze(root, run, 'managed-documents')
        (run/'Package/Sources/NativeRouting/EditorDocument.swift').write_text('// substituted\n')
        self.assertEqual(RUNNER.execute(run, RUNNER.parse_args(['managed-documents']), self.watchdog(self.positive())),125)
        self.assertEqual(self.calls, [])

    def test_incomplete_receipt_cannot_report_managed_success(self):
        root, run = self.managed_fixture(); RUNNER.freeze(root, run, 'managed-documents')
        self.assertEqual(RUNNER.execute(run, RUNNER.parse_args(['managed-documents']), self.watchdog(self.positive(),missing=True)),125)
        self.assertEqual(len(self.calls),1)

if __name__ == '__main__': unittest.main()
