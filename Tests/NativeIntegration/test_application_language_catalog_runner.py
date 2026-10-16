"""Ten finite pure contracts for the standalone fixed application/catalog runner.

Only the synchronous child boundary is substituted. Synthetic object/bundle bytes
are NEVER executed. No subprocess, compiler, native process, timer or real PID.
The retained baseline is inert: positive premises fail ordinarily before deep
controls. Root, not this packet's author, owns actual RED/GREEN execution.
"""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import platform
import shlex
import sys
import tempfile
import unittest
from unittest import mock

HERE = Path(__file__).absolute().parent
CANDIDATE = HERE.parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


RUNNER = load('application_catalog_test_subject', HERE / 'run_application_language_catalog.py')
PROOF = load('application_catalog_proof_test_subject', HERE / 'application_language_catalog_proof.py')
OLD = 'DocumentSearchAppRoutingTests'
NEW = 'ApplicationLanguageCatalogTests'
METHODS = {
    OLD: (
        'testCapturedSearchPanelClaimsOnlyCloseAndSixNativeEditingSelectors',
        'testCapturedSearchAvailabilityAndDispatchShareIdentityAndRefusalPolicy',
        'testActualManagedConfigurationStaysSearchLazyAndAppGuardsPrecedeScope',
        'testActualQuitPublishesNativeReceiptThenJoinsSearchAndExternalExactlyOnceAcrossVetoAndRetry',
    ),
    NEW: (
        'testApplicationCatalogStartupRemainsLazyAndStartsOneActualRead',
        'testApplicationCatalogFailureRetainsLastConfirmedPublicationAndDocumentStartup',
        'testApplicationCatalogErrorPresentationReentryCannotClobberSuccessorState',
        'testQuitBeforeCatalogStartupNeverConstructsOrReadsCatalog',
        'testBusyCatalogQuitVetoDoesNotInvalidateAndReleasedReadSettles',
        'testActualUnresolvedWriteBlocksQuitWithoutAcknowledgingOrDiscarding',
        'testNativeVetoRollsBackOnlyActualCatalogReservationAndKeepsSuccessfulCatalogWrite',
        'testUnsettledSearchVetoReleasesCatalogWithoutReopeningTerminalSearch',
        'testSuccessfulQuitReservesThenJoinsAndInvalidatesActualCatalogBeforeSingleReply',
        'testFalseReplyReentryPreservesNewAttemptAndItsNewCatalogReservation',
    ),
}
TEST_MAP = {
    'Tests/NativeIntegration/ApplicationLanguageCatalogIntegrationTests.swift':
        'Package/Tests/NativeRoutingTests/DocumentSearchAppRoutingTests.swift',
    'Tests/NativeIntegration/ApplicationCatalogStoreControl.swift':
        'Package/Tests/NativeRoutingTests/ApplicationCatalogStoreControl.swift',
    'Tests/PadCoreTests/CatalogTestFixture.swift':
        'Package/Tests/NativeRoutingTests/CatalogTestFixture.swift',
}
TAILS = {
    'AppDelegate.swift': ('DocumentSearchAppRoutingAccess.swift', 'ApplicationCatalogAccess.swift'),
    'EditorWindowController.swift': ('DocumentSearchEditorBindingAccess.swift',),
    'NativeApplicationDocuments.swift': ('DocumentSearchAppNativeOwnerAccess.swift',),
    'DocumentSearchPanelController.swift': ('DocumentSearchPanelAccess.swift',),
}
ROOTS = ('Sources/PadCore', 'Sources/SearchExecution', 'Sources/TheOnlyPad')
EXCLUDED = 'Sources/TheOnlyPad/TheOnlyPadApplication.swift'
MODULES = ('PadCore', 'SearchExecution', 'NativeRouting', 'NativeRoutingTests', 'NativeRoutingPackageTests')
STAGES = ('toolchain', 'build', 'binpath', 'old4', 'new10')
BUDGETS = (30, 180, 30, 180, 180)
OLD_TEST = 'Tests/NativeIntegration/DocumentSearchAppRoutingTests.swift'
COMBINED = 'Tests/NativeIntegration/ApplicationLanguageCatalogIntegrationTests.swift'


def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data if isinstance(data, bytes) else data.encode())


def save(path, value):
    write(path, json.dumps(value, indent=2) + '\n')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def replace_same_bytes(path):
    data = path.read_bytes()
    replacement = path.with_name(path.name + '.replacement')
    write(replacement, data)
    replacement.chmod(path.stat().st_mode & 0o777)
    replacement.replace(path)


def positive_dict(case, value, label):
    case.assertIsInstance(value, dict, label + ' absent; deeper controls UNENTERED')
    if not isinstance(value, dict):
        return False
    return True


def repository(root):
    """Copy the Test's actual repository-layout inputs into synthetic state.

    This also works after public adoption: only ordinary repository-relative
    origins are read. The private authoring Candidate is explicitly labeled a
    future-layout fixture; its private AppDelegate substitution is outside the
    runner API and is never a fallback. No fake compiler acceptance is native
    compilation or public Source adoption.
    """
    for prefix in ROOTS:
        for path in sorted((CANDIDATE / prefix).rglob('*.swift')):
            write(root / path.relative_to(CANDIDATE), path.read_bytes())
    names = [
        'scripts/swift.sh', 'scripts/run-owned-search-tests.py',
        'scripts/test-application-language-catalog.sh',
        'Tests/NativeIntegration/run_native_regressions.py',
        'Tests/NativeIntegration/run_application_language_catalog.py',
        'Tests/NativeIntegration/application_language_catalog_proof.py',
        'Tests/NativeIntegration/test_application_language_catalog_runner.py',
        'Tests/NativeIntegration/application-language-catalog-Package.swift',
        'Tests/NativeIntegration/application-language-catalog-methods.json',
        OLD_TEST, *TEST_MAP,
        *('Tests/NativeIntegration/' + tail for tails in TAILS.values() for tail in tails),
    ]
    for relative in dict.fromkeys(names):
        write(root / relative, (CANDIDATE / relative).read_bytes())
    # Exact native entry exclusion must not accidentally exclude Core basenames.
    write(root / 'Sources/PadCore/TheOnlyPadApplication.swift', '// synthetic Core same-basename control\n')
    write(root / 'Sources/PadSearchWorkerRuntime/Excluded.swift', '// outside fixed three-root graph\n')
    write(root / 'Sources/PadSearchWorker/Excluded.swift', '// outside fixed three-root graph\n')
    root.chmod(0o700)
    return root


def success(selection):
    # Darwin suite names are plain class names; cases are module-qualified.
    n = len(METHODS[selection])
    lines = ["Test Suite 'Selected tests' started at 2026-10-16 12:00:00.000.",
             "Test Suite 'NativeRoutingPackageTests.xctest' started at 2026-10-16 12:00:00.001.",
             "Test Suite '" + selection + "' started at 2026-10-16 12:00:00.002."]
    for name in METHODS[selection]:
        identity = '-[NativeRoutingTests.' + selection + ' ' + name + ']'
        lines += ["Test Case '" + identity + "' started.",
                  "Test Case '" + identity + "' passed (0.001 seconds)."]
    lines += ["Test Suite '" + selection + "' passed at 2026-10-16 12:00:01.000.",
              f'Executed {n} tests, with 0 failures (0 unexpected) in 0.001 (0.002) seconds',
              "Test Suite 'NativeRoutingPackageTests.xctest' passed at 2026-10-16 12:00:01.001.",
              f'Executed {n} tests, with 0 failures (0 unexpected) in 0.001 (0.003) seconds',
              "Test Suite 'Selected tests' passed at 2026-10-16 12:00:01.002.",
              f'Executed {n} tests, with 0 failures (0 unexpected) in 0.001 (0.004) seconds']
    return '\n'.join(lines) + '\n'


def graph(run, manifest=None):
    """Full accepted five-module schema; objects and executable leaf are fake.

    Each group uses actual generated membership, filelist/outputmap paths, source
    to object bijection, authored flags, module companions and one link union.
    """
    if manifest is None:
        originals, generated = [], []
        payloads = {
            'Package/Sources/PadCore/One.swift': b'// synthetic core one\n',
            'Package/Sources/PadCore/Two.swift': b'// synthetic core two\n',
            'Package/Sources/SearchExecution/One.swift': b'// synthetic search\n',
            'Package/Sources/NativeRouting/One.swift': b'// synthetic native\n',
            'Package/Package.swift': (HERE / 'application-language-catalog-Package.swift').read_bytes(),
        }
        for origin, destination in TEST_MAP.items():
            payloads[destination] = (CANDIDATE / origin).read_bytes()
        for relative, data in payloads.items():
            original = 'Original/' + relative
            write(run / original, data)
            write(run / relative, data)
            digest = hashlib.sha256(data).hexdigest()
            originals.append(dict(source=relative, frozen=original, sha256=digest))
            generated.append(dict(frozen=relative, sha256=digest, origin=relative))
        manifest = dict(sources=originals, generated=generated, inputTrees=['Original', 'Package'])
        save(run / 'sources.json', manifest)
    binary = run / 'BuildProducts' / (platform.machine() + '-apple-macosx/debug')
    binary.mkdir(parents=True, exist_ok=True)
    groups = {}
    for module in MODULES:
        if module == 'NativeRoutingPackageTests':
            sources = [binary / 'NativeRoutingPackageTests.derived/runner.swift']
            write(sources[0], '// synthetic generated runner; never compiled\n')
        else:
            prefix = 'Package/' + ('Tests/' if module == 'NativeRoutingTests' else 'Sources/') + module + '/'
            sources = sorted(run / row['frozen'] for row in manifest['generated']
                             if row['frozen'].startswith(prefix) and row['frozen'].endswith('.swift'))
        objects = []
        mapping = {'': {'swift-dependencies': str(binary / (module + '.build/master.swiftdeps'))}}
        for source in sources:
            obj = binary / (module + '.build') / (source.name + '.o')
            write(obj, b'synthetic object; NEVER EXECUTE')
            objects.append(str(obj))
            mapping[str(source)] = {'object': str(obj)}
        filelist = binary / (module + '.build/sources')
        outputmap = binary / (module + '.build/output-file-map.json')
        write(filelist, ''.join(shlex.quote(str(p)) + '\n' for p in sources))
        save(outputmap, mapping)
        arguments = ['-target', platform.machine() + '-apple-macosx14.0',
                     '-warnings-as-errors', '-package-name', 'native_fixture']
        if module != 'NativeRoutingPackageTests':
            arguments += ['-swift-version', '5']
        for suffix in ('.swiftmodule', '.swiftdoc', '.swiftsourceinfo', '.abi.json'):
            write(binary / 'Modules' / (module + suffix), b'synthetic module companion')
        groups[module] = dict(moduleName=module, sources=list(map(str, sources)), objects=objects,
                              fileList=str(filelist), outputFileMapPath=str(outputmap),
                              moduleOutputPath=str(binary / 'Modules' / (module + '.swiftmodule')),
                              otherArguments=arguments)
    write(binary / 'NativeRoutingPackageTests.product/Objects.LinkFileList',
          ''.join(shlex.quote(p) + '\n' for module in MODULES for p in groups[module]['objects']))
    bundle = binary / 'NativeRoutingPackageTests.xctest'
    for relative in (
        'Contents/MacOS/NativeRoutingPackageTests',
        'Contents/MacOS/NativeRoutingPackageTests.dSYM/Contents/Info.plist',
        'Contents/MacOS/NativeRoutingPackageTests.dSYM/Contents/Resources/DWARF/NativeRoutingPackageTests',
        'Contents/MacOS/NativeRoutingPackageTests.dSYM/Contents/Resources/Relocations/aarch64/NativeRoutingPackageTests.yml',
    ):
        write(bundle / relative, b'synthetic bundle leaf; NEVER EXECUTE')
    (bundle / 'Contents/MacOS/NativeRoutingPackageTests').chmod(0o700)
    description = dict(swiftCommands=groups, builtTestProducts=[dict(
        binaryPath=str(bundle / 'Contents/MacOS/NativeRoutingPackageTests'),
        packagePath=str(run / 'Package'), productName='NativeRoutingPackageTests')])
    save(binary / 'description.json', description)
    return binary, manifest, description


class ChildBoundary:
    """One synchronous argv boundary. All filesystem/graph validators stay real."""
    def __init__(self, run, failures=None, mutate=None, receipt_mutation=None, retain=False):
        self.run = run
        self.failures = failures or {}
        self.mutate = mutate
        self.receipt_mutation = receipt_mutation
        self.retain = retain
        self.calls = []
        self.prechild = []

    def __call__(self, argv):
        output = Path(argv[argv.index('--output') + 1])
        name = output.name
        command = argv[argv.index('--') + 1:]
        timeout = int(argv[argv.index('--timeout') + 1])
        self.calls.append((name, timeout, command))
        command_path = self.run / 'Commands' / (name + '.json')
        # Capture what actual producer persisted BEFORE this synchronous callback.
        self.prechild.append(dict(name=name, command=command_path.read_bytes() if command_path.exists() else None,
                                  build=(self.run / 'build-inputs.json').exists(),
                                  oldResult=(self.run / 'old4-result.json').read_bytes()
                                  if (self.run / 'old4-result.json').exists() else None))
        code = self.failures.get(name, 0)
        stdout = b''
        if name == 'toolchain':
            stdout = b'Apple Swift version synthetic\n'
        elif name == 'build':
            graph(self.run, json.loads((self.run / 'sources.json').read_text()))
        elif name == 'binpath':
            stdout = (str(self.run / 'BuildProducts' / (platform.machine() + '-apple-macosx/debug')) + '\n').encode()
        elif name in ('old4', 'new10'):
            selection = OLD if name == 'old4' else NEW
            stdout = success(selection).encode()
            if code:
                # Assertions may exceed methods. Success-only parser must not invent failure credit.
                stdout = stdout.replace(b'0 failures', b'54 failures').replace(b"' passed (", b"' failed (")
            if self.retain or code:
                state = Path(next(x.split('=', 1)[1] for x in command if x.startswith('THEONLYPAD_STATE_DIRECTORY=')))
                write(state / 'retained.synthetic', b'synthetic custody must survive refusal\n')
        output.mkdir(parents=True, exist_ok=False)
        write(output / 'stdout.log', stdout)
        write(output / 'stderr.log', b'')
        # IDs below are inert receipt data only; never queried/signaled/reaped.
        receipt = dict(command=command, pid=424242, processGroup=424242, exitObserved=True,
                       registrationError=None, groupSignalAttempted=True, groupSignalError=None,
                       groupCleanup='signaled', groupQuery=None, waitCompleted=True, returnCode=code,
                       waitError=None, timedOut=False, interruptedSignal=None, truncated=False,
                       captureComplete=True, failure=None, exit=code, captured={
                           'stdout': dict(stored=len(stdout), received=len(stdout), discarded=0),
                           'stderr': dict(stored=0, received=0, discarded=0)}, seconds=0.001)
        save(output / 'status.json', receipt)
        if self.receipt_mutation:
            self.receipt_mutation(name, output, receipt)
        if self.mutate:
            self.mutate(name, self.run)
        return code


def orchestration(case, root, run, **options):
    repository(root)
    run.mkdir(mode=0o700)
    child = ChildBoundary(run, **options)
    with contextlib.redirect_stdout(io.StringIO()):
        code = RUNNER.execute(root, run, child)
    case.assertIs(type(code), int, 'Orchestration API absent; stage/custody controls UNENTERED')
    if type(code) is not int:
        return None
    path = run / 'result.json'
    case.assertTrue(path.is_file(), 'No real final result; receipt/artifact controls UNENTERED')
    if not path.is_file():
        return None
    result = json.loads(path.read_text())
    if not positive_dict(case, result, 'Final result'):
        return None
    return code, result, child


class ApplicationLanguageCatalogRunnerTests(unittest.TestCase):
    def testClosedCLIRejectsOverridesBeforeAnyImportWriteOrChild(self):
        # Missing closed admission would otherwise reach dependency imports or output creation.
        self.assertIsNone(RUNNER.validate_cli([]))
        for argv in (['--filter', NEW], ['--source', '/synthetic/private'], ['--skip-build'],
                     ['--build-path', '/synthetic/debug'], ['--helper', '/synthetic/helper'], ['unknown']):
            with self.subTest(argv=argv):
                with mock.patch.object(importlib.util, 'spec_from_file_location', side_effect=AssertionError('dependency import before admission')):
                    with self.assertRaises((ValueError, SystemExit)):
                        RUNNER.validate_cli(argv)
                    # Main has the same closed gate and may not create a run first.
                    with mock.patch.object(Path, 'mkdir', side_effect=AssertionError('write before admission')):
                        with self.assertRaises((ValueError, SystemExit)):
                            RUNNER.main(argv)

    def testPlanMapsOnlyCurrentThreeModulesExactThreeTestsAndFiveTails(self):
        # Wrong discovery/exclusion or implicit old-Test duplication changes actual compile inputs.
        with tempfile.TemporaryDirectory() as tmp:
            root = repository(Path(tmp) / 'Repo')
            run = Path(tmp) / 'Run'
            plan = RUNNER.build_plan(root, run)
            if not positive_dict(self, plan, 'Fixed current-source plan'):
                return
            self.assertEqual(plan.get('testMappings'), TEST_MAP)
            self.assertEqual(plan.get('tailMappings'), {k: list(v) for k, v in TAILS.items()})
            self.assertEqual(plan.get('stages'), [dict(name=n, timeout=t) for n, t in zip(STAGES, BUDGETS)])
            self.assertEqual(plan.get('captureAfter'), 'binpath')
            expected = sorted(p.relative_to(root).as_posix() for prefix in ROOTS
                              for p in (root / prefix).rglob('*.swift') if p != root / EXCLUDED)
            self.assertEqual(plan.get('productionOrigins'), expected)
            self.assertIn('Sources/PadCore/TheOnlyPadApplication.swift', expected)
            self.assertNotIn(EXCLUDED, expected)
            write(root / 'Sources/PadCore/AddedCurrent.swift', '// new current source\n')
            grown = RUNNER.build_plan(root, run)
            if not positive_dict(self, grown, 'Fresh grown-source plan'):
                return
            self.assertEqual(grown.get('productionOrigins'), sorted(expected + ['Sources/PadCore/AddedCurrent.swift']))
            self.assertFalse(any('.local/' in str(x) for x in grown.get('productionOrigins', [])))

    def testRostersAndWholeOldPrefixCannotBeChangedOrDuplicated(self):
        # A truncated combined payload, changed declaration or stale support roster must refuse.
        combined = (CANDIDATE / COMBINED).read_bytes()
        roster = PROOF.application_methods(combined)
        expected = [(owner, name) for owner, names in METHODS.items() for name in names]
        self.assertEqual(roster, expected, 'Declaration parser absent; roster/prefix controls UNENTERED')
        if roster != expected:
            return
        old = (CANDIDATE / OLD_TEST).read_bytes()
        self.assertEqual(len(old), 51229)
        self.assertEqual(hashlib.sha256(old).hexdigest(), '1e196900670029afdfd995f2b30bac50b2fa19e1f312c64809eddc366b3aa0b9')
        self.assertEqual(old.count(b'import AppKit\n'), 1)
        self.assertEqual(old.count(b'@testable import NativeRouting\n'), 1)
        self.assertEqual(old.count(b'import Darwin\n'), 0)
        self.assertEqual(old.count(b'@testable import PadCore\n'), 0)
        expected_prefix = old.replace(b'import AppKit\n', b'import AppKit\nimport Darwin\n', 1)
        expected_prefix = expected_prefix.replace(
            b'@testable import NativeRouting\n',
            b'@testable import NativeRouting\n@testable import PadCore\n', 1)
        self.assertEqual(len(expected_prefix), 51268)
        self.assertEqual(combined[:len(expected_prefix)], expected_prefix)
        self.assertEqual(combined.count(b'import Darwin\n'), 1)
        self.assertEqual(combined.count(b'@testable import PadCore\n'), 1)
        projected = combined[:len(expected_prefix)]
        self.assertEqual(projected.count(b'import AppKit\nimport Darwin\n'), 1)
        self.assertEqual(projected.count(b'@testable import NativeRouting\n@testable import PadCore\n'), 1)
        inverse = projected.replace(b'import AppKit\nimport Darwin\n', b'import AppKit\n', 1)
        inverse = inverse.replace(
            b'@testable import NativeRouting\n@testable import PadCore\n',
            b'@testable import NativeRouting\n', 1)
        self.assertEqual(inverse, old)
        self.assertEqual(hashlib.sha256(inverse).hexdigest(), '1e196900670029afdfd995f2b30bac50b2fa19e1f312c64809eddc366b3aa0b9')
        for mutation in ('missing', 'repeated', 'foreign', 'wrong-class', 'old-only', 'json-method', 'json-class', 'prefix', 'whole-test', 'extra-test'):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as tmp:
                root = repository(Path(tmp) / 'Repo'); run = Path(tmp) / 'Run'
                plan = RUNNER.build_plan(root, run)
                if not positive_dict(self, plan, 'Otherwise-valid roster plan'):
                    return
                text = (root / COMBINED).read_text()
                needle = 'func ' + METHODS[NEW][0] + '('
                if mutation == 'missing': text = text.replace(needle, 'func removedCase(', 1)
                elif mutation == 'repeated': text += '\nextension ApplicationLanguageCatalogTests { func ' + METHODS[NEW][0] + '() {} }\n'
                elif mutation == 'foreign': text += '\nfinal class Foreign: XCTestCase { func testForeign() {} }\n'
                elif mutation == 'wrong-class': text = text.replace('class ' + NEW, 'class WrongClass', 1)
                elif mutation == 'old-only': text = (root / OLD_TEST).read_text()
                elif mutation.startswith('json-'):
                    path = root / 'Tests/NativeIntegration/application-language-catalog-methods.json'
                    value = json.loads(path.read_text())
                    if mutation == 'json-method': value['new10']['methods'][0] = 'testForeign'
                    else: value['old4']['class'] = 'Foreign'
                    save(path, value)
                elif mutation == 'prefix': text = '// divergent old prefix\n' + text
                elif mutation == 'whole-test': text += '\n// changed bytes without changing accepted14 declarations\n'
                elif mutation == 'extra-test':
                    write(root / 'Tests/NativeIntegration/InjectedTests.swift', (root / OLD_TEST).read_bytes())
                    changed = dict(plan); changed['testMappings'] = dict(TEST_MAP)
                    changed['testMappings']['Tests/NativeIntegration/InjectedTests.swift'] = 'Package/Tests/NativeRoutingTests/InjectedTests.swift'
                    run.mkdir(mode=0o700)
                    with self.assertRaises(ValueError): RUNNER.freeze(root, run, changed)
                    continue
                if mutation not in ('json-method', 'json-class'):
                    write(root / COMBINED, text)
                with self.assertRaises(ValueError): RUNNER.build_plan(root, run)

    def testFreezeAndCurrentMembershipRejectMissingExtraSymlinkReplacementOrForeignOwner(self):
        # Re-adopting changed bytes/inodes or deriving generated bytes from a later read is unsafe.
        with tempfile.TemporaryDirectory() as tmp:
            root = repository(Path(tmp) / 'Repo'); run = Path(tmp) / 'Run'; run.mkdir(mode=0o700)
            plan = RUNNER.build_plan(root, run)
            if not positive_dict(self, plan, 'Capture plan'):
                return
            manifest = RUNNER.freeze(root, run, plan)
            if not positive_dict(self, manifest, 'Captured original/generated authority'):
                return
            self.assertTrue({'sources', 'generated', 'inputTrees'} <= set(manifest))
            RUNNER.verify_inputs(root, run, manifest)
            for target, tails in TAILS.items():
                original = (root / 'Sources/TheOnlyPad' / target).read_bytes()
                generated = run / 'Package/Sources/NativeRouting' / target
                expected = original + b''.join(b'\n' + (root / 'Tests/NativeIntegration' / tail).read_bytes() for tail in tails)
                self.assertEqual(generated.read_bytes(), expected)
                self.assertEqual((run / 'Original/Sources/TheOnlyPad' / target).read_bytes(), original)
            self.assertEqual({row['origin'] for row in manifest['generated'] if row['frozen'].startswith('Package/Tests/')}, set(TEST_MAP))
            self.assertEqual(len([r for r in manifest['generated'] if r['frozen'].startswith('Package/Tests/')]), 3)
            segments = manifest.get('tailSegments')
            self.assertIsInstance(segments, list, 'Tail ranges/inverse authority missing')
            if not isinstance(segments, list): return
            self.assertEqual(len(segments), 5)
            for target, tails in TAILS.items():
                original = (root / 'Sources/TheOnlyPad' / target).read_bytes()
                offset = len(original)
                rows = [r for r in segments if r.get('target') == target]
                self.assertEqual([r.get('source') for r in rows], ['Tests/NativeIntegration/' + tail for tail in tails])
                generated = (run / 'Package/Sources/NativeRouting' / target).read_bytes()
                for row, tail in zip(rows, tails):
                    data = (root / 'Tests/NativeIntegration' / tail).read_bytes()
                    self.assertEqual((row.get('start'), row.get('end')), (offset, offset + 1 + len(data)))
                    self.assertEqual(generated[offset:offset + 1 + len(data)], b'\n' + data)
                    offset += 1 + len(data)
                inverse = generated
                for row in reversed(rows): inverse = inverse[:row['start']] + inverse[row['end']:]
                self.assertEqual(inverse, original)
        for mutation in ('origin', 'tail', 'generated', 'missing', 'extra-source', 'extra-test', 'symlink', 'inode', 'foreign-uid', 'read-then-write'):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as tmp:
                root = repository(Path(tmp) / 'Repo'); run = Path(tmp) / 'Run'; run.mkdir(mode=0o700)
                plan = RUNNER.build_plan(root, run)
                if not positive_dict(self, plan, 'Mutation capture plan'): return
                if mutation == 'read-then-write':
                    watched = root / 'Sources/TheOnlyPad/AppDelegate.swift'
                    original_read = RUNNER.read_input
                    fired = []
                    def observed_read(authority_root, path):
                        captured = original_read(authority_root, path)
                        self.assertIsInstance(captured, tuple, 'Real snapshot reader must return bytes and fact')
                        if not isinstance(captured, tuple): return captured
                        self.assertEqual(len(captured), 2)
                        data, fact = captured
                        self.assertIsInstance(data, bytes)
                        self.assertIsInstance(fact, dict)
                        self.assertEqual(fact.get('bytes'), len(data))
                        self.assertEqual(fact.get('sha256'), hashlib.sha256(data).hexdigest())
                        if path == watched and not fired:
                            fired.append(data)
                            # Preserve BOTH real reader values unchanged; mutate actual live origin.
                            path.write_bytes(data + b'\n// actual mutation after captured read\n')
                        return captured
                    with mock.patch.object(RUNNER, 'read_input', observed_read):
                        with self.assertRaises(ValueError): RUNNER.freeze(root, run, plan)
                    self.assertEqual(len(fired), 1, 'Actual read/write control must be reached')
                    self.assertTrue(watched.read_bytes().endswith(b'// actual mutation after captured read\n'))
                    continue
                manifest = RUNNER.freeze(root, run, plan)
                if not positive_dict(self, manifest, 'Mutation source authority'): return
                path = root / 'Sources/TheOnlyPad/AppDelegate.swift'
                if mutation == 'origin': write(path, path.read_bytes() + b'// origin drift\n')
                elif mutation == 'tail':
                    path = root / 'Tests/NativeIntegration/ApplicationCatalogAccess.swift'; write(path, path.read_bytes() + b'// tail drift\n')
                elif mutation == 'generated':
                    path = run / 'Package/Sources/NativeRouting/EditorWindowController.swift'; write(path, path.read_bytes() + b'// generated drift\n')
                elif mutation == 'missing': path.unlink()
                elif mutation == 'extra-source': write(root / 'Sources/PadCore/Later.swift', '// changed membership\n')
                elif mutation == 'extra-test': write(run / 'Package/Tests/NativeRoutingTests/Extra.swift', '// extra class copy\n')
                elif mutation == 'symlink':
                    path.unlink(); path.symlink_to(root / 'Sources/TheOnlyPad/EditorWindowController.swift')
                elif mutation == 'inode': replace_same_bytes(path)
                if mutation == 'foreign-uid':
                    # Only caller principal changes. Actual stat/read/identity routines remain real.
                    with mock.patch.object(os, 'getuid', return_value=os.getuid() + 1):
                        with self.assertRaises(ValueError): RUNNER.verify_inputs(root, run, manifest)
                        with mock.patch.object(importlib.util, 'spec_from_file_location', side_effect=AssertionError('foreign UID imported dependency')):
                            with self.assertRaises(ValueError): RUNNER.build_plan(root, run)
                            with mock.patch.object(Path, 'mkdir', side_effect=AssertionError('foreign UID created output')):
                                with self.assertRaises(ValueError): RUNNER.main([])
                else:
                    with self.assertRaises(ValueError): RUNNER.verify_inputs(root, run, manifest)

    def testActualFiveModuleGraphRejectsMapObjectLinkFlagAndBundleSubstitution(self):
        # A graph-free capture or source/object/link mismatch must not grant execution authority.
        with tempfile.TemporaryDirectory() as tmp:
            run = Path(tmp).absolute(); binary, manifest, description = graph(run)
            proof = PROOF.validate_native_compiler_graph(run, binary, manifest)
            if not positive_dict(self, proof, 'Complete actual-shape five-module proof'): return
            self.assertEqual([r['module'] for r in proof.get('modules', [])], list(MODULES))
            self.assertEqual(len(manifest['sources']), len(manifest['generated']))
            record = PROOF.capture_native_build(run, binary, sha(run / 'sources.json'))
            if not positive_dict(self, record, 'Real artifact capture'): return
            PROOF.verify_native_build(run, record, sha(run / 'build-inputs.json'))
            self.assertEqual(len([r for r in record.get('artifacts', []) if '.xctest/' in r['path']]), 4)
        mutations = ('filelist', 'map-pair', 'map-extra', 'object', 'extra-object', 'link', 'duplicate-link',
                     'missing-module', 'foreign-module', 'target', 'language', 'werror', 'generated-entry',
                     'module-companion', 'bundle-extra', 'bundle-product', 'bundle-inode')
        for mutation in mutations:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as tmp:
                run = Path(tmp).absolute(); binary, manifest, description = graph(run)
                proof = PROOF.validate_native_compiler_graph(run, binary, manifest)
                if not positive_dict(self, proof, 'Otherwise-valid graph'): return
                groups = description['swiftCommands']; core = groups['PadCore']
                if mutation == 'filelist': write(Path(core['fileList']), shlex.quote(core['sources'][0]) + '\n')
                elif mutation.startswith('map-'):
                    path = Path(core['outputFileMapPath']); data = json.loads(path.read_text())
                    if mutation == 'map-pair':
                        a, b = core['sources']; data[a]['object'], data[b]['object'] = data[b]['object'], data[a]['object']
                    else: data[str(run / 'foreign.swift')] = {'object': core['objects'][0]}
                    save(path, data)
                elif mutation == 'object': Path(core['objects'][0]).unlink()
                elif mutation == 'extra-object': write(binary / 'Extra.build/untracked.o', b'fake extra object')
                elif mutation in ('link', 'duplicate-link'):
                    path = binary / 'NativeRoutingPackageTests.product/Objects.LinkFileList'; lines = path.read_text().splitlines()
                    write(path, '\n'.join(lines[1:] if mutation == 'link' else lines + [lines[0]]) + '\n')
                elif mutation == 'missing-module': del groups['SearchExecution']
                elif mutation == 'foreign-module': groups['foreign'] = dict(core, moduleName='Foreign')
                elif mutation == 'target': core['otherArguments'][1] = platform.machine() + '-apple-macosx13.0'
                elif mutation == 'language': core['otherArguments'][-1] = '6'
                elif mutation == 'werror': core['otherArguments'].remove('-warnings-as-errors')
                elif mutation == 'generated-entry':
                    groups['NativeRoutingPackageTests']['sources'] = [str(run / 'outside.swift')]
                elif mutation == 'module-companion': write(binary / 'Modules/PadCore.extra', b'extra')
                elif mutation == 'bundle-extra': write(binary / 'NativeRoutingPackageTests.xctest/extra', b'extra')
                elif mutation == 'bundle-product': description['builtTestProducts'][0]['packagePath'] = str(run / 'Other')
                elif mutation == 'bundle-inode':
                    record = PROOF.capture_native_build(run, binary, sha(run / 'sources.json'))
                    if not positive_dict(self, record, 'Captured inode authority'): return
                    digest = sha(run / 'build-inputs.json')
                    replace_same_bytes(run / record['testBinary'])
                    with self.assertRaises(ValueError): PROOF.verify_native_build(run, record, digest)
                    continue
                save(binary / 'description.json', description)
                with self.assertRaises(ValueError): PROOF.validate_native_compiler_graph(run, binary, manifest)

    def testExactOld4AndNew10SuccessParserRejectsIncompleteForeignOrFailedOutput(self):
        # Parser grants success only to the exact terminal roster and final expected summary.
        for selection in (OLD, NEW):
            text = success(selection)
            parsed = PROOF.application_success(text, selection)
            expected = dict(tests=len(METHODS[selection]), failures=0, className=selection)
            self.assertEqual(parsed, expected, 'Success parser absent; transcript controls UNENTERED')
            if parsed != expected: return
            terminal = next(line for line in text.splitlines(keepends=True) if "' passed (" in line)
            n = len(METHODS[selection])
            malformed = (text.replace(terminal, '', 1), terminal + text,
                         text.replace(METHODS[selection][0], 'testForeign'),
                         text.replace('NativeRoutingTests.' + selection, 'NativeRoutingTests.Foreign'),
                         text.replace("' passed (", "' skipped (", 1),
                         text.replace("' passed (", "' failed (", 1),
                         text.replace(f'Executed {n} tests', f'Executed {n-1} tests'),
                         text.replace("Test Suite '" + selection + "' passed", "Test Suite 'Foreign' passed"),
                         text + 'error: synthetic failure\n', text + 'caught error: synthetic\n',
                         text + '1 unexpected\n', text.replace('0 failures', '54 failures'),
                         'Executed 0 tests, with 0 failures\n' + text,
                         'Executed 1 tests, with 1 failures\n' + text)
            for raw in malformed:
                with self.subTest(selection=selection, raw=raw[:90]), self.assertRaises(ValueError):
                    PROOF.application_success(raw, selection)
            # APPR-C1: earlier positive zero-failure counts need not equal selection;
            # the accepted parser does not promise started/finished chronology.
            accepted = 'Executed 1 test, with 0 failures\n' + text
            self.assertEqual(PROOF.application_success(accepted, selection), expected)
            self.assertEqual(PROOF.application_success('\n'.join(line for line in text.splitlines() if "' started" not in line) + '\n', selection), expected)
        with self.assertRaises(ValueError): PROOF.application_success(success(OLD), 'arbitrary')

    def testMainRunsFiveDirectStagesAndCapturesOnceBeforeOld4(self):
        # Wrong order, selector, build reuse or missing prechild command persistence must fail.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'Repo'; run = Path(tmp) / 'Run'
            outcome = orchestration(self, root, run)
            if outcome is None: return
            code, result, child = outcome
            self.assertEqual((code, result.get('state'), result.get('exit')), (0, 'COMPLETE_PASS', 0))
            self.assertEqual([(n, t) for n, t, _ in child.calls], list(zip(STAGES, BUDGETS)))
            for actual, before in zip(child.calls, child.prechild):
                name, budget, command = actual
                self.assertIsNotNone(before['command'], 'Current command must exist before synchronous child')
                if before['command'] is None: return
                saved = json.loads(before['command'])
                self.assertEqual((saved.get('command'), saved.get('timeout')), (command, budget))
                self.assertEqual(command[0], '/usr/bin/env')
                state = Path(next(x.split('=', 1)[1] for x in command if x.startswith('THEONLYPAD_STATE_DIRECTORY=')))
                temporary = Path(next(x.split('=', 1)[1] for x in command if x.startswith('TMPDIR=')))
                self.assertEqual(state.stat().st_mode & 0o777, 0o700)
                self.assertEqual(temporary.stat().st_mode & 0o777, 0o700)
                self.assertTrue(state.is_relative_to(run / 'State'))
                self.assertTrue(temporary.is_relative_to(run / 'Temporary'))
            build, binpath = child.calls[1][2], child.calls[2][2]
            for flag in ('--package-path', '--scratch-path'):
                self.assertEqual(build[build.index(flag)+1], binpath[binpath.index(flag)+1])
            self.assertIn('-warnings-as-errors', build); self.assertIn('-warnings-as-errors', binpath)
            self.assertIn('--build-tests', build); self.assertIn('--show-bin-path', binpath)
            self.assertEqual([r['build'] for r in child.prechild], [False, False, False, True, True])
            self.assertIsNone(child.prechild[3]['oldResult'])
            self.assertIsNotNone(child.prechild[4]['oldResult'])
            if child.prechild[4]['oldResult'] is None: return
            self.assertEqual(json.loads(child.prechild[4]['oldResult']), dict(tests=4, failures=0, className=OLD))
            self.assertEqual(json.loads((run / 'new10-result.json').read_text()), dict(tests=10, failures=0, className=NEW))
            for index, selection in ((3, OLD), (4, NEW)):
                command = child.calls[index][2]
                self.assertEqual(command[command.index('-XCTest')+1], 'NativeRoutingTests.' + selection)
                self.assertEqual(command[-1], child.calls[3][2][-1])
                self.assertNotIn('--filter', command); self.assertNotIn('--skip-build', command)
            build_record = json.loads((run / 'build-inputs.json').read_text())
            self.assertEqual([x['module'] for x in build_record.get('compiler', [])], list(MODULES))
            self.assertEqual(len({p.name.casefold() for p in (run / 'ToolSupport', run / 'BuildProducts', run / 'Stages')}), 3)
            self.assertTrue(result.get('postflightVerified'))

    def testOld4FailureStopsNew10AndNaturalNew10FailurePreservesRawCustody(self):
        # Reclassifying a natural nonzero as success/incomplete, retrying or clearing custody is wrong.
        with tempfile.TemporaryDirectory() as tmp:
            outcome = orchestration(self, Path(tmp) / 'Repo', Path(tmp) / 'Run')
            if outcome is None: return
            self.assertEqual(outcome[0], 0, 'Positive stage path required before failure controls')
        for failed, code, expected_state in (('old4', 1, 'OLD4_FAILED_NEW10_UNENTERED'), ('new10', 65, 'NATURAL_STAGE_FAILURE')):
            with self.subTest(failed=failed), tempfile.TemporaryDirectory() as tmp:
                run = Path(tmp) / 'Run'
                outcome = orchestration(self, Path(tmp) / 'Repo', run, failures={failed: code})
                if outcome is None: return
                actual, result, child = outcome
                self.assertEqual((actual, result.get('exit'), result.get('state')), (code, code, expected_state))
                self.assertEqual([r[0] for r in child.calls], list(STAGES[:4 if failed == 'old4' else 5]))
                self.assertIn(b'54 failures', (run / 'Stages' / failed / 'stdout.log').read_bytes())
                self.assertEqual((run / 'State' / failed / 'retained.synthetic').read_bytes(), b'synthetic custody must survive refusal\n')
                self.assertFalse((run / (failed + '-result.json')).exists(), 'Success-only parser must not fabricate failure result')
                self.assertNotIn(failed + 'Result', result, 'No invented structured failure credit')
                if failed == 'old4': self.assertFalse((run / 'Stages/new10').exists())
        for mutation in ('missing', 'extra-key', 'bad-seconds', 'capture-count', 'false-positive'):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as tmp:
                def corrupt(name, output, receipt):
                    if name != 'old4': return
                    if mutation == 'missing': (output / 'status.json').unlink(); return
                    if mutation == 'extra-key': receipt['extra'] = True
                    elif mutation == 'bad-seconds': receipt['seconds'] = float('nan')
                    elif mutation == 'capture-count': receipt['captured']['stdout']['received'] += 1
                    elif mutation == 'false-positive':
                        data = b'Executed 4 tests, with 0 failures\n'; write(output / 'stdout.log', data)
                        receipt['captured']['stdout'] = dict(stored=len(data), received=len(data), discarded=0)
                    save(output / 'status.json', receipt)
                outcome = orchestration(self, Path(tmp) / 'Repo', Path(tmp) / 'Run', receipt_mutation=corrupt)
                if outcome is None: return
                self.assertEqual(outcome[0], 125)
                self.assertNotEqual(outcome[1].get('state'), 'COMPLETE_PASS')
                self.assertEqual([r[0] for r in outcome[2].calls], list(STAGES[:4]))

    def testCurrentCommandAndPriorEvidenceTamperRefuseBeforeLaterChildren(self):
        # Earlier accepted facts and current prelaunch command must never be re-adopted.
        with tempfile.TemporaryDirectory() as tmp:
            outcome = orchestration(self, Path(tmp) / 'Repo', Path(tmp) / 'Run')
            if outcome is None: return
            self.assertEqual(outcome[0], 0, 'Positive custody path required before tamper controls')
        targets = ('Commands/toolchain.json', 'Stages/toolchain/status.json', 'Stages/toolchain/stdout.log',
                   'Stages/toolchain/stderr.log', 'Commands/build.json', 'sources.json', 'input-identities.json',
                   'old4-result.json', 'build-inputs.json', 'module', 'object', 'outputmap', 'link', 'bundle-inode')
        for target in targets:
            with self.subTest(target=target), tempfile.TemporaryDirectory() as tmp:
                reached = []
                def mutate(name, run):
                    when = 'old4' if target == 'old4-result.json' else 'new10' if target == 'bundle-inode' else 'old4'
                    # Old result is produced after old4; alter while next child executes.
                    if target == 'old4-result.json': when = 'new10'
                    if name != when: return
                    binary = run / 'BuildProducts' / (platform.machine() + '-apple-macosx/debug')
                    aliases = {'module': binary / 'Modules/PadCore.swiftmodule',
                               'object': next((binary / 'PadCore.build').glob('*.o')),
                               'outputmap': binary / 'PadCore.build/output-file-map.json',
                               'link': binary / 'NativeRoutingPackageTests.product/Objects.LinkFileList',
                               'bundle-inode': binary / 'NativeRoutingPackageTests.xctest/Contents/MacOS/NativeRoutingPackageTests'}
                    path = aliases[target] if target in aliases else run / target
                    reached.append(path)
                    if target in ('Commands/build.json', 'bundle-inode'): replace_same_bytes(path)
                    else: write(path, path.read_bytes() + b'\n\n')
                run = Path(tmp) / 'Run'
                outcome = orchestration(self, Path(tmp) / 'Repo', run, mutate=mutate)
                if outcome is None: return
                self.assertEqual(len(reached), 1, 'Real prior authority mutation must be reached')
                self.assertEqual(outcome[0], 125)
                self.assertNotEqual(outcome[1].get('state'), 'COMPLETE_PASS')
                self.assertEqual([r[0] for r in outcome[2].calls], list(STAGES[:5 if target in ('old4-result.json', 'bundle-inode') else 4]))
        for current in ('toolchain', 'old4'):
            with self.subTest(current=current), tempfile.TemporaryDirectory() as tmp:
                def mutate(name, run):
                    if name == current:
                        path = run / 'Commands' / (name + '.json'); write(path, path.read_bytes() + b'\n\n')
                outcome = orchestration(self, Path(tmp) / 'Repo', Path(tmp) / 'Run', mutate=mutate)
                if outcome is None: return
                self.assertEqual(outcome[0], 125)
                self.assertEqual(len(outcome[2].calls), 1 if current == 'toolchain' else 4)

    def testFinalPostflightAndStateCleanupAreRequiredWithoutDeletingFailureCustody(self):
        # A nominal final pass must still refuse changed final/prior facts and unresolved State.
        with tempfile.TemporaryDirectory() as tmp:
            outcome = orchestration(self, Path(tmp) / 'Repo', Path(tmp) / 'Run')
            if outcome is None: return
            self.assertEqual(outcome[0], 0, 'Positive postflight required before final controls')
            self.assertTrue(outcome[1].get('postflightVerified'))
            evidence = outcome[1].get('stageEvidence')
            self.assertIsInstance(evidence, list, 'Actual adopted final-stage evidence required')
            if not isinstance(evidence, list): return
            final_path = 'Stages/new10/status.json'
            rows = [row for row in evidence if row.get('path') == final_path]
            self.assertEqual(len(rows), 1, 'Actual accepted final receipt fact, not manufactured authority')
            if len(rows) != 1: return
            run = Path(tmp) / 'Run'
            RUNNER.verify_evidence(run, evidence)
            fact = dict(rows[0]); receipt = run / final_path
            before = receipt.read_bytes()
            replace_same_bytes(receipt)
            with self.assertRaises(ValueError): RUNNER.verify_evidence(run, evidence)
            self.assertEqual(receipt.read_bytes(), before)
            self.assertEqual(rows[0], fact, 'Earlier authority must not be readopted after inode substitution')
        for target in ('Commands/new10.json', 'Stages/new10/status.json', 'Stages/new10/stdout.log',
                       'Stages/new10/stderr.log', 'Commands/old4.json', 'Stages/old4/status.json',
                       'old4-result.json', 'sources.json', 'input-identities.json', 'build-inputs.json',
                       'final-bundle', 'final-origin', 'retained-state'):
            with self.subTest(target=target), tempfile.TemporaryDirectory() as tmp:
                preserved = []
                def mutate(name, run):
                    if name != 'new10': return
                    if target == 'retained-state':
                        path = run / 'State/new10/retained.synthetic'; write(path, b'actual synthetic unresolved custody\n')
                    else:
                        if target == 'final-bundle':
                            path = run / 'BuildProducts' / (platform.machine() + '-apple-macosx/debug/NativeRoutingPackageTests.xctest/Contents/MacOS/NativeRoutingPackageTests')
                        elif target == 'final-origin': path = Path(tmp) / 'Repo/Sources/TheOnlyPad/AppDelegate.swift'
                        else: path = run / target
                        if target == 'Stages/new10/status.json':
                            # Emitted receipt has not yet been adopted at this boundary.
                            # An invalid strict-key shape refuses; do not claim late fact drift.
                            value = json.loads(path.read_text()); value['foreign'] = True; save(path, value)
                        else: write(path, path.read_bytes() + b'\n\n')
                    preserved.append((path, path.read_bytes()))
                outcome = orchestration(self, Path(tmp) / 'Repo', Path(tmp) / 'Run', mutate=mutate)
                if outcome is None: return
                self.assertEqual([r[0] for r in outcome[2].calls], list(STAGES))
                self.assertEqual(len(preserved), 1, 'Final mutation must reach actual emitted authority')
                self.assertEqual(outcome[0], 125)
                self.assertNotEqual(outcome[1].get('state'), 'COMPLETE_PASS')
                path, data = preserved[0]
                self.assertEqual(path.read_bytes(), data, 'Refusal must preserve evidence/custody, never repair it')


if __name__ == '__main__':
    unittest.main()
