"""Pure fixed-command contracts; synthetic archives, no compiler/native child."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

HERE = Path(__file__).absolute().parent
RUNNER = HERE / 'run_native_approval_regressions.py'
if RUNNER.is_file():
    spec = importlib.util.spec_from_file_location('approval_runner_contract', RUNNER)
    runner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runner)
else:
    runner = None

PROVIDERS = (
    'NativeApprovalEventBoundaryOracle.swift', 'NativeNestedStringApprovalTests.swift',
    'NativeVetoHandoffNegativeTests.swift', 'NativeCaretApprovalHistoryTests.swift',
    'NativeApprovalControllerAccess.swift', 'NativeApprovalBrokerAccess.swift',
)
DECLARING = ('EditorWindowController.swift', 'DocumentTextView.swift', 'EditorDocument.swift',
             'DocumentCommitTextStorage.swift', 'ApprovedViewCommitBroker.swift',
             'NativeMacroCommitContext.swift', 'SearchPanelController.swift',
             'TextUtilitiesController.swift')
NATIVE_INPUTS = ('SearchReplacementTests.swift', 'NativeMacroChronologyTests.swift',
                 'MacroChronologyReplayTests.swift', 'NativeMacroStorageTask1ATests.swift',
                 'NativeMacroChronologyAccess.swift', 'run_native_regressions.py',
                 'run_application_language_catalog.py', 'application_language_catalog_proof.py')


class NativeApprovalRunnerContracts(unittest.TestCase):
    def sut(self):
        self.assertIsNotNone(runner, 'Maintained fixed68 runner implementation is required')
        return runner

    def archive(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        paths = ['Sources/PadCore/One.swift', 'Sources/SearchExecution/Two.swift',
                 'Sources/TheOnlyPad/TheOnlyPadApplication.swift', 'scripts/swift.sh',
                 'scripts/run-owned-search-tests.py', 'scripts/test-native-approval-regressions.sh']
        paths += ['Sources/TheOnlyPad/' + name for name in DECLARING]
        paths += ['Tests/NativeIntegration/' + name for name in NATIVE_INPUTS]
        paths += ['Tests/NativeApprovalIntegration/' + name for name in PROVIDERS]
        paths += ['Tests/NativeApprovalIntegration/' + name for name in
                  ('run_native_approval_regressions.py', 'public_capture.py',
                   'test_native_approval_runner.py', 'test_public_capture.py')]
        for name in paths:
            target = root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text('// tiny synthetic archive\n')
        return root

    def testFixedNineStagesAndLiteralNative19Union(self):
        r = self.sut();plan = r.fixed_plan()
        self.assertEqual(plan['stages'], ['toolchain', 'build', 'binpath', 'positive',
                                         'search32', 'native19', 'nested8', 'negative7', 'caret2'])
        native = next(row for row in plan['selections'] if row['stage'] == 'native19')
        self.assertEqual(len(native['classes']), 6)
        self.assertEqual(sum(len(c['methods']) for c in native['classes']), 19)
        self.assertIn('testActualControlledEntryInsideThirtyTwoProcessingScopesPreservesSharedCapacity',
                      [m for c in native['classes'] for m in c['methods']])

    def testExactSixtyEightUniqueWithOnlyMandatoryPositiveOverlap(self):
        plan = self.sut().fixed_plan()
        pairs = [(c['class'], m) for row in plan['selections'] for c in row['classes'] for m in c['methods']]
        self.assertEqual((len(set(pairs)), len(pairs)), (68, 69))
        self.assertEqual([r['stage'] for r in plan['selections'] if r['mandatoryPositive']], ['positive'])
        plan['selections'][0]['classes'][0]['methods'].clear()
        self.assertEqual(len(self.sut().fixed_plan()['selections'][0]['classes'][0]['methods']), 1)

    def testNoSelectorOrSourceOverrideArguments(self):
        r = self.sut();r.validate_cli([])
        for argv in [['nested8'], ['--source', '/tmp'], ['--skip-build'], ['--filter', 'All']]:
            with self.subTest(argv=argv), self.assertRaises(ValueError):r.validate_cli(argv)

    def testCleanArchiveDiscoversCurrentSourcesWithoutGitOrIgnoredInputs(self):
        r = self.sut();root = self.archive();plan = r.discover(root)
        self.assertFalse((root / '.git').exists());self.assertFalse((root / '.local').exists())
        self.assertIn('Sources/TheOnlyPad/TheOnlyPadApplication.swift', plan['sourcePaths'])
        self.assertNotIn('Sources/TheOnlyPad/TheOnlyPadApplication.swift', plan['packageSources'])
        for name in PROVIDERS:self.assertIn('Tests/NativeApprovalIntegration/' + name, plan['inputs'])
        self.assertFalse(any('.local' in p or '.git' in p for p in plan['inputs']))
        (root / 'Sources/PadCore/NewCurrent.swift').write_text('// current membership\n')
        self.assertIn('Sources/PadCore/NewCurrent.swift', r.discover(root)['sourcePaths'])

    def testArchiveRefusesMissingRequiredDeclaringSourceAndProvider(self):
        r = self.sut()
        for relative in ['Sources/TheOnlyPad/EditorDocument.swift',
                         'Tests/NativeApprovalIntegration/NativeVetoHandoffNegativeTests.swift']:
            root = self.archive();(root / relative).unlink()
            with self.subTest(relative=relative), self.assertRaises((ValueError, OSError)):r.discover(root)

    def testArchiveRefusesSymlinkedSourceAndAncestor(self):
        r = self.sut();root = self.archive();target = root / 'Sources/PadCore/One.swift'
        target.unlink();target.symlink_to(root / 'Sources/SearchExecution/Two.swift')
        with self.assertRaises((ValueError, OSError)):r.discover(root)
        root = self.archive();folder = root / 'Sources/PadCore';(folder / 'One.swift').unlink();folder.rmdir()
        folder.symlink_to(root / 'Sources/SearchExecution', target_is_directory=True)
        with self.assertRaises((ValueError, OSError)):r.discover(root)

    def testArchiveRefusesCaseFoldedPackageCollision(self):
        r = self.sut();root = self.archive()
        # Different source directories must not flatten into one declaring module name.
        (root / 'Sources/TheOnlyPad/Sub').mkdir()
        (root / 'Sources/TheOnlyPad/Sub/editorwindowcontroller.swift').write_text('// collision\n')
        with self.assertRaises(ValueError):r.discover(root)

    def testSnapshotRefusesSameBytesReplacementAndAddedSource(self):
        r = self.sut();root = self.archive();captured = r.snapshot(root, r.discover(root)['inputs'])
        r.verify_snapshot(root, captured)
        target = root / 'Sources/PadCore/One.swift';data = target.read_bytes();target.unlink();target.write_bytes(data)
        with self.assertRaises(ValueError):r.verify_snapshot(root, captured)
        root = self.archive();captured = r.snapshot(root, r.discover(root)['inputs'])
        (root / 'Sources/PadCore/Added.swift').write_text('// new\n')
        with self.assertRaises(ValueError):r.verify_snapshot(root, captured)

    def testProviderEquationUsesOnlyExactMarkersAndOrderedPublicClients(self):
        r = self.sut();search = b'original\n'
        for name in ['CONTROLLER', 'PANEL', 'UTILITY']:
            search += ('// SEARCH-' + name + '-ACCESS-BEGIN\nremoved\n// SEARCH-' + name + '-ACCESS-END').encode()
        data = {'Tests/NativeIntegration/SearchReplacementTests.swift': search}
        names = PROVIDERS[:4]
        for index, name in enumerate(names):data['Tests/NativeApprovalIntegration/' + name] = ('part' + str(index)).encode()
        actual = r.combine_search(data)
        self.assertEqual(actual, b'original\n' + b'part0part1part2part3')
        self.assertNotIn(b'removed', actual)
        data['Tests/NativeIntegration/SearchReplacementTests.swift'] += b'// SEARCH-CONTROLLER-ACCESS-BEGIN\n'
        with self.assertRaises(ValueError):r.combine_search(data)

    def testRawProjectionProofReplaysBothDirectionsAndRefusesMutation(self):
        r = self.sut();before = b'a\xf0\x9f\x98\x80z\n';after = b'a\xf0\x9f\x98\x80new\n'
        proof = r.raw_proof(before, after);r.verify_raw_proof(before, after, proof)
        with self.assertRaises(ValueError):r.verify_raw_proof(before, after + b'foreign', proof)
        broken = dict(proof);broken['originalSHA256'] = '0' * 64
        with self.assertRaises(ValueError):r.verify_raw_proof(before, after, broken)

    def testDeclaredMethodCensusRejectsMissingForeignAndDuplicateControls(self):
        r = self.sut();classes = [dict(**{'class': 'ExampleTests'}, methods=['testOne', 'testTwo'])]
        data = b'class ExampleTests: XCTestCase {\n func testOne() {}\n func testTwo() {}\n}\n'
        r.validate_methods(data, classes)
        for changed in [data.replace(b'testTwo', b'testForeign'), data.replace(b'func testTwo() {}', b''), data + b'func testOne() {}\n']:
            with self.subTest(changed=changed), self.assertRaises(ValueError):r.validate_methods(changed, classes)

    def testCleanArchiveFreezeUsesRealPinnedHelpersAndOnlySevenProjections(self):
        r = self.sut();root = self.archive()
        # Read tracked support only; no Git, donor packets, compiler or native work.
        support = next(parent for parent in HERE.parents
                       if all((parent / relative).is_file() for relative in r.DRIVERS))
        for relative in [*r.DRIVERS, 'Tests/NativeIntegration/NativeMacroChronologyAccess.swift',
                         *['Tests/NativeIntegration/' + name for name in r.TEST_CLIENTS],
                         *['Sources/TheOnlyPad/' + name for name in DECLARING]]:
            (root / relative).write_bytes((support / relative).read_bytes())
        plan = r.fixed_plan()
        for name, stage in zip(PROVIDERS[:4], [None, 'nested8', 'negative7', 'caret2']):
            data = '// Synthetic pure provider grammar; never compiled.\n'
            if stage:
                for item in next(s for s in plan['selections'] if s['stage'] == stage)['classes']:
                    data += 'class ' + item['class'] + ': XCTestCase {\n'
                    data += ''.join('func ' + method + '() {}\n' for method in item['methods'])
                    data += '}\n'
            (root / 'Tests/NativeApprovalIntegration' / name).write_text(data)
        captured = r.snapshot(root, r.discover(root)['inputs'])
        run = root / 'fresh-owned-output';run.mkdir(mode=0o700)
        h, native, manifest = r.freeze(root, run, captured)
        self.assertFalse((root / '.git').exists());self.assertFalse((root / '.local').exists())
        self.assertEqual(len(manifest['derivations']), 7)
        native.verify(run, manifest)
        self.assertEqual((run / 'Package/Sources/NativeRouting/DocumentTextView.swift').read_bytes(),
                         (root / 'Sources/TheOnlyPad/DocumentTextView.swift').read_bytes())
        for row in manifest['derivations']:
            r.verify_raw_proof((run / row['origin']).read_bytes(),
                               (run / row['target']).read_bytes(), row['proof'])
        original = run / 'Package/Sources/PadCore/One.swift'
        original.write_bytes(original.read_bytes() + b'foreign')
        with self.assertRaises(ValueError):native.verify(run, manifest)
        (root / 'Sources/PadCore/One.swift').write_text('changed live input\n')
        with self.assertRaises(ValueError):r.verify_snapshot(root, captured)

    def testStrictTwentyFieldShapeNeverAcceptsMissingExtraOrAmbiguousCounters(self):
        r = self.sut();receipt = {key: None for key in r.FIELDS}
        receipt['seconds'] = 0.1
        receipt['captured'] = {name: dict(stored=0, received=0, discarded=0)
                               for name in ('stdout', 'stderr')}
        self.assertEqual(len(receipt), 20)
        r.receipt_shape(receipt)  # Shape alone grants no completion/native authority.
        for value in [True, float('nan'), -1]:
            bad = dict(receipt, seconds=value)
            with self.assertRaises(ValueError):r.receipt_shape(bad)
        bad = dict(receipt);del bad['pid']
        with self.assertRaises(ValueError):r.receipt_shape(bad)
        with self.assertRaises(ValueError):r.receipt_shape(dict(receipt, extra=True))
        bad = dict(receipt, captured={'stdout': {'stored': 0}, 'stderr': {}})
        with self.assertRaises(ValueError):r.receipt_shape(bad)

    def testStateCustodyRejectsRetainedFileAndForeignRoot(self):
        r = self.sut();root = self.archive();state = root / 'State';state.mkdir()
        for name in r.fixed_plan()['stages']:(state / name).mkdir()
        r.verify_state(root)
        (state / 'nested8/retained').write_text('synthetic retained custody')
        with self.assertRaises(ValueError):r.verify_state(root)
        (state / 'nested8/retained').unlink()
        (state / 'foreign').mkdir()
        with self.assertRaises(ValueError):r.verify_state(root)

    def testWrapperHasOwnRootAndNoOuterWatchdogOrBuildPath(self):
        self.sut();wrapper = HERE.parents[1] / 'scripts/test-native-approval-regressions.sh'
        text = wrapper.read_text()
        self.assertIn('dirname -- "$0"', text)
        self.assertIn('run_native_approval_regressions.py', text)
        self.assertNotIn('run-owned-search-tests.py', text)
        self.assertNotIn('--build-path', text)


if __name__ == '__main__':
    unittest.main()
