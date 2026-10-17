"""Fixed current-source nonXML approval plus transfer gate,74 unique/75 occurrences.

The wrapper resolves its repository; inputs are public layout only. One accepted
owned-process watchdog per fixed stage. No native child is started on import.
"""
from pathlib import Path
import copy
import difflib
import hashlib
import importlib.util
import json
import math
import os
import platform
import re
import stat
import sys
import uuid

DRIVERS = {
    'Tests/NativeIntegration/run_application_language_catalog.py': ('Runner/run_application_language_catalog.py', 'fab396f551bcb7ba498fe21950ef8ad1a1cdfdbbd45a81a7fdaae5311516a24f'),
    'Tests/NativeIntegration/application_language_catalog_proof.py': ('Runner/application_language_catalog_proof.py', 'a51a380f2016265187d577416f840eaa83cacd0b6d083aba08f353b5d355cefb'),
    'Tests/NativeIntegration/run_native_regressions.py': ('Runner/run_native_regressions.py', 'ff737184848e47d3d7f655196f6a16c25de62acb4671112209dc74c741dc50cf'),
    'scripts/run-owned-search-tests.py': ('Runner/run-owned-search-tests.py', 'd5bd867e4a65b4ee053209fe0a5822867b8d0878fd6d059f474c9b28a0f6286d'),
}
FIELDS = set('command pid processGroup exitObserved registrationError groupSignalAttempted groupSignalError groupCleanup groupQuery waitCompleted returnCode waitError timedOut interruptedSignal truncated captureComplete failure exit seconds captured'.split())
ERRORS = (OSError, ValueError, TypeError, KeyError, RuntimeError, AttributeError, ImportError)
FIXED_SELECTIONS = [{'stage': 'positive', 'classes': [{'class': 'SearchReplacementTests', 'methods': ['testRealDelegateReplaceAllPreservesSingleStepUnicodeUndoRedo']}], 'timeout': 90, 'mandatoryPositive': True}, {'stage': 'search32', 'classes': [{'class': 'SearchReplacementTests', 'methods': ['testSameLengthDelegateEditRefusesStaleReplaceAll', 'testDetachedDelegateTargetRefusesReplacement', 'testSavingDuringDelegateRefusesReplacement', 'testEditThenRestoreDuringDelegateStillRefusesOldRevision', 'testDelegateRefusalPreservesTextAndExistingUndo', 'testRealDelegateReplaceAllPreservesSingleStepUnicodeUndoRedo', 'testRealDelegateBookkeepingIsNotCommittedAfterUndoBoundaryReentry', 'testPendingSameTextDelegateEditRefusesUnprocessedMutation', 'testPostDelegateAuthorityCallbackPreservesOwnUndoAndMacroOnly', 'testNestedIdenticalDelegateCallKeepsItsOwnMacroAndUndo', 'testSuccessfulReplacementCommitsBookmarksAndOneMacroWithUndo', 'testUndoGroupCallbackCannotPublishPreparedSearchBookkeeping', 'testJSONSuccessAllowsSelectionChangeAndRetainsSingleUndo', 'testReplaySuccessRetainsActionBookmarksAndSingleUndo', 'testReplayRefusesReentrantNativeDelegateTextChange', 'testReplayRefusesOriginalCancellationDuringNativeDelegate', 'testReplayPreservesNewerOperationAfterAdmissionCallback', 'testTextUtilityUnicodePartialSuccessPreservesRangeBookmarksAndUndo', 'testTextUtilityPartialNoOpRetainsExistingBookmarkBookkeepingSemantics', 'testJSONActualCompletionRefusesReentrantDelegateTextChange', 'testLineEndingSuccessRetainsMinimalMacroAndSingleUndo', 'testTextUtilityRefusesReentrantNativeTextChange', 'testTextUtilityRefusesSelectionChangeDuringNativeDelegate', 'testAsyncCommandSuccessRetainsSelectionMacroAndUndo', 'testNoOpAsyncCommandSuccessStillInstallsResultSelection', 'testLineEndingConversionRefusesNewerOperationAfterAdmissionCallback', 'testAsyncCommandRefusesSelectionChangedDuringNativeDelegate', 'testNoOpAsyncCommandPreservesNewerOperationAndCaret', 'testPartialUnicodeTransformPreservesMacroRangeBookmarksAndSingleUndo', 'testInvalidPartialRangesRefuseBeforeDelegateOrMacro', 'testScalarBoundaryInsideGraphemeRemainsEditableAndNoOpWrapperRefuses', 'testDocumentTransformRefusesReentrantEditWithoutPublishingOuterMacro']}], 'timeout': 180, 'mandatoryPositive': False}, {'stage': 'native19', 'classes': [{'class': 'NativeMacroChronologyTests', 'methods': ['testChronologicalUnicodeReplacementUndoRedoPayloadsAndReplay', 'testChronologicalLengthChangingUndoContinueInvalidatesRedo', 'testChronologicalPreRecordingHistoryAndBookmarkOnlyReplay', 'testChronologicalGroupedAndCoalescedEditsReplayActualText', 'testRejectedFallbackNativeInsertionPublishesNoGhostMacroCommand', 'testDeniedNativeUndoLeavesChronologicalStreamAndTextUnchanged', 'testRefusedSearchProposalPreservesChronologicalPrefixAndCallbackEdits']}, {'class': 'NativeMacroApprovedViewReceiptTests', 'methods': ['testForeignExactApprovedWriteAppendsOnceWithoutCallerAttribution', 'testFalseOuterDecisionCannotApproveLaterRawWrite', 'testTrueNoWriteDecisionExpiresWhenHistoryInvocationReturns', 'testTrueDecisionCannotApproveDifferentReplacementPayload', 'testExtraPendingNilAfterControllerPermissionBurnsApproval', 'testPendingNilValueNilABAPreservesTextButNotRecordingApproval']}, {'class': 'NativeMacroApprovedViewCapacityTests', 'methods': ['testThirtyThirdRealProcessingBarrierDoesNotExceedCombinedCapacity', 'testRejectedPairRethrowsOnceAndRestoresActualStacks']}, {'class': 'NativeMacroApprovedViewPayloadTests', 'methods': ['testExactUTF16DelegateRequestAcknowledgesActualBookkeeping', 'testCanonicalEquivalentDifferentUTF16DelegateCannotAuthenticateBookkeeping']}, {'class': 'NativeMacroStrictExplicitCapacityTests', 'methods': ['testActualStrictEntryInsideThirtyTwoProcessingScopesPreservesSharedCapacity']}, {'class': 'NativeMacroControlledExplicitCapacityTests', 'methods': ['testActualControlledEntryInsideThirtyTwoProcessingScopesPreservesSharedCapacity']}], 'timeout': 180, 'mandatoryPositive': False}, {'stage': 'nested8', 'classes': [{'class': 'NativeMacroNestedStringReplacementTests', 'methods': ['testActualConcreteRangeChildRecordsOnceAndLeavesUsableOriginalAuthority', 'testChildNativeVetoHasOnePermissionNoFallbackAndKeepsLawfulParent', 'testRawCharacterWriteInSameAdmissionStillDisclosesIncompleteInterval', 'testRealEmptyStopAndRestartProtectNewEpochFromOldParent', 'testUnicodeReplacementCaretHistoryAndBookmarksMatchActualNonrecordingTwin', 'testSiblingChildrenKeepChronologicalCommandsAndOneNativeEventUndoWithoutOuter', 'testActualGrandchildCommitRejectsBothStaleAncestorsWithoutClearingIt', 'testSharedRealProcessingCapacityKeepsTextOnceAndMarksMissingRecording']}], 'timeout': 180, 'mandatoryPositive': False}, {'stage': 'negative7', 'classes': [{'class': 'NativeVetoHandoffNegativeTests', 'methods': ['testControllerReplacementWithoutChildHasNoHandoff', 'testGenuineVetoCannotAuthorizeForeignSuccessor', 'testGenuineVetoCannotAuthorizeNilSuccessor', 'testConfigurationRefusalBeforeNativePermissionHasNoVetoReceipt', 'testGenuineVetoCannotSurviveRawTextRevisionABA', 'testGenuineVetoCannotSurviveRealEmptyRecorderEpochABA', 'testSecondRecognizedNativeVetoCannotReplaceFirstWindowDisposition']}], 'timeout': 180, 'mandatoryPositive': False}, {'stage': 'caret2', 'classes': [{'class': 'NativeCaretApprovalHistoryTests', 'methods': ['testOwnerReentryRefusesCaretWithoutAddingGhostToSeededUndo', 'testOwnerReentryRefusesCaretWithoutDestroyingSeededRedo']}], 'timeout': 180, 'mandatoryPositive': False}, {'stage': 'transfer6', 'classes': [{'class': 'TransferPreferredResponderTests', 'methods': ['testActualPreferredResponderAndHistoryAcrossThreeTinyLayouts', 'testExactStagedPreferredRefusalRestoresOriginalResponderAndHistory', 'testDeclaredFalseSuccessWithoutInstallingResponderMustRestore', 'testRealFocusCallbackEndpointRetirementCannotGrantMutationAndRetriesExactly', 'testRollbackPreferredRefusalRetainsThenExactReleasedRetryRestores', 'testDefaultOrdinaryHostStillFocusesAndEditsWithoutTransferScope']}], 'timeout': 180, 'mandatoryPositive': False}]
FIXED_STAGES = ['toolchain', 'build', 'binpath', 'positive', 'search32', 'native19', 'nested8', 'negative7', 'caret2', 'transfer6']
TIMEOUTS = {'toolchain': 30, 'build': 180, 'binpath': 30, 'positive': 90, 'search32': 180, 'native19': 180, 'nested8': 180, 'negative7': 180, 'caret2': 180, 'transfer6': 180}

LOCATION = 'Tests/NativeApprovalIntegration/'
PROVIDERS = ('NativeApprovalEventBoundaryOracle.swift', 'NativeNestedStringApprovalTests.swift',
             'NativeVetoHandoffNegativeTests.swift', 'NativeCaretApprovalHistoryTests.swift',
             'NativeApprovalControllerAccess.swift', 'NativeApprovalBrokerAccess.swift')
TRANSFER_PROVIDERS = ('TransferPreferredResponderTests.swift', 'TransferPreferredControllerAccess.swift',
                      'TransferPreferredOwnerAccess.swift', 'TransferPreferredNativeFocusHook.swift')
TEST_CLIENTS = ('SearchReplacementTests.swift', 'NativeMacroChronologyTests.swift',
                'MacroChronologyReplayTests.swift', 'NativeMacroStorageTask1ATests.swift')
DECLARING = ('EditorWindowController.swift', 'DocumentTextView.swift', 'EditorDocument.swift',
             'DocumentCommitTextStorage.swift', 'ApprovedViewCommitBroker.swift',
             'NativeMacroCommitContext.swift', 'SearchPanelController.swift', 'TextUtilitiesController.swift',
             'NativeApplicationDocuments.swift')
PACKAGE = '''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name:"NativeRouting", platforms:[.macOS(.v14)], targets:[.target(name:"PadCore"),.target(name:"SearchExecution",dependencies:["PadCore"]),.target(name:"NativeRouting",dependencies:["PadCore","SearchExecution"]),.testTarget(name:"NativeRoutingTests",dependencies:["NativeRouting","PadCore"])],swiftLanguageModes:[.v5])
'''.encode()


def require(value, message):
    if not value:
        raise ValueError(message)


def validate_cli(argv):
    require(argv == [], 'fixed native approval command accepts no arguments')


def fixed_plan():
    return copy.deepcopy(dict(stages=FIXED_STAGES, selections=FIXED_SELECTIONS,
                              uniqueMethods=74, occurrences=75))


def checked(root, path, directory=False):
    root, path = Path(root).absolute(), Path(path).absolute()
    require(path.is_relative_to(root) and '..' not in path.parts, 'path outside owned root')
    for index in range(len(path.relative_to(root).parts) + 1):
        item = root.joinpath(*path.relative_to(root).parts[:index])
        value = item.lstat()
        require(not stat.S_ISLNK(value.st_mode) and value.st_uid == os.getuid(), 'unowned or symlink input')
        require(stat.S_ISDIR(value.st_mode) if item != path or directory else stat.S_ISREG(value.st_mode),
                'owned regular input required')
    return path


def read_snapshot(root, relative):
    path = checked(root, Path(root) / relative)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        before = os.fstat(descriptor)
        with os.fdopen(descriptor, 'rb', closefd=False) as stream:
            data = stream.read()
        after, named = os.fstat(descriptor), path.lstat()
        keys = ('st_dev', 'st_ino', 'st_uid', 'st_mode', 'st_size', 'st_mtime_ns', 'st_ctime_ns')
        require(all(getattr(before, k) == getattr(after, k) == getattr(named, k) for k in keys),
                'input changed during descriptor snapshot')
        require(len(data) == after.st_size, 'incomplete descriptor read')
        checked(root, path)
        return data, dict(path=relative, bytes=len(data), sha256=hashlib.sha256(data).hexdigest(),
                          device=after.st_dev, inode=after.st_ino, uid=after.st_uid,
                          mode=stat.S_IMODE(after.st_mode))
    finally:
        os.close(descriptor)


def discover(root):
    root = Path(root).absolute()
    checked(root, root, directory=True)
    sources = []
    for folder, dirs, files in os.walk(checked(root, root / 'Sources', directory=True), followlinks=False):
        for name in dirs:
            checked(root, Path(folder) / name, directory=True)
        for name in files:
            path = Path(folder) / name
            checked(root, path)
            if name.endswith('.swift'):
                sources.append(path.relative_to(root).as_posix())
    sources.sort()
    assembled = {s: 'Package/Sources/' + ('NativeRouting' if s.startswith('Sources/TheOnlyPad/') else s.split('/')[1]) + '/' + Path(s).name
                 for s in sources if s.split('/')[1] in ('PadCore', 'SearchExecution', 'TheOnlyPad')
                 and s != 'Sources/TheOnlyPad/TheOnlyPadApplication.swift'}
    folded = [v.casefold() for v in assembled.values()]
    require(len(folded) == len(set(folded)), 'duplicate/case-folded Package destination')
    for module in ('PadCore', 'SearchExecution', 'NativeRouting'):
        require(any(v.startswith('Package/Sources/' + module + '/') for v in assembled.values()),
                'missing productive module')
    for name in DECLARING:
        require('Sources/TheOnlyPad/' + name in assembled, 'missing declaring Source')
    support = [*DRIVERS, 'scripts/swift.sh', 'scripts/test-native-approval-regressions.sh',
               *['Tests/NativeIntegration/' + name for name in (*TEST_CLIENTS, 'NativeMacroChronologyAccess.swift')],
               'Tests/NativeIntegration/DocumentSearchEditorBindingAccess.swift',
               *[LOCATION + name for name in (*PROVIDERS, *TRANSFER_PROVIDERS)],
               *[LOCATION + name for name in ('run_native_approval_regressions.py', 'public_capture.py',
                                             'test_public_capture.py', 'test_native_approval_runner.py')]]
    inputs = sorted(set(sources + support))
    for relative in inputs:
        checked(root, root / relative)
    return dict(sourcePaths=sources, inputs=inputs, packageSources=assembled)


def snapshot(root, paths):
    require(type(paths) is list and len(paths) == len(set(paths)), 'closed unique input list required')
    return {name: read_snapshot(root, name) for name in paths}


def verify_snapshot(root, captured):
    require(set(discover(root)['inputs']) == set(captured), 'current input membership changed')
    for relative, (data, fact) in captured.items():
        current, observed = read_snapshot(root, relative)
        require(observed == fact and current == data, 'current input identity/bytes changed')


def combine_search(data):
    value = data['Tests/NativeIntegration/SearchReplacementTests.swift']
    for label in ('CONTROLLER', 'PANEL', 'UTILITY'):
        begin = ('// SEARCH-' + label + '-ACCESS-BEGIN').encode()
        end = ('// SEARCH-' + label + '-ACCESS-END').encode()
        require(value.count(begin) == value.count(end) == 1, 'exact original Search access markers required')
        a, b = value.index(begin), value.index(end) + len(end)
        require(a < b, 'Search access marker order changed')
        value = value[:a] + value[b:]
    return value + b''.join(data[LOCATION + name] for name in PROVIDERS[:4])


def compose_transfer(data):
    value = data[LOCATION + TRANSFER_PROVIDERS[0]]
    validate_methods(value, FIXED_SELECTIONS[-1]['classes'])
    return value


def validate_methods(data, classes, allow_other_classes=False):
    current = None
    found, names = [], []
    for match in re.finditer(r'\bclass\s+(\w+)\s*:\s*XCTestCase\b|\bfunc\s+(test\w+)\s*\(', data.decode('utf-8')):
        if match.group(1):
            current = match.group(1)
            names.append(current)
        else:
            require(current is not None, 'Test method lacks declaring XCTest class')
            found.append((current, match.group(2)))
    expected = [(c['class'], m) for c in classes for m in c['methods']]
    selected = {c['class'] for c in classes}
    if allow_other_classes:
        found = [row for row in found if row[0] in selected]
        names = [name for name in names if name in selected]
    require(len(found) == len(set(found)) and set(found) == set(expected)
            and len(names) == len(set(names)) and set(names) == selected,
            'fixed class/method provider census differs')


def raw_proof(before, after):
    aa, bb = before.splitlines(keepends=True), after.splitlines(keepends=True)
    apos, bpos = [0], [0]
    for row in aa:apos.append(apos[-1] + len(row))
    for row in bb:bpos.append(bpos[-1] + len(row))
    operations, gaps = [], []
    for kind, a, z, b, y in difflib.SequenceMatcher(None, aa, bb, autojunk=False).get_opcodes():
        if kind == 'equal':
            gaps.append(dict(originalOffset=apos[a], currentOffset=bpos[b], bytes=apos[z] - apos[a],
                             sha256=hashlib.sha256(before[apos[a]:apos[z]]).hexdigest()))
        else:
            operations.append(dict(originalOffset=apos[a], currentOffset=bpos[b],
                                   oldHex=before[apos[a]:apos[z]].hex(), newHex=after[bpos[b]:bpos[y]].hex()))
    return dict(originalBytes=len(before), currentBytes=len(after),
                originalSHA256=hashlib.sha256(before).hexdigest(), currentSHA256=hashlib.sha256(after).hexdigest(),
                operations=operations, wholeUnchangedGaps=gaps)


def verify_raw_proof(before, after, proof):
    require(proof['originalBytes'] == len(before) and proof['currentBytes'] == len(after)
            and proof['originalSHA256'] == hashlib.sha256(before).hexdigest()
            and proof['currentSHA256'] == hashlib.sha256(after).hexdigest(), 'raw projection authority differs')
    for initial, expected, offset, oldkey, newkey in ((before, after, 'originalOffset', 'oldHex', 'newHex'),
                                                   (after, before, 'currentOffset', 'newHex', 'oldHex')):
        value = initial
        offsets = [r[offset] for r in proof['operations']]
        require(offsets == sorted(offsets) and all(type(i) is int and i >= 0 for i in offsets), 'raw offsets required')
        for row in reversed(proof['operations']):
            at, old, new = row[offset], bytes.fromhex(row[oldkey]), bytes.fromhex(row[newkey])
            require(value[at:at + len(old)] == old, 'raw inverse precondition differs')
            value = value[:at] + new + value[at + len(old):]
        require(value == expected, 'whole raw inverse differs')
    for row in proof['wholeUnchangedGaps']:
        a, b, n = row['originalOffset'], row['currentOffset'], row['bytes']
        require(before[a:a + n] == after[b:b + n]
                and hashlib.sha256(before[a:a + n]).hexdigest() == row['sha256'], 'raw protected gap differs')


def compose(data, native, package_sources):
    outputs, derivations = {}, []
    search = data['Tests/NativeIntegration/SearchReplacementTests.swift'].decode('utf-8')
    macro = data['Tests/NativeIntegration/NativeMacroChronologyAccess.swift'].decode('utf-8')
    for relative, target in package_sources.items():
        value = data[relative]
        name = Path(relative).name
        if name == 'EditorWindowController.swift' and relative.startswith('Sources/TheOnlyPad/'):
            text = native.search_replacement_controller(value.decode('utf-8'), native.search_replacement_access(search, 'CONTROLLER'))
            for operation in (native.native_edit_completion, native.native_line_ending_completion,
                              native.native_replay_completion, native.native_text_utility_controller):
                text = operation(text)
            value = text.encode() + native.macro_access(macro, name) + b'\n' + data[LOCATION + PROVIDERS[4]]
            # Append only same-file Test observations after the unchanged original seven derivations.
            value += (b'\n' + data['Tests/NativeIntegration/DocumentSearchEditorBindingAccess.swift']
                      + b'\n' + data[LOCATION + TRANSFER_PROVIDERS[1]]
                      + b'\n' + data[LOCATION + TRANSFER_PROVIDERS[3]])
            start = b'@MainActor private final class EditorAdmissionWindow: NSWindow {'
            end = b'@MainActor\nfinal class EditorWindowController:'
            signature = b'  override func makeFirstResponder(_ responder: NSResponder?) -> Bool {\n'
            anchor = b'    guard !checkingFocusAdmission else { return false }'
            branch = (b'    if let controller = windowController as? EditorWindowController,\n'
                      b'      let result = TransferPreferredNativeHook.beforeFocus?(controller, responder) { return result }\n')
            require(value.count(start) == value.count(end) == 1, 'exact native admission window class required')
            a, z = value.index(start), value.index(end)
            require(a < z, 'native admission window scope differs')
            window = value[a:z]
            require(window.count(signature) == window.count(anchor) == 1
                    and signature + anchor in window and branch not in value,
                    'exact native admission focus anchor required')
            projected = window.replace(anchor, branch + anchor, 1)
            require(projected.replace(branch, b'', 1) == window, 'native focus Test insertion inverse differs')
            value = value[:a] + projected + value[z:]
        elif relative.startswith('Sources/TheOnlyPad/') and name in native.MACRO_ACCESS:
            value += native.macro_access(macro, name)
            if name == 'ApprovedViewCommitBroker.swift':value += b'\n' + data[LOCATION + PROVIDERS[5]]
        elif relative.startswith('Sources/TheOnlyPad/') and name in ('SearchPanelController.swift', 'TextUtilitiesController.swift'):
            value += native.search_replacement_access(search, 'PANEL' if name.startswith('Search') else 'UTILITY').encode()
        elif relative == 'Sources/TheOnlyPad/NativeApplicationDocuments.swift':
            value += b'\n' + data[LOCATION + TRANSFER_PROVIDERS[2]]
        outputs[target] = value
        if value != data[relative]:
            proof = raw_proof(data[relative], value)
            verify_raw_proof(data[relative], value, proof)
            derivations.append(dict(origin='Original/' + relative, target=target, proof=proof))
    require({Path(r['target']).name for r in derivations} == {
        'EditorWindowController.swift', 'ApprovedViewCommitBroker.swift', 'EditorDocument.swift',
        'DocumentCommitTextStorage.swift', 'NativeMacroCommitContext.swift', 'SearchPanelController.swift',
        'TextUtilitiesController.swift', 'NativeApplicationDocuments.swift'},
        'only eight fixed declaring-source Test projections allowed')
    combined = combine_search(data)
    selections = {r['stage']: r['classes'] for r in FIXED_SELECTIONS}
    validate_methods(combined, sum([selections[n] for n in ('search32', 'nested8', 'negative7', 'caret2')], []))
    clients = b'\n'.join(data['Tests/NativeIntegration/' + name] for name in TEST_CLIENTS[1:])
    # Whole Native clients also contain preexisting unselected diagnostic classes.
    validate_methods(clients, selections['native19'], allow_other_classes=True)
    for name in TEST_CLIENTS:
        outputs['Package/Tests/NativeRoutingTests/' + name] = combined if name.startswith('Search') else data['Tests/NativeIntegration/' + name]
    outputs['Package/Tests/NativeRoutingTests/TransferPreferredResponderTests.swift'] = compose_transfer(data)
    outputs['Package/Package.swift'] = PACKAGE
    return outputs, derivations


def import_owned(root, path, name, expected):
    raw, before = read_snapshot(root, path.relative_to(root).as_posix())
    require(before['sha256'] == expected, 'unqualified helper import')
    spec = importlib.util.spec_from_file_location(name, path)
    require(spec is not None and spec.loader is not None, 'missing source loader')
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    require(read_snapshot(root, path.relative_to(root).as_posix()) == (raw, before), 'helper changed on import')
    return module


def freeze(root, run, captured):
    root, run = Path(root).absolute(), Path(run).absolute()
    verify_snapshot(root, captured)
    for relative, (_, row) in captured.items():
        if relative in DRIVERS:require(row['sha256'] == DRIVERS[relative][1], 'unqualified maintained helper bytes')
    sources, generated, originals, frozen, copies = [], [], [], [], []
    def write(name, data, mode=0o600):
        path = run / name
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        checked(run, path.parent, directory=True)
        with path.open('xb') as stream:stream.write(data)
        path.chmod(mode)
        return read_snapshot(run, name)[1]
    for relative, (raw, row) in captured.items():
        destination = 'Original/' + relative
        frozen.append(write(destination, raw, row['mode']))
        originals.append(row)
        sources.append(dict(source=relative, frozen=destination, sha256=row['sha256']))
    for relative, (destination, _) in DRIVERS.items():
        row = write(destination, captured[relative][0]);frozen.append(row)
        generated.append(dict(frozen=destination, sha256=row['sha256'], origin=relative))
        copies.append(dict(origin='Original/' + relative, target=destination))
    native = import_owned(run, run / 'Runner/run_native_regressions.py', 'run_native_regressions',
                          DRIVERS['Tests/NativeIntegration/run_native_regressions.py'][1])
    h = import_owned(run, run / 'Runner/run_application_language_catalog.py', 'native_approval_input_helpers',
                     DRIVERS['Tests/NativeIntegration/run_application_language_catalog.py'][1])
    data = {relative: raw for relative, (raw, _) in captured.items()}
    outputs, derivations = compose(data, native, discover(root)['packageSources'])
    outputs.update({'ToolSupport/scripts/swift.sh': data['scripts/swift.sh'],
                    'Runner/public_capture.py': data[LOCATION + 'public_capture.py']})
    for destination, raw in outputs.items():
        row = write(destination, raw, 0o700 if destination == 'ToolSupport/scripts/swift.sh' else 0o600)
        frozen.append(row);generated.append(dict(frozen=destination, sha256=row['sha256']))
        origins = [key for key, value in data.items() if value == raw]
        if origins:copies.append(dict(origin='Original/' + origins[0], target=destination))
    for name in ['State', 'Temporary', 'Stages', 'Commands', *[f'{parent}/{stage}' for parent in ('State', 'Temporary') for stage in FIXED_STAGES]]:
        (run / name).mkdir(parents=True, exist_ok=True, mode=0o700)
    dirs = {root}
    for relative in captured:dirs.update(p for p in (root / relative).parents if p.is_relative_to(root))
    owned = ['.', 'Original', 'Package', 'Runner', 'ToolSupport', 'ToolSupport/scripts', 'State', 'Temporary', 'Stages', 'Commands']
    owned += [f'{parent}/{stage}' for parent in ('State', 'Temporary') for stage in FIXED_STAGES]
    identities = dict(original=originals, frozen=frozen,
                      originalDirectories=[h.directory_fact(root, p) for p in sorted(dirs)],
                      ownedDirectories=[h.directory_fact(run, run / p) for p in owned])
    manifest = dict(sources=sources, generated=generated, identities=identities, copyRecipes=copies,
                    derivations=derivations, plan=fixed_plan(), sourcePaths=discover(root)['sourcePaths'],
                    inputTrees=['Original', 'Package', 'Runner', 'ToolSupport/scripts'])
    manifest['trees'] = {name: h.tree(run, run / name) for name in manifest['inputTrees']}
    h.save(run / 'input-identities.json', identities);h.save(run / 'sources.json', manifest)
    verify_snapshot(root, captured)
    return h, native, manifest


def receipt_shape(receipt):
    # Shape is never a completion receipt: actual native.receipt_success is also required.
    require(type(receipt) is dict and set(receipt) == FIELDS
            and type(receipt['seconds']) in (int, float) and math.isfinite(receipt['seconds'])
            and receipt['seconds'] >= 0, 'strict receipt schema/time')
    require(type(receipt['captured']) is dict and set(receipt['captured']) == {'stdout', 'stderr'}
            and all(type(v) is dict and set(v) == {'stored', 'received', 'discarded'}
                    for v in receipt['captured'].values()), 'strict capture schema')


def verify_state(run):
    state = checked(run, run / 'State', directory=True)
    require({p.name for p in state.iterdir()} == set(FIXED_STAGES), 'State root membership changed')
    for name in FIXED_STAGES:
        path = checked(run, state / name, directory=True)
        require(not list(path.iterdir()), 'unresolved State custody')


def execute(root, run, h, native, manifest, captured):
    result = dict(state='INCOMPLETE', exit=125, stages=[], stageEvidence=[],
                  qualification='Current-source maintained nonXML native approval gate only. '
                  'Fixed74 unique/75 occurrences including original68/69 subplan; ordinary failures remain1, compiler/unexpected/'
                  'retained custody/integrity failures125. Full method census does not prove guarded deep entry; '
                  'no broader XML/C3/GUI or Source adoption acceptance.',
                  targetEntered=False, mandatoryPositiveComplete=False)
    evidence = result['stageEvidence']
    artifact = None
    original_dirs = manifest['identities']['originalDirectories']
    stage_names = FIXED_STAGES
    evidence.extend([h.fact(run, run / 'sources.json'), h.fact(run, run / 'input-identities.json')])

    def verify_all():
        verify_snapshot(root, captured)
        require(h.load_json(run, run / 'sources.json') == manifest, 'source authority changed')
        require(h.load_json(run, run / 'input-identities.json') == manifest['identities'], 'identity authority changed')
        for row in original_dirs:
            require(h.directory_fact(root, root / row['path']) == row, 'original directory identity changed')
        for row in manifest['identities']['frozen']:
            require(h.fact(run, run / row['path']) == row, 'frozen identity changed')
        for row in manifest['identities']['ownedDirectories']:
            require(h.directory_fact(run, run / row['path']) == row, 'frozen directory changed')
        for name, rows in manifest['trees'].items():
            require(h.tree(run, run / name) == rows, 'frozen exact membership changed')
        for row in manifest['copyRecipes']:
            require(h.read_input(run, run / row['origin'])[0] == h.read_input(run, run / row['target'])[0],
                    'exact copy recipe changed')
        for row in manifest['derivations']:
            verify_raw_proof(h.read_input(run, run / row['origin'])[0],
                             h.read_input(run, run / row['target'])[0], row['proof'])
        support = h.checked(run, run / 'ToolSupport', directory=True)
        require({p.name for p in support.iterdir()} <= {'scripts', '.cache'}, 'foreign ToolSupport entry')
        cache = support / '.cache'
        if cache.exists() or cache.is_symlink():
            for p in [cache, *cache.rglob('*')]:h.checked(run, p, directory=p.is_dir())
        h.verify_evidence(run, evidence)
        reached = {r['name'] for r in result['stages']}
        require({p.name for p in (run / 'Commands').iterdir()} == {n + '.json' for n in reached}, 'command membership changed')
        require({p.name for p in (run / 'Stages').iterdir()} == reached, 'stage membership changed')
        for name in reached:
            require({p.name for p in (run / 'Stages' / name).iterdir()} == {'status.json', 'stdout.log', 'stderr.log'},
                    'stage leaves changed')
        allowed = {'Original', 'Package', 'Runner', 'ToolSupport', 'State', 'Temporary', 'Stages', 'Commands',
                   'BuildProducts', 'sources.json', 'input-identities.json', 'build-inputs.json',
                   'build-identities.json', *[r['stage'] + '-result.json' for r in FIXED_SELECTIONS]}
        require({p.name for p in run.iterdir()} <= allowed, 'unexpected run namespace')
        verify_state(run)
        native.verify(run, manifest)
        if artifact is not None:h.verify_capture(run, manifest, artifact)

    try:
        verify_all()
        watchdog = h.import_module(run / 'Runner/run-owned-search-tests.py', 'native_approval_watchdog').main
        parser = h.import_module(run / 'Runner/public_capture.py', 'native_approval_capture')
        verify_all()
        swift = str(run / 'ToolSupport/scripts/swift.sh')
        common = ['--package-path', str(run / 'Package'), '--scratch-path', str(run / 'BuildProducts')]
        commands = {'toolchain': ['/usr/bin/xcrun', 'swift', '--version'], 'build': [swift, 'build', *common, '--build-tests', '-Xswiftc', '-warnings-as-errors'], 'binpath': [swift, 'build', *common, '--show-bin-path', '-Xswiftc', '-warnings-as-errors']}
        bundle = run / 'BuildProducts' / (platform.machine() + '-apple-macosx/debug/NativeRoutingPackageTests.xctest')
        for selection in FIXED_SELECTIONS:
            literal = ','.join('NativeRoutingTests.' + row['class'] + '/' + method
                for row in selection['classes'] for method in row['methods'])
            commands[selection['stage']] = ['/usr/bin/xcrun', 'xctest', '-XCTest', literal, str(bundle)]
        commands = {name: ['/usr/bin/env', 'THEONLYPAD_STATE_DIRECTORY=' + str(run / 'State' / name), 'TMPDIR=' + str(run / 'Temporary' / name) + '/', *command] for name, command in commands.items()}
        for name in stage_names:
            verify_all()
            timeout = TIMEOUTS[name]
            command = commands[name]
            command_path = run / 'Commands' / (name + '.json')
            h.save(command_path, dict(name=name, command=command, timeout=timeout))
            evidence.append(h.fact(run, command_path))
            result['stages'].append(dict(name=name, command=command, timeout=timeout, exit=None))
            output = run / 'Stages' / name
            code = watchdog(['--timeout', str(timeout), '--output', str(output), '--', *command])
            result['stages'][-1]['exit'] = code
            require({p.name for p in output.iterdir()} == {'status.json', 'stdout.log', 'stderr.log'}, 'incomplete stage output')
            rows_out = [h.read_input(run, output / leaf) for leaf in ('status.json', 'stdout.log', 'stderr.log')]
            require(len(rows_out[0][0]) <= 8 * 1024 * 1024 and all(len(v[0]) <= 1_048_576 for v in rows_out[1:]), 'capture exceeds bound')
            evidence.extend([h.directory_fact(run, output), *[r[1] for r in rows_out]])
            receipt = h.load_json(run, output / 'status.json')
            receipt_shape(receipt)
            require(native.receipt_success(output, command, code), 'direct owned receipt refused')
            verify_all()
            require(all(not list((run / 'State' / stage_name).iterdir()) for stage_name in FIXED_STAGES),
                    'unresolved State custody after child')
            raw = rows_out[1][0] + b'\n' + rows_out[2][0]
            require(b'NATIVE_EVENT_ORACLE_INCOMPLETE' not in raw, 'retained oracle custody; incomplete')
            require(not any(marker in raw for marker in (b'NATIVE_EVENT_ORACLE', b'NESTEDUNDO',
                b'NATIVESIBLING', b'APPROVALRETIRE', b'XMLTRANSFER', b'XMLLATEHISTORY',
                b'NATIVEUNDOEVENT', b'NATIVEUNDOPROVISIONAL')), 'unselected diagnostic marker')
            if name in ('toolchain', 'build', 'binpath'):
                require(code == 0, 'nonzero compiler/toolchain stage; not behavioral RED')
                require(re.search(rb'(?im)^.*(?:warning:|error:)', raw) is None, 'compiler/toolchain diagnostic')
            else:
                selection = next(r for r in FIXED_SELECTIONS if r['stage'] == name)
                report = parser.parse_result(raw, code, selection['classes'])
                h.save(run / (name + '-result.json'), report)
                evidence.append(h.fact(run, run / (name + '-result.json')))
                result['stages'][-1]['parsedResult'] = report
                require(not list((run / 'State' / name).iterdir()), 'unresolved State after test stage')
                if selection['mandatoryPositive'] and report['exit'] != 0:
                    result['stoppedAfterPrerequisiteOrdinaryFailure'] = name
                    break
            if name == 'binpath':
                artifact = h.capture(run, manifest)
                evidence.extend([h.fact(run, run / 'build-inputs.json'), h.fact(run, run / 'build-identities.json')])
            verify_all()
        reached = {stage['name']: stage for stage in result['stages']}
        result['targetEntered'] = all(row['stage'] in reached and
            reached[row['stage']].get('parsedResult', {}).get('executed') == sum(len(c['methods']) for c in row['classes'])
            for row in FIXED_SELECTIONS)
        result['completeFixedMethodCensus'] = result['targetEntered']
        result['complete68MethodCensus'] = all(row['stage'] in reached and
            reached[row['stage']].get('parsedResult', {}).get('executed') == sum(len(c['methods']) for c in row['classes'])
            for row in FIXED_SELECTIONS[:-1])
        result['transferDeepControlEntry'] = 'NOT_INDEPENDENTLY_PROVEN_BY_OUTPUT'
        observed = [(identity, outcome) for stage in result['stages']
            for identity, outcome in stage.get('parsedResult', {}).get('observed', [])]
        result['observedOccurrences'] = len(observed)
        result['observedUniqueMethods'] = len({identity for identity, _ in observed})
        old_observed = [(identity, outcome) for stage in result['stages'] if stage['name'] != 'transfer6'
            for identity, outcome in stage.get('parsedResult', {}).get('observed', [])]
        if result['complete68MethodCensus']:
            require(len(old_observed) == 69 and len({identity for identity, _ in old_observed}) == 68,
                    'complete68/69 actual subplan census differs')
        if result['completeFixedMethodCensus']:
            require(len(observed) == 75 and len({identity for identity, _ in observed}) == 74,
                    'complete74/75 actual full census differs')
        result['mandatoryPositiveComplete'] = all(row['stage'] in reached and reached[row['stage']]['exit'] == 0
            for row in FIXED_SELECTIONS if row['mandatoryPositive'])
        if all(stage['exit'] == 0 for stage in result['stages']):
            require([stage['name'] for stage in result['stages']] == FIXED_STAGES, 'all fixed stages required for PASS')
        failed = any(r['exit'] != 0 for r in result['stages'])
        result.update(state='COMPLETE_ORDINARY_FAILURE' if failed else 'COMPLETE_PASS', exit=1 if failed else 0)
    except ERRORS as error:
        result.update(state='INCOMPLETE', exit=125, failureType=type(error).__name__, failure=str(error))
    finally:
        try:
            verify_all()
            result['postflightVerified'] = True
        except ERRORS as error:
            result.update(state='INCOMPLETE', exit=125, postflightVerified=False, postflightFailure=str(error))
        result['stateDirectoryEntries'] = sorted(p.relative_to(run).as_posix() for p in (run / 'State').rglob('*')) if (run / 'State').is_dir() else []
        h.save(run / 'result.json', result)
    print(json.dumps(result), flush=True)
    return result['exit']


def main(argv):
    validate_cli(argv)
    root = Path(__file__).absolute().parents[2]
    captured = snapshot(root, discover(root)['inputs'])
    local = root / '.local'
    local.mkdir(mode=0o700, exist_ok=True)
    checked(root, local, directory=True)
    base = local / 'native-approval-regressions'
    base.mkdir(mode=0o700, exist_ok=True)
    checked(root, base, directory=True)
    require(stat.S_IMODE(base.stat().st_mode) == 0o700, 'private output directory must be0700')
    run = base / uuid.uuid4().hex
    run.mkdir(mode=0o700)
    h, native, manifest = freeze(root, run, captured)
    print('Native approval evidence: ' + run.relative_to(root).as_posix(), flush=True)
    return execute(root, run, h, native, manifest, captured)


if __name__ == '__main__':
    sys.dont_write_bytecode = True
    os.umask(0o077)
    try:
        raise SystemExit(main(sys.argv[1:]))
    except ERRORS as error:
        print('Native approval execution refused: ' + type(error).__name__ + ': ' + str(error), file=sys.stderr)
        raise SystemExit(125)
