"""Pure coordinator controls: synthetic files and a fake stage boundary, no subprocesses."""
import contextlib
import errno
import io
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

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
                    f"WORKER-SCOPE scope=observed mode={json.loads((self.run / 'helper.json').read_text())['mode']}\n"
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


    def test_production_defaults_without_bundle_refuses_before_run_setup(self):
        errors = io.StringIO()
        with mock.patch.object(RUNNER, 'freeze') as freeze, \
                mock.patch.object(RUNNER.tempfile, 'mkdtemp') as make_run, \
                contextlib.redirect_stderr(errors):
            with self.assertRaises(SystemExit) as refused:
                RUNNER.main(['--case', 'production-defaults'])
        self.assertEqual(refused.exception.code, 2)
        self.assertIn('requires --application-bundle', errors.getvalue())
        freeze.assert_not_called()
        make_run.assert_not_called()
        self.assertEqual(self.calls, [])

    def test_forged_ordinary_options_without_bundle_refuse_before_dispatch(self):
        # Exercise execute's own guard, not argparse's unknown-selector refusal.
        RUNNER.freeze(self.root, self.run)
        options = RUNNER.parse_args([])
        options.case = 'production-defaults'
        self.assertEqual(RUNNER.execute(self.run, options, self.fake_watchdog), 125)
        self.assertEqual(self.calls, [])
        result = json.loads((self.run / 'status.json').read_text())
        self.assertFalse(result['setupComplete'])
        self.assertEqual(result['testsPassed'], [])
        self.assertEqual(result['stages'], [])
        self.assertIn('requires --application-bundle', result['failure']['reason'])

    def test_packaged_default_selects_original_five_then_ordinary_constructor(self):
        bundle = self.production_bundle()
        self.assertEqual(self.execute(['--application-bundle', str(bundle)],
                                      self.production_watchdog), 0)
        selections = [call[call.index('--filter') + 1] for call in self.calls if '--filter' in call]
        self.assertEqual(selections, [
            'RealSearchWorkerTests/testUnicodeFindUsesLiteralUTF16Ranges',
            'RealSearchWorkerTests/testRegexCaptureReplacementUsesRealEngine',
            'RealSearchWorkerTests/testNoMatchReplacementPreservesEveryLiteralCodeUnit',
            'RealSearchWorkerTests/testSemanticErrorThenHealthyRequestUsesSameGeneration',
            'RealSearchWorkerTests/testEmptyThenFragmentedSupplementaryReplacement',
            'RealSearchWorkerTests/testProductionDefaultsUseOrdinaryConstructorAndJoinedShutdown'])
        status = json.loads((self.run / 'status.json').read_text())
        self.assertEqual(len(status['testsPassed']), 6)
        self.assertEqual(status['testsPassed'][-1], self.ordinary_result())
        self.assertEqual(status['mode'], 'packaged')

    def test_explicit_production_defaults_selects_only_exact_ordinary_method(self):
        bundle = self.production_bundle()
        self.assertEqual(self.execute(['--case', 'production-defaults', '--application-bundle', str(bundle)],
                                      self.production_watchdog), 0)
        tests = [call[call.index('--') + 1:] for call in self.calls if 'test' in call]
        self.assertEqual(len(tests), 1)
        self.assertEqual(tests[0][tests[0].index('--filter') + 1],
                         'RealSearchWorkerTests/testProductionDefaultsUseOrdinaryConstructorAndJoinedShutdown')
        self.assertIn('--skip-build', tests[0])
        result = json.loads((self.run / 'status.json').read_text())
        self.assertEqual(result['testsPassed'], [self.ordinary_result()])
        self.assertEqual(result['mode'], 'packaged')

    def test_ordinary_logical_summary_has_exact_fields_and_no_pid_credit(self):
        output = self.capture(self.ordinary_output())
        actual = RUNNER.verify_test_output(
            output, 'testProductionDefaultsUseOrdinaryConstructorAndJoinedShutdown', mode='packaged')
        self.assertEqual(actual, self.ordinary_result())
        for forbidden in ['pid', 'signals', 'reaps', 'exit', 'released']:
            self.assertNotIn(forbidden, actual)

    def test_observed_scope_preserves_original_exact_validator_result(self):
        method = 'testUnicodeFindUsesLiteralUTF16Ranges'
        expected = dict(method=method, generation='00000000-0000-0000-0000-000000000001',
                        pid=99, exit='signaled:9', signals=[dict(signal=9, result=0)])
        # Existing two-argument callers retain built-mode behavior and dictionary shape.
        self.assertEqual(RUNNER.verify_test_output(self.capture(self.observed_output()), method), expected)
        self.assertEqual(RUNNER.verify_test_output(
            self.capture(self.observed_output(mode='packaged')), method, mode='packaged'), expected)

    def test_observed_missing_wrong_duplicate_or_unclassified_scope_is_refused(self):
        valid = self.observed_output()
        scope = 'WORKER-SCOPE scope=observed mode=built\n'
        for records in ['', 'WORKER-SCOPE scope=ordinary mode=built\n',
                        'WORKER-SCOPE scope=observed mode=packaged\n',
                        scope + scope, 'WORKER-SCOPE scope=observed mode=built extra=1\n',
                        'WORKER-SCOPE scope=unknown mode=built\n']:
            with self.subTest(records=records), self.assertRaises(ValueError):
                RUNNER.verify_test_output(self.capture(valid.replace(scope, records)),
                                          'testUnicodeFindUsesLiteralUTF16Ranges')
        for extra in ['WORKER-UNKNOWN value=1\n', 'WORKER-SCOPE malformed\n',
                      'WORKER-SETTLED pid=not-a-pid\n', 'WORKER-SIGNAL pid=not-a-pid\n']:
            with self.subTest(extra=extra), self.assertRaises(ValueError):
                RUNNER.verify_test_output(self.capture(valid + extra),
                                          'testUnicodeFindUsesLiteralUTF16Ranges')

    def test_ordinary_each_cleanup_field_and_generation_must_be_exact(self):
        valid = self.ordinary_output()
        changes = [
            ('generation=00000000-0000-0000-0000-000000000001',
             'generation=00000000-0000-0000-0000-000000000000'),
            ('generation=00000000-0000-0000-0000-000000000001',
             'generation=------------------------------------'),
            ('generation=00000000-0000-0000-0000-000000000001',
             'generation=000000000-000-0000-0000-000000000001'),
            ('ownership=admitted', 'ownership=refused'),
            ('laneStop=acknowledged', 'laneStop=failed'),
            ('stopped=1', 'stopped=0'), ('stopped=1', 'stopped=True'),
            ('channelsClosed=1', 'channelsClosed=0'),
            ('cleanup=noChild', 'cleanup=stopUnconfirmed'),
            ('parentSettled=1', 'parentSettled=0'),
            ('retainedParentLanes=0', 'retainedParentLanes=1'),
            ('retainedParentLanes=0', 'retainedParentLanes=False'),
        ]
        for before, after in changes:
            with self.subTest(after=after), self.assertRaises(ValueError):
                RUNNER.verify_test_output(
                    self.capture(valid.replace(before, after)),
                    'testProductionDefaultsUseOrdinaryConstructorAndJoinedShutdown', mode='packaged')
        summary = self.ordinary_summary()
        for field in summary.rstrip('\n').split()[1:]:
            with self.subTest(missing=field), self.assertRaises(ValueError):
                RUNNER.verify_test_output(
                    self.capture(valid.replace(' ' + field, '', 1)),
                    'testProductionDefaultsUseOrdinaryConstructorAndJoinedShutdown', mode='packaged')

    def test_ordinary_scope_mode_and_unique_complete_summary_are_required(self):
        valid = self.ordinary_output()
        scope = 'WORKER-SCOPE scope=ordinary mode=packaged\n'
        summary = self.ordinary_summary()
        variants = [
            valid.replace(scope, ''), valid.replace(scope, scope + scope),
            valid.replace(scope, 'WORKER-SCOPE scope=observed mode=packaged\n'),
            valid.replace(scope, 'WORKER-SCOPE scope=ordinary mode=built\n'),
            valid.replace(summary, ''), valid + summary,
            valid.replace('retainedParentLanes=0', 'retainedParentLanes=0 extra=1'),
            valid + 'WORKER-UNKNOWN value=1\n', valid + 'WORKER-ORDINARY malformed\n',
        ]
        for index, text in enumerate(variants):
            with self.subTest(index=index), self.assertRaises(ValueError):
                RUNNER.verify_test_output(
                    self.capture(text), 'testProductionDefaultsUseOrdinaryConstructorAndJoinedShutdown',
                    mode='packaged')
        for mode in ['built', 'unknown', None]:
            with self.subTest(mode=mode), self.assertRaises(ValueError):
                RUNNER.verify_test_output(
                    self.capture(valid), 'testProductionDefaultsUseOrdinaryConstructorAndJoinedShutdown',
                    mode=mode)

    def test_cross_scope_records_never_convert_logical_cleanup_to_pid_evidence(self):
        ordinary = self.ordinary_output()
        for extra in [
            'WORKER-SETTLED generation=00000000-0000-0000-0000-000000000001 pid=99 '
            'exit=signaled:9 reaps=1 signals=1 released=1\n',
            'WORKER-SIGNAL generation=00000000-0000-0000-0000-000000000001 pid=99 signal=9 result=0\n',
            'WORKER-SETTLED pid=not-a-pid\n', 'WORKER-SIGNAL malformed\n',
        ]:
            with self.subTest(extra=extra), self.assertRaises(ValueError):
                RUNNER.verify_test_output(
                    self.capture(ordinary + extra),
                    'testProductionDefaultsUseOrdinaryConstructorAndJoinedShutdown', mode='packaged')
        # This direction reaches the old two-argument validator and discriminates
        # silently ignored ordinary markers even before the new mode API exists.
        for extra in [self.ordinary_summary(), 'WORKER-ORDINARY malformed\n']:
            with self.subTest(extra=extra), self.assertRaises(ValueError):
                RUNNER.verify_test_output(self.capture(self.observed_output() + extra),
                                          'testUnicodeFindUsesLiteralUTF16Ranges')

    def test_ordinary_summary_cannot_replace_exact_selected_xctest_identity_and_count(self):
        valid = self.ordinary_output()
        method = 'testProductionDefaultsUseOrdinaryConstructorAndJoinedShutdown'
        variants = [
            self.ordinary_summary() + 'WORKER-SCOPE scope=ordinary mode=packaged\n'
            'Executed 1 test, with 0 failures\n',
            valid.replace(method, 'testUnicodeFindUsesLiteralUTF16Ranges'),
            valid.replace(' passed (', ' failed ('),
            valid.replace('Executed 1 test, with 0 failures', 'Executed 0 tests, with 0 failures'),
            valid.replace('Executed 1 test, with 0 failures', 'Executed 2 tests, with 0 failures'),
            valid.replace('Executed 1 test, with 0 failures', 'Executed 1 test, with 1 failures'),
            valid.replace('Executed 1 test, with 0 failures (0 unexpected) in 0.01 seconds\n', ''),
        ]
        for index, text in enumerate(variants):
            with self.subTest(index=index), self.assertRaises(ValueError):
                RUNNER.verify_test_output(self.capture(text), method, mode='packaged')

    def test_execute_cannot_credit_observed_rows_for_ordinary_selected_method(self):
        bundle = self.production_bundle()
        # Unmodified fake_watchdog supplies observed PID rows for every method.
        # Once the selector exists, execute must pass actual mode/scope to validation.
        self.assertNotEqual(self.execute(
            ['--case', 'production-defaults', '--application-bundle', str(bundle)]), 0)
        result = json.loads((self.run / 'status.json').read_text())
        self.assertTrue(result['setupComplete'])
        self.assertEqual(result['testsPassed'], [])
        self.assertEqual(len([call for call in self.calls if '--filter' in call]), 1)

    def production_bundle(self):
        bundle = self.root / 'dist/TheOnlyPad.app'
        helper = bundle / 'Contents/Helpers/PadSearchWorker'
        helper.parent.mkdir(parents=True)
        helper.write_bytes(b'independent ordinary packaged helper fixture')
        helper.chmod(0o500)
        return bundle

    def production_watchdog(self, argv):
        result = self.fake_watchdog(argv)
        if '--filter' in argv and argv[argv.index('--filter') + 1] == (
                'RealSearchWorkerTests/testProductionDefaultsUseOrdinaryConstructorAndJoinedShutdown'):
            output = Path(argv[argv.index('--output') + 1])
            self.write_receipt(output, argv[argv.index('--') + 1:], self.ordinary_output())
        return result

    def capture(self, text):
        output = self.run / 'validator-capture'
        output.mkdir(exist_ok=True)
        (output / 'stdout.log').write_text(text)
        (output / 'stderr.log').write_text('')
        return output

    @staticmethod
    def ordinary_summary():
        return ('WORKER-ORDINARY generation=00000000-0000-0000-0000-000000000001 '
                'ownership=admitted laneStop=acknowledged stopped=1 channelsClosed=1 '
                'cleanup=noChild parentSettled=1 retainedParentLanes=0\n')

    def ordinary_output(self):
        method = 'testProductionDefaultsUseOrdinaryConstructorAndJoinedShutdown'
        return (f"Test Case '-[SearchWorkerIntegrationTests.RealSearchWorkerTests {method}]' started.\n"
                'WORKER-SCOPE scope=ordinary mode=packaged\n' + self.ordinary_summary() +
                f"Test Case '-[SearchWorkerIntegrationTests.RealSearchWorkerTests {method}]' passed (0.01 seconds).\n"
                'Executed 1 test, with 0 failures (0 unexpected) in 0.01 seconds\n')

    @staticmethod
    def ordinary_result():
        return dict(method='testProductionDefaultsUseOrdinaryConstructorAndJoinedShutdown',
                    generation='00000000-0000-0000-0000-000000000001',
                    scope='ordinary', mode='packaged', ownership='admitted', laneStop='acknowledged',
                    stopped=True, channelsClosed=True, cleanup='noChild', parentSettled=True,
                    retainedParentLanes=0)

    @staticmethod
    def observed_output(mode='built'):
        return ("Test Case '-[SearchWorkerIntegrationTests.RealSearchWorkerTests testUnicodeFindUsesLiteralUTF16Ranges]' started.\n"
                'WORKER-SETTLED generation=00000000-0000-0000-0000-000000000001 pid=99 '
                'exit=signaled:9 reaps=1 signals=1 released=1\n'
                'WORKER-SIGNAL generation=00000000-0000-0000-0000-000000000001 pid=99 signal=9 result=0\n'
                f'WORKER-SCOPE scope=observed mode={mode}\n'
                "Test Case '-[SearchWorkerIntegrationTests.RealSearchWorkerTests testUnicodeFindUsesLiteralUTF16Ranges]' passed (0.01 seconds).\n"
                'Executed 1 test, with 0 failures (0 unexpected) in 0.01 seconds\n')



if __name__ == '__main__':
    unittest.main()
