"""Pure harness contracts: temporary bytes and injected watchdog, no child processes."""
import errno
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('search_child_harness', Path(__file__).with_name('run_harness.py'))
HARNESS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HARNESS)


class HarnessTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / 'repo'
        self.root.mkdir()
        self.run = Path(self.temporary.name) / 'run'
        self.run.mkdir()
        files = {
            'Sources/PadCore/Core.swift': 'import Foundation\n',
            'Sources/SearchExecution/Child.swift': 'import PadCore\n',
            'Tests/SearchExecutionTests/SearchChildLifecycleTests.swift': 'import XCTest\n',
            'Tests/SearchChildIntegration/SearchChildChannelTests.swift': '// real channel test source\n',
            'Tests/SearchChildIntegration/SearchChildLauncherTests.swift': '// launcher controls\n',
            'Tests/SearchChildIntegration/SearchChildLifetimeTests.swift': '// lifetime controls\n',
            'Tests/SearchChildIntegration/FixtureMain.swift': '// benign fixture\n',
            'scripts/swift.sh': '#!/bin/sh\nexec swift "$@"\n',
            'scripts/run-owned-search-tests.py': '# accepted watchdog snapshot\n',
            'scripts/test-search-child-lifecycle.sh': '# entry\n',
            'Tests/SearchChildIntegration/run_harness.py': '# coordinator\n',
        }
        for name, contents in files.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(contents)
        self.calls = []

    def freeze(self):
        return HARNESS.freeze(self.root, self.run)

    def fake_watchdog(self, argv):
        self.calls.append(argv)
        output = Path(argv[argv.index('--output') + 1])
        output.mkdir()
        command = argv[argv.index('--') + 1:]
        text = ('Executed 32 tests, with 0 failures (0 unexpected)\n'
                'Test run with 0 tests in 0 suites passed\n') if 'test' in command else 'compiled\n'
        if '--show-bin-path' in command:
            folder = output.parent / 'Build/arch/debug'; folder.mkdir(parents=True, exist_ok=True)
            binary = folder / 'SearchChildFixture'; binary.write_bytes(b'actual fake compiled fixture'); binary.chmod(0o700)
            text = str(folder) + '\n'
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
        return 0

    def execute(self, argv=(), watchdog=None):
        self.freeze()
        return HARNESS.execute(self.run, HARNESS.parse_args(list(argv)), watchdog or self.fake_watchdog)

    def test_cli_rejects_unknown_empty_and_conflicting_options(self):
        for argv in [['--fd-collision-probe'], ['--filter', ''], ['--filter'],
                     ['--build-only', '--filter', 'x']]:
            with self.subTest(argv=argv), self.assertRaises(SystemExit):
                HARNESS.parse_args(argv)

    def test_snapshot_exact_sources_dependencies_and_swift_wrapper_hash(self):
        manifest = self.freeze()
        self.assertIn('scripts/swift.sh', [item['source'] for item in manifest['sources']])
        for item in manifest['sources']:
            self.assertEqual((self.root / item['source']).read_bytes(),
                             (self.run / item['frozen']).read_bytes())
        package = (self.run / 'Package/Package.swift').read_text()
        self.assertIn('swiftLanguageModes: [.v5]', package)
        self.assertIn('SearchExecutionTests', package)
        self.assertIn('executableTarget(name: "SearchChildFixture", dependencies: ["SearchExecution"])', package)
        self.assertEqual((self.run / 'Package/Sources/SearchChildFixture/main.swift').read_bytes(),
                         (self.root / 'Tests/SearchChildIntegration/FixtureMain.swift').read_bytes())

    def test_channel_test_is_frozen_into_existing_test_target(self):
        manifest = self.freeze()
        item = next(x for x in manifest['sources'] if x['source'] ==
                    'Tests/SearchChildIntegration/SearchChildChannelTests.swift')
        self.assertEqual(item['frozen'],
                         'Package/Tests/SearchExecutionTests/SearchChildChannelTests.swift')
        self.assertEqual((self.run / item['frozen']).read_bytes(),
                         (self.root / item['source']).read_bytes())
        self.assertEqual(HARNESS.parse_args([]).filter, 'SearchChildLifecycleTests')


    def test_fixture_metadata_and_binary_are_pinned_and_build_contained(self):
        self.assertEqual(self.execute(), 0)
        value = json.loads((self.run / 'fixture.json').read_text())
        self.assertEqual(Path(value['executable']), self.run / 'Build/FrozenFixture/SearchChildFixture')
        self.assertEqual(value['sourceManifestSHA256'], HARNESS.digest((self.run / 'sources.json').read_bytes()))
        self.assertEqual(HARNESS.digest(Path(value['executable']).read_bytes()), value['sha256'])
        self.assertEqual(HARNESS.digest(Path(value['builtExecutable']).read_bytes()), value['sha256'])
        self.assertEqual(json.loads((self.run / 'status.json').read_text())['fixtureManifestSHA256'],
                         HARNESS.digest((self.run / 'fixture.json').read_bytes()))

    def test_missing_changed_extra_symlink_fixture_artifact_is_refused(self):
        def change_bytes(path):
            path.chmod(0o700); path.write_bytes(b'changed')
        def replace_symlink(path):
            path.unlink(); path.symlink_to(self.run / 'sources.json')
        mutations = [
            lambda run, value: Path(value['executable']).unlink(),
            lambda run, value: change_bytes(Path(value['executable'])),
            lambda run, value: change_bytes(Path(value['builtExecutable'])),
            lambda run, value: replace_symlink(Path(value['executable'])),
            lambda run, value: replace_symlink(run / 'fixture.json'),
            lambda run, value: (Path(value['executable']).parent / 'extra').write_bytes(b'extra'),
            lambda run, value: (run / 'fixture.json').write_text('{}'),
            lambda run, value: (run / 'fixture.json').write_text(json.dumps(dict(value, extra=True))),
        ]
        for index, mutation in enumerate(mutations):
            with self.subTest(index=index):
                self.run = Path(self.temporary.name) / ('variant' + str(index)); self.run.mkdir()
                changed = []
                def change_after_test(argv):
                    code = self.fake_watchdog(argv)
                    if 'test' in argv:
                        value = json.loads((self.run / 'fixture.json').read_text()); mutation(self.run, value)
                        changed.append(True)
                    return code
                self.assertNotEqual(self.execute(watchdog=change_after_test), 0)
                self.assertEqual(changed, [True], 'mutation must actually occur before admission rejects it')
                self.assertEqual(json.loads((self.run / 'status.json').read_text())['failure'], 'ValueError')

    def test_binpath_outside_build_missing_binary_and_symlink_are_refused_before_test(self):
        for index, mode in enumerate(['outside', 'missing', 'symlink', 'multiple']):
            with self.subTest(mode=mode):
                self.run = Path(self.temporary.name) / ('pathvariant' + str(index)); self.run.mkdir()
                self.calls.clear()
                def invalid_binpath(argv):
                    code = self.fake_watchdog(argv)
                    if '--show-bin-path' in argv:
                        output = Path(argv[argv.index('--output') + 1])
                        folder = self.run / 'Build/arch/debug'; binary = folder / 'SearchChildFixture'
                        if mode == 'outside':
                            folder = self.run / 'Outside'; folder.mkdir(); (folder / binary.name).write_bytes(b'outside')
                        elif mode == 'missing': binary.unlink()
                        elif mode == 'symlink':
                            binary.unlink(); binary.symlink_to(self.run / 'sources.json')
                        text = str(folder) + ('\nextra' if mode == 'multiple' else '') + '\n'
                        (output / 'stdout.log').write_text(text)
                        receipt = json.loads((output / 'status.json').read_text())
                        receipt['captured']['stdout'] = dict(received=len(text.encode()), stored=len(text.encode()), discarded=0)
                        (output / 'status.json').write_text(json.dumps(receipt))
                    return code
                self.assertNotEqual(self.execute(watchdog=invalid_binpath), 0)
                self.assertFalse(any('test' in call for call in self.calls))


    def test_binpath_cli_zero_cannot_hide_command_mismatch_or_incomplete_receipt(self):
        for index, mutation in enumerate([{'command': ['forged']}, {'captureComplete': False},
                                           {'waitError': 1}, {'groupQuery': {}}, {'pid': True}]):
            with self.subTest(mutation=mutation):
                self.run = Path(self.temporary.name) / ('receiptvariant' + str(index)); self.run.mkdir()
                self.calls.clear()
                def invalid(argv):
                    code = self.fake_watchdog(argv)
                    if '--show-bin-path' in argv:
                        path = Path(argv[argv.index('--output') + 1]) / 'status.json'
                        value = json.loads(path.read_text()); value.update(mutation); path.write_text(json.dumps(value))
                    return code
                self.assertNotEqual(self.execute(watchdog=invalid), 0)
                self.assertFalse(any('test' in call for call in self.calls))
                self.assertFalse((self.run / 'fixture.json').exists())

    def test_missing_metadata_or_extra_binary_refuses_before_test_dispatch(self):
        original = HARNESS.freeze_fixture
        for index, mode in enumerate(['metadata-missing', 'binary-extra', 'metadata-symlink']):
            with self.subTest(mode=mode):
                self.run = Path(self.temporary.name) / ('predispatch' + str(index)); self.run.mkdir()
                self.calls.clear()
                def change_after_capture(run, output, manifest_hash):
                    pinned = original(run, output, manifest_hash)
                    metadata = run / 'fixture.json'
                    if mode == 'metadata-missing': metadata.unlink()
                    elif mode == 'metadata-symlink':
                        metadata.unlink(); metadata.symlink_to(run / 'sources.json')
                    else: (run / 'Build/FrozenFixture/extra').write_bytes(b'extra')
                    return pinned
                HARNESS.freeze_fixture = change_after_capture
                try:
                    self.assertNotEqual(self.execute(), 0)
                    self.assertEqual(len(self.calls), 3)
                    self.assertFalse(any('test' in call for call in self.calls))
                finally:
                    HARNESS.freeze_fixture = original

    def test_rejects_symlink_source_and_intermediate_directory(self):
        path = self.root / 'Sources/PadCore/Core.swift'
        data = path.read_bytes(); path.unlink()
        other = self.root / 'outside.swift'; other.write_bytes(data)
        path.symlink_to(other)
        with self.assertRaises(ValueError): self.freeze()
        path.unlink(); path.write_bytes(data)
        folder = self.root / 'Sources/SearchExecution'
        folder.rename(self.root / 'Moved')
        folder.symlink_to(self.root / 'Moved', target_is_directory=True)
        with self.assertRaises(ValueError): self.freeze()

    def test_source_change_during_full_snapshot_is_refused(self):
        original = HARNESS.copy_source
        def changing(source, target):
            original(source, target)
            if source.name == 'Child.swift':
                (self.root / 'Sources/PadCore/Core.swift').write_text('changed\n')
        HARNESS.copy_source = changing
        self.addCleanup(setattr, HARNESS, 'copy_source', original)
        with self.assertRaises(ValueError): self.freeze()

    def test_build_only_invokes_direct_watchdog_without_test(self):
        self.assertEqual(self.execute(['--build-only']), 0)
        self.assertEqual(len(self.calls), 3)
        build = self.calls[-2]
        self.assertIn('--build-tests', build)
        self.assertNotIn('test', build)
        self.assertEqual(build[build.index('--') + 1], str(self.run / 'Runner/scripts/swift.sh'))

    def test_default_actual_test_filter_and_nonzero_count(self):
        self.assertEqual(self.execute(), 0)
        self.assertEqual(len(self.calls), 4)
        self.assertEqual(self.calls[-1][-2:], ['--filter', 'SearchChildLifecycleTests'])
        self.assertIn('--skip-build', self.calls[-1])
        self.assertEqual(json.loads((self.run / 'status.json').read_text())['testsExecuted'], 32)

    def test_custom_filter_is_single_argv_not_shell(self):
        value = 'SearchChildLifecycleTests/(testOne|testTwo)'
        self.assertEqual(self.execute(['--filter', value]), 0)
        self.assertEqual(self.calls[-1][-1], value)

    def test_nonzero_and_interrupted_stage_prevent_later_subprocess(self):
        for code in [1, 124, 143]:
            with self.subTest(code=code):
                run = self.run / str(code); run.mkdir(); HARNESS.freeze(self.root, run)
                calls = []
                def failed(argv): calls.append(argv); return code
                self.assertNotEqual(HARNESS.execute(run, HARNESS.parse_args([]), failed), 0)
                self.assertEqual(len(calls), 1)

    def test_cli_zero_with_invalid_cleanup_capture_or_timeout_receipt_fails(self):
        variants = [dict(groupCleanup='unconfirmed'), dict(captureComplete=False),
                    dict(waitCompleted=False), dict(timedOut=True), dict(truncated=True),
                    dict(interruptedSignal=15), dict(failure='observation'), dict(returnCode=9)]
        for index, changes in enumerate(variants):
            with self.subTest(changes=changes):
                run = self.run / str(index); run.mkdir(); HARNESS.freeze(self.root, run)
                self.calls.clear()
                def invalid(argv):
                    self.fake_watchdog(argv)
                    path = Path(argv[argv.index('--output') + 1]) / 'status.json'
                    value = json.loads(path.read_text()); value.update(changes); path.write_text(json.dumps(value))
                    return 0
                self.assertNotEqual(HARNESS.execute(run, HARNESS.parse_args([]), invalid), 0)
                self.assertEqual(len(self.calls), 1)

    def test_zero_or_missing_xctest_count_never_passes(self):
        for index, footer in enumerate(['Executed 0 tests, with 0 failures\n', 'no tests listed\n']):
            run = self.run / str(index); run.mkdir(); HARNESS.freeze(self.root, run)
            def empty(argv):
                self.fake_watchdog(argv)
                if 'test' in argv:
                    output = Path(argv[argv.index('--output') + 1]); (output / 'stdout.log').write_text(footer)
                    value = json.loads((output / 'status.json').read_text())
                    value['captured']['stdout'] = dict(received=len(footer), stored=len(footer), discarded=0)
                    (output / 'status.json').write_text(json.dumps(value))
                return 0
            self.assertNotEqual(HARNESS.execute(run, HARNESS.parse_args([]), empty), 0)

    def test_frozen_mutation_prevents_next_stage(self):
        def mutate(argv):
            self.fake_watchdog(argv)
            (self.run / 'Package/Sources/PadCore/Core.swift').write_text('changed')
            return 0
        self.assertNotEqual(self.execute(watchdog=mutate), 0)
        self.assertEqual(len(self.calls), 1)

    def test_exited_leader_only_requires_complete_exact_group_receipt(self):
        def invalid(argv):
            self.fake_watchdog(argv)
            path = Path(argv[argv.index('--output') + 1]) / 'status.json'
            value = json.loads(path.read_text())
            value.update(groupCleanup='exitedLeaderOnly', groupSignalError=errno.EPERM,
                         groupQuery=dict(processGroup=91, errorNumber=None, returnedBytes=8,
                                         bufferBytes=1024, members=[91, 92]))
            path.write_text(json.dumps(value)); return 0
        self.assertNotEqual(self.execute(watchdog=invalid), 0)


    def test_added_compiler_inputs_before_execution_launch_no_stage(self):
        for index, name in enumerate([
            'Sources/SearchExecution/Unmanifested.swift',
            'Tests/SearchExecutionTests/Extra.swift', 'Package@swift-6.0.swift',
            'Sources/PadCore/UnexpectedDirectory/',
        ]):
            with self.subTest(name=name):
                run = self.run / str(index); run.mkdir(); HARNESS.freeze(self.root, run)
                path = run / 'Package' / name
                if name.endswith('/'): path.mkdir()
                else: path.write_text('// synthetic unexpected input\n')
                self.calls.clear()
                self.assertNotEqual(HARNESS.execute(run, HARNESS.parse_args([]), self.fake_watchdog), 0)
                self.assertEqual(self.calls, [])

    def test_added_source_after_metadata_prevents_build(self):
        def add(argv):
            self.fake_watchdog(argv)
            (self.run / 'Package/Sources/SearchExecution/Extra.swift').write_text('// extra\n')
            return 0
        self.assertNotEqual(self.execute(watchdog=add), 0)
        self.assertEqual(len(self.calls), 1)

    def test_success_receipt_requires_nullable_fields_and_exact_numeric_types(self):
        mutations = [
            lambda r: r.pop('failure'), lambda r: r.pop('waitError'),
            lambda r: r.update(exit=False), lambda r: r.update(returnCode=0.0),
            lambda r: r.update(processGroup=91.0),
            lambda r: r['captured']['stderr'].update(received=False),
            lambda r: r['captured']['stderr'].update(discarded=False),
            lambda r: r.update(groupCleanup='exitedLeaderOnly', groupSignalError=True,
                groupQuery=dict(processGroup=91, returnedBytes=4, bufferBytes=1024, members=[91])),
        ]
        for index, mutate in enumerate(mutations):
            with self.subTest(index=index):
                run = self.run / str(index); run.mkdir(); HARNESS.freeze(self.root, run)
                self.calls.clear()
                def malformed(argv):
                    self.fake_watchdog(argv)
                    path = Path(argv[argv.index('--output') + 1]) / 'status.json'
                    receipt = json.loads(path.read_text()); mutate(receipt)
                    path.write_text(json.dumps(receipt)); return 0
                self.assertNotEqual(HARNESS.execute(run, HARNESS.parse_args([]), malformed), 0)
                self.assertEqual(len(self.calls), 1)


    def test_valid_cleanup_branches_and_missing_singleton_fields(self):
        branches = [dict(groupCleanup='signaled', groupSignalError=None, groupQuery=None),
                    dict(groupCleanup='absent', groupSignalError=errno.ESRCH, groupQuery=None),
                    dict(groupCleanup='exitedLeaderOnly', groupSignalError=errno.EPERM,
                         groupQuery=dict(processGroup=91, errorNumber=None, returnedBytes=4,
                                         bufferBytes=1024, members=[91]))]
        for index, branch in enumerate(branches):
            run = self.run / str(index); run.mkdir(); HARNESS.freeze(self.root, run)
            def receipt(argv):
                self.fake_watchdog(argv)
                path = Path(argv[argv.index('--output') + 1]) / 'status.json'
                value = json.loads(path.read_text()); value.update(branch)
                path.write_text(json.dumps(value)); return 0
            self.assertEqual(HARNESS.execute(run, HARNESS.parse_args(['--build-only']), receipt), 0)
        singleton = self.run / '2/toolchain'
        path = singleton / 'status.json'; original = json.loads(path.read_text())
        for key in original['groupQuery']:
            with self.subTest(missing=key):
                value = json.loads(json.dumps(original)); value['groupQuery'].pop(key)
                path.write_text(json.dumps(value))
                self.assertFalse(HARNESS.receipt_success(singleton, original['command']))
        path.write_text(json.dumps(original))

    def test_extra_symlink_is_rejected_without_following_it(self):
        manifest = self.freeze()
        (self.run / 'Package/Sources/PadCore/Extra.swift').symlink_to(self.root / 'Sources/PadCore/Core.swift')
        with self.assertRaises(ValueError):
            HARNESS.verify_frozen(self.run, manifest)


if __name__ == '__main__':
    unittest.main()
