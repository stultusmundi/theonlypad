"""Frozen hidden native regressions with one accepted same-process watchdog owner."""
import argparse
import errno
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import shlex
import stat
import sys
import tempfile

SUITES={'folder-navigation':('FolderNavigationTests','folder-navigation-tests'),
        'help':('HelpReferenceTests','help-reference-tests'),
        'search-replacement':('SearchReplacementTests','search-replacement-tests'),
        'settings':('DocumentAppliedSettingsTests','document-applied-settings-tests'),
        'transfer':('EditorDocumentTransferTests','native-document-transfer-tests'),
        'projection':('EditorTransferProjectionTests','editor-transfer-projection-tests'),
        'close':(None,'native-close-model'),
        'macro':('NativeMacroChronologyTests','native-macro-chronology-tests'),
        'managed-admission':('NativeManagedAdmissionStartupTests','managed-admission-tests'),
        'managed-documents':('AppDelegateDocumentsTests','managed-documents-tests'),
        'document-search':('DocumentSearchEditorIntegrationTests','document-search-integration'),
        'document-search-app':('DocumentSearchAppRoutingTests','document-search-app-integration'),
        'document-text-storage':('DocumentTextStorageTests','document-text-storage-integration'),
        'document-search-real-helper':('DocumentSearchRealHelperIntegrationTests','document-search-real-helper-integration')}
CLOSE_SOURCES=('EditorDocument','EditorDocumentCloseAdapter','EditorDocumentFactory',
    'NativeDocumentSeed','EditorDocumentWorkspaceAdapter','WorkspaceDocumentRegistryTypes',
    'EditorPane','DocumentTextView','DocumentPanePresentation','EditorPaneHost',
    'NativeSyntaxHighlighter','LineNumberRuler','DocumentFileStateController','FileMonitorClient')
CLOSE_HARNESSES=('NativeCloseModelHarness','DocumentFactoryHarness','SharedPaneOwnershipHarness')
FIXED=('scripts/swift.sh','scripts/run-owned-search-tests.py',
       'scripts/test-native-document-transfer.sh','scripts/test-editor-transfer-projection.sh',
       'scripts/test-native-close-model.sh','Tests/NativeIntegration/run_native_regressions.py',
       'Tests/NativeIntegration/test_native_regressions.py')
SHARED_MARKER='PASS shared storage/undo, exact Unicode, revisions, selections, bounded detach/reattach, lifetime'
PACKAGE='''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name:"NativeRouting", platforms:[.macOS(.v14)], targets:[.target(name:"PadCore"),.target(name:"SearchExecution",dependencies:["PadCore"]),.target(name:"NativeRouting",dependencies:["PadCore","SearchExecution"]),.testTarget(name:"NativeRoutingTests",dependencies:["NativeRouting","PadCore"])],swiftLanguageModes:[.v5])
'''


MACRO_TESTS=('MacroChronologyReplayTests','NativeMacroChronologyTests','NativeMacroStorageTask1ATests')
MACRO_ACCESS=('ApprovedViewCommitBroker.swift','DocumentCommitTextStorage.swift',
              'EditorDocument.swift','EditorWindowController.swift','NativeMacroCommitContext.swift')
MACRO_CLASSES={'NativeMacroApprovedViewCapacityTests':2,'NativeMacroApprovedViewPayloadTests':2,
               'NativeMacroApprovedViewReceiptTests':6,'NativeMacroChronologyTests':7,
               'NativeMacroControlledExplicitCapacityTests':1,'NativeMacroStrictExplicitCapacityTests':1}
MACRO_SELECTOR='|'.join(MACRO_CLASSES)
MACRO_ACCESS_FILE='Tests/NativeIntegration/NativeMacroChronologyAccess.swift'
ADMISSION_TESTS=('NativeManagedAdmissionStartupTests','EditorApplicationRoutingTests')
ADMISSION_ACCESS={'EditorWindowController.swift':'ManagedAdmissionControllerAccess.swift',
                  'EditorDocument.swift':'ManagedAdmissionHistoryAccess.swift'}
ADMISSION_METHODS={
    ('NativeManagedAdmissionStartupTests','testActualEmptyOwnerStartupRetainsViewAndHistoryRouting'),
    ('NativeManagedAdmissionStartupTests','testActualPlainFileOwnerStartupRetainsViewAndHistoryRouting'),
    ('NativeManagedAdmissionCallbackTests','testActualEndpointCallbackSuccessorSurvivesOuterAdmissionRefusal'),
    ('NativeManagedAdmissionCallbackTests','testActualPostPreservationCloseTicketRevokesRoutingOnOuterRefusal')}
ADMISSION_CLASSES={'NativeManagedAdmissionStartupTests':2,'NativeManagedAdmissionCallbackTests':2}
ADMISSION_SELECTOR='|'.join(ADMISSION_CLASSES)


# Fixed complete six-file managed regression selection; no caller roster/filter.
MANAGED_DOCUMENT_FILE_METHODS={'AppDelegateDocumentsTests.swift': (('AppDelegateDocumentsTests',
                                      'testStartupUsesOneOwnerAndActualManagedScratch'),
                                     ('AppDelegateDocumentsTests',
                                      'testLaunchRequestsQueuedBeforeStartupUseActualFIFOAndPositions'),
                                     ('AppDelegateDocumentsTests',
                                      'testFinderAndLaunchRequestsShareBoundedPrestartupQueueAndQuitRefusal'),
                                     ('AppDelegateDocumentsTests',
                                      'testSettingsAreAppliedAfterManagedStartupAndUnreadyToolsRefuse'),
                                     ('AppDelegateDocumentsTests',
                                      'testActualTerminationDelegateUsesOwnerFinalReceipt'),
                                     ('AppDelegateDocumentsTests',
                                      'testFinalWriteFailureVetoesAndRestoresMonitoringThenCanRetry'),
                                     ('AppDelegateDocumentsTests',
                                      'testLargeViewerPositionRefusesBeforeAnyWindowPresentation'),
                                     ('AppDelegateDocumentsTests',
                                      'testResolvedImportCannotNotifyOrEraseNewerPanelAttempt'),
                                     ('AppDelegateDocumentsTests',
                                      'testResolvedImportCannotNotifyNewerRequestInSamePanel')),
 'NativeApplicationDocumentsTests.swift': (('NativeApplicationDocumentsTests',
                                            'testEmptyStartupCreatesOneActualManagedScratchWindow'),
                                           ('NativeApplicationDocumentsTests',
                                            'testRestoresFilesInOrderAndSelectedPinThroughFinalCheckpoint'),
                                           ('NativeApplicationDocumentsTests',
                                            'testRetryDuringHeldStartupCannotCreateCompetingScratch'),
                                           ('NativeApplicationDocumentsTests',
                                            'testNativeCloseAndReopenCommandsUseOneOwnerAndFreshRecoveryAuthority'),
                                           ('NativeApplicationDocumentsTests',
                                            'testUnresolvedFileRetryUsesManagedClaimAndNewWindowUsesSamePublisher'),
                                           ('NativeApplicationDocumentsTests',
                                            'testExternalFIFOQueuesBeforeStartupAndPositionsEachExactDocument'),
                                           ('NativeApplicationDocumentsTests',
                                            'testWindowCapacityIncludesUnresolvedReservationsBeforeCreatingEndpoint'),
                                           ('NativeApplicationDocumentsTests',
                                            'testFullUnresolvedDocumentBudgetDoesNotAllocateAnotherScratch'),
                                           ('NativeApplicationDocumentsTests',
                                            'testCheckpointRetryRecreatesLostEndpointWithoutReplacingDirtyModel')),
 'EditorApplicationRoutingTests.swift': (('EditorApplicationRoutingTests',
                                          'testScratchUsesRealIntakeRegistryAndPublisher'),
                                         ('EditorApplicationRoutingTests',
                                          'testOpenCompletionWaitsForActualIntakeProjection'),
                                         ('EditorApplicationRoutingTests',
                                          'testDuplicateBackupAndExistingMissingURLUseOwnedModels'),
                                         ('EditorApplicationRoutingTests',
                                          'testNoOpProjectionPreservesCaretUndoStorageAndProcessObserver'),
                                         ('EditorApplicationRoutingTests',
                                          'testStaleEndpointBeforeIntakeRegistrationFailsOpenExactlyOnce'),
                                         ('EditorApplicationRoutingTests',
                                          'testProjectionRefusesStaleWrongEndpointAndInactiveOwnership'),
                                         ('EditorApplicationRoutingTests',
                                          'testPreparedSessionSeedUsesActualClaimAndExactPresentation'),
                                         ('EditorApplicationRoutingTests',
                                          'testRealPreparedDiskCopyTransfersBeforeOperationFinishes'),
                                         ('EditorApplicationRoutingTests',
                                          'testRegistryCloseLeaseRefusesPaneAndCommandMutation'),
                                         ('EditorApplicationRoutingTests',
                                          'testUserGateDoesNotBlockProjectionOrFrozenCapture'),
                                         ('EditorApplicationRoutingTests',
                                          'testCloseAdmissionPreservesSemanticStateAndCleanHistory'),
                                         ('EditorApplicationRoutingTests',
                                          'testSaveChooserReentryCannotWriteAfterCloseLease'),
                                         ('EditorApplicationRoutingTests',
                                          'testDirtyCloseCancelAndStaleConfirmationKeepBuffer'),
                                         ('EditorApplicationRoutingTests',
                                          'testActualNativeSelectionAndUndoStayFrozenUnderLease'),
                                         ('EditorApplicationRoutingTests',
                                          'testHistoryProjectionToSurvivingTabPreservesRetiredPresentation'),
                                         ('EditorApplicationRoutingTests',
                                          'testEmptyWindowPermitClosesOnlyEmptyExactEndpoint'),
                                         ('EditorApplicationRoutingTests',
                                          'testUnconfirmedPublicationCannotCloseEvenAtSavedText'),
                                         ('EditorApplicationRoutingTests',
                                          'testNativeResourceValidationAndLegacyDrainDoNotCaptureOrWrite'),
                                         ('EditorApplicationRoutingTests',
                                          'testProjectionCannotGrantUserEditAdmissionDuringCallback'),
                                         ('EditorApplicationRoutingTests',
                                          'testEmptyClosePermitRejectsRevisionChangeDuringEndpointCheck'),
                                         ('EditorApplicationRoutingTests',
                                          'testProjectionCallbackCannotFocusUnrelatedPaneWithUserGateClosed'),
                                         ('EditorApplicationRoutingTests',
                                          'testRecreatedEndpointReattachesSameModelMonitorAndParentContinuity'),
                                         ('EditorApplicationRoutingTests',
                                          'testUserCanCloseOnlyAnActuallyEmptyRegistryWindow'),
                                         ('EditorApplicationRoutingTests',
                                          'testAsyncReopenWaitsForWorkerPreparationBeforeRealIntakeID'),
                                         ('EditorApplicationRoutingTests',
                                          'testRetainedNativeIntakeNeedsExplicitNewEndpointReconciliation'),
                                         ('EditorApplicationRoutingTests',
                                          'testSuccessfulReattachIsNotRepeatedAfterLaterProjectionValidationFails'),
                                         ('EditorApplicationRoutingTests',
                                          'testManagedNavigationCompletesExactUnicodePositionWithUserGateClosed'),
                                         ('EditorApplicationRoutingTests',
                                          'testManagedNavigationRejectsChangedSelectionDuringWorker'),
                                         ('EditorApplicationRoutingTests',
                                          'testManagedNavigationRejectsEditAndEndpointLossDuringWorker'),
                                         ('EditorApplicationRoutingTests',
                                          'testManagedNavigationRefusesRegistryCloseLeaseAfterWorker'),
                                         ('EditorApplicationRoutingTests',
                                          'testManagedNavigationNeverUsesDifferentCurrentDocument'),
                                         ('EditorApplicationRoutingTests',
                                          'testManagedNavigationRefusesPendingCharacterBatchBeforeRevisionAdvances'),
                                         ('NativeManagedAdmissionCallbackTests',
                                          'testActualEndpointCallbackSuccessorSurvivesOuterAdmissionRefusal'),
                                         ('NativeManagedAdmissionCallbackTests',
                                          'testActualPostPreservationCloseTicketRevokesRoutingOnOuterRefusal')),
 'NativeDocumentIntakeTests.swift': (('NativeDocumentIntakeTests',
                                      'testNativeSeedCreatesManagedModelAndPairedRecovery'),
                                     ('NativeDocumentIntakeTests',
                                      'testLostEndpointReconcilesSameModelAndAuthority'),
                                     ('NativeDocumentIntakeTests',
                                      'testProjectionEndpointLossRetainsInsteadOfReportingImported'),
                                     ('NativeDocumentIntakeTests',
                                      'testReconciliationRejectsRecreatedOldEndpointAndChangedOwnership'),
                                     ('NativeDocumentIntakeTests',
                                      'testPreparedInsertionIndexPreservesRequestedTabOrder'),
                                     ('NativeDocumentIntakeTests',
                                      'testMissingEndpointRefusesBeforeNativeFactory')),
 'NativeApplicationOpenTests.swift': (('NativeApplicationOpenTests',
                                       'testActualSeedIntakeAndAwaitedNavigationBeforeNextRequest'),
                                      ('NativeApplicationOpenTests',
                                       'testRetainedIntakeAndNavigationRetryDoNotReadOrSubmitAgain'),
                                      ('NativeApplicationOpenTests',
                                       'testExistingRequiredPortAvoidsReadAndUsesSameDocumentRetry'),
                                      ('NativeApplicationOpenTests',
                                       'testAggregateCapacityStartupAndQuitDrainPreserveCurrent'),
                                      ('NativeApplicationOpenTests',
                                       'testDescriptorRejectsDirectoryAndLargeFilePreservesNavigationRequest'),
                                      ('NativeApplicationOpenTests',
                                       'testDestinationChangedAfterWorkerReadRefusesBeforeSubmission'),
                                      ('NativeApplicationOpenTests',
                                       'testActualRetainedProjectionRetriesSameAdoptedModelAfterSourceRemoval'),
                                      ('NativeApplicationOpenTests',
                                       'testErrorCallbackObservesSettledFailureAndCanRetrySynchronously'),
                                      ('NativeApplicationOpenTests',
                                       'testClosedPositionTargetAdvancesButIntakeFailureNeverAbandons'),
                                      ('NativeApplicationOpenTests',
                                       'testInvalidNativeLinePreservesImportedModelAndAdvancesQueue')),
 'NativeApplicationCloseTests.swift': (('NativeApplicationCloseTests',
                                        'testNativeCleanClosePreservesHistoryAndProjectsEmptyWindow'),
                                       ('NativeApplicationCloseTests',
                                        'testNativeDirtyCancelPreservesModelAndUndo'),
                                       ('NativeApplicationCloseTests',
                                        'testNativeDirtyDiscardDeletesWithoutHistory'),
                                       ('NativeApplicationCloseTests',
                                        'testEndpointLossAfterDeletionRetainsUntilExactReprojection'),
                                       ('NativeApplicationCloseTests',
                                        'testRealActorDeletionFailureRepairsNativeModelAndReopensAdmission'))}
MANAGED_DOCUMENT_METHODS={method for methods in MANAGED_DOCUMENT_FILE_METHODS.values() for method in methods}
MANAGED_DOCUMENT_ACCESS={
    'AppDelegate.swift':'AppDelegateDocumentsAccess.swift',
    'SessionRestorationController.swift':'AppDelegateSessionPanelAccess.swift',
    'EditorWindowController.swift':'ManagedAdmissionControllerAccess.swift',
    'EditorDocument.swift':'ManagedAdmissionHistoryAccess.swift'}


# Fixed native editor search integration: no caller roster/filter or body probes.
DOCUMENT_SEARCH_METHODS=(
    ('DocumentSearchEditorBindingTests', 'testManagedFindCapturesOriginalNativeSourceWithoutEarlyTextCapture'),
    ('DocumentSearchEditorBindingTests', 'testTwoManagedEditorsShareOwnerWithDistinctWindowTickets'),
    ('DocumentSearchEditorBindingTests', 'testTabAndFocusChangesPreserveOriginalResultBinding'),
    ('DocumentSearchEditorBindingTests', 'testRealOriginRemovalAndTransferRequireFreshDestinationBinding'),
    ('DocumentSearchEditorBindingTests', 'testOriginalWindowAndEndpointRetireExactlyTheirSearchTicket'),
    ('DocumentSearchEditorBindingTests', 'testFactoryAndPresentationReentryPreserveNewerConcreteChild'),
    ('DocumentSearchTransferCloseNoSearchTests', 'testRealTransferThenCloseWithoutAnySearchInvocation'),
    ('FileStateDetachmentPhaseTests', 'testRealDetachPhasePreservesOuterScopeAcrossRecursiveRefusal'),
    ('FileStateDetachmentPhaseTests', 'testRealIdentityGuardErrorClearsPhaseAndPreservesRetry'),
    ('FileStateDetachmentPhaseTests', 'testRealCancellationInvalidationThrowsAndClearsAdmittedPhase'),
    ('ManagedTransferCloseRetirementTests', 'testRealRetiringBoundarySuspensionPreservesExactMovedBridgeUntilDetach'),
    ('DocumentSearchQuitPresentationTests', 'testQuitPresentationRetirementWithoutChildStaysLazy'),
    ('DocumentSearchQuitPresentationTests', 'testQuitPresentationRetiresOnlyOriginalChildAndPreservesLiveWindowTickets'),
    ('DocumentSearchQuitPresentationTests', 'testQuitPresentationCloseAndConstructorReentryCannotAdoptAChild'),
    ('DocumentSearchQuitPresentationTests', 'testQuitPresentationRetiredEndpointCannotBeRevivedByLateCallbacks'),
)
DOCUMENT_SEARCH_CLASSES=('DocumentSearchEditorBindingTests', 'DocumentSearchTransferCloseNoSearchTests', 'FileStateDetachmentPhaseTests', 'ManagedTransferCloseRetirementTests', 'DocumentSearchQuitPresentationTests')
DOCUMENT_SEARCH_SELECTOR='|'.join(DOCUMENT_SEARCH_CLASSES)
DOCUMENT_SEARCH_ACCESS={
    'EditorWindowController.swift':'DocumentSearchEditorBindingAccess.swift',
    'NativeApplicationDocuments.swift':'DocumentSearchNativeOwnerAccess.swift',
    'NativeApplicationCloseCoordinator.swift':'DocumentSearchNativeCloseAccess.swift',
    'DocumentSearchPanelController.swift':'DocumentSearchPanelAccess.swift'}

# Fixed App routing contract; no editor-repair observer access or caller selection.
DOCUMENT_SEARCH_APP_METHODS=(
    ('DocumentSearchAppRoutingTests', 'testCapturedSearchPanelClaimsOnlyCloseAndSixNativeEditingSelectors'),
    ('DocumentSearchAppRoutingTests', 'testCapturedSearchAvailabilityAndDispatchShareIdentityAndRefusalPolicy'),
    ('DocumentSearchAppRoutingTests', 'testActualManagedConfigurationStaysSearchLazyAndAppGuardsPrecedeScope'),
    ('DocumentSearchAppRoutingTests', 'testActualQuitPublishesNativeReceiptThenJoinsSearchAndExternalExactlyOnceAcrossVetoAndRetry'),
)
DOCUMENT_SEARCH_APP_CLASSES=('DocumentSearchAppRoutingTests',)
DOCUMENT_SEARCH_APP_SELECTOR='|'.join(DOCUMENT_SEARCH_APP_CLASSES)
DOCUMENT_SEARCH_APP_ACCESS={
    'AppDelegate.swift':'DocumentSearchAppRoutingAccess.swift',
    'EditorWindowController.swift':'DocumentSearchEditorBindingAccess.swift',
    'NativeApplicationDocuments.swift':'DocumentSearchAppNativeOwnerAccess.swift',
    'DocumentSearchPanelController.swift':'DocumentSearchPanelAccess.swift'}

# Fixed storage public-API contract; raw Source only and no access tails.
DOCUMENT_TEXT_STORAGE_METHODS=(
    ('DocumentTextStorageTests', 'testSameLengthMutationABAAndNoOp'),
    ('DocumentTextStorageTests', 'testRetainedOldSnapshotImmutability'),
    ('DocumentTextStorageTests', 'testMutableStringAdapterInvalidatesSnapshot'),
    ('DocumentTextStorageTests', 'testAttributedReplacementInvalidatesSnapshot'),
    ('DocumentTextStorageTests', 'testAttributeOnlyChangesPreserveText'),
    ('DocumentTextStorageTests', 'testDeleteReinsertUnicode'),
    ('DocumentTextStorageTests', 'testRepeated32NSStringReadsRetainAtMostOneIdentity'),
)
DOCUMENT_TEXT_STORAGE_CLASSES=('DocumentTextStorageTests',)
DOCUMENT_TEXT_STORAGE_SELECTOR='DocumentTextStorageTests'

REAL_HELPER_PACKAGE='// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(\n  name: "NativeRouting", platforms: [.macOS(.v14)],\n  products: [.executable(name: "PadSearchWorker", targets: ["PadSearchWorker"])],\n  targets: [\n    .target(name: "PadCore"), .target(name: "SearchExecution", dependencies: ["PadCore"]),\n    .target(name: "PadSearchWorkerRuntime", dependencies: ["PadCore", "SearchExecution"]),\n    .executableTarget(\n      name: "PadSearchWorker", dependencies: ["PadSearchWorkerRuntime", "SearchExecution"]),\n    .target(name: "NativeRouting", dependencies: ["PadCore", "SearchExecution"]),\n    .testTarget(\n      name: "NativeRoutingTests", dependencies: ["NativeRouting", "PadCore", "SearchExecution"]),\n  ], swiftLanguageModes: [.v5])\n'

REAL_HELPER_CLASS='DocumentSearchRealHelperIntegrationTests'
REAL_HELPER_METHODS=(
    'testRealBundledHelperFindReplaceUndoAndApplicationJoinedQuit',
    'testRealHelperMalformedRegexRefusesAndSamePanelCanRetryThenJoinedQuit',
    'testRealHelperReplacementApprovalRefusesAfterNativeEditUndoABAThenJoinedQuit')
REAL_HELPER_STAGES=('test-happy','test-invalid-pattern','test-stale-approval')
REAL_HELPER_MODULES=('PadCore','SearchExecution','PadSearchWorkerRuntime','PadSearchWorker',
    'NativeRouting','NativeRoutingTests','NativeRoutingPackageTests')
REAL_HELPER_WORKER_MODULES=REAL_HELPER_MODULES[:4]
REAL_HELPER_TEST_MODULES=('PadCore','SearchExecution','NativeRouting','NativeRoutingTests','NativeRoutingPackageTests')

def real_helper_methods(data):
    """Fixed class plus same-file extension census, not a general Swift parser."""
    owner=None;classes=[];methods=[]
    pattern=r'\bclass\s+(\w+)\s*:\s*XCTestCase\b|\bextension\s+(\w+)\s*\{|\bfunc\s+(test\w+)\s*\('
    for match in re.finditer(pattern,data.decode()):
        if match.group(1):
            owner=match.group(1);classes.append(owner)
        elif match.group(2): owner=match.group(2)
        else:
            if owner!=REAL_HELPER_CLASS: raise ValueError('real helper method outside exact class')
            methods.append((owner,match.group(3)))
    expected=[(REAL_HELPER_CLASS,name) for name in REAL_HELPER_METHODS]
    if classes!=[REAL_HELPER_CLASS] or methods!=expected:
        raise ValueError('fixed real helper method census changed')
    return methods

def real_helper_success(text,selected_method):
    if selected_method not in REAL_HELPER_METHODS: raise ValueError('foreign helper selection')
    if re.search(r'(?m)^.*(?:error:|caught error:|warning:)|\b[1-9][0-9]* unexpected\b',text):
        raise ValueError('real helper error or warning record')
    counts=[tuple(map(int,pair)) for pair in re.findall(r'Executed (\d+) tests?, with (\d+) failures',text)]
    if not counts or any(pair!=(1,0) for pair in counts): raise ValueError('incomplete real helper summary')
    terminal=re.findall(r"^Test Case '([^']+)' (passed|failed|skipped)(?: \(.*\)\.)?$",text,re.M)
    expected='-[NativeRoutingTests.'+REAL_HELPER_CLASS+' '+selected_method+']'
    if terminal!=[(expected,'passed')]: raise ValueError('real helper exact case did not pass once')
    if len(re.findall(r"^Test Suite '"+REAL_HELPER_CLASS+r"' passed(?: at .*\.)?$",text,re.M))!=1:
        raise ValueError('real helper class did not pass once')
    return dict(tests=1,failures=0)

def real_helper_owned_path(run,path,directory=False):
    """Owned canonical paths only; no symlink ancestors or special file reads."""
    run,path=Path(run),Path(path)
    if not run.is_absolute() or not path.is_absolute() or '..' in path.parts or not path.is_relative_to(run):
        raise ValueError('real helper path escapes owned run')
    cursor=run
    for part in (None,*path.relative_to(run).parts):
        if part is not None: cursor=cursor/part
        try: value=cursor.lstat()
        except FileNotFoundError as error:
            raise ValueError('missing owned real helper path: '+str(cursor)) from error
        if stat.S_ISLNK(value.st_mode) or value.st_uid!=os.getuid(): raise ValueError('unowned or symlink path')
        if cursor!=path or directory:
            if not stat.S_ISDIR(value.st_mode): raise ValueError('owned directory required')
        elif not stat.S_ISREG(value.st_mode): raise ValueError('owned regular file required')
    return path

def real_helper_artifact(run,path):
    path=real_helper_owned_path(run,path)
    before=path.stat();data=read_real(run,path);after=path.stat()
    signature=lambda s:(s.st_dev,s.st_ino,s.st_uid,s.st_mode,s.st_size,s.st_mtime_ns,s.st_ctime_ns)
    if signature(before)!=signature(after): raise ValueError('artifact changed during read')
    return dict(path=path.relative_to(run).as_posix(),bytes=len(data),sha256=hashlib.sha256(data).hexdigest(),
        device=after.st_dev,inode=after.st_ino,uid=after.st_uid,mode=after.st_mode&0o777)

def real_helper_json(run,path):
    real_helper_owned_path(run,path)
    data=read_real(run,path)
    if len(data)>8*1024*1024: raise ValueError('compiler metadata exceeds bound')
    def unique(pairs):
        result={}
        for key,value in pairs:
            if key in result: raise ValueError('duplicate compiler JSON key')
            result[key]=value
        return result
    return json.loads(data,object_pairs_hook=unique)

def validate_real_helper_compiler_graph(run,binary,manifest):
    """Actual compiler maps and exact two-product unions, before artifact authority."""
    run,binary=Path(run),Path(binary)
    real_helper_owned_path(run,binary,directory=True)
    if not binary.is_relative_to(run/'Build'): raise ValueError('compiler products outside owned Build')
    verify(run,manifest)
    description=real_helper_json(run,binary/'description.json')
    commands=description.get('swiftCommands')
    if not isinstance(commands,dict) or len(commands)!=len(REAL_HELPER_MODULES):
        raise ValueError('unexpected compiler module census')
    groups={}
    for command in commands.values():
        if not isinstance(command,dict): raise ValueError('invalid compiler group')
        module=command.get('moduleName')
        if module not in REAL_HELPER_MODULES or module in groups: raise ValueError('foreign or duplicate module')
        groups[module]=command
    if set(groups)!=set(REAL_HELPER_MODULES): raise ValueError('missing compiler module')
    paths={binary/'description.json'};module_rows=[];memberships=[];objects={};package_names=[]
    for module in REAL_HELPER_MODULES:
        command=groups[module]
        if module=='NativeRoutingPackageTests':
            expected=[binary/'NativeRoutingPackageTests.derived/runner.swift']
        else:
            prefix='Package/'+('Tests/' if module=='NativeRoutingTests' else 'Sources/')+module+'/'
            expected=sorted(run/row['frozen'] for row in manifest['generated']
                if row['frozen'].startswith(prefix) and row['frozen'].endswith('.swift'))
        if not expected or len(set(expected))!=len(expected): raise ValueError('missing or repeated frozen module Source')
        declared=command.get('sources')
        if not isinstance(declared,list) or any(type(x) is not str for x in declared): raise ValueError('invalid compiler Sources')
        if len(set(declared))!=len(declared) or sorted(declared)!=sorted(map(str,expected)):
            raise ValueError('compiler Sources differ from frozen membership')
        for source in expected: real_helper_owned_path(run,source)
        object_paths=[binary/(module+'.build')/(source.name+'.o') for source in expected]
        if len(set(object_paths))!=len(object_paths): raise ValueError('ambiguous Source basenames')
        declared_objects=command.get('objects')
        if not isinstance(declared_objects,list) or any(type(x) is not str for x in declared_objects):
            raise ValueError('invalid compiler objects')
        if len(set(declared_objects))!=len(declared_objects) or sorted(declared_objects)!=sorted(map(str,object_paths)):
            raise ValueError('compiler object pairing differs')
        actual_objects=sorted((binary/(module+'.build')).rglob('*.o'))
        if actual_objects!=sorted(object_paths): raise ValueError('unknown or missing module object')
        for path in object_paths: real_helper_owned_path(run,path)
        filelist=binary/(module+'.build/sources');outputmap=binary/(module+'.build/output-file-map.json')
        module_output=binary/'Modules'/(module+'.swiftmodule')
        if (command.get('fileList')!=str(filelist) or command.get('outputFileMapPath')!=str(outputmap)
            or command.get('moduleOutputPath')!=str(module_output)):
            raise ValueError('compiler output path changed')
        real_helper_owned_path(run,filelist)
        listed=shlex.split(read_real(run,filelist).decode())
        if len(listed)!=len(set(listed)) or sorted(listed)!=sorted(declared): raise ValueError('compiler filelist differs')
        mapping=real_helper_json(run,outputmap)
        if not isinstance(mapping,dict) or set(mapping)!={*declared,''}: raise ValueError('compiler outputmap Source census differs')
        for source,obj in zip(expected,object_paths):
            value=mapping[str(source)]
            if not isinstance(value,dict) or value.get('object')!=str(obj): raise ValueError('compiler Source/object map differs')
        arguments=command.get('otherArguments')
        if not isinstance(arguments,list) or any(type(x) is not str for x in arguments): raise ValueError('invalid compiler flags')
        def operand(flag):
            if arguments.count(flag)!=1 or arguments.index(flag)+1>=len(arguments): raise ValueError('missing/duplicate compiler operand')
            return arguments[arguments.index(flag)+1]
        if operand('-target')!=platform.machine()+'-apple-macosx14.0' or arguments.count('-warnings-as-errors')!=1:
            raise ValueError('compiler target or Werror changed')
        if module!='NativeRoutingPackageTests' or '-swift-version' in arguments:
            if operand('-swift-version')!='5': raise ValueError('authored compiler language changed')
        package_name=operand('-package-name')
        if not re.fullmatch(r'[A-Za-z0-9_]{1,128}',package_name): raise ValueError('invalid compiler package identity')
        package_names.append(package_name)
        companions=[binary/'Modules'/(module+suffix) for suffix in ('.swiftmodule','.swiftdoc','.swiftsourceinfo','.abi.json')]
        if sorted((binary/'Modules').glob(module+'.*'))!=sorted(companions): raise ValueError('module companion membership differs')
        for path in companions: real_helper_owned_path(run,path)
        paths.update([*object_paths,filelist,outputmap,*companions])
        if module=='NativeRoutingPackageTests':
            derived=binary/'NativeRoutingPackageTests.derived'
            if sorted(derived.rglob('*.swift'))!=expected: raise ValueError('generated entry Source membership differs')
            paths.update(expected)
            memberships.append(dict(root=derived.relative_to(run).as_posix(),pattern='*.swift',
                paths=[x.relative_to(run).as_posix() for x in expected]))
        objects[module]=object_paths
        memberships.append(dict(root=(binary/(module+'.build')).relative_to(run).as_posix(),pattern='*.o',
            paths=sorted(x.relative_to(run).as_posix() for x in object_paths)))
        module_rows.append(dict(module=module,sources=list(map(str,expected)),objects=list(map(str,object_paths)),
            generatedEntry=module=='NativeRoutingPackageTests',swiftVersionExplicit='-swift-version' in arguments))
    if len(set(package_names))!=1: raise ValueError('compiler package identity disagreement')
    all_objects=sorted(x for values in objects.values() for x in values)
    if sorted(binary.rglob('*.o'))!=all_objects: raise ValueError('foreign compiled object outside fixed modules')
    memberships.append(dict(root=binary.relative_to(run).as_posix(),pattern='*.o',
        paths=[x.relative_to(run).as_posix() for x in all_objects]))
    expected_modules={binary/'Modules'/(module+suffix) for module in REAL_HELPER_MODULES
        for suffix in ('.swiftmodule','.swiftdoc','.swiftsourceinfo','.abi.json')}
    if set((binary/'Modules').iterdir())!=expected_modules: raise ValueError('foreign module companion')
    memberships.append(dict(root=(binary/'Modules').relative_to(run).as_posix(),pattern='*',
        paths=sorted(x.relative_to(run).as_posix() for x in expected_modules)))
    links=[]
    for product,modules in (('PadSearchWorker',REAL_HELPER_WORKER_MODULES),('NativeRoutingPackageTests',REAL_HELPER_TEST_MODULES)):
        path=binary/(product+'.product/Objects.LinkFileList');real_helper_owned_path(run,path)
        members=shlex.split(read_real(run,path).decode())
        expected=[str(obj) for module in modules for obj in objects[module]]
        if len(set(members))!=len(members) or sorted(members)!=sorted(expected): raise ValueError('product link union differs')
        paths.add(path);links.append(dict(product=product,objects=members))
    helper=binary/'PadSearchWorker';bundle=binary/'NativeRoutingPackageTests.xctest'
    test_binary=bundle/'Contents/MacOS/NativeRoutingPackageTests'
    products=description.get('builtTestProducts')
    if (not isinstance(products,list) or len(products)!=1 or not isinstance(products[0],dict)
        or products[0].get('binaryPath')!=str(test_binary) or products[0].get('packagePath')!=str(run/'Package')
        or products[0].get('productName')!='NativeRoutingPackageTests'):
        raise ValueError('built Test product differs')
    real_helper_owned_path(run,helper);real_helper_owned_path(run,bundle,directory=True);real_helper_owned_path(run,test_binary)
    leaves=sorted(x for x in bundle.rglob('*') if not x.is_dir())
    if len(leaves)!=4: raise ValueError('unexpected Test bundle leaf count')
    symbol=bundle/'Contents/MacOS/NativeRoutingPackageTests.dSYM/Contents'
    required={test_binary,symbol/'Info.plist',symbol/'Resources/DWARF/NativeRoutingPackageTests'}
    remainder=set(leaves)-required
    if not required.issubset(leaves) or len(remainder)!=1: raise ValueError('Test bundle layout differs')
    relocation=next(iter(remainder))
    if re.fullmatch(r'Resources/Relocations/(?:aarch64|x86_64)/NativeRoutingPackageTests.yml',relocation.relative_to(symbol).as_posix()) is None:
        raise ValueError('Test bundle relocation differs')
    for path in leaves: real_helper_owned_path(run,path)
    paths.update([helper,*leaves])
    memberships.append(dict(root=bundle.relative_to(run).as_posix(),pattern='files',
        paths=sorted(x.relative_to(run).as_posix() for x in leaves)))
    return dict(paths=sorted(x.relative_to(run).as_posix() for x in paths),modules=module_rows,links=links,
        membership=memberships,helper=helper.relative_to(run).as_posix(),packageName=package_names[0],
        generatedEntry='NativeRoutingPackageTests.derived/runner.swift',
        sharedObjectCount=len(set(links[0]['objects'])&set(links[1]['objects'])))

def capture_real_helper_build(run,binary_directory,source_manifest_hash):
    run,binary=Path(run),Path(binary_directory)
    if digest(run/'sources.json')!=source_manifest_hash: raise ValueError('source authority changed before capture')
    manifest=real_helper_json(run,run/'sources.json')
    proof=validate_real_helper_compiler_graph(run,binary,manifest)
    artifacts=[real_helper_artifact(run,run/path) for path in proof['paths']]
    if validate_real_helper_compiler_graph(run,binary,manifest)!=proof: raise ValueError('compiler graph changed during capture')
    record=dict(sourceManifestSHA256=source_manifest_hash,helper=proof['helper'],artifacts=artifacts,
        membership=proof['membership'],compiler=proof['modules'],links=proof['links'],
        packageName=proof['packageName'],sharedObjectCount=proof['sharedObjectCount'],
        generatedEntryQualification='generated runner has separately recorded explicit-language flag; authored modules Swift5')
    helper_row=next(x for x in artifacts if x['path']==record['helper'])
    if not helper_row['mode']&0o111: raise ValueError('built helper is not executable')
    path=run/'build-inputs.json'
    with path.open('x') as stream: stream.write(json.dumps(record,indent=2)+'\n')
    path.chmod(0o600)
    verify_real_helper_build(run,record,digest(path))
    return record

def verify_real_helper_build(run,record,expected_record_hash):
    run=Path(run)
    path=run/'build-inputs.json'
    if digest(real_helper_owned_path(run,path))!=expected_record_hash or real_helper_json(run,path)!=record:
        raise ValueError('original build authority changed')
    if digest(real_helper_owned_path(run,run/'sources.json'))!=record['sourceManifestSHA256']:
        raise ValueError('frozen source authority changed')
    rows=record['artifacts']
    if not isinstance(rows,list) or not rows or len({row['path'] for row in rows})!=len(rows):
        raise ValueError('ambiguous artifact authority')
    if sum(row['path']==record['helper'] for row in rows)!=1: raise ValueError('missing exact helper authority')
    for row in rows:
        path=run/row['path']
        if not path.is_relative_to(run/'Build') or real_helper_artifact(run,path)!=row:
            raise ValueError('build artifact changed')
    for item in record.get('membership',[]):
        root=real_helper_owned_path(run,run/item['root'],directory=True)
        if item['pattern']=='files': actual=sorted(x for x in root.rglob('*') if not x.is_dir())
        elif item['pattern'] in ('*.o','*.swift'): actual=sorted(root.rglob(item['pattern']))
        elif item['pattern']=='*': actual=sorted(root.iterdir())
        else: raise ValueError('invalid artifact membership shape')
        if [x.relative_to(run).as_posix() for x in actual]!=item['paths']:
            raise ValueError('artifact membership changed')
        for path in actual: real_helper_owned_path(run,path)

def real_helper_private_directory(run,path):
    path=Path(path)
    if not path.is_relative_to(run) or '..' in path.parts: raise ValueError('private path escape')
    if not path.exists():
        real_helper_private_directory(run,path.parent)
        path.mkdir(mode=0o700)
    real_helper_owned_path(run,path,directory=True)
    if path.stat().st_mode&0o777!=0o700: raise ValueError('private directory must be0700')
    return path

def stage_real_helper(run,stage_name,build_record):
    run=Path(run)
    if stage_name not in REAL_HELPER_STAGES: raise ValueError('foreign helper stage')
    # The caller retains the earlier digest; equality here never replaces that caller check.
    if real_helper_json(run,run/'build-inputs.json')!=build_record: raise ValueError('staging authority differs')
    source=run/build_record['helper']
    rows=[row for row in build_record['artifacts'] if row['path']==build_record['helper']]
    if len(rows)!=1 or real_helper_artifact(run,source)!=rows[0]: raise ValueError('staging original helper changed')
    state=real_helper_private_directory(run,run/'State'/stage_name)
    if list(state.iterdir()): raise ValueError('stage State not empty')
    destination=state/'RealHelperFixture.app/Contents/Helpers/PadSearchWorker'
    real_helper_private_directory(run,destination.parent)
    data=read_real(run,source)
    fd=os.open(destination,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o700)
    with os.fdopen(fd,'wb') as stream: stream.write(data)
    destination.chmod(0o755)
    copied=real_helper_artifact(run,destination)
    if copied['sha256']!=rows[0]['sha256'] or copied['bytes']!=rows[0]['bytes'] or real_helper_artifact(run,source)!=rows[0]:
        raise ValueError('helper copy changed')
    directories=[]
    for path in (state,state/'RealHelperFixture.app',state/'RealHelperFixture.app/Contents',destination.parent):
        s=path.stat();directories.append(dict(path=path.relative_to(run).as_posix(),device=s.st_dev,inode=s.st_ino,uid=s.st_uid,mode=s.st_mode&0o777))
    record=dict(stage=stage_name,buildManifestSHA256=digest(run/'build-inputs.json'),original=rows[0],copied=copied,directories=directories)
    folder=real_helper_private_directory(run,run/'HelperStages');path=folder/(stage_name+'.json')
    with path.open('x') as stream: stream.write(json.dumps(record,indent=2)+'\n')
    path.chmod(0o600)
    result=dict(stage=stage_name,record=record,recordSHA256=digest(path))
    verify_real_helper_fixture(run,result)
    return result

def verify_real_helper_fixture(run,stage_record):
    run=Path(run);name=stage_record['stage']
    if name not in REAL_HELPER_STAGES: raise ValueError('unknown staged helper')
    path=run/'HelperStages'/(name+'.json')
    if digest(real_helper_owned_path(run,path))!=stage_record['recordSHA256'] or real_helper_json(run,path)!=stage_record['record']:
        raise ValueError('helper stage authority changed')
    record=stage_record['record']
    if digest(real_helper_owned_path(run,run/'build-inputs.json'))!=record['buildManifestSHA256']:
        raise ValueError('helper build authority changed after staging')
    for kind in ('original','copied'):
        if real_helper_artifact(run,run/record[kind]['path'])!=record[kind]: raise ValueError('staged helper bytes or identity changed')
    expected=set()
    for row in record['directories']:
        directory=real_helper_owned_path(run,run/row['path'],directory=True);s=directory.stat()
        if dict(path=row['path'],device=s.st_dev,inode=s.st_ino,uid=s.st_uid,mode=s.st_mode&0o777)!=row or row['mode']!=0o700:
            raise ValueError('staged directory identity changed')
        expected.add(directory)
    state=run/'State'/name
    expected.remove(state);expected.add(run/record['copied']['path'])
    if set(state.rglob('*'))!=expected: raise ValueError('unsettled fixture or foreign State content retained')


def execute_real_helper_stages(run,args,watchdog_main):
    run=Path(run);manifest=real_helper_json(run,run/'sources.json');manifest_hash=digest(run/'sources.json')
    result=dict(exit=125,suite=args.suite,stages=[],results={},sourceManifestSHA256=manifest_hash,
        buildProvenance='same frozen Package builds actual worker and XCTest; three separate fixed fresh-state processes')
    authority=None;authority_hash=None
    def check():
        verify(run,manifest)
        if digest(run/'sources.json')!=manifest_hash: raise ValueError('source manifest changed')
        if authority is not None: verify_real_helper_build(run,authority,authority_hash)
    def stage(name,command,timeout,method=None):
        check();state=real_helper_private_directory(run,run/'State'/name)
        temporary=real_helper_private_directory(run,run/'Temporary'/name)
        staged=stage_real_helper(run,name,authority) if method is not None else None
        command=['/usr/bin/env','THEONLYPAD_STATE_DIRECTORY='+str(state),'TMPDIR='+str(temporary)+'/',*map(str,command)]
        output=run/'Stages'/name
        code=watchdog_main(['--timeout',str(timeout),'--output',str(output),'--',*command])
        result['stages'].append(dict(name=name,exit=code,receipt=str((output/'status.json').relative_to(run))))
        check()
        if type(code) is not int or not receipt_success(output,command,code): raise ValueError('incomplete direct stage receipt')
        if code!=0: raise StageFailure(code)
        stdout=(output/'stdout.log').read_text(errors='replace');stderr=(output/'stderr.log').read_text(errors='replace')
        text=stdout+stderr
        if re.search(r'(?im)^.*(?:warning:|error:)',text): raise ValueError('stage warning or error')
        if method is not None:
            result['results'][method]=real_helper_success(text,method)
            verify_real_helper_fixture(run,staged)
            result.setdefault('helperStages',[]).append(staged)
        return stdout
    try:
        stage('toolchain',['/usr/bin/xcrun','swift','--version'],30)
        swift=run/'Original/scripts/swift.sh';common=['--package-path',run/'Package','--scratch-path',run/'Build']
        stage('build',[swift,'build',*common,'--build-tests','-Xswiftc','-warnings-as-errors'],180)
        output=stage('bin-path',[swift,'build',*common,'--show-bin-path'],30)
        lines=output.strip().splitlines()
        if len(lines)!=1: raise ValueError('ambiguous product directory')
        binary=Path(lines[0]);real_helper_owned_path(run,binary,directory=True)
        if not binary.is_relative_to(run/'Build'): raise ValueError('product outside owned Build')
        authority=capture_real_helper_build(run,binary,manifest_hash);authority_hash=digest(run/'build-inputs.json')
        result['buildManifestSHA256']=authority_hash
        for name,method in zip(REAL_HELPER_STAGES,REAL_HELPER_METHODS):
            stage(name,['/usr/bin/xcrun','xctest','-XCTest','NativeRoutingTests.'+REAL_HELPER_CLASS+'/'+method,
                binary/'NativeRoutingPackageTests.xctest'],180,method)
        check();result['exit']=0
    except StageFailure as error: result['exit']=error.code if 0<error.code<256 else 125
    except (OSError,ValueError,TypeError,KeyError,AttributeError) as error:
        result['failure']=type(error).__name__;result['exit']=125
    finally: (run/'status.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result),flush=True)
    return result['exit']


def document_search_methods(data):
    """Exact fixed fixture census; not a general Swift parser."""
    owner=None;classes=[];methods=[]
    for match in re.finditer(r'\bclass\s+(\w+)\s*:\s*XCTestCase\b|\bfunc\s+(test\w+)\s*\(',data.decode()):
        if match.group(1):
            owner=match.group(1);classes.append(owner)
        elif owner: methods.append((owner,match.group(2)))
        else: raise ValueError('document search method lacks fixed XCTest class')
    if tuple(classes)!=DOCUMENT_SEARCH_CLASSES or tuple(methods)!=DOCUMENT_SEARCH_METHODS:
        raise ValueError('fixed document search declaration census changed')
    return methods

def document_search_success(text):
    if re.search(r'(?m)^.*(?:error:|caught error:)|\b[1-9][0-9]* unexpected\b',text):
        raise ValueError('document search error record')
    counts=[tuple(map(int,pair)) for pair in re.findall(r'Executed (\d+) tests?, with (\d+) failures',text)]
    expected=len(DOCUMENT_SEARCH_METHODS)
    if not counts or counts[-1]!=(expected,0) or any(n<=0 or failure for n,failure in counts):
        raise ValueError('missing complete document search result')
    terminal=re.findall(r"^Test Case '([^']+)' (passed|failed|skipped)(?: \(.*\)\.)?$",text,re.M)
    if len(terminal)!=expected or any(result!='passed' for _,result in terminal):
        raise ValueError('incomplete document search cases')
    cases=[]
    for identity,_ in terminal:
        match=re.fullmatch(r'\-\[NativeRoutingTests\.(\w+) (test\w+)\]',identity)
        if match is None: raise ValueError('foreign document search case')
        cases.append(match.groups())
    if len(set(cases))!=expected or set(cases)!=set(DOCUMENT_SEARCH_METHODS):
        raise ValueError('document search exact case selection changed')
    for owner in DOCUMENT_SEARCH_CLASSES:
        if len(re.findall(r"^Test Suite '"+re.escape(owner)+r"' passed(?: at .*\.)?$",text,re.M))!=1:
            raise ValueError('document search class did not pass exactly once')
    return dict(tests=expected,failures=0)

def document_search_app_methods(data):
    """Exact fixed fixture census; not a general Swift parser."""
    owner=None;classes=[];methods=[]
    for match in re.finditer(r'\bclass\s+(\w+)\s*:\s*XCTestCase\b|\bfunc\s+(test\w+)\s*\(',data.decode()):
        if match.group(1):
            owner=match.group(1);classes.append(owner)
        elif owner: methods.append((owner,match.group(2)))
        else: raise ValueError('document search app method lacks fixed XCTest class')
    if tuple(classes)!=DOCUMENT_SEARCH_APP_CLASSES or tuple(methods)!=DOCUMENT_SEARCH_APP_METHODS:
        raise ValueError('fixed document search app declaration census changed')
    return methods

def document_search_app_success(text):
    if re.search(r'(?m)^.*(?:error:|caught error:)|\b[1-9][0-9]* unexpected\b',text):
        raise ValueError('document search app error record')
    counts=[tuple(map(int,pair)) for pair in re.findall(r'Executed (\d+) tests?, with (\d+) failures',text)]
    expected=len(DOCUMENT_SEARCH_APP_METHODS)
    if not counts or counts[-1]!=(expected,0) or any(n<=0 or failure for n,failure in counts):
        raise ValueError('missing complete document search app result')
    terminal=re.findall(r"^Test Case '([^']+)' (passed|failed|skipped)(?: \(.*\)\.)?$",text,re.M)
    if len(terminal)!=expected or any(result!='passed' for _,result in terminal):
        raise ValueError('incomplete document search app cases')
    cases=[]
    for identity,_ in terminal:
        match=re.fullmatch(r'\-\[NativeRoutingTests\.(\w+) (test\w+)\]',identity)
        if match is None: raise ValueError('foreign document search app case')
        cases.append(match.groups())
    if len(set(cases))!=expected or set(cases)!=set(DOCUMENT_SEARCH_APP_METHODS):
        raise ValueError('document search app exact case selection changed')
    for owner in DOCUMENT_SEARCH_APP_CLASSES:
        if len(re.findall(r"^Test Suite '"+re.escape(owner)+r"' passed(?: at .*\.)?$",text,re.M))!=1:
            raise ValueError('document search app class did not pass exactly once')
    return dict(tests=expected,failures=0)

def document_text_storage_methods(data):
    """Exact fixed fixture census; not a general Swift parser."""
    owner=None;classes=[];methods=[]
    for match in re.finditer(r'\bclass\s+(\w+)\s*:\s*XCTestCase\b|\bfunc\s+(test\w+)\s*\(',data.decode()):
        if match.group(1):
            owner=match.group(1);classes.append(owner)
        elif owner: methods.append((owner,match.group(2)))
        else: raise ValueError('document text storage method lacks fixed XCTest class')
    if tuple(classes)!=DOCUMENT_TEXT_STORAGE_CLASSES or tuple(methods)!=DOCUMENT_TEXT_STORAGE_METHODS:
        raise ValueError('fixed document text storage declaration census changed')
    return methods

def document_text_storage_success(text):
    if re.search(r'(?m)^.*(?:error:|caught error:)|\b[1-9][0-9]* unexpected\b',text):
        raise ValueError('document text storage error record')
    counts=[tuple(map(int,pair)) for pair in re.findall(r'Executed (\d+) tests?, with (\d+) failures',text)]
    expected=len(DOCUMENT_TEXT_STORAGE_METHODS)
    if not counts or counts[-1]!=(expected,0) or any(n<=0 or failure for n,failure in counts):
        raise ValueError('missing complete document text storage result')
    terminal=re.findall(r"^Test Case '([^']+)' (passed|failed|skipped)(?: \(.*\)\.)?$",text,re.M)
    if len(terminal)!=expected or any(result!='passed' for _,result in terminal):
        raise ValueError('incomplete document text storage cases')
    cases=[]
    for identity,_ in terminal:
        match=re.fullmatch(r'\-\[NativeRoutingTests\.(\w+) (test\w+)\]',identity)
        if match is None: raise ValueError('foreign document text storage case')
        cases.append(match.groups())
    if len(set(cases))!=expected or set(cases)!=set(DOCUMENT_TEXT_STORAGE_METHODS):
        raise ValueError('document text storage exact case selection changed')
    for owner in DOCUMENT_TEXT_STORAGE_CLASSES:
        if len(re.findall(r"^Test Suite '"+re.escape(owner)+r"' passed(?: at .*\.)?$",text,re.M))!=1:
            raise ValueError('document text storage class did not pass exactly once')
    return dict(tests=expected,failures=0)

def managed_document_methods(data, filename):
    """Fixed fixture declaration census, not a general Swift parser."""
    owner=None;methods=[]
    for match in re.finditer(r'\bclass\s+(\w+)\s*:\s*XCTestCase\b|\bfunc\s+(test\w+)\s*\(',data.decode()):
        if match.group(1): owner=match.group(1)
        elif owner: methods.append((owner,match.group(2)))
        else: raise ValueError('managed test method lacks fixed XCTest class')
    if tuple(methods)!=MANAGED_DOCUMENT_FILE_METHODS[filename]:
        raise ValueError('fixed managed document method census changed')
    return methods

def managed_documents_success(text):
    if re.search(r'(?m)^.*(?:error:|caught error:)|\b[1-9][0-9]* unexpected\b',text):
        raise ValueError('managed document error record')
    counts=[tuple(map(int,pair)) for pair in re.findall(r'Executed (\d+) tests?, with (\d+) failures',text)]
    expected=len(MANAGED_DOCUMENT_METHODS)
    if not counts or counts[-1]!=(expected,0) or any(n<=0 or failure for n,failure in counts):
        raise ValueError('missing complete managed document result')
    terminal=re.findall(r"^Test Case '([^']+)' (passed|failed|skipped)(?: \(.*\)\.)?$",text,re.M)
    if len(terminal)!=expected or any(result!='passed' for _,result in terminal):
        raise ValueError('incomplete managed document cases')
    cases=[]
    for identity,_ in terminal:
        match=re.fullmatch(r'\-\[NativeRoutingTests\.(\w+) (test\w+)\]',identity)
        if match is None: raise ValueError('foreign managed document case')
        cases.append(match.groups())
    if len(set(cases))!=expected or set(cases)!=MANAGED_DOCUMENT_METHODS:
        raise ValueError('managed document case selection changed')
    for name in {owner for owner,_ in MANAGED_DOCUMENT_METHODS}:
        if len(re.findall(r"^Test Suite '"+re.escape(name)+r"' passed(?: at .*\.)?$",text,re.M))!=1:
            raise ValueError('managed document class did not pass exactly once')
    return dict(tests=expected,failures=0)

def digest(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def read_real(root,path):
    root,path=Path(root),Path(path)
    cursor=root
    if root.is_symlink(): raise ValueError('symlink root refused')
    for part in path.relative_to(root).parts:
        cursor=cursor/part
        if cursor.is_symlink(): raise ValueError('symlink input refused')
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
    with os.fdopen(fd,'rb') as stream: return stream.read()

def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    module=importlib.util.module_from_spec(spec);sys.modules[name]=module;spec.loader.exec_module(module)
    return module

def parse_args(argv):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('suite',choices=SUITES)
    parser.add_argument('build_path',nargs='?')
    args=parser.parse_args(argv)
    if args.build_path and args.suite!='close': parser.error('only close accepts an existing debug build path')
    return args

def discover(root,suite,prebuilt):
    paths={root/name for name in FIXED}
    if suite=='folder-navigation': paths.add(root/'scripts/test-folder-navigation.sh')
    if suite=='help': paths.add(root/'scripts/test-help-reference.sh')
    if suite=='settings': paths.add(root/'scripts/test-document-applied-settings.sh')
    if suite=='macro':
        paths.add(root/'scripts/test-native-macro.sh')
        paths.add(root/MACRO_ACCESS_FILE)
    if suite=='managed-admission':
        paths.add(root/'scripts/test-managed-admission.sh')
        paths.update(root/'Tests/NativeIntegration'/name for name in ADMISSION_ACCESS.values())
    if suite=='managed-documents':
        paths.add(root/'scripts/test-managed-documents.sh')
        paths.add(root/'Tests/NativeIntegration/test_managed_documents_runner.py')
        paths.update(root/'Tests/NativeIntegration'/name for name in MANAGED_DOCUMENT_ACCESS.values())
    if suite=='document-search':
        paths.add(root/'scripts/test-document-search.sh')
        paths.add(root/'Tests/NativeIntegration/test_document_search_runner.py')
        paths.update(root/'Tests/NativeIntegration'/name for name in DOCUMENT_SEARCH_ACCESS.values())
    if suite=='document-search-app':
        paths.add(root/'scripts/test-document-search-app.sh')
        paths.add(root/'Tests/NativeIntegration/test_document_search_app_runner.py')
        paths.update(root/'Tests/NativeIntegration'/name for name in DOCUMENT_SEARCH_APP_ACCESS.values())
    if suite=='document-search-real-helper':
        paths.add(root/'scripts/test-document-search-real-helper.sh')
        paths.add(root/'Tests/NativeIntegration/test_document_search_real_helper_runner.py')
        paths.add(root/'Tests/NativeIntegration/expected-Package.swift')
        paths.update(root/'Tests/NativeIntegration'/name for name in DOCUMENT_SEARCH_APP_ACCESS.values())
    if suite=='document-text-storage':
        paths.add(root/'scripts/test-document-text-storage.sh')
        paths.add(root/'Tests/NativeIntegration/test_document_text_storage_runner.py')
    if suite=='search-replacement': paths.add(root/'scripts/test-search-replacement.sh')
    if suite=='document-search-real-helper':
        for module in ('PadCore','SearchExecution','TheOnlyPad','PadSearchWorkerRuntime','PadSearchWorker'):
            paths.update((root/'Sources'/module).glob('*.swift'))
    elif suite in ('document-search-app','document-text-storage'):
        for module in ('PadCore','SearchExecution','TheOnlyPad'):
            paths.update((root/'Sources'/module).glob('*.swift'))
    elif suite!='close' or not prebuilt:
        paths.update((root/'Sources').rglob('*.swift'))
        if suite=='close':
            paths.add(root/'Package.swift')
            for name in ('PadCoreTests','SearchExecutionTests','PadSearchWorkerRuntimeTests'):
                paths.update((root/'Tests'/name).glob('*.swift'))
    else:
        paths.update((root/'Sources/TheOnlyPad').glob('*.swift'))
        paths.update((root/'Sources/PadCore').glob('*.swift'))
        paths.update((root/'Sources/SearchExecution').glob('*.swift'))
    optional=root/'Sources/TheOnlyPad/DocumentAppliedSettings.swift'
    if optional.exists() or optional.is_symlink(): paths.add(optional)
    names=CLOSE_HARNESSES if suite=='close' else (MACRO_TESTS if suite=='macro' else (ADMISSION_TESTS if suite=='managed-admission' else (SUITES[suite][0],)))
    if suite=='managed-documents': names=tuple(Path(name).stem for name in MANAGED_DOCUMENT_FILE_METHODS)
    paths.update(root/'Tests/NativeIntegration'/(name+'.swift') for name in names)
    result=sorted(paths)
    if not any(p.parent==root/'Sources/PadCore' for p in result): raise ValueError('missing PadCore sources')
    for path in result: read_real(root,path)
    return result

def macro_access(text, filename):
    label=Path(filename).stem
    begin='// MACRO-'+label+'-ACCESS-BEGIN\n'
    end='// MACRO-'+label+'-ACCESS-END'
    if filename not in MACRO_ACCESS or text.count(begin)!=1 or text.count(end)!=1:
        raise ValueError('macro access markers changed')
    first=text.index(begin)+len(begin);last=text.index(end)
    if last<first: raise ValueError('macro access marker order changed')
    return text[first:last].encode()

def projection_probe(text,access):
    marker='  override func makeFirstResponder(_ responder: NSResponder?) -> Bool {\n'
    if text.count(marker)!=1: raise ValueError('focus probe marker changed')
    text=text.replace(marker,marker+'    if let controller = windowController as? EditorWindowController,\n      let result = ProjectionFocusProbe.beforeFocus?(controller, responder) { return result }\n')
    start=text.index('  private func installResolvedPanes(')
    end=text.index('  private func installPendingPresentationIfPossible',start)
    body=text[start:end];marker='      try validateAuthority()\n    }'
    index=body.rfind(marker)
    if index<0: raise ValueError('origin probe marker changed')
    body=body[:index]+'      ProjectionFocusProbe.afterOrigin?(self)\n'+body[index:]
    return text[:start]+body+text[end:]+'\n'+access

def search_replacement_access(test_source, name):
    begin='// SEARCH-'+name+'-ACCESS-BEGIN\n'
    end='// SEARCH-'+name+'-ACCESS-END'
    if test_source.count(begin)!=1 or test_source.count(end)!=1:
        raise ValueError('search access markers changed')
    return test_source.split(begin)[1].split(end)[0]

def native_edit_completion(text):
    start='  private func performDocumentCommand('
    end='  func navigateManaged('
    if text.count(start)!=1 or text.count(end)!=1:
        raise ValueError('native command completion boundaries changed')
    first=text.index(start);last=text.index(end,first)
    body=text[first:last]
    marker='      defer { Self.completeFileOperation(document, id: operationID, controller: self) }'
    if body.count(marker)!=1: raise ValueError('native command completion marker changed')
    body=body.replace(marker,marker[:-2]+'; NativeEditTestCompletion.finish?() }')
    return text[:first]+body+text[last:]

def native_line_ending_completion(text):
    start='  private func convertLineEndings('
    end='  private func convertEncoding('
    if text.count(start)!=1 or text.count(end)!=1:
        raise ValueError('native line ending completion boundaries changed')
    first=text.index(start);last=text.index(end,first)
    body=text[first:last]
    marker='      defer { Self.completeFileOperation(document, id: operationID, controller: self) }'
    if body.count(marker)!=1: raise ValueError('native line ending completion marker changed')
    body=body.replace(marker,marker[:-2]+'; NativeEditTestCompletion.finish?() }')
    return text[:first]+body+text[last:]

def native_replay_completion(text):
    start='  func replay(_ macro: EditorMacro, repeatCount: Int) {'
    end='  func textViewDidChangeSelection('
    if text.count(start)!=1 or text.count(end)!=1:
        raise ValueError('native replay completion boundaries changed')
    first=text.index(start);last=text.index(end,first)
    body=text[first:last]
    marker='        Self.completeFileOperation(document, id: operationID, controller: self)\n      }\n      do {'
    if body.count(marker)!=1: raise ValueError('native replay completion marker changed')
    body=body.replace(marker,marker.replace('\n      }','\n        NativeEditTestCompletion.finish?()\n      }'))
    return text[:first]+body+text[last:]

def native_text_utility_controller(text):
    start='  private func showTextUtilities() {'
    end='  private func showSearch() {'
    if text.count(start)!=1 or text.count(end)!=1:
        raise ValueError('native utility construction boundaries changed')
    first=text.index(start);last=text.index(end,first)
    body=text[first:last];marker='    panel.showWindow(nil)'
    if body.count(marker)!=1: raise ValueError('native utility presentation marker changed')
    body=body.replace(marker,'    // Hidden harness: construct the actual utility panel without showing it.')
    return text[:first]+body+text[last:]

def search_replacement_controller(text,access):
    start='  private func showSearch() {'
    end='  private func apply(_ transform: LineTransform) {'
    if text.count(start)!=1 or text.count(end)!=1:
        raise ValueError('search construction boundaries changed')
    first=text.index(start);last=text.index(end,first)
    body=text[first:last];marker='    panel.showWindow(nil)'
    if body.count(marker)!=1: raise ValueError('search presentation marker changed')
    body=body.replace(marker,'    // Hidden harness: construct the actual panel without showing it.')
    return text[:first]+body+text[last:]+'\n'+access

def freeze(root,run,suite,prebuilt=False):
    root,run=Path(root),Path(run)
    paths=discover(root,suite,prebuilt);items=[];generated=[]
    for path in paths:
        relative=path.relative_to(root).as_posix();target=run/'Original'/relative
        target.parent.mkdir(parents=True,exist_ok=True)
        target.write_bytes(read_real(root,path))
        if path.suffix=='.sh': target.chmod(0o700)
        items.append(dict(source=relative,frozen=target.relative_to(run).as_posix(),sha256=digest(target)))
    if discover(root,suite,prebuilt)!=paths: raise ValueError('source discovery changed during capture')
    for item in items:
        if hashlib.sha256(read_real(root,root/item['source'])).hexdigest()!=item['sha256']:
            raise ValueError('source bytes changed during capture')
    def generate(relative,data,origin=None):
        target=run/relative;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data)
        generated.append(dict(frozen=relative,sha256=digest(target),origin=origin))
    if suite!='close':
        for item in items:
            name=item['source'];path=Path(name)
            if name.startswith(('Sources/PadCore/', 'Sources/SearchExecution/')) or (suite=='document-search-real-helper' and name.startswith(('Sources/PadSearchWorkerRuntime/','Sources/PadSearchWorker/'))):
                generate('Package/'+name,(run/item['frozen']).read_bytes(),name)
            elif name.startswith('Sources/TheOnlyPad/') and path.name!='TheOnlyPadApplication.swift':
                data=(run/item['frozen']).read_bytes()
                if suite=='folder-navigation':
                    test_source=(run/'Original/Tests/NativeIntegration/FolderNavigationTests.swift').read_text()
                    label={'EditorWindowController.swift':'CONTROLLER',
                           'FolderSearchController.swift':'PANEL'}.get(path.name)
                    if label:
                        begin='// FOLDER-'+label+'-ACCESS-BEGIN\n'
                        end='// FOLDER-'+label+'-ACCESS-END'
                        if test_source.count(begin)!=1 or test_source.count(end)!=1:
                            raise ValueError('folder access markers changed')
                        text=data.decode()
                        if label=='CONTROLLER':
                            first=text.index('    case "edit.findFolder":')
                            last=text.index('    case "view.splitVertical":',first)
                            body=text[first:last]
                            marker='      panel.showWindow(nil)'
                            if body.count(marker)!=1: raise ValueError('folder presentation marker changed')
                            text=text[:first]+body.replace(marker,'      // Hidden test: keep the actual folder panel unshown.')+text[last:]
                        data=(text+'\n'+test_source.split(begin)[1].split(end)[0]).encode()
                if suite=='projection' and path.name=='EditorWindowController.swift':
                    access=(run/'Original/Tests/NativeIntegration/EditorTransferProjectionTests.swift').read_text().split('// NATIVE-ACCESS-BEGIN\n')[1].split('// NATIVE-ACCESS-END')[0]
                    data=projection_probe(data.decode(),access).encode()
                if suite=='search-replacement':
                    test_source=(run/'Original/Tests/NativeIntegration/SearchReplacementTests.swift').read_text()
                    if path.name=='EditorWindowController.swift':
                        text=search_replacement_controller(data.decode(),search_replacement_access(test_source,'CONTROLLER'))
                        for transform in (native_edit_completion,native_line_ending_completion,
                                          native_text_utility_controller,native_replay_completion):
                            text=transform(text)
                        data=text.encode()
                    if path.name=='TextUtilitiesController.swift':
                        data+=('\n'+search_replacement_access(test_source,'UTILITY')).encode()
                    if path.name=='SearchPanelController.swift':
                        data+=('\n'+search_replacement_access(test_source,'PANEL')).encode()
                if suite=='settings':
                    access=(run/'Original/Tests/NativeIntegration/DocumentAppliedSettingsTests.swift').read_text().split('// NATIVE-ACCESS-BEGIN\n')[1].split('// NATIVE-ACCESS-END')[0]
                    if path.name=='EditorWindowController.swift': data+=('\n'+access).encode()
                    if path.name=='DocumentTextView.swift':
                        marker='  let documentUndo: UndoManager'
                        if data.decode().count(marker)!=1: raise ValueError('font probe marker changed')
                        probe='  override var defaultParagraphStyle: NSParagraphStyle? {\n    get { super.defaultParagraphStyle }\n    set { AppliedSettingsProbe.paragraphWrites += 1; super.defaultParagraphStyle = newValue }\n  }\n  override var typingAttributes: [NSAttributedString.Key: Any] {\n    get { super.typingAttributes }\n    set { AppliedSettingsProbe.typingWrites += 1; super.typingAttributes = newValue }\n  }\n  override var isHorizontallyResizable: Bool {\n    get { super.isHorizontallyResizable }\n    set { AppliedSettingsProbe.beforeWrap?(self); super.isHorizontallyResizable = newValue }\n  }\n  override var font: NSFont? {\n    get { super.font }\n    set { AppliedSettingsProbe.fontWrites += 1; AppliedSettingsProbe.beforeFont?(self); super.font = newValue }\n  }\n'
                        data=data.decode().replace(marker,probe+marker).encode()
                if suite=='macro' and path.name in MACRO_ACCESS:
                    access=(run/'Original'/MACRO_ACCESS_FILE).read_bytes().decode()
                    data+=macro_access(access,path.name)
                if suite=='managed-admission' and path.name in ADMISSION_ACCESS:
                    # Exact declaring access: stored observations plus only the
                    # original public32 makeDiskConflict construction forwarder.
                    access=run/'Original/Tests/NativeIntegration'/ADMISSION_ACCESS[path.name]
                    data+=b'\n'+access.read_bytes()
                if suite=='managed-documents' and path.name in MANAGED_DOCUMENT_ACCESS:
                    access=run/'Original/Tests/NativeIntegration'/MANAGED_DOCUMENT_ACCESS[path.name]
                    data+=b'\n'+access.read_bytes()
                if suite=='document-search' and path.name in DOCUMENT_SEARCH_ACCESS:
                    access=run/'Original/Tests/NativeIntegration'/DOCUMENT_SEARCH_ACCESS[path.name]
                    data+=b'\n'+access.read_bytes()
                if suite in ('document-search-app','document-search-real-helper') and path.name in DOCUMENT_SEARCH_APP_ACCESS:
                    access=run/'Original/Tests/NativeIntegration'/DOCUMENT_SEARCH_APP_ACCESS[path.name]
                    data+=b'\n'+access.read_bytes()
                if path.name=='EditorDocument.swift' and suite not in ('macro','managed-admission','managed-documents','document-search','document-search-app','document-text-storage','document-search-real-helper'):
                    text=data.decode();marker='  var dirty: Bool {'
                    if text.count(marker)!=1: raise ValueError('dirty getter transform marker changed')
                    data=text.replace(marker,'  var transferHarnessDirtyReads = 0\n'+marker+'\n    transferHarnessDirtyReads += 1').encode()
                generate('Package/Sources/NativeRouting/'+path.name,data,name)
        name=SUITES[suite][0]+'.swift'
        test_data=(run/'Original/Tests/NativeIntegration'/name).read_bytes()
        if suite=='document-search': document_search_methods(test_data)
        if suite=='document-search-app': document_search_app_methods(test_data)
        if suite=='document-text-storage': document_text_storage_methods(test_data)
        if suite=='document-search-real-helper': real_helper_methods(test_data)
        if suite=='folder-navigation':
            text=test_data.decode()
            for label in ('CONTROLLER','PANEL'):
                start=text.index('// FOLDER-'+label+'-ACCESS-BEGIN')
                end=text.index('// FOLDER-'+label+'-ACCESS-END')+len('// FOLDER-'+label+'-ACCESS-END')
                text=text[:start]+text[end:]
            test_data=text.encode()
        if suite in ('settings','projection'):
            text=test_data.decode();start=text.index('// NATIVE-ACCESS-BEGIN');end=text.index('// NATIVE-ACCESS-END')+len('// NATIVE-ACCESS-END');test_data=(text[:start]+text[end:]).encode()
        if suite=='search-replacement':
            text=test_data.decode()
            for label in ('CONTROLLER','PANEL','UTILITY'):
                search_replacement_access(text,label)
                start=text.index('// SEARCH-'+label+'-ACCESS-BEGIN')
                end=text.index('// SEARCH-'+label+'-ACCESS-END')+len('// SEARCH-'+label+'-ACCESS-END')
                text=text[:start]+text[end:]
            test_data=text.encode()
        generate('Package/Tests/NativeRoutingTests/'+name,test_data,
                 'Tests/NativeIntegration/'+name)
        if suite=='macro':
            for extra in MACRO_TESTS:
                if extra!=SUITES[suite][0]:
                    origin='Tests/NativeIntegration/'+extra+'.swift'
                    generate('Package/Tests/NativeRoutingTests/'+extra+'.swift',
                             (run/'Original'/origin).read_bytes(),origin)
        if suite=='managed-admission':
            for extra in ADMISSION_TESTS:
                if extra!=SUITES[suite][0]:
                    origin='Tests/NativeIntegration/'+extra+'.swift'
                    generate('Package/Tests/NativeRoutingTests/'+extra+'.swift',
                             (run/'Original'/origin).read_bytes(),origin)
        if suite=='managed-documents':
            for filename in MANAGED_DOCUMENT_FILE_METHODS:
                origin='Tests/NativeIntegration/'+filename
                data=(run/'Original'/origin).read_bytes()
                managed_document_methods(data,filename)
                if filename!=name:
                    generate('Package/Tests/NativeRoutingTests/'+filename,data,origin)
        package=REAL_HELPER_PACKAGE if suite=='document-search-real-helper' else PACKAGE
        if suite=='document-search':
            marker='dependencies:["NativeRouting","PadCore"]'
            if package.count(marker)!=1: raise ValueError('document search Test dependency marker changed')
            package=package.replace(marker,'dependencies:["NativeRouting","PadCore","SearchExecution"]')
        if suite=='document-search-app':
            marker='dependencies:["NativeRouting","PadCore"]'
            if package.count(marker)!=1: raise ValueError('App document search Test dependency marker changed')
            package=package.replace(marker,'dependencies:["NativeRouting","PadCore","SearchExecution"]')
        generate('Package/Package.swift',package.encode())
    else:
        # Custom storage has an authentic controller owner. Compile the captured
        # native dependency graph, excluding only the application's entry point.
        for item in items:
            name=item['source']
            if name.startswith('Sources/TheOnlyPad/') and name.endswith('.swift'):
                path=run/item['frozen']
                if path.name!='TheOnlyPadApplication.swift':
                    generate('NativeSources/'+path.name,path.read_bytes(),name)
        if not prebuilt:
            for item in items:
                name=item['source']
                if name=='Package.swift' or name.startswith(('Sources/','Tests/PadCoreTests/','Tests/SearchExecutionTests/','Tests/PadSearchWorkerRuntimeTests/')):
                    generate('BuildPackage/'+name,(run/item['frozen']).read_bytes(),name)
    trees=['Package'] if suite!='close' else ['NativeSources']+([] if prebuilt else ['BuildPackage'])
    manifest=dict(version=1,suite=suite,prebuilt=prebuilt,sources=items,generated=generated,inputTrees=trees,
        transformation=('Exact current real-helper three-case fixture; same frozen worker/runtime/native Sources, four unchanged declaring access tails; no historical helper or extra producer hook. Three separate fresh-state processes.' if suite=='document-search-real-helper' else 'Exact current public storage contract,7 fixed methods/one class; all native production bytes unchanged, no access tails, dirty getter or product-body hooks.' if suite=='document-text-storage' else 'Exact current public App search routing,4 fixed methods/one class; four declaring access tails only, no dirty getter or product-body hooks. Existing native close wait and real action forwards remain qualified; no repair stage observers.' if suite=='document-search-app' else 'Exact public native editor integration,15 fixed methods/five classes; four declaring access tails only, no dirty getter or product-body hooks. Existing effectful close wait and chained stage observer remain qualified.' if suite=='document-search' else 'Exact six managed clients,73 methods/seven classes; four unchanged declaring access tails, no dirty getter or product-body hooks. Admission controller access replaces obsolete broad monitor access and includes its identical required disk-conflict forwarder.' if suite=='managed-documents' else 'Exact public production bodies plus two declaring access tails only: C raw observations and original public32 disk-conflict construction forwarder (NOT readonly); D stored weak history observations. Exact startup and routing clients; original routing32 compiled unselected, four named cases selected. No dirty getter, installer, warmup or private native language substitution.' if suite=='managed-admission' else 'Exact three macro fixture clients; five explicit access tails only; no dirty getter or product body hooks; six-class19 selection.' if suite=='macro' else 'Dirty getter counter; folder controller/panel private access appended; only folder command showWindow suppressed; access regions omitted from XCTest source.' if suite=='folder-navigation' else 'Dirty getter counter; test access extracted into frozen controller, search panel and text utility panel; exact search and text utility showWindow calls suppressed; document command, line-ending conversion and macro replay defer completion observers appended with original cleanup retained; access regions omitted from XCTest source.' if suite=='search-replacement' else 'Dirty getter counter; test access extracted into frozen controller; native font/paragraph/typing/wrap setters wrapped for tests; test-access region omitted from XCTest source.' if suite=='settings' else 'Dirty getter counter; test access extracted into frozen controller; focus entry and post-origin callback probes retain original bodies; test-access region omitted from XCTest source.' if suite=='projection' else 'One counter before original dirty getter; implementation retained unchanged.' if suite!='close' else None))
    if suite=='macro':
        access=(run/'Original'/MACRO_ACCESS_FILE).read_bytes().decode()
        manifest['macroAccess']=[dict(target=name,source=MACRO_ACCESS_FILE,
            bytes=len(macro_access(access,name)),
            sha256=hashlib.sha256(macro_access(access,name)).hexdigest()) for name in MACRO_ACCESS]
    if suite=='managed-admission':
        manifest['managedAdmissionAccess']=[dict(
            target=target,source='Tests/NativeIntegration/'+access,
            bytes=len((run/'Original/Tests/NativeIntegration'/access).read_bytes()),
            sha256=digest(run/'Original/Tests/NativeIntegration'/access),join='LF',
            originalSHA256=digest(run/'Original/Sources/TheOnlyPad'/target),
            generatedSHA256=digest(run/'Package/Sources/NativeRouting'/target))
            for target,access in ADMISSION_ACCESS.items()]
    if suite=='managed-documents':
        manifest['managedDocumentsMethods']=[list(x) for x in sorted(MANAGED_DOCUMENT_METHODS)]
        manifest['managedDocumentsAccess']=[dict(
            target=target,source='Tests/NativeIntegration/'+access,
            bytes=len((run/'Original/Tests/NativeIntegration'/access).read_bytes()),
            sha256=digest(run/'Original/Tests/NativeIntegration'/access),join='LF',
            originalSHA256=digest(run/'Original/Sources/TheOnlyPad'/target),
            generatedSHA256=digest(run/'Package/Sources/NativeRouting'/target))
            for target,access in MANAGED_DOCUMENT_ACCESS.items()]
    if suite=='document-search':
        manifest['documentSearchMethods']=[list(x) for x in DOCUMENT_SEARCH_METHODS]
        manifest['documentSearchAccess']=[dict(
            target=target,source='Tests/NativeIntegration/'+access,
            bytes=len((run/'Original/Tests/NativeIntegration'/access).read_bytes()),
            sha256=digest(run/'Original/Tests/NativeIntegration'/access),join='LF',
            originalSHA256=digest(run/'Original/Sources/TheOnlyPad'/target),
            generatedSHA256=digest(run/'Package/Sources/NativeRouting'/target))
            for target,access in DOCUMENT_SEARCH_ACCESS.items()]
    if suite=='document-text-storage':
        manifest['documentTextStorageMethods']=[list(x) for x in DOCUMENT_TEXT_STORAGE_METHODS]
    if suite=='document-search-app':
        manifest['documentSearchAppMethods']=[list(x) for x in DOCUMENT_SEARCH_APP_METHODS]
        manifest['documentSearchAppAccess']=[dict(
            target=target,source='Tests/NativeIntegration/'+access,
            bytes=len((run/'Original/Tests/NativeIntegration'/access).read_bytes()),
            sha256=digest(run/'Original/Tests/NativeIntegration'/access),join='LF',
            originalSHA256=digest(run/'Original/Sources/TheOnlyPad'/target),
            generatedSHA256=digest(run/'Package/Sources/NativeRouting'/target))
            for target,access in DOCUMENT_SEARCH_APP_ACCESS.items()]
    if suite=='document-search-real-helper':
        manifest['documentSearchRealHelperMethods']=[[REAL_HELPER_CLASS,name] for name in REAL_HELPER_METHODS]
        manifest['documentSearchRealHelperAccess']=[dict(
            target=target,source='Tests/NativeIntegration/'+access,
            bytes=len((run/'Original/Tests/NativeIntegration'/access).read_bytes()),
            sha256=digest(run/'Original/Tests/NativeIntegration'/access),join='LF',
            originalSHA256=digest(run/'Original/Sources/TheOnlyPad'/target),
            generatedSHA256=digest(run/'Package/Sources/NativeRouting'/target))
            for target,access in DOCUMENT_SEARCH_APP_ACCESS.items()]
    (run/'sources.json').write_text(json.dumps(manifest,indent=2)+'\n')
    verify(run,manifest)
    return manifest

def verify(run,manifest):
    items=manifest['sources']+manifest['generated']
    for tree in manifest['inputTrees']:
        root=run/tree
        if root.is_symlink() or not root.is_dir(): raise ValueError('missing or symlink input tree')
        expected=set()
        for item in items:
            name=Path(item['frozen'])
            if not name.is_relative_to(tree): continue
            expected.add(('file',name.as_posix()))
            for parent in name.parents:
                if parent==Path(tree): break
                expected.add(('directory',parent.as_posix()))
        actual=set()
        for folder,directories,files in os.walk(root,followlinks=False):
            for kind,names in [('directory',directories),('file',files)]:
                for name in names:
                    path=Path(folder)/name
                    if path.is_symlink(): raise ValueError('symlink compiler input refused')
                    actual.add((kind,path.relative_to(run).as_posix()))
        if actual!=expected: raise ValueError('compiler input membership changed')
    for item in items:
        if hashlib.sha256(read_real(run,run/item['frozen'])).hexdigest()!=item['sha256']:
            raise ValueError('frozen bytes changed')

def manifest_inputs(run,manifest,prefix,suffix):
    """Compiler argv comes from the captured inventory, never a later directory glob."""
    return sorted(run/item['frozen'] for item in manifest['sources']+manifest['generated']
                  if item['frozen'].startswith(prefix) and item['frozen'].endswith(suffix))

def build_package_identity(binary, run, core_objects, search_objects):
    """Bind the compiler package operand to the captured module/object selection."""
    description = binary / 'description.json'
    if not description.is_file():
        raise ValueError('package consumers require compiler description')
    raw = read_real(binary, description)
    if len(raw) > 4 * 1024 * 1024:
        raise ValueError('compiler description exceeds bound')
    commands = json.loads(raw).get('swiftCommands')
    if not isinstance(commands, dict):
        raise ValueError('missing compiler command groups')
    package_names = []
    for module, objects in (('PadCore', core_objects), ('SearchExecution', search_objects)):
        groups = [value for value in commands.values()
                  if isinstance(value, dict) and value.get('moduleName') == module]
        if len(groups) != 1:
            raise ValueError('ambiguous compiler module group')
        group = groups[0]
        arguments = group.get('otherArguments')
        if not isinstance(arguments, list) or arguments.count('-package-name') != 1:
            raise ValueError('missing or duplicate compiler package operand')
        index = arguments.index('-package-name') + 1
        value = arguments[index] if index < len(arguments) else None
        if not isinstance(value, str) or re.fullmatch(r'[A-Za-z0-9_]{1,128}', value) is None:
            raise ValueError('invalid compiler package operand')
        package_names.append(value)
        if group.get('moduleOutputPath') != str(binary / 'Modules' / (module + '.swiftmodule')):
            raise ValueError('compiler module output differs from captured artifact')
        declared = group.get('objects')
        if not isinstance(declared, list) or any(not isinstance(x, str) for x in declared):
            raise ValueError('invalid compiler object roster')
        if len(set(declared)) != len(declared) or sorted(declared) != sorted(map(str, objects)):
            raise ValueError('compiler object roster differs from captured artifacts')
        sources = group.get('sources')
        if not isinstance(sources, list) or any(not isinstance(x, str) or not Path(x).is_absolute() for x in sources):
            raise ValueError('invalid compiler source roster')
        if len(set(sources)) != len(sources) or sorted(Path(x).name + '.o' for x in sources) != sorted(x.name for x in objects):
            raise ValueError('compiler source/object pairing differs')
        # Real coordinator captures actual source bytes separately. Pure artifact
        # fixtures lack that manifest and do not claim compiler provenance.
        original = run / 'Original/Sources' / module
        if original.is_dir():
            if sorted(x.name for x in original.glob('*.swift')) != sorted(Path(x).name for x in sources):
                raise ValueError('compiler source roster differs from frozen sources')
            for source in sources:
                source = Path(source)
                if read_real(source.parent, source) != read_real(original, original / source.name):
                    raise ValueError('compiler source bytes differ from frozen sources')
    if package_names[0] != package_names[1]:
        raise ValueError('compiler modules have different package identities')
    return package_names[0], raw

def freeze_core(binary,run):
    binary=Path(binary).resolve()
    core_objects=sorted((binary/'PadCore.build').glob('*.o'))
    search_objects=sorted((binary/'SearchExecution.build').glob('*.o'))
    core_modules=sorted((binary/'Modules').glob('PadCore.*'))
    search_modules=sorted((binary/'Modules').glob('SearchExecution.*'))
    objects=[*core_objects,*search_objects]
    modules=[*core_modules,*search_modules]
    paths=[*objects,*modules]
    if not core_objects or not (binary/'Modules/PadCore.swiftmodule').is_file():
        raise ValueError('verified debug build must contain PadCore objects and module')
    if search_objects or search_modules:
        if not search_objects or not (binary/'Modules/SearchExecution.swiftmodule').is_file():
            raise ValueError('SearchExecution artifacts require both objects and module')
    package_name, description_bytes = build_package_identity(binary, run, core_objects, search_objects) if search_objects else (None, None)
    if package_name is not None:
        paths.append(binary / 'description.json')
    items=[]
    for path in paths:
        relative=path.relative_to(binary);target=run/'Core'/relative
        target.parent.mkdir(parents=True,exist_ok=True)
        target.write_bytes(description_bytes if path == binary / 'description.json' else read_real(binary,path))
        items.append(dict(source=relative.as_posix(),frozen=target.relative_to(run).as_posix(),sha256=digest(target)))
    if (core_objects!=sorted((binary/'PadCore.build').glob('*.o'))
        or search_objects!=sorted((binary/'SearchExecution.build').glob('*.o'))
        or core_modules!=sorted((binary/'Modules').glob('PadCore.*'))
        or search_modules!=sorted((binary/'Modules').glob('SearchExecution.*'))):
        raise ValueError('build outputs changed during capture')
    for item in items:
        if hashlib.sha256(read_real(binary,binary/item['source'])).hexdigest()!=item['sha256']:
            raise ValueError('build output bytes changed during capture')
    manifest=dict(version=1,sourceDirectory=str(binary),sources=items,generated=[],inputTrees=['Core'],packageName=package_name)
    (run/'build-inputs.json').write_text(json.dumps(manifest,indent=2)+'\n')
    verify(run,manifest)
    return manifest

def receipt_success(output,command,expected_code=0):
    try:
        value=json.loads((output/'status.json').read_text())
        required={'command','pid','processGroup','exitObserved','registrationError','groupSignalAttempted',
            'groupSignalError','groupCleanup','groupQuery','waitCompleted','returnCode','waitError',
            'timedOut','interruptedSignal','truncated','captureComplete','failure','exit','captured'}
        if not isinstance(value,dict) or not required.issubset(value): return False
        if type(expected_code) is not int or not 0<=expected_code<256: return False
        if not isinstance(command,list) or not command or any(type(word) is not str or '\0' in word for word in command): return False
        if any(value[key] is not True for key in ('waitCompleted','captureComplete','groupSignalAttempted')): return False
        if any(value[key] is not False for key in ('timedOut','truncated')): return False
        if any(value[key] is not None for key in ('failure','interruptedSignal','waitError')): return False
        if any(type(value[key]) is not int or value[key]!=expected_code for key in ('exit','returnCode')): return False
        if value['command']!=command: return False
        pid=value['pid']
        if type(pid) is not int or pid<=0 or type(value['processGroup']) is not int or value['processGroup']!=pid: return False
        observed,registration=value['exitObserved'],value['registrationError']
        if type(observed) is not bool: return False
        if registration is not None and (type(registration) is not int or registration!=errno.ESRCH): return False
        if not observed and registration!=errno.ESRCH: return False
        cleanup,error=value['groupCleanup'],value['groupSignalError']
        if cleanup=='signaled':
            if error is not None or value['groupQuery'] is not None: return False
        elif cleanup=='absent':
            if type(error) is not int or error!=errno.ESRCH or value['groupQuery'] is not None: return False
        elif cleanup=='exitedLeaderOnly':
            query=value['groupQuery'];fields={'processGroup','errorNumber','bufferBytes','returnedBytes','members'}
            if type(error) is not int or error!=errno.EPERM or not observed: return False
            if not isinstance(query,dict) or not fields.issubset(query) or query['errorNumber'] is not None: return False
            if any(type(query[key]) is not int or query[key]!=expected for key,expected in
                   [('processGroup',pid),('bufferBytes',1024),('returnedBytes',4)]): return False
            if not isinstance(query['members'],list) or len(query['members'])!=1: return False
            if type(query['members'][0]) is not int or query['members'][0]!=pid: return False
        else: return False
        if not isinstance(value['captured'],dict): return False
        for name in ('stdout','stderr'):
            counts=value['captured'].get(name)
            if not isinstance(counts,dict) or not {'stored','received','discarded'}.issubset(counts): return False
            if any(type(counts[key]) is not int for key in ('stored','received','discarded')): return False
            stored=counts['stored']
            if (not 0<=stored<=1_048_576 or counts['received']!=stored
                or counts['discarded']!=0 or (output/(name+'.log')).stat().st_size!=stored): return False
        return True
    except (OSError,ValueError,TypeError,KeyError,AttributeError): return False

def parse_success(kind,text):
    if any(line.startswith('FAIL ') for line in text.splitlines()): raise ValueError('native assertion failed')
    if kind=='document-search': return document_search_success(text)
    if kind=='document-search-app': return document_search_app_success(text)
    if kind=='document-text-storage': return document_text_storage_success(text)
    if kind=='managed-documents': return managed_documents_success(text)
    if kind=='managed-admission':
        counts=[tuple(map(int,pair)) for pair in re.findall(r'Executed (\d+) tests?, with (\d+) failures',text)]
        if not counts or counts[-1]!=(4,0) or any(n<=0 or failures!=0 for n,failures in counts):
            raise ValueError('missing exact positive managed admission result')
        terminal=re.findall(r"^Test Case '([^']+)' (passed|failed|skipped)(?: \(.*\)\.)?$",text,re.M)
        if len(terminal)!=4 or any(result!='passed' for _,result in terminal):
            raise ValueError('managed admission incomplete or nonpassing cases')
        cases=[]
        for identity,_ in terminal:
            match=re.fullmatch(r'\-\[NativeRoutingTests\.(\w+) (test\w+)\]',identity)
            if match is None: raise ValueError('foreign managed admission case')
            cases.append(match.groups())
        if len(set(cases))!=4 or set(cases)!=ADMISSION_METHODS:
            raise ValueError('managed admission exact case selection changed')
        if {name:sum(case[0]==name for case in cases) for name in ADMISSION_CLASSES}!=ADMISSION_CLASSES:
            raise ValueError('managed admission class count changed')
        for name in ADMISSION_CLASSES:
            if len(re.findall(r"^Test Suite '"+re.escape(name)+r"' passed(?: at .*\.)?$",text,re.M))!=1:
                raise ValueError('managed admission class did not pass')
        return dict(tests=4,failures=0)
    if kind=='macro':
        counts=[tuple(map(int,pair)) for pair in re.findall(r'Executed (\d+) tests?, with (\d+) failures',text)]
        if not counts or counts[-1]!=(19,0) or any(n<=0 or failures!=0 for n,failures in counts):
            raise ValueError('missing exact positive macro result')
        cases=re.findall(r"Test Case '-\[NativeRoutingTests\.(\w+) (test\w+)\]' passed",text)
        if len(cases)!=19 or len(set(cases))!=19:
            raise ValueError('macro actual case count changed')
        if {name:sum(case[0]==name for case in cases) for name in MACRO_CLASSES}!=MACRO_CLASSES:
            raise ValueError('macro class selection changed')
        for name in MACRO_CLASSES:
            # Require one passed class header, including native XCTest's time suffix.
            if len(re.findall(r"^Test Suite '"+re.escape(name)+r"' passed(?: at .*\.)?$",text,re.M))!=1:
                raise ValueError('macro class did not pass')
        return dict(tests=19,failures=0)
    if kind in SUITES and kind!='close':
        counts=[tuple(map(int,pair)) for pair in re.findall(r'Executed (\d+) tests?, with (\d+) failures',text)]
        if not counts or any(n<=0 or failures!=0 for n,failures in counts): raise ValueError('missing positive XCTest result')
        if "Test Suite '"+SUITES[kind][0]+"' passed" not in text: raise ValueError('expected suite did not pass')
        return dict(tests=counts[-1][0],failures=0)
    if kind=='SharedPaneOwnershipHarness':
        if text.splitlines().count(SHARED_MARKER)!=1: raise ValueError('missing shared ownership scenario')
        return dict(scenarios=1,failures=0)
    prefix={'NativeCloseModelHarness':'Native close model','DocumentFactoryHarness':'Factory'}[kind]
    counts=re.findall(re.escape(prefix)+r' checks: (\d+), failures: (\d+)',text)
    if len(counts)!=1 or int(counts[0][0])<=0 or int(counts[0][1])!=0: raise ValueError('missing positive native checks')
    return dict(checks=int(counts[0][0]),failures=0)

class StageFailure(Exception):
    def __init__(self,code): self.code=code

def execute(run,args,watchdog_main):
    if args.suite=='document-search-real-helper': return execute_real_helper_stages(run,args,watchdog_main)
    run=Path(run);manifest=json.loads((run/'sources.json').read_text());manifest_hash=digest(run/'sources.json')
    result=dict(exit=125,suite=args.suite,stages=[],results={},sourceManifestSHA256=manifest_hash,
        buildProvenance='caller must supply a verified matching debug build; frozen artifact hashes alone do not prove source equivalence' if args.build_path else 'built from frozen sources')
    core=None;core_hash=None
    def check():
        verify(run,manifest)
        if digest(run/'sources.json')!=manifest_hash: raise ValueError('source manifest changed')
        if core is not None:
            verify(run,core)
            if digest(run/'build-inputs.json')!=core_hash: raise ValueError('build manifest changed')
    def stage(name,command,timeout,kind=None):
        check();output=run/'Stages'/name;state=run/'State'/name;state.mkdir(parents=True)
        if args.suite in ('managed-documents','document-search','document-search-app','document-text-storage'):
            state.parent.chmod(0o700);state.chmod(0o700)
        # env execs the fixed command in the same owned leader/session. Only synthetic
        # state is added after the accepted watchdog's environment sanitization.
        command=['/usr/bin/env','THEONLYPAD_STATE_DIRECTORY='+str(state),*map(str,command)]
        code=watchdog_main(['--timeout',str(timeout),'--output',str(output),'--',*command])
        result['stages'].append(dict(name=name,exit=code,receipt=str((output/'status.json').relative_to(run))))
        check()
        if type(code) is not int or not receipt_success(output,command,code): raise ValueError('incomplete stage receipt')
        if code!=0: raise StageFailure(code)
        text=(output/'stdout.log').read_text(errors='replace')+(output/'stderr.log').read_text(errors='replace')
        if kind: result['results'][kind]=parse_success(kind,text)
        return text
    try:
        stage('toolchain',['/usr/bin/xcrun','swift','--version'],30)
        swift=run/'Original/scripts/swift.sh'
        if args.suite!='close':
            command=[swift,'test','--package-path',run/'Package','--scratch-path',run/'Build']
            if args.suite=='macro': command+=['-Xswiftc','-warnings-as-errors','--filter',MACRO_SELECTOR]
            if args.suite=='managed-admission': command+=['-Xswiftc','-warnings-as-errors','--filter',ADMISSION_SELECTOR]
            if args.suite=='managed-documents': command+=['-Xswiftc','-warnings-as-errors']
            if args.suite=='document-search': command+=['-Xswiftc','-warnings-as-errors','--filter',DOCUMENT_SEARCH_SELECTOR]
            if args.suite=='document-search-app': command+=['-Xswiftc','-warnings-as-errors','--filter',DOCUMENT_SEARCH_APP_SELECTOR]
            if args.suite=='document-text-storage': command+=['-Xswiftc','-warnings-as-errors','--filter',DOCUMENT_TEXT_STORAGE_SELECTOR]
            stage('test',command,180,args.suite)
        else:
            if args.build_path:
                binary=Path(args.build_path).resolve()
            else:
                common=['--package-path',run/'BuildPackage','--scratch-path',run/'Build','-c','debug']
                stage('build',[swift,'build',*common],180)
                output=stage('bin-path',[swift,'build',*common,'--show-bin-path'],30)
                lines=output.strip().splitlines()
                if len(lines)!=1: raise ValueError('ambiguous built product path')
                binary=Path(lines[0])
                if not binary.is_absolute() or not binary.resolve().is_relative_to((run/'Build').resolve()):
                    raise ValueError('built product path outside owned scratch directory')
            core=freeze_core(binary,run);core_hash=digest(run/'build-inputs.json');result['buildManifestSHA256']=core_hash
            native_sources=manifest_inputs(run,manifest,'NativeSources/','.swift')
            core_objects=manifest_inputs(run,core,'Core/PadCore.build/','.o')
            search_objects=manifest_inputs(run,core,'Core/SearchExecution.build/','.o')
            if any(b'import SearchExecution' in path.read_bytes() for path in native_sources):
                if not search_objects or not (run/'Core/Modules/SearchExecution.swiftmodule').is_file():
                    raise ValueError('native SearchExecution consumer requires captured objects and module')
            for name in CLOSE_HARNESSES:
                package_arguments = ['-package-name', core['packageName']] if core['packageName'] is not None else []
                command=['/usr/bin/xcrun','swiftc','-swift-version','5',*package_arguments,'-target',platform.machine()+'-apple-macosx14.0',
                    '-module-cache-path',run/'cache','-parse-as-library','-I',run/'Core/Modules',
                    *native_sources,
                    run/'Original/Tests/NativeIntegration'/(name+'.swift'),
                    *core_objects,*search_objects,'-o',run/name]
                stage(name+'.compile',command,120)
                binary_hash=digest(run/name)
                result.setdefault('binaryHashes',{})[name]=binary_hash
                stage(name,[run/name],30,name)
                if digest(run/name)!=binary_hash: raise ValueError('native executable changed')
        check();result['exit']=0
    except StageFailure as error:
        result['exit']=error.code if 0<error.code<256 else 125
    except (OSError,ValueError,TypeError,KeyError,AttributeError) as error:
        result['failure']=type(error).__name__;result['exit']=125
    finally:
        (run/'status.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result),flush=True)
    return result['exit']

def main(argv=None):
    args=parse_args(sys.argv[1:] if argv is None else argv)
    root=Path(__file__).absolute().parents[2]
    parent=root/'.local'/SUITES[args.suite][1];parent.mkdir(parents=True,exist_ok=True)
    run=Path(tempfile.mkdtemp(prefix='run.',dir=parent));run.chmod(0o700)
    print('Private native regression evidence: '+str(run),flush=True)
    try:
        freeze(root,run,args.suite,bool(args.build_path))
        frozen=load('frozen_native_regressions',run/'Original/Tests/NativeIntegration/run_native_regressions.py')
        watchdog=load('frozen_native_watchdog',run/'Original/scripts/run-owned-search-tests.py')
        return frozen.execute(run,args,watchdog.main)
    except (OSError,ValueError,ImportError) as error:
        (run/'status.json').write_text(json.dumps(dict(exit=125,failure=type(error).__name__))+'\n')
        return 125

if __name__=='__main__': raise SystemExit(main())
