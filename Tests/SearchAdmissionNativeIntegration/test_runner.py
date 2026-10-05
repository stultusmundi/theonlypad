"""Pure runner controls. Synthetic receipts only; never invoke Swift, AppKit or a process."""
import importlib.util
import json
import os
from pathlib import Path
import py_compile
import tempfile
import unittest
from unittest.mock import patch

path = Path(__file__).with_name('run_harness.py')
spec = importlib.util.spec_from_file_location('native_runner', path)
r = importlib.util.module_from_spec(spec)
exec(compile(path.read_bytes(), str(path), 'exec'), r.__dict__)


def source(names=None):
    return 'final class NativeBorrowBoundaryTests {\n' + '\n'.join(
        'func ' + name + '() {}' for name in (r.REQUIRED if names is None else names)) + '\n}\n'


def log(names):
    return '\n'.join(f"Test Case '{name}' started.\nTest Case '{name}' passed (0.001 seconds)."
                     for name in names) + f'\nExecuted {len(names)} tests, with 0 failures (0 unexpected)'


class NamedTests(unittest.TestCase):
    def test_exact_native_names(self):
        names = r.native_tests(source())
        self.assertEqual(names, ['NativeBorrowBoundaryTests.' + name for name in r.REQUIRED])
        self.assertEqual(r.validate_tests(log(names), names), 3)

    def test_missing_required_native_case_refused(self):
        for absent in r.REQUIRED:
            with self.subTest(absent=absent), self.assertRaises(ValueError):
                r.native_tests(source([name for name in r.REQUIRED if name != absent]))

    def test_wrong_class_refused(self):
        with self.assertRaises(ValueError):
            r.native_tests(source().replace('NativeBorrowBoundaryTests', 'UnrelatedTests'))

    def test_duplicate_skipped_or_conditional_source_refused(self):
        for text in [source(list(r.REQUIRED) + [r.REQUIRED[0]]), source() + '\nXCTSkip()',
                     '#if DEBUG\n' + source() + '#endif']:
            with self.subTest(text=text), self.assertRaises(ValueError):
                r.native_tests(text)

    def test_missing_duplicate_skipped_or_failed_execution_refused(self):
        names = r.native_tests(source())
        for text in [log(names[:-1]), log(names + [names[0]]), log(names).replace(' passed (', ' skipped ('),
                     log(names).replace(' passed (', ' failed ('), 'Executed 0 tests, with 0 failures']:
            with self.subTest(text=text), self.assertRaises(ValueError):
                r.validate_tests(text, names)

    def test_native_objc_identifiers(self):
        names = r.native_tests(source())
        objc = ['-[SearchExecutionTests.' + name.replace('.', ' ') + ']' for name in names]
        self.assertEqual(r.validate_tests(log(objc), names), 3)

    def test_loader_ignores_stale_bytecode(self):
        with tempfile.TemporaryDirectory() as folder:
            p = Path(folder) / 'value.py'
            p.write_text('value = 1\n'); before = p.stat()
            py_compile.compile(str(p), doraise=True)
            p.write_text('value = 2\n')
            os.utime(p, ns=(before.st_atime_ns, before.st_mtime_ns))
            self.assertEqual(r.load(p, 'source_bound').value, 2)

    def test_arguments_cannot_select_a_smaller_suite(self):
        with self.assertRaises(SystemExit):
            r.main(['--filter', 'one'])


class Fixture(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup)
        base = Path(temp.name).resolve()
        self.root = base / 'archive'; self.root.mkdir()
        self.run = base / 'run'; self.run.mkdir()
        repo = Path(__file__).resolve().parents[2]
        if not (repo / 'Tests/SearchChildIntegration/run_harness.py').is_file():
            repo = Path.cwd()
        self.common = r.load(repo / 'Tests/SearchChildIntegration/run_harness.py', 'native_common')
        for name in r.FIXED: self.write(name, '// synthetic input\n')
        self.write('Sources/PadCore/Example.swift', '// unchanged core\n')
        self.write('Sources/SearchExecution/Nested/Example.swift', '// unchanged nested execution\n')
        self.write(r.NATIVE, source())
        self.calls = []
        self.mutations = {}
        self.stage_code = 0

    def write(self, name, text):
        p = self.root / name; p.parent.mkdir(parents=True, exist_ok=True); p.write_text(text)

    def freeze(self):
        return r.freeze(self.root, self.run, self.common)

    def watchdog(self, argv):
        output = Path(argv[argv.index('--output') + 1]); output.mkdir()
        command = argv[argv.index('--') + 1:]
        self.calls.append((output.name, command, argv))
        manifest = json.loads((self.run / 'sources.json').read_text())
        stdout = log(manifest['expectedTests']) if output.name == 'test' else 'synthetic toolchain'
        if getattr(self, 'empty', False) and output.name == 'test': stdout = 'Executed 0 tests, with 0 failures'
        stderr = 'warning: synthetic' if getattr(self, 'warning', False) else ''
        (output / 'stdout.log').write_text(stdout); (output / 'stderr.log').write_text(stderr)
        status = dict(command=command, pid=123, processGroup=123, exitObserved=True,
                      registrationError=None, groupSignalAttempted=True, groupSignalError=None,
                      groupCleanup='signaled', groupQuery=None, waitCompleted=True, returnCode=0,
                      waitError=None, timedOut=False, interruptedSignal=None, truncated=False,
                      captureComplete=True, failure=None, exit=0, captured={
                          stream: dict(stored=len(text.encode()), received=len(text.encode()), discarded=0)
                          for stream, text in [('stdout', stdout), ('stderr', stderr)]})
        status.update(self.mutations)
        (output / 'status.json').write_text(json.dumps(status))
        if getattr(self, 'mutate_source', False):
            (self.run / 'Package/Sources/PadCore/Example.swift').write_text('// changed')
        if getattr(self, 'mutate_manifest', False):
            (self.run / 'sources.json').write_text('{}')
        return self.stage_code


class FreezeTests(Fixture):
    def test_archive_without_git_and_unchanged_recursive_inputs(self):
        self.assertFalse((self.root / '.git').exists())
        manifest = self.freeze()
        for item in manifest['sources']:
            self.assertEqual((self.root / item['source']).read_bytes(), (self.run / item['frozen']).read_bytes())
            self.assertEqual(item['sha256'], item['originSHA256'])
        self.assertTrue((self.run / 'Package/Sources/SearchExecution/Nested/Example.swift').is_file())
        self.assertEqual(len(manifest['expectedTests']), 3)
        self.assertIn('swiftLanguageModes: [.v5]', (self.run / 'Package/Package.swift').read_text())
        r.verify(self.run, manifest, self.common)

    def test_added_compiler_manifest_refused(self):
        manifest = self.freeze()
        (self.run / 'Package/Package@swift-6.swift').write_text('// override')
        with self.assertRaises(ValueError): r.verify(self.run, manifest, self.common)

    def test_missing_required_native_case_cannot_shrink_frozen_suite(self):
        self.write(r.NATIVE, source(list(r.REQUIRED)[:-1]))
        with self.assertRaises(ValueError): self.freeze()

    def test_changed_package_or_wrapper_refused(self):
        manifest = self.freeze()
        for name in ['Package/Package.swift', 'Runner/scripts/swift.sh']:
            p = self.run / name; original = p.read_bytes(); p.write_bytes(b'changed')
            with self.subTest(name=name), self.assertRaises(ValueError): r.verify(self.run, manifest, self.common)
            p.write_bytes(original)

    def test_source_transform_even_with_updated_compiled_digest_refused(self):
        manifest = self.freeze()
        item = next(x for x in manifest['sources'] if x['source'].startswith('Sources/'))
        p = self.run / item['frozen']; p.write_text('// modified')
        item['sha256'] = self.common.digest(p.read_bytes())
        with self.assertRaises(ValueError): r.verify(self.run, manifest, self.common)

    def test_expected_name_manifest_drift_refused(self):
        manifest = self.freeze(); manifest['expectedTests'] = manifest['expectedTests'][:-1]
        with self.assertRaises(ValueError): r.verify(self.run, manifest, self.common)

    def test_symlink_source_refused(self):
        p = self.root / 'Sources/PadCore/Example.swift'; p.unlink(); p.symlink_to(self.root / 'Package.swift')
        with self.assertRaises(ValueError): self.freeze()

    def test_live_source_changed_during_capture_refused(self):
        original = self.common.read_source; changed = False
        def read(path):
            nonlocal changed
            data = original(path)
            if not changed:
                changed = True; path.write_bytes(data + b'// concurrent change')
            return data
        with patch.object(self.common, 'read_source', read), self.assertRaises(ValueError): self.freeze()


class ExecuteTests(Fixture):
    def test_direct_watchdog_exact_commands_named_tests_and_archive_layout(self):
        self.freeze()
        scratch = self.root / '.build/native'
        self.assertEqual(r.execute(self.run, scratch, self.common, self.watchdog), 0)
        self.assertEqual([name for name, _, _ in self.calls], ['toolchain', 'test'])
        command = self.calls[1][1]
        self.assertEqual(command, [str(self.run / 'Runner/scripts/swift.sh'), 'test', '--package-path',
                          str(self.run / 'Package'), '--scratch-path', str(scratch), '--filter', 'NativeBorrowBoundaryTests'])
        self.assertEqual(self.calls[1][2][:2], ['--timeout', '180'])
        self.assertEqual(json.loads((self.run / 'status.json').read_text())['testsExecuted'], 3)

    def test_incomplete_or_wrong_command_receipt_refused(self):
        self.freeze()
        self.mutations = {'waitCompleted': False}
        self.assertEqual(r.execute(self.run, self.run / 'scratch', self.common, self.watchdog), 125)
        self.assertEqual(len(self.calls), 1)

    def test_wrong_command_receipt_refused(self):
        self.freeze(); self.mutations = {'command': ['swift', '--version']}
        self.assertEqual(r.execute(self.run, self.run / 'scratch', self.common, self.watchdog), 125)

    def test_failed_stage_never_starts_native_stage(self):
        self.freeze(); self.stage_code = 1
        self.assertEqual(r.execute(self.run, self.run / 'scratch', self.common, self.watchdog), 1)
        self.assertEqual(len(self.calls), 1)

    def test_empty_execution_refused(self):
        self.freeze(); self.empty = True
        self.assertEqual(r.execute(self.run, self.run / 'scratch', self.common, self.watchdog), 125)

    def test_changed_frozen_source_stops_stages(self):
        self.freeze(); self.mutate_source = True
        self.assertEqual(r.execute(self.run, self.run / 'scratch', self.common, self.watchdog), 125)
        self.assertEqual(len(self.calls), 1)

    def test_manifest_mutation_stops_stages(self):
        self.freeze(); self.mutate_manifest = True
        self.assertEqual(r.execute(self.run, self.run / 'scratch', self.common, self.watchdog), 125)
        self.assertEqual(len(self.calls), 1)

    def test_compiler_warning_requires_review(self):
        self.freeze(); self.warning = True
        self.assertEqual(r.execute(self.run, self.run / 'scratch', self.common, self.watchdog), 125)


if __name__ == '__main__': unittest.main()
