import importlib.util
from pathlib import Path
import tempfile
import json
import os
import py_compile
import unittest

spec = importlib.util.spec_from_file_location('runner', Path(__file__).with_name('run_harness.py'))
r = importlib.util.module_from_spec(spec)
exec(compile(Path(spec.origin).read_bytes(), spec.origin, 'exec'), r.__dict__)

class RunnerTests(unittest.TestCase):
    def source(self):
        return (Path(__file__).absolute().parents[2] / 'Sources/SearchExecution/SearchParentWireDriver.swift').read_text()

    def test_transform_adds_all_declared_hooks(self):
        result = r.instrument(self.source().encode()).decode()
        self.assertNotEqual(result, self.source())
        for hook in ('afterSettlementInspection', 'scopeExit', 'sessionExit', 'beforeConsume', 'beforeExpect', 'readScope', 'beforeChannelObservation'):
            self.assertIn('SearchParentDriverTestHooks.' + hook + '?', result)
        self.assertIn('enum SearchParentDriverTestHooks', result)

    def lifecycle_source(self):
        return (Path(__file__).absolute().parents[2] / 'Sources/SearchExecution/SearchChildLifecycle.swift').read_text()

    def test_lifecycle_transform_observes_adopted_release_only_in_copy(self):
        original = self.lifecycle_source()
        changed = r.instrument_lifecycle(original.encode()).decode()
        self.assertEqual(changed.count('SearchChildLifecycleTestHooks.afterAdoptedRelease?(generation)'), 1)
        self.assertNotIn('SearchChildLifecycleTestHooks', original)
        self.assertIn('ownership = nil\n    SearchChildLifecycleTestHooks.afterAdoptedRelease?(generation)', changed)

    def test_lifecycle_transform_rejects_missing_or_duplicate_anchor(self):
        source = self.lifecycle_source()
        anchor = '    slot = .absent\n    ownership = nil\n    if let current = operation'
        for changed in (source.replace(anchor, ''), source + '\n' + anchor):
            with self.subTest(changed=len(changed)), self.assertRaises(ValueError):
                r.instrument_lifecycle(changed.encode())

    def test_missing_anchor_refused(self):
        with self.assertRaises(ValueError):
            r.instrument(self.source().replace('    withExtendedLifetime(source) {}', '').encode())

    def test_duplicate_anchor_refused(self):
        with self.assertRaises(ValueError):
            r.instrument((self.source() + '\n' + '        await discardSession(epoch)\n        readOwnerExited(epoch)').encode())

    def test_pass_receipt_requires_each_named_test(self):
        names = ['Normal.testOne', 'Instrumented.testTwo']
        text = self.log(names)
        self.assertEqual(r.validate_tests(text, names), 2)

    def test_missing_or_duplicate_test_refused(self):
        for names in (['Normal.testOne'], ['Normal.testOne', 'Normal.testOne']):
            with self.subTest(names=names), self.assertRaises(ValueError):
                r.validate_tests(self.log(names), ['Normal.testOne', 'Instrumented.testTwo'])

    def test_skip_or_failure_refused(self):
        names = ['Normal.testOne']
        for state in ('skipped', 'failed'):
            with self.subTest(state=state), self.assertRaises(ValueError):
                r.validate_tests(self.log(names).replace(" passed (", f" {state} ("), names)

    def test_native_xctest_identifier_is_recognized(self):
        text = self.log(['-[SearchExecutionTests.Normal testOne]'])
        self.assertEqual(r.validate_tests(text, ['Normal.testOne']), 1)

    def test_loader_uses_source_not_stale_timestamp_bytecode(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'synthetic.py'
            path.write_text('value = 1\n')
            before = path.stat()
            py_compile.compile(str(path), doraise=True)
            path.write_text('value = 2\n')
            os.utime(path, ns=(before.st_atime_ns, before.st_mtime_ns))
            self.assertEqual(r.load(path, 'stale_cache_control').value, 2)

    def test_empty_suite_refused(self):
        with self.assertRaises(ValueError):
            r.validate_tests('Executed 0 tests, with 0 failures', [])

    def test_failing_aggregate_refused(self):
        with self.assertRaises(ValueError):
            r.validate_tests(self.log(['N.testOne']).replace('0 failures', '1 failures'), ['N.testOne'])

    @staticmethod
    def log(names):
        return '\n'.join(f"Test Case '{name}' started.\nTest Case '{name}' passed (0.001 seconds)." for name in names) + f'\nExecuted {len(names)} tests, with 0 failures (0 unexpected) in 0.010 seconds'

class FixtureBase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'root'
        self.root.mkdir()
        self.run = Path(self.temp.name) / 'run'
        self.run.mkdir()
        repo = Path(__file__).resolve().parents[2]
        if not (repo / 'Tests/SearchChildIntegration/run_harness.py').exists():
            repo = Path.cwd()
        self.common = r.load(repo / 'Tests/SearchChildIntegration/run_harness.py', 'runner_common_test')
        for name in r.FIXED:
            self.write(name, '// synthetic input\n')
        self.write('Sources/PadCore/Example.swift', '// core\n')
        self.write('Sources/SearchExecution/SearchParentWireDriver.swift', RunnerTests().source())
        self.write('Sources/SearchExecution/SearchChildLifecycle.swift', RunnerTests().lifecycle_source())
        self.write('Tests/SearchExecutionTests/SearchParentWireDriverTests.swift',
                   'final class SearchParentWireDriverTests { func testNormal() {} }')
        self.write('Tests/SearchParentDriverIntegration/SearchParentWireDriverInstrumentedTests.swift',
                   'final class SearchParentWireDriverInstrumentedTests {\n' +
                   '\n'.join('func ' + name + '() {}' for name in r.REQUIRED_INSTRUMENTED) + '\n}')

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)


class FreezeTests(FixtureBase):
    def test_freeze_preserves_original_and_instruments_only_copy(self):
        original = (self.root / 'Sources/SearchExecution/SearchParentWireDriver.swift').read_bytes()
        manifest = r.freeze(self.root, self.run, self.common)
        self.assertTrue(manifest.get('sources'))
        self.assertEqual((self.root / 'Sources/SearchExecution/SearchParentWireDriver.swift').read_bytes(), original)
        self.assertEqual((self.run / 'Original/SearchParentWireDriver.swift').read_bytes(), original)
        self.assertNotEqual((self.run / 'Package/Sources/SearchExecution/SearchParentWireDriver.swift').read_bytes(), original)
        self.assertEqual(len(manifest['expectedTests']), 1 + len(r.REQUIRED_INSTRUMENTED))
        r.verify(self.run, manifest, self.common)

    def test_added_compiler_input_refused(self):
        manifest = r.freeze(self.root, self.run, self.common)
        target = self.run / 'Package/Package@swift-6.swift'
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text('// unlisted manifest')
        with self.assertRaises(ValueError):
            r.verify(self.run, manifest, self.common)

    def test_changed_original_refused(self):
        manifest = r.freeze(self.root, self.run, self.common)
        target = self.run / 'Original/SearchParentWireDriver.swift'
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text('// replaced origin')
        with self.assertRaises(ValueError):
            r.verify(self.run, manifest, self.common)

    def test_changed_lifecycle_original_refused(self):
        manifest = r.freeze(self.root, self.run, self.common)
        target = self.run / 'Original/SearchChildLifecycle.swift'
        target.write_text('// replaced lifecycle origin')
        with self.assertRaises(ValueError):
            r.verify(self.run, manifest, self.common)

    def test_lifecycle_transform_relationship_checked_even_with_updated_digest(self):
        manifest = r.freeze(self.root, self.run, self.common)
        name = 'Package/Sources/SearchExecution/SearchChildLifecycle.swift'
        target = self.run / name
        changed = target.read_bytes().replace(b'afterAdoptedRelease?(generation)', b'afterAdoptedRelease?(UUID())')
        target.write_bytes(changed)
        for item in manifest['sources']:
            if item['frozen'] == name:
                item['sha256'] = self.common.digest(changed)
        with self.assertRaises(ValueError):
            r.verify(self.run, manifest, self.common)

    def test_missing_required_instrumented_test_refused(self):
        self.write('Tests/SearchParentDriverIntegration/SearchParentWireDriverInstrumentedTests.swift',
                   'final class SearchParentWireDriverInstrumentedTests { func testUnrelated() {} }')
        with self.assertRaises(ValueError):
            r.freeze(self.root, self.run, self.common)

    def test_symlink_source_refused(self):
        file = self.root / 'Sources/PadCore/Example.swift'
        file.unlink()
        file.symlink_to(self.root / 'Package.swift')
        with self.assertRaises(ValueError):
            r.freeze(self.root, self.run, self.common)

class ExecuteTests(FixtureBase):
    # Frozen synthetic receipts exercise the coordinator; no subprocess or Swift build.
    def watchdog(self, argv):
        output = Path(argv[argv.index('--output') + 1]); output.mkdir()
        command = argv[argv.index('--') + 1:]
        manifest = json.loads((self.run / 'sources.json').read_text())
        stdout = RunnerTests.log(manifest['expectedTests']) if output.name == 'test' else 'synthetic toolchain'
        if getattr(self, 'empty', False) and output.name == 'test':
            stdout = 'Executed 0 tests, with 0 failures'
        (output / 'stdout.log').write_text(stdout)
        (output / 'stderr.log').write_text('')
        status = dict(command=command, pid=123, processGroup=123,
            exitObserved=True, registrationError=None, groupSignalAttempted=True,
            groupSignalError=None, groupCleanup='signaled', groupQuery=None,
            waitCompleted=True, returnCode=0, waitError=None, timedOut=False,
            interruptedSignal=None, truncated=False, captureComplete=True,
            failure=None, exit=0, captured={
                'stdout': dict(stored=len(stdout.encode()), received=len(stdout.encode()), discarded=0),
                'stderr': dict(stored=0, received=0, discarded=0)})
        if getattr(self, 'incomplete', False): status['waitCompleted'] = False
        (output / 'status.json').write_text(json.dumps(status))
        if getattr(self, 'mutate', False):
            (self.run / 'Package/Sources/PadCore/Example.swift').write_text('// altered')
        self.calls.append(output.name)
        return 0

    def setup_execution(self):
        r.freeze(self.root, self.run, self.common)
        self.calls = []

    def test_full_stage_receipts_and_counts_recorded(self):
        self.setup_execution()
        self.assertEqual(r.execute(self.run, self.run / 'scratch', self.common, self.watchdog), 0)
        self.assertEqual(self.calls, ['toolchain', 'test'])
        status = json.loads((self.run / 'status.json').read_text())
        self.assertEqual(status['testsExecuted'], 1 + len(r.REQUIRED_INSTRUMENTED))
        self.assertEqual(status['exit'], 0)

    def test_exit_zero_without_cleanup_receipt_refused(self):
        self.setup_execution(); self.incomplete = True
        self.assertNotEqual(r.execute(self.run, self.run / 'scratch', self.common, self.watchdog), 0)
        self.assertEqual(self.calls, ['toolchain'])

    def test_empty_test_success_refused(self):
        self.setup_execution(); self.empty = True
        self.assertNotEqual(r.execute(self.run, self.run / 'scratch', self.common, self.watchdog), 0)

    def test_changed_frozen_source_stops_further_stages(self):
        self.setup_execution(); self.mutate = True
        self.assertNotEqual(r.execute(self.run, self.run / 'scratch', self.common, self.watchdog), 0)
        self.assertEqual(self.calls, ['toolchain'])

if __name__ == '__main__':
    unittest.main()
