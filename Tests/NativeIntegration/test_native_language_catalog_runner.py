"""Pure contract: temporary text fixtures only; never invoke a compiler or watchdog."""
from pathlib import Path
import importlib.util
import json
import tempfile
import unittest
import contextlib
import inspect
from types import SimpleNamespace
from unittest import mock

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location('catalog_runner_under_test', HERE / 'run_native_language_catalog.py')
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)
METHODS = json.loads((HERE / 'native-language-catalog-methods.json').read_text())
CLASS = 'NativeLanguageCatalogOwnerTests.NativeLanguageCatalogOwnerTests'
GENERATED = 'NativeLanguageCatalogPackageTests'
OWNER = 'Sources/TheOnlyPad/NativeLanguageCatalogOwner.swift'
TESTS = ('NativeLanguageCatalogOwnerTests.swift', 'NativeLanguageCatalogOwnerFixtures.swift')
MUTATION = 'Sources/TheOnlyPad/NativeLanguageCatalogMutation.swift'
MUTATION_TESTS = ('NativeLanguageCatalogMutationTests.swift', 'NativeLanguageCatalogMutationFixtures.swift')
WIRE = 'Tests/PadCoreTests/CatalogTestFixture.swift'
MUTATION_METHODS = json.loads((HERE / 'native-language-catalog-mutation-methods.json').read_text())
MUTATION_CLASS = 'NativeLanguageCatalogOwnerTests.NativeLanguageCatalogMutationTests'
SELECTIONS = {'old14': {'class': CLASS, 'methods': METHODS},
              'new31': {'class': MUTATION_CLASS, 'methods': MUTATION_METHODS}}


def put(path, value='// synthetic path fixture, never compiled\n'):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value)


def repository(root):
    # The fixture intentionally has two Core files: the planner must enumerate
    # current Core membership, not hard-code one historical59-file hash/count.
    for name in ('Sources/PadCore/A.swift', 'Sources/PadCore/B.swift', OWNER, MUTATION, WIRE,
                 'Sources/TheOnlyPad/AppDelegate.swift', 'Sources/SearchExecution/Excluded.swift',
                 'Tests/PadCoreTests/ExcludedTests.swift', 'scripts/swift.sh',
                 'scripts/run-owned-search-tests.py', 'Tests/NativeIntegration/run_native_regressions.py',
                 'Tests/NativeIntegration/run_native_language_catalog.py'):
        put(root / name)
    for names, methods, class_name in ((TESTS, METHODS, CLASS),
                                        (MUTATION_TESTS, MUTATION_METHODS, MUTATION_CLASS)):
        for name in names:
            text = ('final class ' + class_name.split('.')[-1] + ' {\n' +
                    '\n'.join('  func ' + method + '() {}' for method in methods) + '\n}\n') if name == names[0] else '// fixture\n'
            put(root / 'Tests/NativeIntegration' / name, text)
    for name in ('native-language-catalog-methods.json', 'native-language-catalog-mutation-methods.json',
                 'native-language-catalog-Package.swift', 'run_native_language_catalog.py', 'run_native_regressions.py'):
        put(root / 'Tests/NativeIntegration' / name, (HERE / name).read_text())
    for name in ('swift.sh', 'run-owned-search-tests.py', 'test-native-language-catalog.sh'):
        put(root / 'scripts' / name, (HERE.parents[1] / 'scripts' / name).read_text())


def log(failed=False):
    lines = []
    for index, method in enumerate(METHODS):
        identity = '-[' + CLASS + ' ' + method + ']'
        lines.append("Test Case '" + identity + "' started.")
        if failed and index == 0:
            lines.append('fixture.swift:1: error: ' + identity + ' : XCTAssertTrue failed')
        lines.append("Test Case '" + identity + "' " + ('failed' if failed and index == 0 else 'passed') + ' (0.001 seconds).')
    lines.append('Executed 14 tests, with ' + ('1' if failed else '0') + ' failures (0 unexpected)')
    return ('\n'.join(lines) + '\n').encode()


def compiler_fixture(run, preserve_frozen_sources=False):
    # Deliberately non-executable bytes. This tests path/map/link discrimination,
    # not real Swift compilation, signature, target execution or native behavior.
    binary = run / 'BuildProducts/arm64-apple-macosx/debug'
    groups = {
        'PadCore': sorted((run / 'Package/Sources/PadCore').glob('*.swift')) if preserve_frozen_sources else [run / 'Package/Sources/PadCore/A.swift'],
        'NativeLanguageCatalogComponent': [run / 'Package/Sources/NativeLanguageCatalogComponent' / name for name in ('NativeLanguageCatalogOwner.swift', 'NativeLanguageCatalogMutation.swift')],
        'NativeLanguageCatalogOwnerTests': [run / 'Package/Tests/NativeLanguageCatalogOwnerTests' / name for name in (*TESTS, *MUTATION_TESTS, 'CatalogTestFixture.swift')],
        GENERATED: [binary / (GENERATED + '.derived/runner.swift')],
    }
    commands = {}; all_objects = []
    for module, sources in groups.items():
        objects = [binary / (module + '.build') / (source.name + '.o') for source in sources]
        for source in sources:
            if not preserve_frozen_sources or not source.exists(): put(source)
        for obj in objects: put(obj, 'synthetic object\n')
        put(binary / 'Modules' / (module + '.swiftmodule'), 'synthetic module\n')
        filelist = binary / (module + '.build/sources')
        outputmap = binary / (module + '.build/output-file-map.json')
        put(filelist, '\n'.join(map(str, sources)) + '\n')
        mapping = {'': {}}
        mapping.update({str(source): {'object': str(obj)} for source, obj in zip(sources, objects)})
        put(outputmap, json.dumps(mapping))
        commands[module] = dict(moduleName=module, sources=list(map(str, sources)), objects=list(map(str, objects)),
            fileList=str(filelist), outputFileMapPath=str(outputmap),
            otherArguments=['-target', 'arm64-apple-macosx14.0', '-swift-version', '5', '-warnings-as-errors'])
        all_objects.extend(objects)
    put(binary / 'description.json', json.dumps({'swiftCommands': commands}))
    put(binary / (GENERATED + '.product/Objects.LinkFileList'), '\n'.join(map(str, all_objects)) + '\n')
    return binary, commands


def require_mutation_surface(test, root, run):
    plan = RUNNER.build_plan(root, run)
    test.assertIsInstance(plan, dict, 'Missing plan; dependent mutation contract UNENTERED')
    test.assertEqual(plan.get('selections'), SELECTIONS,
                     'Missing fixed old14/new31 selection contract; deeper calls UNENTERED')
    test.assertEqual(list(plan['selections']), ['old14', 'new31'])
    return plan


def mutation_log(failures=0):
    # A synthetic complete 31-method shape: 54 assertion failures may exceed 31 methods.
    lines = []
    for index, method in enumerate(MUTATION_METHODS):
        identity = '-[' + MUTATION_CLASS + ' ' + method + ']'
        lines.append("Test Case '" + identity + "' started.")
        if failures and index == 0:
            lines.extend('fixture.swift:1: error: ' + identity + ' : XCTAssertTrue failed' for _ in range(failures))
        lines.append("Test Case '" + identity + "' " + ('failed' if failures and index == 0 else 'passed') + ' (0.001 seconds).')
    lines.append('Executed 31 tests, with ' + str(failures) + ' failures (0 unexpected)')
    return ('\n'.join(lines) + '\n').encode()


@contextlib.contextmanager
def relocated_runner(root):
    # Only locations move to a synthetic public-shaped checkout. No production method is replaced.
    here = root / 'Tests/NativeIntegration'
    with mock.patch.object(RUNNER, 'HERE', here), mock.patch.object(RUNNER, '__file__', str(here / 'run_native_language_catalog.py')):
        yield


def receipt_fixture(output, command, code, stdout=b'', stderr=b''):
    # Synthetic collaborator protocol only: this is NOT an actual owned-process receipt.
    output.mkdir()
    (output / 'stdout.log').write_bytes(stdout)
    (output / 'stderr.log').write_bytes(stderr)
    value = dict(command=command, pid=4242, processGroup=4242, exitObserved=True,
        registrationError=None, groupSignalAttempted=True, groupSignalError=3,
        groupCleanup='absent', groupQuery=None, waitCompleted=True, returnCode=code,
        waitError=None, timedOut=False, interruptedSignal=None, truncated=False,
        captureComplete=True, failure=None, exit=code, seconds=0.01,
        captured={name: dict(stored=len(data), received=len(data), discarded=0)
                  for name, data in [('stdout', stdout), ('stderr', stderr)]})
    put(output / 'status.json', json.dumps(value))


def orchestrate(test, root, old_failure=False, new_failure=False, tamper=None):
    repository(root)
    with relocated_runner(root):
        require_mutation_surface(test, root, root / 'Prospective')
        calls = []
        recorded_run = None
        real_import = RUNNER.import_module

        def child(argv):
            nonlocal recorded_run
            output = Path(argv[argv.index('--output') + 1]); run = output.parent
            command = argv[argv.index('--') + 1:]; name = output.name
            recorded_run = run
            test.assertEqual(argv[:2], ['--timeout', '30' if name in ('toolchain', 'binpath') else '180'])
            test.assertIn(name, ('toolchain', 'build', 'binpath', 'old14', 'new31'))
            calls.append(name)
            stdout = b''; stderr = b''; code = 0
            if name == 'build':
                binary, _ = compiler_fixture(run, preserve_frozen_sources=True)
                executable = binary / (GENERATED + '.xctest/Contents/MacOS/' + GENERATED)
                put(executable, 'SYNTHETIC NOT EXECUTED\n'); executable.chmod(0o700)
            elif name == 'binpath':
                stdout = (str(run / 'BuildProducts/arm64-apple-macosx/debug') + '\n').encode()
            elif name in ('old14', 'new31'):
                expected = CLASS if name == 'old14' else MUTATION_CLASS
                test.assertEqual(command[-5:], ['/usr/bin/xcrun', 'xctest', '-XCTest', expected,
                    str(run / 'BuildProducts/arm64-apple-macosx/debug' / (GENERATED + '.xctest'))])
                failed = old_failure if name == 'old14' else new_failure
                code = 1 if failed else 0
                stderr = log(failed=failed) if name == 'old14' else mutation_log(54 if failed else 0)
            receipt_fixture(output, command, code, stdout, stderr)
            if name == 'new31' and tamper is not None:
                target = run / tamper
                test.assertTrue(target.is_file(), 'Prior authority must be stored before later child')
                with target.open('ab') as stream: stream.write(b'\n\n')
            return code

        def imported(path, name):
            if Path(path).name == 'run-owned-search-tests.py': return SimpleNamespace(main=child)
            test.assertEqual(Path(path).name, 'receipt-verifier.py')
            # The accepted receipt validator is real. Only the synchronous child boundary is mocked.
            return real_import(path, name)

        with mock.patch.object(RUNNER, 'import_module', side_effect=imported):
            code = RUNNER.main([])
        test.assertIsNotNone(recorded_run, 'No child reached; later output oracles UNENTERED')
        result = json.loads((recorded_run / 'result.json').read_text())
        return code, result, calls, recorded_run


class CatalogRunnerContractTests(unittest.TestCase):
    def testPublicPlanUsesOnlyCurrentCoreOwnerAndExactTwoTests(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / 'Repo'; run = Path(temp) / 'Run'; repository(root)
            plan = RUNNER.build_plan(root, run)
            self.assertIsInstance(plan, dict, 'Missing fixed catalog runner plan; deeper mapping unentered')
            self.assertEqual(plan['selection'], CLASS)
            self.assertEqual(plan['methods'], METHODS)
            self.assertEqual(plan['package'], (HERE / 'native-language-catalog-Package.swift').read_text())
            self.assertEqual(plan['swiftInputs'], {
                'Sources/PadCore/A.swift': 'Package/Sources/PadCore/A.swift',
                'Sources/PadCore/B.swift': 'Package/Sources/PadCore/B.swift',
                OWNER: 'Package/Sources/NativeLanguageCatalogComponent/NativeLanguageCatalogOwner.swift',
                MUTATION: 'Package/Sources/NativeLanguageCatalogComponent/NativeLanguageCatalogMutation.swift',
                WIRE: 'Package/Tests/NativeLanguageCatalogOwnerTests/CatalogTestFixture.swift',
                **{'Tests/NativeIntegration/' + name: 'Package/Tests/NativeLanguageCatalogOwnerTests/' + name for name in (*TESTS, *MUTATION_TESTS)}})
            self.assertEqual(plan['tools'], {
                'scripts/swift.sh': 'ToolSupport/scripts/swift.sh',
                'scripts/run-owned-search-tests.py': 'Runner/run-owned-search-tests.py',
                'Tests/NativeIntegration/run_native_regressions.py': 'Runner/receipt-verifier.py',
                'Tests/NativeIntegration/run_native_language_catalog.py': 'Runner/run_native_language_catalog.py'})

    def testFourStagesBuildThenDirectBoundClassWithoutPostCapturePlanner(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / 'Repo'; run = Path(temp) / 'Run'; repository(root)
            plan = RUNNER.build_plan(root, run)
            self.assertIsInstance(plan, dict, 'Missing fixed stage plan; deeper argv unentered')
            common = ['--package-path', str(run / 'Package'), '--scratch-path', str(run / 'BuildProducts')]
            swift = str(run / 'ToolSupport/scripts/swift.sh')
            commands = [
                ('toolchain', 30, ['/usr/bin/xcrun', 'swift', '--version']),
                ('build', 180, [swift, 'build', *common, '--build-tests', '-Xswiftc', '-warnings-as-errors']),
                ('binpath', 30, [swift, 'build', *common, '--show-bin-path', '-Xswiftc', '-warnings-as-errors']),
                ('old14', 180, ['/usr/bin/xcrun', 'xctest', '-XCTest', CLASS, str(run / 'BuildProducts/arm64-apple-macosx/debug' / (GENERATED + '.xctest'))]),
                ('new31', 180, ['/usr/bin/xcrun', 'xctest', '-XCTest', MUTATION_CLASS, str(run / 'BuildProducts/arm64-apple-macosx/debug' / (GENERATED + '.xctest'))]),
            ]
            self.assertEqual(plan['stages'], [dict(name=name, timeout=timeout, command=['/usr/bin/env',
                'THEONLYPAD_STATE_DIRECTORY=' + str(run / 'State' / name),
                'TMPDIR=' + str(run / 'Temporary' / name), *command]) for name, timeout, command in commands])
            self.assertEqual(plan['captureAfter'], 'binpath')

    def testClosedCLIRejectsAnySourceFilterHelperOrBuildOverride(self):
        self.assertIsNone(RUNNER.validate_cli([]))
        for argv in (['--filter', 'Other'], ['--source', 'Other.swift'], ['--build-path', '/tmp/other'], ['--helper-path', '/tmp/helper'], ['--skip-build']):
            with self.subTest(argv=argv), self.assertRaises(ValueError): RUNNER.validate_cli(argv)

    def testCompleteFourteenPassAndOrdinaryFailureRemainDistinct(self):
        result = RUNNER.parse_result(log(), 0)
        self.assertIsInstance(result, dict, 'Missing actual14 result parser; deeper result assertions unentered')
        self.assertEqual((result['executed'], result['failures'], result['exit']), (14, 0, 0))
        self.assertEqual(result['methods'], METHODS)
        failed = RUNNER.parse_result(log(failed=True), 1)
        self.assertEqual((failed['executed'], failed['failures'], failed['exit']), (14, 1, 1))

    def testIncompleteRepeatedForeignSkippedAndExitMismatchAreNotPassingEvidence(self):
        good = log()
        variants = [good.replace(METHODS[1].encode(), METHODS[0].encode()),
                    good.replace(METHODS[1].encode(), b'testForeign'),
                    good.replace(b" passed (", b" skipped (", 1),
                    good.splitlines(keepends=True)[0], good.replace(b'0 unexpected', b'1 unexpected')]
        for raw in variants:
            with self.subTest(raw=raw[:60]), self.assertRaises(ValueError): RUNNER.parse_result(raw, 0)
        with self.assertRaises(ValueError): RUNNER.parse_result(good, 1)
        with self.assertRaises(ValueError): RUNNER.parse_result(log(failed=True), 0)

    def testCompilerProofRejectsFilelistOutputmapAndLinkSubstitution(self):
        with tempfile.TemporaryDirectory() as temp:
            run = Path(temp); binary, commands = compiler_fixture(run)
            RUNNER.validate_compiler_graph(run, binary)  # Inert baseline accepts this valid shape.
            row = commands['PadCore']; source = row['sources'][0]
            mutations = [(Path(row['fileList']), source.replace('A.swift', 'Foreign.swift') + '\n'),
                         (Path(row['outputFileMapPath']), json.dumps({'': {}, source: {'object': commands[GENERATED]['objects'][0]}})),
                         (binary / (GENERATED + '.product/Objects.LinkFileList'), commands[GENERATED]['objects'][0] + '\n')]
            for path, wrong in mutations:
                original = path.read_bytes()
                try:
                    path.write_text(wrong)
                    with self.subTest(path=path.name), self.assertRaises(ValueError): RUNNER.validate_compiler_graph(run, binary)
                finally: path.write_bytes(original)

    def testMissingMutationSourceOrExactWireFixtureRefusesBeforeFreeze(self):
        for missing in (MUTATION, WIRE):
            with self.subTest(missing=missing), tempfile.TemporaryDirectory() as temp:
                root = Path(temp) / 'Repo'; run = Path(temp) / 'Run'; repository(root)
                require_mutation_surface(self, root, run)
                (root / missing).unlink()
                with self.assertRaises((ValueError, OSError)):
                    RUNNER.build_plan(root, run)
                self.assertFalse(run.exists(), 'Missing required source must refuse before any frozen child')

    def testTwoFixedRostersAndFrozenDeclarationsCannotSubstituteEachOther(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / 'Probe'; repository(root)
            require_mutation_surface(self, root, Path(temp) / 'Unused')
        for variant in ('valid', 'missing', 'duplicate', 'foreign', 'oldRoster', 'wrongClass', 'wrongDeclaration'):
            with self.subTest(variant=variant), tempfile.TemporaryDirectory() as temp:
                root = Path(temp) / 'Repo'; repository(root)
                support = root / 'Tests/NativeIntegration/native-language-catalog-mutation-methods.json'
                methods = list(MUTATION_METHODS)
                if variant == 'missing': methods.pop()
                elif variant == 'duplicate': methods[-1] = methods[0]
                elif variant == 'foreign': methods[-1] = 'testUnrepresentedForeignMutation'
                elif variant == 'oldRoster': methods = list(METHODS)
                support.write_text(json.dumps(methods))
                native = root / 'Tests/NativeIntegration/NativeLanguageCatalogMutationTests.swift'
                if variant == 'wrongClass':
                    native.write_text(native.read_text().replace('final class NativeLanguageCatalogMutationTests', 'final class NativeLanguageCatalogOwnerTests'))
                elif variant == 'wrongDeclaration':
                    native.write_text(native.read_text().replace(MUTATION_METHODS[0], METHODS[0]))
                run = Path(temp) / 'Run'; run.mkdir(mode=0o700)
                with relocated_runner(root):
                    if variant == 'valid':
                        plan = require_mutation_surface(self, root, run)
                        RUNNER.freeze(root, run, plan)
                        self.assertEqual((run / 'Package/Tests/NativeLanguageCatalogOwnerTests/NativeLanguageCatalogMutationTests.swift').read_bytes(), native.read_bytes())
                        self.assertEqual((run / 'Runner/native-language-catalog-methods.json').read_bytes(), (HERE / 'native-language-catalog-methods.json').read_bytes())
                    else:
                        with self.assertRaises(ValueError):
                            plan = RUNNER.build_plan(root, run)
                            RUNNER.freeze(root, run, plan)

    def testMutation31PassAnd54OrdinaryAssertionsRemainTruthful(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / 'Repo'; repository(root)
            require_mutation_surface(self, root, Path(temp) / 'Run')
        self.assertIn('selection', inspect.signature(RUNNER.parse_result).parameters,
                      'Missing optional parser selection; new parser horizons UNENTERED')
        good = RUNNER.parse_result(mutation_log(), 0, selection='new31')
        self.assertEqual((good['executed'], good['failures'], good['unexpected'], good['exit']), (31, 0, 0, 0))
        self.assertEqual(good['methods'], MUTATION_METHODS)
        failed = RUNNER.parse_result(mutation_log(54), 1, selection='new31')
        self.assertEqual((failed['executed'], failed['failures'], failed['unexpected'], failed['exit']), (31, 54, 0, 1))
        for raw, code in ((mutation_log(), 1), (mutation_log(54), 0),
                          (mutation_log().replace(MUTATION_CLASS.encode(), CLASS.encode()), 0),
                          (mutation_log().replace(b'0 unexpected', b'1 unexpected'), 0)):
            with self.subTest(code=code, raw=raw[:50]), self.assertRaises(ValueError):
                RUNNER.parse_result(raw, code, selection='new31')
        with self.assertRaises(ValueError): RUNNER.parse_result(mutation_log(), 0, selection='arbitrary')

    def testOld14FailurePreventsNew31AndPreservesNaturalOne(self):
        with tempfile.TemporaryDirectory() as temp:
            code, result, calls, run = orchestrate(self, Path(temp) / 'Repo', old_failure=True)
            self.assertEqual(code, 1)
            self.assertEqual(result['state'], 'OLD14_FAILED_NEW31_UNENTERED')
            self.assertEqual(result['exit'], 1)
            self.assertTrue(result['postflightVerified'])
            self.assertEqual(calls, ['toolchain', 'build', 'binpath', 'old14'])
            self.assertFalse((run / 'new31').exists())
            self.assertFalse((run / 'new31-result.json').exists())
            self.assertEqual(json.loads((run / 'old14-result.json').read_text())['failures'], 1)

    def testNew31FailureCannotBecomeCompletePassOrExitZero(self):
        with tempfile.TemporaryDirectory() as temp:
            code, result, calls, run = orchestrate(self, Path(temp) / 'Repo', new_failure=True)
            self.assertEqual(code, 1)
            self.assertEqual((result['state'], result['exit']), ('COMPLETE_ORDINARY_FAILURE', 1))
            self.assertTrue(result['postflightVerified'])
            self.assertEqual(calls, ['toolchain', 'build', 'binpath', 'old14', 'new31'])
            self.assertEqual(json.loads((run / 'old14-result.json').read_text())['failures'], 0)
            self.assertEqual(json.loads((run / 'new31-result.json').read_text())['failures'], 54)
            self.assertEqual(json.loads((run / 'new31/status.json').read_text())['exit'], 1)

    def testPriorStageCommandReceiptStreamsAndArtifactsRemainPinned(self):
        with tempfile.TemporaryDirectory() as temp:
            code, result, calls, run = orchestrate(self, Path(temp) / 'Repo')
            self.assertEqual((code, result['state'], result['exit']), (0, 'COMPLETE_PASS', 0))
            self.assertTrue(result['postflightVerified'])
            self.assertEqual(calls, ['toolchain', 'build', 'binpath', 'old14', 'new31'])
        for target in ('Commands/old14.json', 'old14/status.json', 'old14/stdout.log',
                       'old14/stderr.log', 'artifacts.json'):
            with self.subTest(target=target), tempfile.TemporaryDirectory() as temp:
                code, result, calls, run = orchestrate(self, Path(temp) / 'Repo', tamper=target)
                self.assertEqual(code, 125)
                self.assertEqual(result['exit'], 125)
                self.assertNotEqual(result['state'], 'COMPLETE_PASS')
                self.assertFalse(result['postflightVerified'])
                self.assertEqual(calls, ['toolchain', 'build', 'binpath', 'old14', 'new31'])
                self.assertTrue((run / target).read_bytes().endswith(b'\n\n'), 'Mutation retained, never repaired or reblessed')


    def testCurrentStageCommandChangedDuringChildIsNotAdoptedAsAuthority(self):
        # All five synchronous child calls must run before the command-drift verdict.
        # The real coordinator wrote this current command before this child callback;
        # the existing collaborator appends only two LF bytes while that child runs.
        with tempfile.TemporaryDirectory() as temp:
            code, result, calls, run = orchestrate(
                self, Path(temp) / 'Repo', tamper='Commands/new31.json')
            self.assertEqual(calls, ['toolchain', 'build', 'binpath', 'old14', 'new31'])
            changed = (run / 'Commands/new31.json').read_bytes()
            self.assertTrue(changed.endswith(b'\n\n'), 'The actual command mutation must be reached and retained')
            self.assertEqual(json.loads(changed)['name'], 'new31')
            self.assertEqual(json.loads(changed)['command'],
                             json.loads((run / 'new31/status.json').read_text())['command'])
            self.assertEqual(code, 125, 'Current-command drift must refuse, not become newly trusted authority')
            self.assertEqual(result['exit'], 125)
            self.assertNotEqual(result['state'], 'COMPLETE_PASS')
            self.assertFalse(result['postflightVerified'])
            self.assertEqual((run / 'Commands/new31.json').read_bytes(), changed,
                             'Changed evidence must remain intact, never recreated or repaired')


if __name__ == '__main__':
    unittest.main()
