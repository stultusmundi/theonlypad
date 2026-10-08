"""Pure coordinator controls: synthetic files and a fake stage boundary, no subprocesses."""
import errno
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('worker_runner', Path(__file__).with_name('run_harness.py'))
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


class WorkerRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve() / 'repo'
        self.run = Path(self.temporary.name).resolve() / 'run'
        self.root.mkdir()
        self.run.mkdir()
        names = [
            'Sources/PadCore/Core.swift', 'Sources/SearchExecution/Parent.swift',
            'Sources/PadSearchWorkerRuntime/Runtime.swift',
            'Sources/PadSearchWorker/PadSearchWorkerMain.swift',
            'Package.swift', 'Tests/SearchWorkerIntegration/RealSearchWorkerTests.swift',
            'Tests/SearchWorkerIntegration/run_harness.py',
            'Tests/SearchWorkerIntegration/test_runner.py',
            'Tests/SearchChildIntegration/run_harness.py',
            'scripts/swift.sh', 'scripts/run-owned-search-tests.py', 'scripts/test-search-worker.sh',
        ]
        for name in names:
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text('// synthetic input: ' + name + '\n')
        (self.root / 'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "TheOnlyPad", platforms: [.macOS(.v14)],
    products: [.library(name: "PadCore", targets: ["PadCore"]),
               .executable(name: "PadSearchWorker", targets: ["PadSearchWorker"]),
               .executable(name: "TheOnlyPad", targets: ["TheOnlyPad"])],
    targets: [
        .target(name: "PadCore"),
        .target(name: "SearchExecution", dependencies: ["PadCore"]),
        .target(name: "PadSearchWorkerRuntime", dependencies: ["PadCore", "SearchExecution"]),
        .executableTarget(name: "PadSearchWorker", dependencies: ["PadSearchWorkerRuntime", "SearchExecution"]),
        .testTarget(name: "PadSearchWorkerRuntimeTests", dependencies: ["PadSearchWorkerRuntime", "PadCore", "SearchExecution"]),
        .executableTarget(name: "TheOnlyPad", dependencies: ["PadCore"]),
        .testTarget(name: "PadCoreTests", dependencies: ["PadCore"]),
        .testTarget(name: "SearchExecutionTests", dependencies: ["SearchExecution", "PadCore"])],
    swiftLanguageModes: [.v5])
''')
        self.calls = []

    def fake_watchdog(self, argv):
        self.calls.append(argv)
        output = Path(argv[argv.index('--output') + 1])
        output.mkdir()
        command = argv[argv.index('--') + 1:]
        scratch = Path(command[command.index('--scratch-path') + 1]) if '--scratch-path' in command else self.run / 'HelperBuild'
        directory = scratch / 'arm64-apple-macosx/release'
        directory.mkdir(parents=True, exist_ok=True)
        helper = directory / 'PadSearchWorker'
        helper.write_bytes(b'synthetic compiled helper')
        helper.chmod(0o700)
        if '--build-tests' in command:
            binary = directory / 'SearchWorkerIntegrationPackageTests.xctest/Contents/MacOS/SearchWorkerIntegrationPackageTests'
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b'synthetic test bundle executable')
            binary.chmod(0o700)
        text = 'compiled\n'
        if '--show-bin-path' in command:
            text = str(directory) + '\n'
        if 'test' in command:
            selected = command[command.index('--filter') + 1]
            method = selected.split('/')[-1]
            text = (f"Test Case '-[SearchWorkerIntegrationTests.RealSearchWorkerTests {method}]' started.\n"
                    'WORKER-SETTLED generation=00000000-0000-0000-0000-000000000001 pid=99 '
                    'exit=signaled:9 reaps=1 signals=1 released=1\n'
                    'WORKER-SIGNAL generation=00000000-0000-0000-0000-000000000001 pid=99 signal=9 result=0\n'
                    f"Test Case '-[SearchWorkerIntegrationTests.RealSearchWorkerTests {method}]' passed (0.01 seconds).\n"
                    'Executed 1 test, with 0 failures (0 unexpected) in 0.01 seconds\n')
        self.write_receipt(output, command, text)
        return 0

    def write_receipt(self, output, command, text):
        (output / 'stdout.log').write_text(text)
        (output / 'stderr.log').write_bytes(b'')
        receipt = dict(command=command, pid=91, processGroup=91, exitObserved=True,
                       registrationError=None, groupSignalAttempted=True, groupSignalError=None,
                       groupCleanup='signaled', groupQuery=None, waitCompleted=True,
                       returnCode=0, waitError=None, timedOut=False, interruptedSignal=None,
                       truncated=False, captureComplete=True, failure=None, exit=0,
                       captured={name: dict(received=size, stored=size, discarded=0)
                                 for name, size in [('stdout', len(text.encode())), ('stderr', 0)]})
        (output / 'status.json').write_text(json.dumps(receipt))

    def execute(self, args=(), watchdog=None):
        RUNNER.freeze(self.root, self.run)
        return RUNNER.execute(self.run, RUNNER.parse_args(list(args)), watchdog or self.fake_watchdog)

    def test_exact_single_selection_dispatches_named_method(self):
        self.assertEqual(self.execute(['--case', 'semantic-reuse']), 0)
        tests = [call[call.index('--') + 1:] for call in self.calls if 'test' in call]
        self.assertEqual(len(tests), 1)
        command = tests[0]
        self.assertEqual(command[command.index('--filter') + 1],
                         'RealSearchWorkerTests/testSemanticErrorThenHealthyRequestUsesSameGeneration')
        self.assertIn('--skip-build', command)
        self.assertEqual(command[command.index('--configuration') + 1], 'release')

    def test_default_runs_exact_five_real_methods(self):
        self.assertEqual(self.execute(), 0)
        selections = [call[call.index('--filter') + 1] for call in self.calls if '--filter' in call]
        self.assertEqual(selections, [
            'RealSearchWorkerTests/testUnicodeFindUsesLiteralUTF16Ranges',
            'RealSearchWorkerTests/testRegexCaptureReplacementUsesRealEngine',
            'RealSearchWorkerTests/testNoMatchReplacementPreservesEveryLiteralCodeUnit',
            'RealSearchWorkerTests/testSemanticErrorThenHealthyRequestUsesSameGeneration',
            'RealSearchWorkerTests/testEmptyThenFragmentedSupplementaryReplacement'])

    def test_build_only_never_dispatches_test(self):
        self.assertEqual(self.execute(['--build-only']), 0)
        self.assertFalse(any('test' in call for call in self.calls))
        self.assertEqual(json.loads((self.run / 'status.json').read_text())['testsPassed'], [])

    def test_unknown_or_conflicting_selectors_refused(self):
        for args in [['--case', 'missing'], ['--filter', '.*'], ['--case', ''],
                     ['--build-only', '--case', 'unicode-find']]:
            with self.subTest(args=args), self.assertRaises(SystemExit):
                RUNNER.parse_args(args)

    def test_required_entry_missing_refuses_before_watchdog(self):
        (self.root / 'Sources/PadSearchWorker/PadSearchWorkerMain.swift').unlink()
        with self.assertRaisesRegex(ValueError, 'missing source'):
            self.execute()
        self.assertEqual(self.calls, [])

    def test_runtime_target_missing_refuses_before_watchdog(self):
        (self.root / 'Sources/PadSearchWorkerRuntime/Runtime.swift').unlink()
        with self.assertRaisesRegex(ValueError, 'empty production'):
            self.execute()
        self.assertEqual(self.calls, [])

    def test_public_helper_dependency_drift_refuses_before_watchdog(self):
        path = self.root / 'Package.swift'
        original = path.read_text()
        path.write_text(original.replace(
            '.executableTarget(name: "PadSearchWorker", dependencies: ["PadSearchWorkerRuntime", "SearchExecution"])',
            '.executableTarget(name: "PadSearchWorker", dependencies: ["PadCore"])'))
        with self.assertRaisesRegex(ValueError, 'recipe differs'):
            self.execute()
        self.assertEqual(self.calls, [])

    def test_missing_public_helper_product_refuses_before_watchdog(self):
        path = self.root / 'Package.swift'
        path.write_text(path.read_text().replace(
            '.executable(name: "PadSearchWorker", targets: ["PadSearchWorker"]),', ''))
        with self.assertRaisesRegex(ValueError, 'recipe differs'):
            self.execute()
        self.assertEqual(self.calls, [])

    def test_exact_sources_and_generated_targets_reach_frozen_compiler_tree(self):
        manifest = RUNNER.freeze(self.root, self.run)
        rows = {row['source']: row for row in manifest['sources']}
        for name in ['Sources/PadSearchWorker/PadSearchWorkerMain.swift',
                     'Sources/PadSearchWorkerRuntime/Runtime.swift']:
            self.assertEqual(rows[name]['frozen'], 'Package/' + name)
            self.assertEqual((self.run / rows[name]['frozen']).read_bytes(), (self.root / name).read_bytes())
        test = rows['Tests/SearchWorkerIntegration/RealSearchWorkerTests.swift']
        self.assertEqual(test['frozen'], 'Package/Tests/SearchWorkerIntegrationTests/RealSearchWorkerTests.swift')
        package = (self.run / 'Package/Package.swift').read_text()
        self.assertIn('.executableTarget(name: "PadSearchWorker", dependencies: ["PadSearchWorkerRuntime", "SearchExecution"])', package)
        self.assertIn('.target(name: "PadSearchWorkerRuntime", dependencies: ["PadCore", "SearchExecution"])', package)
        self.assertIn('Package.swift', rows)

    def test_changed_compiler_input_prevents_first_dispatch(self):
        RUNNER.freeze(self.root, self.run)
        target = self.run / 'Package/Sources/PadCore/Core.swift'
        target.chmod(0o600)
        try:
            target.write_text('changed')
        finally:
            target.chmod(0o400)
        self.assertNotEqual(RUNNER.execute(self.run, RUNNER.parse_args([]), self.fake_watchdog), 0)
        self.assertEqual(self.calls, [])

    def test_extra_compiler_file_prevents_first_dispatch(self):
        RUNNER.freeze(self.root, self.run)
        (self.run / 'Package/Sources/PadCore/Injected.swift').write_text('changed')
        self.assertNotEqual(RUNNER.execute(self.run, RUNNER.parse_args([]), self.fake_watchdog), 0)
        self.assertEqual(self.calls, [])

    def test_frozen_helper_copy_survives_later_built_binary_mutation_but_detects_it(self):
        def changed(argv):
            result = self.fake_watchdog(argv)
            if '--build-tests' in argv:
                (self.run / 'HelperBuild/arm64-apple-macosx/release/PadSearchWorker').write_bytes(b'changed after copy')
            return result
        self.assertNotEqual(self.execute(watchdog=changed), 0)
        self.assertEqual((self.run / 'Build/FrozenHelper/PadSearchWorker').read_bytes(), b'synthetic compiled helper')
        self.assertFalse(any('test' in call for call in self.calls))

    def test_nonexecutable_or_missing_test_bundle_refused_before_test(self):
        def changed(argv):
            result = self.fake_watchdog(argv)
            if '--build-tests' in argv:
                target = self.run / 'Build/arm64-apple-macosx/release/SearchWorkerIntegrationPackageTests.xctest/Contents/MacOS/SearchWorkerIntegrationPackageTests'
                target.chmod(0o600)
            return result
        self.assertNotEqual(self.execute(watchdog=changed), 0)
        self.assertFalse(any('test' in call for call in self.calls))

    def test_test_bundle_mutation_during_test_refused(self):
        def changed(argv):
            result = self.fake_watchdog(argv)
            if 'test' in argv:
                (self.run / 'Build/arm64-apple-macosx/release/SearchWorkerIntegrationPackageTests.xctest/Contents/MacOS/SearchWorkerIntegrationPackageTests').write_bytes(b'changed test')
            return result
        self.assertNotEqual(self.execute(['--case', 'unicode-find'], changed), 0)

    def test_boolean_exit_receipt_not_success(self):
        def changed(argv):
            result = self.fake_watchdog(argv)
            output = Path(argv[argv.index('--output') + 1])
            status = json.loads((output / 'status.json').read_text())
            status['exit'] = False
            (output / 'status.json').write_text(json.dumps(status))
            return result
        self.assertNotEqual(self.execute(watchdog=changed), 0)
        self.assertEqual(len(self.calls), 1)

    def test_wrong_command_receipt_not_success(self):
        def changed(argv):
            result = self.fake_watchdog(argv)
            output = Path(argv[argv.index('--output') + 1])
            status = json.loads((output / 'status.json').read_text())
            status['command'] = ['/different/command']
            (output / 'status.json').write_text(json.dumps(status))
            return result
        self.assertNotEqual(self.execute(watchdog=changed), 0)
        self.assertEqual(len(self.calls), 1)

    def test_missing_signal_record_cannot_credit_signaled_exit(self):
        def changed(argv):
            result = self.fake_watchdog(argv)
            if 'test' in argv:
                output = Path(argv[argv.index('--output') + 1])
                text = (output / 'stdout.log').read_text()
                text = '\n'.join(line for line in text.splitlines() if not line.startswith('WORKER-SIGNAL')) + '\n'
                self.write_receipt(output, argv[argv.index('--') + 1:], text)
            return result
        self.assertNotEqual(self.execute(['--case', 'unicode-find'], changed), 0)

    def test_generic_positive_count_cannot_replace_selected_method(self):
        def changed(argv):
            result = self.fake_watchdog(argv)
            if 'test' in argv:
                output = Path(argv[argv.index('--output') + 1])
                self.write_receipt(output, argv[argv.index('--') + 1:], 'Executed 1 test, with 0 failures\n')
            return result
        self.assertNotEqual(self.execute(['--case', 'unicode-find'], changed), 0)

    def test_packaged_mode_pins_existing_helper_and_bundle_without_replacing_them(self):
        bundle = self.root / 'dist/TheOnlyPad.app'
        helper = bundle / 'Contents/Helpers/PadSearchWorker'
        helper.parent.mkdir(parents=True)
        helper.write_bytes(b'independent final nested bytes')
        helper.chmod(0o500)
        self.assertEqual(self.execute(['--case', 'unicode-find', '--application-bundle', str(bundle)]), 0)
        value = json.loads((self.run / 'helper.json').read_text())
        self.assertEqual(value['mode'], 'packaged')
        self.assertEqual(value['executable'], str(helper))
        self.assertEqual(helper.read_bytes(), b'independent final nested bytes')

    def test_packaged_helper_mutation_prevents_outcome_credit(self):
        bundle = self.root / 'dist/TheOnlyPad.app'
        helper = bundle / 'Contents/Helpers/PadSearchWorker'
        helper.parent.mkdir(parents=True)
        helper.write_bytes(b'final nested bytes'); helper.chmod(0o700)
        def changed(argv):
            result = self.fake_watchdog(argv)
            if 'test' in argv: helper.write_bytes(b'substitution')
            return result
        self.assertNotEqual(self.execute(['--case', 'unicode-find', '--application-bundle', str(bundle)], changed), 0)


if __name__ == '__main__':
    unittest.main()
