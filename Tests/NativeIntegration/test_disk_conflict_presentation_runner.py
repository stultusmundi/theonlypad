"""Pure fixed-runner contracts. Synthetic files only; no compiler/native/watchdog execution.

Only the synchronous watchdog import boundary is replaced in orchestration. Real
reader/receipt/proof/freeze/capture/orchestration functions run after GREEN.
"""
from pathlib import Path
import ast
import contextlib
import hashlib
import importlib.util
import json
import os
import platform
import shlex
import tempfile
import unittest
from types import SimpleNamespace
from unittest import mock

HERE = Path(__file__).absolute().parent
SPEC = importlib.util.spec_from_file_location('locate_runner_under_test', HERE / 'run_disk_conflict_presentation.py')
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)
SELECTIONS = json.loads((HERE / 'disk-conflict-presentation-methods.json').read_text())
GENERATED = 'NativeRoutingPackageTests'
TEST_NAME = 'LocateDiskConflictPresentationTests.swift'
TAILS = {
    'DocumentFileStateController.swift': ['NativeMonitorBridgeAccess.swift'],
    'EditorWindowController.swift': ['NativeMonitorControllerAccess.swift', 'DocumentSearchEditorBindingAccess.swift', 'LocatePresentationOwnerAccess.swift'],
    'NativeApplicationDocuments.swift': ['DocumentSearchAppNativeOwnerAccess.swift', 'LocatePresentationCheckpointAccess.swift'],
    'DocumentDiskConflictController.swift': ['LocatePresentationPanelAccess.swift'],
}
TEST_SHA = 'f514f9a2897b3bed59974d7e0682719ba7e040f0fb87493fce26760c5993f128'
MODULES = ('PadCore', 'SearchExecution', 'NativeRouting', 'NativeRoutingTests', GENERATED)


def put(path, value=b'// synthetic structural fixture; never compiled\n'):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(value.encode() if isinstance(value, str) else value)


def repository(root):
    # The two real candidate prefixes are FUTURE public-shaped fixture bytes in this
    # private packet, explicitly mapped separately from active public Source originals.
    source_root = HERE.parents[1]
    for name in ('Sources/PadCore/A.swift', 'Sources/PadCore/B.swift', 'Sources/PadCore/TheOnlyPadApplication.swift', 'Sources/SearchExecution/Search.swift',
                 'Sources/TheOnlyPad/NativeApplicationDocuments.swift', 'Sources/TheOnlyPad/DocumentFileStateController.swift',
                 'Sources/TheOnlyPad/Extra.swift', 'Sources/TheOnlyPad/TheOnlyPadApplication.swift'):
        put(root / name)
    for name in ('EditorWindowController.swift', 'DocumentDiskConflictController.swift'):
        put(root / 'Sources/TheOnlyPad' / name, (source_root / 'Sources/TheOnlyPad' / name).read_bytes())
    for name in (TEST_NAME, 'disk-conflict-presentation-methods.json', 'disk-conflict-presentation-Package.swift',
                 'run_disk_conflict_presentation.py', 'disk_conflict_presentation_proof.py',
                 'run_native_language_catalog.py', 'run_native_regressions.py',
                 *[tail for tails in TAILS.values() for tail in tails]):
        put(root / 'Tests/NativeIntegration' / name, (HERE / name).read_bytes())
    for name in ('swift.sh', 'run-owned-search-tests.py', 'test-disk-conflict-presentation.sh'):
        put(root / 'scripts' / name, (source_root / 'scripts' / name).read_bytes())


@contextlib.contextmanager
def relocated(root):
    # Public-location inputs only, matching the existing retained catalog pure pattern.
    here = root / 'Tests/NativeIntegration'
    with mock.patch.object(RUNNER, 'HERE', here), mock.patch.object(RUNNER, '__file__', str(here / 'run_disk_conflict_presentation.py')):
        yield


def log(selection='old2', failures=0, unexpected=0):
    # Exactly two cases; assertion failures may exceed the method count.
    choice = SELECTIONS[selection]
    plain = choice['class'].rsplit('.', 1)[1]
    lines = ["Test Suite 'Selected tests' started.", "Test Suite '" + plain + "' started."]
    for index, name in enumerate(choice['methods']):
        identity = '-[' + choice['class'] + ' ' + name + ']'
        lines.append("Test Case '" + identity + "' started.")
        if index == 0 and failures:
            lines += ['fixture.swift:1: error: ' + identity + ' : XCTAssertTrue failed' for _ in range(failures)]
        outcome = 'failed' if index == 0 and failures else 'passed'
        lines.append("Test Case '" + identity + "' " + outcome + ' (0.001 seconds).')
    outcome = 'failed' if failures else 'passed'
    lines += ["Test Suite '" + plain + "' " + outcome + ' at synthetic-time.',
              'Executed 2 tests, with ' + str(failures) + ' failures (' + str(unexpected) + ' unexpected)',
              "Test Suite 'Selected tests' " + outcome + ' at synthetic-time.',
              'Executed 2 tests, with ' + str(failures) + ' failures (' + str(unexpected) + ' unexpected)']
    return ('\n'.join(lines) + '\n').encode()


def receipt(output, command, code, stdout=b'', stderr=b'', bad=None):
    # Synthetic collaborator protocol, never an observed process/PID/group receipt.
    output.mkdir(parents=True)
    put(output / 'stdout.log', stdout)
    put(output / 'stderr.log', stderr)
    value = dict(command=command, pid=4242, processGroup=4242, exitObserved=True,
                 registrationError=None, groupSignalAttempted=True, groupSignalError=3,
                 groupCleanup='absent', groupQuery=None, waitCompleted=True, returnCode=code,
                 waitError=None, timedOut=False, interruptedSignal=None, truncated=False,
                 captureComplete=True, failure=None, exit=code, seconds=0.01,
                 captured={name: dict(stored=len(data), received=len(data), discarded=0)
                           for name, data in [('stdout', stdout), ('stderr', stderr)]})
    if bad == 'truncated': value['truncated'] = True
    if bad == 'capture': value['captured']['stderr']['received'] += 1
    if bad == 'exit': value['returnCode'] = 0 if code else 1
    if bad == 'extra': value['unapproved'] = True
    if bad == 'seconds': value['seconds'] = -1
    put(output / 'status.json', json.dumps(value))


def compiler_fixture(run, manifest, write_binpath=True):
    # Complete positive actual manifest shape; bytes are synthetic/non-native text.
    binary = run / 'BuildProducts' / (platform.machine() + '-apple-macosx/debug')
    groups = {}
    for module in MODULES:
        if module == GENERATED:
            sources = [binary / (GENERATED + '.derived/runner.swift')]
            put(sources[0], '// synthetic generated entry; never compiled\n')
        else:
            prefix = 'Package/' + ('Tests/' if module == 'NativeRoutingTests' else 'Sources/') + module + '/'
            sources = sorted(run / row['frozen'] for row in manifest['generated']
                             if row['frozen'].startswith(prefix) and row['frozen'].endswith('.swift'))
        if not sources: raise AssertionError('Positive frozen module Source prerequisite absent')
        objects = [binary / (module + '.build') / (source.name + '.o') for source in sources]
        for obj in objects: put(obj, 'SYNTHETIC OBJECT NOT EXECUTED\n')
        for suffix in ('.swiftmodule', '.swiftdoc', '.swiftsourceinfo', '.abi.json'):
            put(binary / 'Modules' / (module + suffix), 'SYNTHETIC MODULE NOT LOADED\n')
        filelist = binary / (module + '.build/sources')
        outputmap = binary / (module + '.build/output-file-map.json')
        put(filelist, '\n'.join(shlex.quote(str(source)) for source in sources) + '\n')
        put(outputmap, json.dumps({'': {}, **{str(source): {'object': str(obj)} for source, obj in zip(sources, objects)}}))
        groups[module] = dict(moduleName=module, sources=list(map(str, sources)), objects=list(map(str, objects)),
                              fileList=str(filelist), outputFileMapPath=str(outputmap),
                              moduleOutputPath=str(binary / 'Modules' / (module + '.swiftmodule')),
                              otherArguments=['-target', platform.machine() + '-apple-macosx14.0',
                                              '-swift-version', '5', '-warnings-as-errors', '-package-name', 'NativeRouting'])
    linked = [obj for row in groups.values() for obj in row['objects']]
    put(binary / (GENERATED + '.product/Objects.LinkFileList'), '\n'.join(shlex.quote(obj) for obj in linked) + '\n')
    bundle = binary / (GENERATED + '.xctest')
    executable = bundle / 'Contents/MacOS' / GENERATED
    put(executable, 'SYNTHETIC EXECUTABLE NEVER INVOKED\n')
    executable.chmod(0o700)
    symbol = bundle / ('Contents/MacOS/' + GENERATED + '.dSYM/Contents')
    put(symbol / 'Info.plist', 'synthetic plist\n')
    put(symbol / 'Resources/DWARF' / GENERATED, 'synthetic symbols\n')
    relocation = 'aarch64' if platform.machine() in ('arm64', 'aarch64') else 'x86_64'
    put(symbol / ('Resources/Relocations/' + relocation + '/' + GENERATED + '.yml'), 'synthetic relocation\n')
    put(binary / 'description.json', json.dumps(dict(swiftCommands=groups, builtTestProducts=[dict(
        binaryPath=str(executable), packagePath=str(run / 'Package'), productName=GENERATED)])))
    if write_binpath: put(run / 'Stages/binpath/stdout.log', str(binary) + '\n')
    return binary, groups


def planned(test, root, run):
    test.assertTrue(callable(getattr(RUNNER, 'build_plan', None)), 'Missing callable API; deeper horizon UNENTERED')
    if not callable(getattr(RUNNER, 'build_plan', None)): return None
    value = RUNNER.build_plan(root, run)
    test.assertIsInstance(value, dict, 'Missing plan; deeper horizon UNENTERED')
    if not isinstance(value, dict): return None
    test.assertEqual(value.get('selections'), SELECTIONS, 'Missing real fixed selections; deeper horizon UNENTERED')
    if value.get('selections') != SELECTIONS: return None
    test.assertIsInstance(value.get('swiftInputs'), dict)
    test.assertIsInstance(value.get('accessTails'), dict)
    if not isinstance(value.get('swiftInputs'), dict) or not isinstance(value.get('accessTails'), dict): return None
    stages = value.get('stages')
    test.assertIsInstance(stages, list, 'Missing fixed stages; orchestration UNENTERED')
    if not isinstance(stages, list): return None
    names = [row.get('name') if isinstance(row, dict) else None for row in stages]
    test.assertEqual(names, ['toolchain', 'build', 'binpath', 'old2', 'new2'])
    if names != ['toolchain', 'build', 'binpath', 'old2', 'new2']: return None
    return value


def frozen(test, root, run):
    value = planned(test, root, run)
    if value is None: return None
    manifest = RUNNER.freeze(root, run, value)
    test.assertIsInstance(manifest, dict)
    if not isinstance(manifest, dict): return None
    for key in ('sources', 'generated', 'inputTrees', 'originals', 'copies', 'ownedDirectories'):
        test.assertIn(key, manifest, 'Missing actual manifest compatibility field; deeper graph UNENTERED')
    if not all(key in manifest for key in ('sources', 'generated', 'inputTrees', 'originals', 'copies', 'ownedDirectories')): return None
    for key in ('sources', 'generated', 'inputTrees', 'originals', 'copies', 'ownedDirectories'):
        test.assertIsInstance(manifest[key], list, 'Wrong manifest compatibility field; graph UNENTERED')
    if not all(isinstance(manifest[key], list) for key in ('sources', 'generated', 'inputTrees', 'originals', 'copies', 'ownedDirectories')): return None
    test.assertTrue(manifest['generated'], 'Empty generated graph is not a positive fixture')
    if not manifest['generated']: return None
    return manifest


def captured(test, run, manifest):
    record = RUNNER.capture(run, manifest)
    test.assertIsInstance(record, dict, 'Missing actual capture before corruption; deep oracle UNENTERED')
    if not isinstance(record, dict): return None
    test.assertTrue(record.get('artifacts'), 'Empty capture is not evidence')
    test.assertTrue(record.get('compiler'), 'Missing actual five-module proof')
    if not record.get('artifacts') or not record.get('compiler'): return None
    test.assertIsInstance(record['compiler'], list)
    if not isinstance(record['compiler'], list): return None
    valid_rows = all(isinstance(row, dict) and isinstance(row.get('module'), str) for row in record['compiler'])
    test.assertTrue(valid_rows, 'Actual module proof shape required before deeper artifact oracles')
    if not valid_rows: return None
    test.assertEqual({row['module'] for row in record['compiler']}, set(MODULES))
    RUNNER.verify_capture(run, manifest, record)
    return record


def orchestrate(test, root, old_failure=False, new_failure=False, incomplete=False, tamper=None, bad_receipt=None):
    repository(root)
    with relocated(root):
        if planned(test, root, root / 'Prospective') is None: return None
        real_import = RUNNER.import_module
        calls = []
        owned_run = None
        authority_ready = False
        artifact_identity = None

        def child(argv):
            nonlocal owned_run, authority_ready, artifact_identity
            test.assertEqual(argv[0], '--timeout')
            output = Path(argv[argv.index('--output') + 1])
            test.assertEqual(output.parent.name, 'Stages')
            name = output.name
            test.assertIn(name, ('toolchain', 'build', 'binpath', 'old2', 'new2'))
            test.assertEqual(argv[1], '30' if name in ('toolchain', 'binpath') else '180')
            run = output.parent.parent
            owned_run = run
            command = argv[argv.index('--') + 1:]
            test.assertTrue((run / 'Commands' / (name + '.json')).is_file(), 'Current command must exist before child')
            calls.append(name)
            stdout = b''
            stderr = b''
            code = 0
            if name == 'build':
                inputs = json.loads((run / 'inputs.json').read_text())
                compiler_fixture(run, inputs, write_binpath=False)
            elif name == 'binpath':
                binary = run / 'BuildProducts' / (platform.machine() + '-apple-macosx/debug')
                stdout = (str(binary) + '\n').encode()
            elif name in ('old2', 'new2'):
                test.assertTrue((run / 'artifacts.json').is_file(), 'Actual capture precedes either direct selection')
                authority_ready = True
                artifact = run / 'artifacts.json'
                info = artifact.stat()
                identity = (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns,
                            info.st_ctime_ns, hashlib.sha256(artifact.read_bytes()).hexdigest())
                if name == 'old2': artifact_identity = identity
                else: test.assertEqual(identity, artifact_identity, 'Capture file must not be rewritten between direct selections')
                target = run / 'BuildProducts' / (platform.machine() + '-apple-macosx/debug') / (GENERATED + '.xctest')
                test.assertEqual(command[-5:], ['/usr/bin/xcrun', 'xctest', '-XCTest', SELECTIONS[name]['class'], str(target)])
                failing = old_failure if name == 'old2' else new_failure
                code = 1 if failing else 0
                stderr = log(name, failures=3 if failing else 0)
                if name == 'new2' and incomplete: stderr = b'INCOMPLETE synthetic XCTest capture\n'
                if name == 'new2': test.assertTrue((run / 'old2-result.json').is_file(), 'Old2parsed authority must precede new2')
            receipt(output, command, code, stdout, stderr, bad_receipt if name == 'new2' else None)
            if tamper is not None:
                when, relative = tamper
                if name == when:
                    target = run / relative
                    test.assertTrue(target.is_file(), 'Tamper target must be actual prior authority, never invented')
                    with target.open('ab') as stream: stream.write(b'\nTAMPER\n')
            return code

        def imported(path, name):
            if Path(path).name == 'run-owned-search-tests.py': return SimpleNamespace(main=child)
            return real_import(path, name)

        with mock.patch.object(RUNNER, 'import_module', side_effect=imported):
            code = RUNNER.main([])
        test.assertIsNotNone(owned_run, 'No real fake-child boundary reached; later orchestration horizon UNENTERED')
        if owned_run is None: return None
        result_path = owned_run / 'result.json'
        test.assertTrue(result_path.is_file(), 'Main must retain honest terminal coordinator result')
        if not result_path.is_file(): return None
        result = json.loads(result_path.read_text())
        return code, result, calls, owned_run, authority_ready


class DiskConflictPresentationRunnerContractTests(unittest.TestCase):
    def testFixedPlanCopiesCurrentThreeRootsExactTestAndSevenTails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); repository(root); run = root / 'Candidate'; run.mkdir(mode=0o700)
            with relocated(root):
                plan = planned(self, root, run)
                if plan is None: return
                expected = {}
                for module, target in [('PadCore', 'PadCore'), ('SearchExecution', 'SearchExecution'), ('TheOnlyPad', 'NativeRouting')]:
                    expected.update({str(path.relative_to(root)): 'Package/Sources/' + target + '/' + path.name
                                     for path in (root / 'Sources' / module).rglob('*.swift') if path != root / 'Sources/TheOnlyPad/TheOnlyPadApplication.swift'})
                expected['Tests/NativeIntegration/' + TEST_NAME] = 'Package/Tests/NativeRoutingTests/' + TEST_NAME
                self.assertEqual(plan['swiftInputs'], expected)
                self.assertEqual(plan['accessTails'], {name: ['Tests/NativeIntegration/' + tail for tail in tails] for name, tails in TAILS.items()})
                manifest = frozen(self, root, run)
                if manifest is None: return
                self.assertEqual(hashlib.sha256((run / 'Package/Tests/NativeRoutingTests' / TEST_NAME).read_bytes()).hexdigest(), TEST_SHA)
                for name, tails in TAILS.items():
                    original = (root / 'Sources/TheOnlyPad' / name).read_bytes()
                    for tail in tails: original += b'\n' + (root / 'Tests/NativeIntegration' / tail).read_bytes()
                    self.assertEqual((run / 'Package/Sources/NativeRouting' / name).read_bytes(), original)
                self.assertEqual((run / 'Package/Package.swift').read_bytes(), (HERE / 'disk-conflict-presentation-Package.swift').read_bytes())
                self.assertFalse((run / 'Package/Sources/NativeRouting/TheOnlyPadApplication.swift').exists())
                self.assertTrue((run / 'Package/Sources/PadCore/TheOnlyPadApplication.swift').is_file(), 'Exclude only the fixed native entry path, never its basename in another module')
                self.assertTrue(all('.local/' not in key for key in plan['swiftInputs']))
                RUNNER.verify_inputs(root, run, manifest)

    def testFiveStagesUseDisjointNamespacesAndOneCapturedDirectBundle(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); repository(root); run = root / 'Candidate'; run.mkdir(mode=0o700)
            with relocated(root):
                plan = planned(self, root, run)
                if plan is None: return
                stages = plan.get('stages')
                self.assertIsInstance(stages, list)
                if not isinstance(stages, list): return
                self.assertEqual([(r['name'], r['timeout']) for r in stages], [('toolchain', 30), ('build', 180), ('binpath', 30), ('old2', 180), ('new2', 180)])
                if [(r.get('name'), r.get('timeout')) for r in stages] != [('toolchain', 30), ('build', 180), ('binpath', 30), ('old2', 180), ('new2', 180)]: return
                byname = {r['name']: r for r in stages}
                for name, mode in [('build', '--build-tests'), ('binpath', '--show-bin-path')]:
                    words = byname[name]['command']
                    self.assertIn(str(run / 'ToolSupport/scripts/swift.sh'), words)
                    self.assertIn(str(run / 'BuildProducts'), words)
                    self.assertIn(mode, words)
                    self.assertEqual(words.count('-warnings-as-errors'), 1)
                    self.assertEqual(words[words.index('-Xswiftc') + 1], '-warnings-as-errors')
                self.assertEqual(plan.get('captureAfter'), 'binpath')
                for name in ('old2', 'new2'):
                    words = byname[name]['command']
                    self.assertIn(SELECTIONS[name]['class'], words)
                    self.assertIn('xctest', Path(words[-4]).name)
                    self.assertFalse(any(word == 'swift' or word == '--skip-build' for word in words))
                trace = orchestrate(self, root)
                if trace is None: return
                code, result, calls, owned, ready = trace
                self.assertEqual((code, result.get('state')), (0, 'COMPLETE_PASS'))
                self.assertEqual(calls, ['toolchain', 'build', 'binpath', 'old2', 'new2'])
                self.assertTrue(ready)
                self.assertEqual((owned / 'ToolSupport').name.casefold(), 'toolsupport')
                self.assertNotEqual((owned / 'Stages/build').parent, (owned / 'BuildProducts').parent)
                self.assertNotEqual((owned / 'Stages/toolchain').parent, (owned / 'ToolSupport').parent)

    def testClosedCLIRejectsOverridesBeforeAnyChild(self):
        for argv in [['--help'], ['--filter', 'Other'], ['--source', 'other'], ['--package-path', 'other'], ['--build-path', 'other'], ['--helper', 'other']]:
            with self.subTest(argv=argv), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); repository(root)
                with relocated(root), mock.patch.object(RUNNER, 'import_module', side_effect=AssertionError('No import/child permitted for invalid CLI')):
                    with self.assertRaises(ValueError): RUNNER.validate_cli(argv)
                    with self.assertRaises(ValueError): RUNNER.main(argv)
                self.assertFalse((root / '.local').exists())

    def testTwoExactRostersAndBothFrozenClassesCannotBeSubstituted(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); repository(root); run = root / 'Candidate'; run.mkdir(mode=0o700)
            with relocated(root):
                if planned(self, root, run) is None: return
                data = (root / 'Tests/NativeIntegration' / TEST_NAME).read_bytes()
                RUNNER.validate_declarations(data, SELECTIONS)
                first = SELECTIONS['old2']['methods'][0].encode()
                variants = [data.replace(first, b'testForeign', 1), data.replace(first, SELECTIONS['old2']['methods'][1].encode(), 1),
                            data + b'\nfinal class ForeignTests: XCTestCase { func testForeign() {} }\n',
                            data.replace(b'class ManagedLocateTokenCharacterizationTests', b'class WrongTests', 1)]
                for candidate in variants:
                    with self.subTest(kind=len(candidate)), self.assertRaises(ValueError): RUNNER.validate_declarations(candidate, SELECTIONS)
                rosters = root / 'Tests/NativeIntegration/disk-conflict-presentation-methods.json'
                valid = rosters.read_bytes()
                for changed in [{'old2': SELECTIONS['new2'], 'new2': SELECTIONS['old2']}, {'old2': SELECTIONS['old2']}, {**SELECTIONS, 'foreign': SELECTIONS['old2']}]:
                    rosters.write_text(json.dumps(changed))
                    with self.assertRaises(ValueError): RUNNER.build_plan(root, run)
                    rosters.write_bytes(valid)

    def testCompletePassOrdinaryAssertionsAndIncompleteResultsRemainDistinct(self):
        good = RUNNER.parse_result(log(), 0, 'old2')
        self.assertIsInstance(good, dict, 'No positive parser result; corruption horizons UNENTERED')
        if not isinstance(good, dict): return
        self.assertEqual((good.get('executed'), good.get('failures'), good.get('unexpected')), (2, 0, 0))
        for selection in ('old2', 'new2'):
            failure = RUNNER.parse_result(log(selection, failures=3), 1, selection)
            self.assertEqual((failure['executed'], failure['failures'], failure['unexpected']), (2, 3, 0))
        raw = log()
        case = '-[' + SELECTIONS['old2']['class'] + ' ' + SELECTIONS['old2']['methods'][0] + ']'
        variants = [raw.replace(b'0 unexpected', b'1 unexpected'), raw.replace(b' passed (', b' skipped (', 1),
                    raw + ("Test Case '" + case + "' passed (0.001 seconds).\n").encode(),
                    raw.replace(SELECTIONS['old2']['methods'][0].encode(), b'testForeign'),
                    raw.replace(b"Test Suite 'ManagedLocateTokenCharacterizationTests' passed", b"Test Suite 'NativeRoutingTests.ManagedLocateTokenCharacterizationTests' passed"),
                    raw.replace(b'Executed 2 tests', b'Executed 1 tests', 1), b'partial\n',
                    raw.replace(("Test Case '" + case + "' started.").encode(), ("Test Case '" + case + "' malformed.").encode(), 1)]
        for candidate in variants:
            with self.subTest(raw=candidate[:50]), self.assertRaises(ValueError): RUNNER.parse_result(candidate, 0, 'old2')
        with self.assertRaises(ValueError): RUNNER.parse_result(raw, 1, 'old2')
        with self.assertRaises(ValueError): RUNNER.parse_result(log('new2'), 0, 'old2')
        with self.assertRaises(ValueError): RUNNER.parse_result(raw, 0, 'foreign')

    def testFiveModuleProofRejectsMapSourceObjectAndLinkSubstitution(self):
        for kind in ('filelist', 'outputmap', 'source', 'object', 'link', 'module', 'package', 'werror', 'language', 'generated', 'bundle'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); repository(root); run = root / 'Candidate'; run.mkdir(mode=0o700)
                with relocated(root):
                    manifest = frozen(self, root, run)
                    if manifest is None: return
                    binary, groups = compiler_fixture(run, manifest)
                    if captured(self, run, manifest) is None: return
                    row = groups['NativeRouting']
                    description = binary / 'description.json'
                    data = json.loads(description.read_text())
                    if kind == 'filelist': put(Path(row['fileList']), 'foreign.swift\n')
                    elif kind == 'outputmap':
                        mapping = json.loads(Path(row['outputFileMapPath']).read_text())
                        mapping[row['sources'][0]]['object'] = row['objects'][1]
                        put(Path(row['outputFileMapPath']), json.dumps(mapping))
                    elif kind == 'source':
                        data['swiftCommands']['NativeRouting']['sources'].append(row['sources'][0])
                        put(description, json.dumps(data))
                    elif kind == 'object': put(binary / 'NativeRouting.build/Foreign.swift.o')
                    elif kind == 'link':
                        link = binary / (GENERATED + '.product/Objects.LinkFileList')
                        put(link, link.read_bytes() + (shlex.quote(row['objects'][0]) + '\n').encode())
                    elif kind == 'module': put(binary / 'Modules/Foreign.swiftmodule')
                    elif kind in ('package', 'werror', 'language'):
                        arguments = data['swiftCommands']['NativeRouting']['otherArguments']
                        if kind == 'package': arguments[arguments.index('-package-name') + 1] = 'Foreign'
                        elif kind == 'werror': arguments.remove('-warnings-as-errors')
                        else: arguments[arguments.index('-swift-version') + 1] = '6'
                        put(description, json.dumps(data))
                    elif kind == 'generated': put(binary / (GENERATED + '.derived/Foreign.swift'))
                    elif kind == 'bundle': put(binary / (GENERATED + '.xctest/Contents/Foreign.txt'))
                    with self.assertRaises(ValueError): RUNNER.capture(run, manifest)

    def testFreezeRechecksActualRosterAndEveryOriginalAndCopy(self):
        for kind in ('original', 'copy', 'newsource', 'identity', 'symlink', 'uid'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); repository(root); run = root / 'Candidate'; run.mkdir(mode=0o700)
                with relocated(root):
                    plan = planned(self, root, run)
                    if plan is None: return
                    if kind == 'uid':
                        # Simulate a different caller principal, not a forged file uid or
                        # patched reader/native helper. Actual inode/uid bytes stay unchanged.
                        foreign = os.getuid() + 1
                        with mock.patch.object(os, 'getuid', return_value=foreign), mock.patch.object(os, 'geteuid', return_value=foreign), mock.patch.object(RUNNER, 'import_module', side_effect=AssertionError('Owned guard must precede dependency import')):
                            with self.assertRaises(ValueError): RUNNER.build_plan(root, run)
                        continue
                    manifest = frozen(self, root, run)
                    if manifest is None: return
                    original = root / 'Sources/PadCore/A.swift'
                    if kind == 'original': put(original, '// changed original\n')
                    elif kind == 'copy': put(run / 'Package/Sources/PadCore/A.swift', '// changed frozen\n')
                    elif kind == 'newsource': put(root / 'Sources/SearchExecution/New.swift')
                    elif kind == 'identity':
                        same = original.read_bytes(); original.unlink(); put(original, same)
                    elif kind == 'symlink':
                        target = root / 'replacement.swift'; put(target)
                        original.unlink(); original.symlink_to(target)
                    with self.assertRaises(ValueError): RUNNER.verify_inputs(root, run, manifest)

    def testCurrentCommandMutationDuringChildIsNotAdopted(self):
        for stage in ('old2', 'new2'):
            with self.subTest(stage=stage), tempfile.TemporaryDirectory() as directory:
                trace = orchestrate(self, Path(directory), tamper=(stage, 'Commands/' + stage + '.json'))
                if trace is None: return
                code, result, calls, _, ready = trace
                self.assertEqual(code, 125)
                self.assertNotEqual(result.get('state'), 'COMPLETE_PASS')
                self.assertTrue(ready)
                self.assertEqual(calls[-1], stage)
                if stage == 'old2': self.assertNotIn('new2', calls)

    def testPriorCaptureReceiptCommandAndCompilerArtifactsRemainImmutable(self):
        object_file = 'BuildProducts/' + platform.machine() + '-apple-macosx/debug/NativeRouting.build/Extra.swift.o'
        link_file = 'BuildProducts/' + platform.machine() + '-apple-macosx/debug/' + GENERATED + '.product/Objects.LinkFileList'
        targets = ('Commands/toolchain.json', 'Stages/build/status.json', 'Stages/build/stdout.log', 'Stages/build/stderr.log',
                   'old2-result.json', 'artifacts.json', 'inputs.json', 'Stages/new2/status.json',
                   'Stages/new2/stdout.log', 'Stages/new2/stderr.log', object_file, link_file)
        for target in targets:
            with self.subTest(target=target), tempfile.TemporaryDirectory() as directory:
                trace = orchestrate(self, Path(directory), tamper=('new2', target))
                if trace is None: return
                code, result, calls, _, ready = trace
                self.assertEqual(code, 125)
                self.assertNotEqual(result.get('state'), 'COMPLETE_PASS')
                self.assertEqual(calls, ['toolchain', 'build', 'binpath', 'old2', 'new2'])
                self.assertTrue(ready)

    def testOldFailureStopsNewAndIncompleteOrFailingNewCannotPass(self):
        variants = [('old', True, False, False, None), ('new', False, True, False, None),
                    ('incomplete', False, False, True, None), ('unexpected', False, False, False, 'truncated'),
                    ('capture', False, False, False, 'capture'), ('exit', False, False, False, 'exit'),
                    ('extra', False, False, False, 'extra'), ('seconds', False, False, False, 'seconds')]
        for label, old_failure, new_failure, incomplete, bad in variants:
            with self.subTest(kind=label), tempfile.TemporaryDirectory() as directory:
                trace = orchestrate(self, Path(directory), old_failure=old_failure, new_failure=new_failure,
                                    incomplete=incomplete, bad_receipt=bad)
                if trace is None: return
                code, result, calls, run, ready = trace
                self.assertTrue(ready)
                if label == 'old':
                    self.assertEqual((code, result.get('state')), (1, 'OLD2_FAILED_NEW2_UNENTERED'))
                    self.assertEqual(calls, ['toolchain', 'build', 'binpath', 'old2'])
                    self.assertFalse((run / 'new2-result.json').exists())
                    report = json.loads((run / 'old2-result.json').read_text())
                    self.assertEqual((report['executed'], report['failures'], report['unexpected']), (2, 3, 0))
                elif label == 'new':
                    self.assertEqual((code, result.get('state')), (1, 'COMPLETE_ORDINARY_FAILURE'))
                    self.assertEqual(calls, ['toolchain', 'build', 'binpath', 'old2', 'new2'])
                    report = json.loads((run / 'new2-result.json').read_text())
                    self.assertEqual((report['executed'], report['failures'], report['unexpected']), (2, 3, 0))
                else:
                    self.assertEqual(code, 125)
                    self.assertNotEqual(result.get('state'), 'COMPLETE_PASS')
                    self.assertIn('new2', calls)
                    self.assertTrue((run / 'Stages/new2/status.json').is_file())


if __name__ == '__main__': unittest.main()
