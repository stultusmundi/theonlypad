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

OLD_STAGE_NAMES = ('toolchain', 'build', 'binpath', 'positive', 'search32', 'native19', 'nested8', 'negative7', 'caret2')
OLD_SELECTIONS = [{'stage': 'positive', 'classes': [{'class': 'SearchReplacementTests', 'methods': ['testRealDelegateReplaceAllPreservesSingleStepUnicodeUndoRedo']}], 'timeout': 90, 'mandatoryPositive': True}, {'stage': 'search32', 'classes': [{'class': 'SearchReplacementTests', 'methods': ['testSameLengthDelegateEditRefusesStaleReplaceAll', 'testDetachedDelegateTargetRefusesReplacement', 'testSavingDuringDelegateRefusesReplacement', 'testEditThenRestoreDuringDelegateStillRefusesOldRevision', 'testDelegateRefusalPreservesTextAndExistingUndo', 'testRealDelegateReplaceAllPreservesSingleStepUnicodeUndoRedo', 'testRealDelegateBookkeepingIsNotCommittedAfterUndoBoundaryReentry', 'testPendingSameTextDelegateEditRefusesUnprocessedMutation', 'testPostDelegateAuthorityCallbackPreservesOwnUndoAndMacroOnly', 'testNestedIdenticalDelegateCallKeepsItsOwnMacroAndUndo', 'testSuccessfulReplacementCommitsBookmarksAndOneMacroWithUndo', 'testUndoGroupCallbackCannotPublishPreparedSearchBookkeeping', 'testJSONSuccessAllowsSelectionChangeAndRetainsSingleUndo', 'testReplaySuccessRetainsActionBookmarksAndSingleUndo', 'testReplayRefusesReentrantNativeDelegateTextChange', 'testReplayRefusesOriginalCancellationDuringNativeDelegate', 'testReplayPreservesNewerOperationAfterAdmissionCallback', 'testTextUtilityUnicodePartialSuccessPreservesRangeBookmarksAndUndo', 'testTextUtilityPartialNoOpRetainsExistingBookmarkBookkeepingSemantics', 'testJSONActualCompletionRefusesReentrantDelegateTextChange', 'testLineEndingSuccessRetainsMinimalMacroAndSingleUndo', 'testTextUtilityRefusesReentrantNativeTextChange', 'testTextUtilityRefusesSelectionChangeDuringNativeDelegate', 'testAsyncCommandSuccessRetainsSelectionMacroAndUndo', 'testNoOpAsyncCommandSuccessStillInstallsResultSelection', 'testLineEndingConversionRefusesNewerOperationAfterAdmissionCallback', 'testAsyncCommandRefusesSelectionChangedDuringNativeDelegate', 'testNoOpAsyncCommandPreservesNewerOperationAndCaret', 'testPartialUnicodeTransformPreservesMacroRangeBookmarksAndSingleUndo', 'testInvalidPartialRangesRefuseBeforeDelegateOrMacro', 'testScalarBoundaryInsideGraphemeRemainsEditableAndNoOpWrapperRefuses', 'testDocumentTransformRefusesReentrantEditWithoutPublishingOuterMacro']}], 'timeout': 180, 'mandatoryPositive': False}, {'stage': 'native19', 'classes': [{'class': 'NativeMacroChronologyTests', 'methods': ['testChronologicalUnicodeReplacementUndoRedoPayloadsAndReplay', 'testChronologicalLengthChangingUndoContinueInvalidatesRedo', 'testChronologicalPreRecordingHistoryAndBookmarkOnlyReplay', 'testChronologicalGroupedAndCoalescedEditsReplayActualText', 'testRejectedFallbackNativeInsertionPublishesNoGhostMacroCommand', 'testDeniedNativeUndoLeavesChronologicalStreamAndTextUnchanged', 'testRefusedSearchProposalPreservesChronologicalPrefixAndCallbackEdits']}, {'class': 'NativeMacroApprovedViewReceiptTests', 'methods': ['testForeignExactApprovedWriteAppendsOnceWithoutCallerAttribution', 'testFalseOuterDecisionCannotApproveLaterRawWrite', 'testTrueNoWriteDecisionExpiresWhenHistoryInvocationReturns', 'testTrueDecisionCannotApproveDifferentReplacementPayload', 'testExtraPendingNilAfterControllerPermissionBurnsApproval', 'testPendingNilValueNilABAPreservesTextButNotRecordingApproval']}, {'class': 'NativeMacroApprovedViewCapacityTests', 'methods': ['testThirtyThirdRealProcessingBarrierDoesNotExceedCombinedCapacity', 'testRejectedPairRethrowsOnceAndRestoresActualStacks']}, {'class': 'NativeMacroApprovedViewPayloadTests', 'methods': ['testExactUTF16DelegateRequestAcknowledgesActualBookkeeping', 'testCanonicalEquivalentDifferentUTF16DelegateCannotAuthenticateBookkeeping']}, {'class': 'NativeMacroStrictExplicitCapacityTests', 'methods': ['testActualStrictEntryInsideThirtyTwoProcessingScopesPreservesSharedCapacity']}, {'class': 'NativeMacroControlledExplicitCapacityTests', 'methods': ['testActualControlledEntryInsideThirtyTwoProcessingScopesPreservesSharedCapacity']}], 'timeout': 180, 'mandatoryPositive': False}, {'stage': 'nested8', 'classes': [{'class': 'NativeMacroNestedStringReplacementTests', 'methods': ['testActualConcreteRangeChildRecordsOnceAndLeavesUsableOriginalAuthority', 'testChildNativeVetoHasOnePermissionNoFallbackAndKeepsLawfulParent', 'testRawCharacterWriteInSameAdmissionStillDisclosesIncompleteInterval', 'testRealEmptyStopAndRestartProtectNewEpochFromOldParent', 'testUnicodeReplacementCaretHistoryAndBookmarksMatchActualNonrecordingTwin', 'testSiblingChildrenKeepChronologicalCommandsAndOneNativeEventUndoWithoutOuter', 'testActualGrandchildCommitRejectsBothStaleAncestorsWithoutClearingIt', 'testSharedRealProcessingCapacityKeepsTextOnceAndMarksMissingRecording']}], 'timeout': 180, 'mandatoryPositive': False}, {'stage': 'negative7', 'classes': [{'class': 'NativeVetoHandoffNegativeTests', 'methods': ['testControllerReplacementWithoutChildHasNoHandoff', 'testGenuineVetoCannotAuthorizeForeignSuccessor', 'testGenuineVetoCannotAuthorizeNilSuccessor', 'testConfigurationRefusalBeforeNativePermissionHasNoVetoReceipt', 'testGenuineVetoCannotSurviveRawTextRevisionABA', 'testGenuineVetoCannotSurviveRealEmptyRecorderEpochABA', 'testSecondRecognizedNativeVetoCannotReplaceFirstWindowDisposition']}], 'timeout': 180, 'mandatoryPositive': False}, {'stage': 'caret2', 'classes': [{'class': 'NativeCaretApprovalHistoryTests', 'methods': ['testOwnerReentryRefusesCaretWithoutAddingGhostToSeededUndo', 'testOwnerReentryRefusesCaretWithoutDestroyingSeededRedo']}], 'timeout': 180, 'mandatoryPositive': False}]
TRANSFER_PROVIDERS = ('TransferPreferredResponderTests.swift', 'TransferPreferredControllerAccess.swift',
                      'TransferPreferredOwnerAccess.swift', 'TransferPreferredNativeFocusHook.swift')
TRANSFER_CLASS = 'TransferPreferredResponderTests'
TRANSFER_METHODS = ['testActualPreferredResponderAndHistoryAcrossThreeTinyLayouts', 'testExactStagedPreferredRefusalRestoresOriginalResponderAndHistory', 'testDeclaredFalseSuccessWithoutInstallingResponderMustRestore', 'testRealFocusCallbackEndpointRetirementCannotGrantMutationAndRetriesExactly', 'testRollbackPreferredRefusalRetainsThenExactReleasedRetryRestores', 'testDefaultOrdinaryHostStillFocusesAndEditsWithoutTransferScope']
TRANSFER_SELECTION = {'stage': 'transfer6', 'classes': [{'class': TRANSFER_CLASS, 'methods': TRANSFER_METHODS}],
                      'timeout': 180, 'mandatoryPositive': False}
FOCUS_BRANCH = b'    if let controller = windowController as? EditorWindowController,\n      let result = TransferPreferredNativeHook.beforeFocus?(controller, responder) { return result }\n'


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
        paths += ['Sources/TheOnlyPad/' + name for name in (*DECLARING, 'NativeApplicationDocuments.swift')]
        paths += ['Tests/NativeIntegration/' + name for name in NATIVE_INPUTS]
        paths += ['Tests/NativeApprovalIntegration/' + name for name in (*PROVIDERS, *TRANSFER_PROVIDERS)]
        paths += ['Tests/NativeIntegration/DocumentSearchEditorBindingAccess.swift']
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
        self.assertEqual(plan['stages'][:9], ['toolchain', 'build', 'binpath', 'positive',
                                         'search32', 'native19', 'nested8', 'negative7', 'caret2'])
        native = next(row for row in plan['selections'] if row['stage'] == 'native19')
        self.assertEqual(len(native['classes']), 6)
        self.assertEqual(sum(len(c['methods']) for c in native['classes']), 19)
        self.assertIn('testActualControlledEntryInsideThirtyTwoProcessingScopesPreservesSharedCapacity',
                      [m for c in native['classes'] for m in c['methods']])

    def testExactSixtyEightUniqueWithOnlyMandatoryPositiveOverlap(self):
        plan = self.sut().fixed_plan()
        pairs = [(c['class'], m) for row in plan['selections'] if row['stage'] in OLD_STAGE_NAMES for c in row['classes'] for m in c['methods']]
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
                         *['Sources/TheOnlyPad/' + name for name in (*DECLARING, 'NativeApplicationDocuments.swift')],
                         'Tests/NativeIntegration/DocumentSearchEditorBindingAccess.swift',
                         *['Tests/NativeApprovalIntegration/' + name for name in TRANSFER_PROVIDERS]]:
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
        self.assertEqual(len([row for row in manifest['derivations']
                              if Path(row['target']).name != 'NativeApplicationDocuments.swift']), 7)
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

class PublicTransferRunnerContracts(unittest.TestCase):
    """Prospective contracts; no coordinator main/compiler/native execution."""
    sut = NativeApprovalRunnerContracts.sut
    archive = NativeApprovalRunnerContracts.archive

    def extension(self):
        r = self.sut()
        self.assertTrue(callable(getattr(r, 'compose_transfer', None)),
                        'Public transfer compose_transfer API is required')
        return r

    def seed_archive(self):
        root = self.archive()
        support = next(parent for parent in HERE.parents
                       if all((parent / relative).is_file() for relative in self.sut().DRIVERS))
        paths = [*self.sut().DRIVERS,
                 *['Sources/TheOnlyPad/' + name for name in (*DECLARING, 'NativeApplicationDocuments.swift')],
                 *['Tests/NativeIntegration/' + name for name in NATIVE_INPUTS
                   if name.endswith('.swift')],
                 'Tests/NativeIntegration/DocumentSearchEditorBindingAccess.swift',
                 *['Tests/NativeApprovalIntegration/' + name for name in (*PROVIDERS, *TRANSFER_PROVIDERS)]]
        for relative in paths:
            (root / relative).write_bytes((support / relative).read_bytes())
        return root

    def freeze_archive(self):
        r = self.extension();root = self.seed_archive()
        captured = r.snapshot(root, r.discover(root)['inputs'])
        run = root / 'fresh-owned-output';run.mkdir(mode=0o700)
        h, native, manifest = r.freeze(root, run, captured)
        return r, root, run, h, native, manifest

    def testFullPlanAppendsExactActualClassSchemaWithoutChangingOldSubplan(self):
        r = self.extension();plan = r.fixed_plan()
        self.assertEqual(plan['stages'], [*OLD_STAGE_NAMES, 'transfer6'])
        self.assertEqual(r.FIXED_STAGES, plan['stages'])
        self.assertEqual(r.TIMEOUTS, {'toolchain': 30, 'build': 180, 'binpath': 30, 'positive': 90,
                                    'search32': 180, 'native19': 180, 'nested8': 180, 'negative7': 180,
                                    'caret2': 180, 'transfer6': 180})
        self.assertEqual(plan['selections'][:-1], OLD_SELECTIONS)
        self.assertEqual(plan['selections'][-1], TRANSFER_SELECTION)
        self.assertEqual(set(plan['selections'][-1]), {'stage', 'classes', 'timeout', 'mandatoryPositive'})
        self.assertEqual(set(plan['selections'][-1]['classes'][0]), {'class', 'methods'})
        pairs = [(c['class'], m) for stage in plan['selections'] for c in stage['classes'] for m in c['methods']]
        self.assertEqual((len(set(pairs)), len(pairs)), (74, 75))
        self.assertEqual([s['stage'] for s in plan['selections'] if s['mandatoryPositive']], ['positive'])
        self.assertEqual((plan['uniqueMethods'], plan['occurrences']), (74, 75))
        plan['selections'][-1]['classes'][0]['methods'].clear()
        self.assertEqual(r.fixed_plan()['selections'][-1], TRANSFER_SELECTION)

    def testNewDiscoveryRequiresExactlyPublicProvidersManagedAccessAndOwner(self):
        r = self.extension();root = self.archive();plan = r.discover(root)
        expected_support = {*r.DRIVERS, 'scripts/swift.sh', 'scripts/test-native-approval-regressions.sh',
            *['Tests/NativeIntegration/' + name for name in NATIVE_INPUTS],
            'Tests/NativeIntegration/DocumentSearchEditorBindingAccess.swift',
            *['Tests/NativeApprovalIntegration/' + name for name in (*PROVIDERS, *TRANSFER_PROVIDERS)],
            *['Tests/NativeApprovalIntegration/' + name for name in
              ('run_native_approval_regressions.py', 'public_capture.py', 'test_public_capture.py', 'test_native_approval_runner.py')]}
        self.assertEqual(set(plan['inputs']), set(plan['sourcePaths']) | expected_support)
        self.assertIn('NativeApplicationDocuments.swift', r.DECLARING)
        self.assertIn('Sources/TheOnlyPad/NativeApplicationDocuments.swift', plan['packageSources'])
        self.assertFalse((root / '.git').exists());self.assertFalse((root / '.local').exists())
        self.assertFalse(any('.local' in name or '.git' in name for name in plan['inputs']))
        for relative in [*['Tests/NativeApprovalIntegration/' + name for name in TRANSFER_PROVIDERS],
                         'Tests/NativeIntegration/DocumentSearchEditorBindingAccess.swift',
                         'Sources/TheOnlyPad/NativeApplicationDocuments.swift']:
            fresh = self.archive();(fresh / relative).unlink()
            with self.subTest(relative=relative), self.assertRaises((ValueError, OSError)):r.discover(fresh)

    def testStandaloneCompositionIsWholeImportsHeadedProviderWithExactSixMethods(self):
        r = self.extension();raw = (HERE / TRANSFER_PROVIDERS[0]).read_bytes()
        data = {'Tests/NativeApprovalIntegration/' + TRANSFER_PROVIDERS[0]: raw}
        self.assertEqual(r.compose_transfer(data), raw)
        self.assertEqual(raw.count(b'import AppKit\n'), 1)
        self.assertEqual(raw.count(b'@testable import NativeRouting\n'), 1)
        self.assertNotIn(b'XMLNativeObservation', raw)
        self.assertNotIn(b'class XMLAppFormattingTests', raw)
        r.validate_methods(raw, TRANSFER_SELECTION['classes'])
        invalid = [raw.replace(TRANSFER_METHODS[0].encode(), b'testForeign', 1),
                   raw.replace(('  func ' + TRANSFER_METHODS[0]).encode(), b'  func unselected', 1),
                   raw + ('\nclass ForeignTests: XCTestCase {func testOther() {}}\n').encode(),
                   raw + ('\nfunc ' + TRANSFER_METHODS[0] + '() {}\n').encode()]
        for value in invalid:
            with self.subTest(value=value[-100:]), self.assertRaises(ValueError):
                r.compose_transfer({next(iter(data)): value})

    def testCleanPublicArchiveFreezeAddsStandaloneClientAndOnlyEightProjections(self):
        r, root, run, h, native, manifest = self.freeze_archive()
        self.assertFalse((root / '.git').exists());self.assertFalse((root / '.local').exists())
        self.assertEqual({Path(row['target']).name for row in manifest['derivations']},
                         {'EditorWindowController.swift', 'ApprovedViewCommitBroker.swift', 'EditorDocument.swift',
                          'DocumentCommitTextStorage.swift', 'NativeMacroCommitContext.swift', 'SearchPanelController.swift',
                          'TextUtilitiesController.swift', 'NativeApplicationDocuments.swift'})
        self.assertEqual(len(manifest['derivations']), 8)
        standalone = run / 'Package/Tests/NativeRoutingTests/TransferPreferredResponderTests.swift'
        self.assertEqual(standalone.read_bytes(), (HERE / TRANSFER_PROVIDERS[0]).read_bytes())
        combined = (run / 'Package/Tests/NativeRoutingTests/SearchReplacementTests.swift').read_bytes()
        self.assertEqual(combined, r.combine_search({name: (root / name).read_bytes()
                                                  for name in r.discover(root)['inputs']}))
        self.assertNotIn(b'class TransferPreferredResponderTests', combined)
        for name in NATIVE_INPUTS[1:4]:
            self.assertEqual((run / 'Package/Tests/NativeRoutingTests' / name).read_bytes(),
                             (root / 'Tests/NativeIntegration' / name).read_bytes())
        for relative, target in r.discover(root)['packageSources'].items():
            if Path(relative).name not in {Path(row['target']).name for row in manifest['derivations']}:
                self.assertEqual((run / target).read_bytes(), (root / relative).read_bytes())
        native.verify(run, manifest);r.verify_snapshot(root, r.snapshot(root, r.discover(root)['inputs']))

    def testActualAdmissionWindowHookPreservesWholeOriginalNilPathAndUniqueTails(self):
        r, root, run, h, native, manifest = self.freeze_archive()
        before = (root / 'Sources/TheOnlyPad/EditorWindowController.swift').read_bytes()
        after = (run / 'Package/Sources/NativeRouting/EditorWindowController.swift').read_bytes()
        start = b'@MainActor private final class EditorAdmissionWindow: NSWindow {'
        end = b'@MainActor\nfinal class EditorWindowController:'
        self.assertEqual(before.count(start), 1);self.assertEqual(after.count(start), 1)
        original_window = before[before.index(start):before.index(end)]
        actual_window = after[after.index(start):after.index(end)]
        self.assertEqual(actual_window.count(FOCUS_BRANCH), 1)
        self.assertEqual(actual_window.replace(FOCUS_BRANCH, b'', 1), original_window)
        self.assertIn(FOCUS_BRANCH + b'    guard !checkingFocusAdmission else { return false }', actual_window)
        parts = [(root / 'Tests/NativeIntegration/DocumentSearchEditorBindingAccess.swift').read_bytes(),
                 (HERE / TRANSFER_PROVIDERS[1]).read_bytes(), (HERE / TRANSFER_PROVIDERS[3]).read_bytes()]
        for value in parts:self.assertEqual(after.count(value), 1)
        self.assertEqual([after.index(value) for value in parts], sorted(after.index(value) for value in parts))
        self.assertIn(b'var xmlNativeTestPreparingToQuit: Bool { preparingToQuit }', parts[1])
        self.assertIn(b'let result = TransferPreferredNativeHook.beforeFocus?', FOCUS_BRANCH)
        self.assertNotIn(b'invalidateXMLFormatting', after)

    def testMissingChangedOrRepeatedNativeFocusAnchorRefusesInsteadOfGuessing(self):
        r, root, run, h, native, manifest = self.freeze_archive()
        captured = r.snapshot(root, r.discover(root)['inputs'])
        data = {name: raw for name, (raw, _) in captured.items()}
        relative = 'Sources/TheOnlyPad/EditorWindowController.swift';before = data[relative]
        header = b'override func makeFirstResponder(_ responder: NSResponder?) -> Bool {'
        anchor = b'    guard !checkingFocusAdmission else { return false }'
        for value in [before.replace(b'class EditorAdmissionWindow:', b'class ForeignAdmissionWindow:', 1),
                      before.replace(header, b'override func changedResponder(_ responder: NSResponder?) -> Bool {', 1),
                      before.replace(anchor, b'    guard false else { return false }', 1),
                      before.replace(anchor, anchor + b'\n' + anchor, 1)]:
            changed = dict(data);changed[relative] = value
            with self.subTest(value=value[before.index(header):][:100]), self.assertRaises(ValueError):
                r.compose(changed, native, r.discover(root)['packageSources'])

    def testOwnerProviderAppendsOnlyRealStoredFactsAndEveryProjectionHasDualInverse(self):
        r, root, run, h, native, manifest = self.freeze_archive()
        before = (root / 'Sources/TheOnlyPad/NativeApplicationDocuments.swift').read_bytes()
        tail = (HERE / TRANSFER_PROVIDERS[2]).read_bytes()
        after = (run / 'Package/Sources/NativeRouting/NativeApplicationDocuments.swift').read_bytes()
        self.assertEqual(after, before + b'\n' + tail)
        self.assertEqual(after.count(b'var transferPreferredTestQuitFacts:'), 1)
        self.assertEqual(after.count(b'var transferPreferredRetirementTestFacts:'), 1)
        self.assertNotIn(b'allowRetired', tail)
        for row in manifest['derivations']:
            old = (run / row['origin']).read_bytes();new = (run / row['target']).read_bytes()
            r.verify_raw_proof(old, new, row['proof'])
            with self.subTest(target=row['target']), self.assertRaises(ValueError):
                r.verify_raw_proof(old, new + b'foreign', row['proof'])

    def testNewProviderAndManagedAccessIdentityMembershipSymlinkAndCaseControls(self):
        r = self.extension()
        names = ['Tests/NativeApprovalIntegration/' + TRANSFER_PROVIDERS[0],
                 'Tests/NativeIntegration/DocumentSearchEditorBindingAccess.swift']
        for name in names:
            root = self.archive();captured = r.snapshot(root, r.discover(root)['inputs'])
            path = root / name;data = path.read_bytes();path.unlink();path.write_bytes(data)
            with self.subTest(name=name), self.assertRaises(ValueError):r.verify_snapshot(root, captured)
            root = self.archive();path = root / name;path.unlink()
            path.symlink_to(root / 'Sources/PadCore/One.swift')
            with self.subTest(symlink=name), self.assertRaises((ValueError, OSError)):r.discover(root)
        root = self.archive();captured = r.snapshot(root, r.discover(root)['inputs'])
        (root / 'Tests/NativeApprovalIntegration' / TRANSFER_PROVIDERS[1]).unlink()
        with self.assertRaises((ValueError, OSError)):r.verify_snapshot(root, captured)
        root = self.archive();captured = r.snapshot(root, r.discover(root)['inputs'])
        (root / 'Sources/TheOnlyPad/NewTransferSource.swift').write_text('// unexpected membership\n')
        with self.assertRaises(ValueError):r.verify_snapshot(root, captured)
        root = self.archive();(root / 'Sources/TheOnlyPad/Sub').mkdir()
        (root / 'Sources/TheOnlyPad/Sub/nativeapplicationdocuments.swift').write_text('// collision\n')
        with self.assertRaises(ValueError):r.discover(root)

    def testUnqualifiedHelperIsRejectedBeforeAnyFrozenHelperImport(self):
        r = self.extension();root = self.seed_archive()
        relative = next(iter(r.DRIVERS));path = root / relative
        path.write_bytes(path.read_bytes() + b'\n# substituted helper\n')
        captured = r.snapshot(root, r.discover(root)['inputs']);run = root / 'refused-output';run.mkdir(mode=0o700)
        with self.assertRaises(ValueError):r.freeze(root, run, captured)
        self.assertFalse((run / 'Runner').exists())

    def testTransferStateAndStrictReceiptControlsHaveNoIncompleteAcceptance(self):
        r = self.extension();root = self.archive();state = root / 'State';state.mkdir()
        for name in r.fixed_plan()['stages']:(state / name).mkdir()
        r.verify_state(root)
        (state / 'transfer6/retained').write_text('synthetic unresolved ownership')
        with self.assertRaises(ValueError):r.verify_state(root)
        receipt = {key: None for key in r.FIELDS};receipt['seconds'] = 0.1
        receipt['captured'] = {name: dict(stored=0, received=0, discarded=0) for name in ('stdout', 'stderr')}
        r.receipt_shape(receipt);self.assertEqual(len(receipt), 20)
        for bad in [dict(receipt, extra=True), {key: value for key, value in receipt.items() if key != 'waitCompleted'},
                    dict(receipt, seconds=True), dict(receipt, seconds=float('inf'))]:
            with self.subTest(bad=bad), self.assertRaises(ValueError):r.receipt_shape(bad)

    def testRealParserSixCaseCapsulesKeepOrdinaryAssertionsDistinctFromUnknown(self):
        self.extension()
        from public_capture import parse_result
        from test_public_capture import transcript
        classes = TRANSFER_SELECTION['classes'];valid = transcript(classes)
        self.assertEqual(parse_result(valid, 0, classes)['executed'], 6)
        failed = transcript(classes, failed={TRANSFER_METHODS[2]: 2})
        result = parse_result(failed, 1, classes)
        self.assertEqual((result['executed'], result['failures'], result['unexpected'], result['exit']), (6, 2, 0, 1))
        damaged = [valid.replace(TRANSFER_METHODS[0].encode(), b'testForeign'),
                   valid.replace(b"' passed (0.001 seconds).", b"' skipped (0.001 seconds).", 1),
                   b'\n'.join(line for line in valid.splitlines() if not (TRANSFER_METHODS[0].encode() in line and b' passed ' in line)),
                   next(line for line in valid.splitlines(True) if b'Test Case' in line) + valid,
                   transcript(classes, failed={TRANSFER_METHODS[0]: 1}, unexpected=1)]
        for index, raw in enumerate(damaged):
            with self.subTest(index=index), self.assertRaises(ValueError):parse_result(raw, 1 if index == 4 else 0, classes)
        with self.assertRaises(ValueError):parse_result(valid, 0, [{'className': TRANSFER_CLASS, 'methods': TRANSFER_METHODS}])

    def testNoNewCliSourcePrivateProviderPrebuiltOrExtraWatchdogEntry(self):
        r = self.extension()
        for argv in [['transfer6'], ['--source', 'Candidate'], ['--provider', '.local/donor'],
                     ['--skip-build'], ['--build-path', 'prebuilt'], ['--filter', TRANSFER_CLASS]]:
            with self.subTest(argv=argv), self.assertRaises(ValueError):r.validate_cli(argv)
        import ast
        source = RUNNER.read_text();tree = ast.parse(source)
        execute = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == 'execute')
        text = ast.get_source_segment(source, execute)
        self.assertIn("'retained oracle custody; incomplete'", text)
        self.assertIn("'unresolved State custody after child'", text)
        self.assertIn("state='INCOMPLETE', exit=125", text)
        self.assertIn("'nonzero compiler/toolchain stage; not behavioral RED'", text)
        self.assertIn("'native_approval_watchdog').main", text)
        self.assertIn("if name == 'binpath':", text)
        self.assertIn('h.capture(run, manifest)', text)
        self.assertIn("if selection['mandatoryPositive']", text)
        self.assertNotIn('subprocess.', source)
        self.assertNotIn('os.system(', source)
        self.assertNotIn('Popen(', source)

    def testFullCensusFieldDoesNotRedefineExistingSixtyEightSubplanMeaning(self):
        r = self.extension()
        import ast
        source = RUNNER.read_text();tree = ast.parse(source)
        execute = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == 'execute')
        assigned = {}
        for node in ast.walk(execute):
            if isinstance(node, ast.Assign):
                for target in node.targets:
                    if isinstance(target, ast.Subscript) and isinstance(target.value, ast.Name) and target.value.id == 'result':
                        try:key = ast.literal_eval(target.slice)
                        except (ValueError, TypeError):continue
                        assigned[key] = ast.get_source_segment(source, node.value)
        self.assertIn('completeFixedMethodCensus', assigned)
        self.assertIn('complete68MethodCensus', assigned)
        self.assertNotEqual(assigned['complete68MethodCensus'], "result['targetEntered']")
        self.assertEqual(r.fixed_plan()['selections'][:-1], OLD_SELECTIONS)


if __name__ == '__main__':
    unittest.main()
