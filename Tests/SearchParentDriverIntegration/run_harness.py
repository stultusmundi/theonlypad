"""Frozen parent-driver ownership tests; no real child or GUI."""
import re

def instrument(data):
    transformer = load(Path(__file__).with_name('driver_transform.py'), 'frozen_driver_transform')
    joined = load(Path(__file__).with_name('joined_transform.py'), 'frozen_joined_transform')
    return joined.driver(transformer.transform_driver(data.decode('utf-8'))).encode('utf-8')


def instrument_lifecycle(data):
    transformer = load(Path(__file__).with_name('driver_transform.py'), 'frozen_lifecycle_transform')
    joined = load(Path(__file__).with_name('joined_transform.py'), 'frozen_joined_lifecycle_transform')
    return joined.lifecycle(transformer.transform_lifecycle(data.decode('utf-8'))).encode('utf-8')


def instrument_lane(data):
    joined = load(Path(__file__).with_name('joined_transform.py'), 'frozen_joined_lane_transform')
    return joined.lane(data.decode('utf-8')).encode('utf-8')


def validate_tests(text, expected):
    def normalized(value):
        match = re.fullmatch(r'-\[SearchExecutionTests\.(\w+) (test\w+)\]', value)
        return match[1] + '.' + match[2] if match else value
    started = re.findall(r"Test Case '([^']+)' started\.", text)
    passed = re.findall(r"Test Case '([^']+)' passed \(", text)
    started, passed = [normalized(v) for v in started], [normalized(v) for v in passed]
    counts = re.findall(r'Executed (\d+) tests?, with (\d+) failures', text)
    if (not expected or len(set(expected)) != len(expected)
            or sorted(started) != sorted(expected) or sorted(passed) != sorted(expected)
            or not counts or tuple(map(int, counts[-1])) != (len(expected), 0)
            or any(int(failed) for _, failed in counts)):
        raise ValueError('incomplete named XCTest execution')
    return len(expected)

from pathlib import Path
import hashlib
import importlib.util
import json
import os
import sys
import tempfile
import subprocess

SDK_INPUTS = (
    'SDKSettings.json', 'usr/include/sys/wait.h', 'usr/include/sys/errno.h',
    'usr/include/sys/signal.h', 'usr/include/sys/stat.h', 'usr/include/sys/types.h',
    'usr/include/unistd.h', 'usr/include/fcntl.h', 'usr/include/spawn.h',
)

FIXED = (
    'Tests/SearchExecutionTests/SearchParentWireDriverTests.swift',
    'Tests/SearchExecutionTests/SearchParentWireDriverTestHarness.swift',
    'Tests/SearchExecutionTests/SearchParentJoinedShutdownTests.swift',
    'Tests/SearchParentDriverIntegration/SearchParentWireDriverInstrumentedTests.swift',
    'Tests/SearchParentDriverIntegration/SearchParentJoinedShutdownInstrumentedTests.swift',
    'Tests/SearchParentDriverIntegration/run_harness.py',
    'Tests/SearchParentDriverIntegration/driver_transform.py',
    'Tests/SearchParentDriverIntegration/joined_transform.py',
    'Tests/SearchParentDriverIntegration/test_runner.py',
    'Tests/SearchChildIntegration/run_harness.py',
    'scripts/swift.sh', 'scripts/run-owned-search-tests.py',
    'scripts/test-search-parent-driver.sh', 'Package.swift',
)
REQUIRED_INSTRUMENTED = (
    'testSettlementCancellationCleanupPermitsFreshAdmissionWithoutShutdown',
    'testSettlementCloseAcknowledgmentPermitsFreshAdmissionWithoutShutdown',
    'testSettlementRejectsHandleChangedDuringInspection',
    'testSettlementRejectsSessionRetiredDuringInspection',
    'testTerminalPublicationWaitsForSourceScopeThenImmediateResubmit',
    'testRefusedAdmissionPreservesUnobservedCompactFailure',
    'testNoTicketRefusalCannotClearHeldIdleConsumeCredit',
    'testCancellationBeforeBeginUsesSharedReceiptAndSuppressesHello',
    'testCancellationBeforeRefusedBeginSettlesWithoutTicket',
    'testObserverCancellationBeforeInstallDoesNotConsumeReceipt',
    'testCancellationAtDeliveryClaimPreservesOneShotReceipt',
    'testNewGenerationWaitsForOldReadOwnerReceipt',
    'testEOFDuringUploadCannotRaceIntoProtocolFailure',
    'testCancelIntentCannotRaceIntoProtocolFailure',
    'testShutdownIntentCannotRaceIntoProtocolFailure',
    'testReadPayloadIsIneligibleUntilReadHelperReturns',
    'testReadFailureWaitsForItsHelperBeforeAuthorityObservation',
    'testFalseIdleRetirementKeepsOldGenerationUnavailable',
    'testTerminalSequenceExhaustionKeepsAcceptedResult',
    'testPartialResponseSequenceExhaustionReservesCleanup',
    'testExpectGatePreventsPrematureConsumeAfterUploadReceipt',
)

REQUIRED_JOINED_ORDINARY = (
    'testNeverAdmittedNilJoinsAndClosesAdmission',
    'testNilAfterConsumedAdmissionLatchesStaleOwnership',
    'testConsumedLatestHandleIsAdmittedAndCompletionIsStable',
    'testWrongLaterKeyCannotBorrowNeverAdmittedCompletion',
    'testLegacyFirstPermanentlyRefusesJoinedMode',
)
REQUIRED_JOINED_INSTRUMENTED = (
    'testPreOwnerStartClosesActualSubmitAdmission',
    'testJoinedFirstLegacySecondAliasesOneOriginalCommand',
    'testLegacyGraceHeldRepeatedSnapshotReturnsAndJoinedStaysRefused',
    'testCancelledMatchingCallerAndWrongLateKeyPreserveOwner',
    'testActiveAdmissionRefusalStillJoinsFailedBeginWithoutConsumingReceipt',
    'testUnconsumedReceiptRefusalRemainsAfterActualConsumption',
    'testObserverPresentRefusalPreservesActualOutcome',
    'testJoinedAbandonDeliversExistingObserverBeforeDiscard',
    'testJoinedAbandonPreservesCancellationBeforePublication',
    'testJoinedAbandonPreservesCancellationAtDeliveryClaim',
    'testHeldReadOwnerRequiresFinalWakeAndRescuesMutationFinitely',
    'testMechanicalReadinessBeforeRegistrationDoesNotLoseWake',
    'testOriginalPendingChildRemainsPendingAfterRealCleanup',
    'testHeldLaneLoopAcknowledgementPreventsCommittedCompletion',
    'testConflictingLaneObserverNormalizesFiniteFailure',
    'testHeldCodecBodyCannotBeReportedAsJoined',
    'testHeldCodecCompletionScopeRequiresExistingLaneStop',
    'testHeldRealCloseAcknowledgementPreventsJoinedCompletion',
    'testHeldConsumingReapPreventsJoinedCompletion',
)

PACKAGE = '''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "SearchParentDriverIntegration", platforms: [.macOS(.v14)], targets: [
  .target(name: "PadCore"),
  .target(name: "SearchExecution", dependencies: ["PadCore"]),
  .testTarget(name: "SearchExecutionTests", dependencies: ["PadCore", "SearchExecution"])
], swiftLanguageModes: [.v5])
'''


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    # Execute the declared bytes, never timestamp-valid unbound Python bytecode.
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'rb') as source:
        data = source.read()
    exec(compile(data, str(path), 'exec'), module.__dict__)
    return module


def discover(root, common):
    paths = []
    for target in ('PadCore', 'SearchExecution'):
        folder = common.real_path(root, root / 'Sources' / target)
        found = sorted(folder.glob('*.swift'))
        if not found:
            raise ValueError('missing production target')
        paths.extend(found)
    paths.extend(root / name for name in FIXED)
    for path in paths:
        common.real_path(root, path)
        if not path.is_file():
            raise ValueError('missing source input')
    return paths


def freeze(root, run, common, sdk_root=None):
    paths = discover(root, common)
    items, expected = [], []
    for source in paths:
        relative = source.relative_to(root).as_posix()
        original = common.read_source(source)
        data = original
        prefix = 'Package' if relative.startswith(('Sources/', 'Tests/SearchExecutionTests/')) else 'Runner'
        target = run / prefix / relative
        if source.name in ('SearchParentWireDriverInstrumentedTests.swift',
                           'SearchParentJoinedShutdownInstrumentedTests.swift'):
            target = run / 'Package/Tests/SearchExecutionTests' / source.name
        if relative in ('Sources/SearchExecution/SearchParentWireDriver.swift',
                        'Sources/SearchExecution/SearchChildLifecycle.swift',
                        'Sources/SearchExecution/SearchParentWireBridge.swift'):
            transform = {'SearchParentWireDriver.swift': instrument,
                         'SearchChildLifecycle.swift': instrument_lifecycle,
                         'SearchParentWireBridge.swift': instrument_lane}[source.name]
            data = transform(original)
            origin = run / 'Original' / source.name
            origin.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            origin.write_bytes(original)
            items.append(dict(source=relative, frozen=origin.relative_to(run).as_posix(),
                              sha256=common.digest(original), originSHA256=common.digest(original)))
        if source.name in ('SearchParentWireDriverTests.swift', 'SearchParentWireDriverInstrumentedTests.swift',
                           'SearchParentJoinedShutdownTests.swift', 'SearchParentJoinedShutdownInstrumentedTests.swift'):
            text = original.decode()
            if '#if' in text or 'XCTSkip' in text:
                raise ValueError('conditional or skipped driver test refused')
            names = re.findall(r'\bfunc (test\w+)\s*\(', text)
            if not names or len(names) != len(set(names)):
                raise ValueError('missing or duplicate named tests')
            if source.stem == 'SearchParentWireDriverInstrumentedTests' and not set(REQUIRED_INSTRUMENTED).issubset(names):
                raise ValueError('required ownership case missing')
            if source.stem == 'SearchParentJoinedShutdownTests' and not set(REQUIRED_JOINED_ORDINARY).issubset(names):
                raise ValueError('required ordinary joined case missing')
            if source.stem == 'SearchParentJoinedShutdownInstrumentedTests' and not set(REQUIRED_JOINED_INSTRUMENTED).issubset(names):
                raise ValueError('required frozen joined case missing')
            owner = 'SearchParentJoinedShutdownTests' if source.stem.startswith('SearchParentJoinedShutdown') else source.stem
            expected.extend(owner + '.' + name for name in names)
        target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        target.write_bytes(data)
        if source.suffix == '.sh':
            target.chmod(0o700)
        items.append(dict(source=relative, frozen=target.relative_to(run).as_posix(),
                          sha256=common.digest(data), originSHA256=common.digest(original)))
    if discover(root, common) != paths:
        raise ValueError('source membership changed during capture')
    for item in items:
        if common.digest(common.read_source(common.real_path(root, root / item['source']))) != item['originSHA256']:
            raise ValueError('origin changed during capture')
    package = run / 'Package/Package.swift'
    package.write_text(PACKAGE)
    generated = [dict(frozen='Package/Package.swift', sha256=common.digest(package.read_bytes()))]
    original_wrapper = (run / 'Runner/scripts/swift.sh').read_bytes()
    anchor = b'cd "$(dirname "$0")/.."'
    if original_wrapper.count(anchor) != 1:
        raise ValueError('swift wrapper cd anchor not unique')
    wrapper = run / 'Runner/scripts/swift-driver.sh'
    wrapper.write_bytes(original_wrapper.replace(anchor, b'cd "$(dirname "$0")/../.."'))
    wrapper.chmod(0o700)
    generated.append(dict(frozen=wrapper.relative_to(run).as_posix(), sha256=common.digest(wrapper.read_bytes())))
    sdk = Path(sdk_root) if sdk_root is not None else Path(
        subprocess.check_output(['/usr/bin/xcrun', '--show-sdk-path'], text=True).strip()).resolve()
    if not sdk.is_absolute() or not sdk.is_dir() or sdk.is_symlink():
        raise ValueError('selected SDK must be an absolute real directory')
    headers = []
    for name in SDK_INPUTS:
        source = sdk / name
        data = common.read_source(common.real_path(sdk, source))
        target = run / 'SDK' / name
        target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        target.write_bytes(data)
        generated.append(dict(frozen=target.relative_to(run).as_posix(), sha256=common.digest(data)))
        headers.append(dict(source=str(source), sha256=common.digest(data)))
    manifest = dict(version=1, sources=items, expectedTests=expected,
                    generated=generated, SDK=str(sdk), headers=headers)
    (run / 'sources.json').write_text(json.dumps(manifest, indent=2) + '\n')
    verify(run, manifest, common)
    return manifest


def verify(run, manifest, common):
    common.verify_frozen(run, manifest)
    expected = set()
    for item in manifest['sources'] + manifest['generated']:
        name = Path(item['frozen'])
        expected.add(('file', name.as_posix()))
        for parent in name.parents:
            if len(parent.parts) < 2:
                break
            expected.add(('directory', parent.as_posix()))
    actual = set()
    for top in ('Package', 'Runner', 'Original', 'SDK'):
        for folder, directories, files in os.walk(run / top, followlinks=False):
            for kind, names in [('directory', directories), ('file', files)]:
                for name in names:
                    path = Path(folder) / name
                    if path.is_symlink():
                        raise ValueError('symlink frozen input refused')
                    actual.add((kind, path.relative_to(run).as_posix()))
    if actual != expected:
        raise ValueError('complete frozen input membership changed')
    for header in manifest['headers']:
        if common.digest(common.read_source(common.real_path(Path(manifest['SDK']), Path(header['source'])))) != header['sha256']:
            raise ValueError('selected SDK input changed')
    original_wrapper = (run / 'Runner/scripts/swift.sh').read_bytes()
    anchor = b'cd "$(dirname "$0")/.."'
    if original_wrapper.count(anchor) != 1 or original_wrapper.replace(
            anchor, b'cd "$(dirname "$0")/../.."') != (run / 'Runner/scripts/swift-driver.sh').read_bytes():
        raise ValueError('swift wrapper derivation changed')
    # Verify the transformation relationship as well as both pinned byte streams.
    for name, transform in (('SearchParentWireDriver.swift', instrument),
                            ('SearchChildLifecycle.swift', instrument_lifecycle),
                            ('SearchParentWireBridge.swift', instrument_lane)):
        source = common.read_source(common.real_path(run, run / 'Original' / name))
        compiled = common.read_source(common.real_path(run, run / 'Package/Sources/SearchExecution' / name))
        if transform(source) != compiled:
            raise ValueError('instrumented source relationship changed')


def execute(run, scratch, common, watchdog_main):
    result = dict(exit=125, stages=[], testsExecuted=None)
    try:
        manifest_bytes = (run / 'sources.json').read_bytes()
        manifest = json.loads(manifest_bytes)
        result['sourceManifestSHA256'] = common.digest(manifest_bytes)
        swift = str(run / 'Runner/scripts/swift-driver.sh')
        stages = [
            ('toolchain', 30, ['/usr/bin/xcrun', 'swift', '--version']),
            ('test', 180, ['/usr/bin/env', 'SDKROOT=' + manifest['SDK'], swift, 'test', '--package-path', str(run / 'Package'),
                           '--scratch-path', str(scratch), '--filter',
                           'SearchParentWireDriverTests|SearchParentWireDriverInstrumentedTests|SearchParentJoinedShutdownTests']),
        ]
        def checked_inputs():
            if (run / 'sources.json').read_bytes() != manifest_bytes:
                raise ValueError('source manifest changed')
            verify(run, manifest, common)
        for name, seconds, command in stages:
            checked_inputs()
            output = run / name
            # Direct same-process supervisor. Never wrap this coordinator in another watchdog.
            code = watchdog_main(['--timeout', str(seconds), '--output', str(output), '--', *command])
            result['stages'].append(dict(name=name, exit=code))
            checked_inputs()
            if code != 0:
                result['exit'] = code if type(code) is int and 0 < code < 256 else 125
                return result['exit']
            if not common.receipt_success(output, command):
                raise ValueError('incomplete process receipt')
            if name == 'test':
                stdout = (output / 'stdout.log').read_text(errors='strict')
                stderr = (output / 'stderr.log').read_text(errors='strict')
                result['testsExecuted'] = validate_tests(stdout, manifest['expectedTests'])
                if 'warning:' in stderr or 'error:' in stderr:
                    raise ValueError('compiler diagnostics require review')
        result['exit'] = 0
        return 0
    except (OSError, ValueError, TypeError, KeyError, UnicodeError) as error:
        result['failure'] = type(error).__name__ + ': ' + str(error)
        return 125
    finally:
        (run / 'status.json').write_text(json.dumps(result, indent=2) + '\n')


def main(argv=None):
    if argv is None:
        argv = sys.argv[1:]
    if argv:
        raise SystemExit('This runner takes no arguments; it executes the complete driver and joined-shutdown suites.')
    root = Path(__file__).absolute().parents[2]
    common = load(root / 'Tests/SearchChildIntegration/run_harness.py', 'parent_driver_common')
    parent = common.real_path(root, root / '.local/search-parent-driver-integration')
    parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix='run.', dir=parent))
    print('Private parent-driver evidence: ' + str(run), flush=True)
    try:
        freeze(root, run, common)
        runner = load(run / 'Runner/Tests/SearchParentDriverIntegration/run_harness.py', 'frozen_parent_driver_runner')
        frozen_common = load(run / 'Runner/Tests/SearchChildIntegration/run_harness.py', 'frozen_parent_driver_common')
        watchdog = load(run / 'Runner/scripts/run-owned-search-tests.py', 'frozen_parent_driver_watchdog')
        scratch = common.real_path(root, root / '.build/search-worker-engine-task2')
        return runner.execute(run, scratch, frozen_common, watchdog.main)
    except (OSError, ValueError, ImportError) as error:
        (run / 'status.json').write_text(json.dumps(dict(exit=125, failure=type(error).__name__)) + '\n')
        return 125


if __name__ == '__main__':
    raise SystemExit(main())
