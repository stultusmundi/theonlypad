"""Pure contract: temporary text fixtures only; never invoke a compiler or watchdog."""
from pathlib import Path
import importlib.util
import json
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location('catalog_runner_under_test', HERE / 'run_native_language_catalog.py')
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)
METHODS = json.loads((HERE / 'native-language-catalog-methods.json').read_text())
CLASS = 'NativeLanguageCatalogOwnerTests.NativeLanguageCatalogOwnerTests'
GENERATED = 'NativeLanguageCatalogPackageTests'
OWNER = 'Sources/TheOnlyPad/NativeLanguageCatalogOwner.swift'
TESTS = ('NativeLanguageCatalogOwnerTests.swift', 'NativeLanguageCatalogOwnerFixtures.swift')


def put(path, value='// synthetic path fixture, never compiled\n'):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value)


def repository(root):
    # The fixture intentionally has two Core files: the planner must enumerate
    # current Core membership, not hard-code one historical59-file hash/count.
    for name in ('Sources/PadCore/A.swift', 'Sources/PadCore/B.swift', OWNER,
                 'Sources/TheOnlyPad/AppDelegate.swift', 'Sources/SearchExecution/Excluded.swift',
                 'Tests/PadCoreTests/ExcludedTests.swift', 'scripts/swift.sh',
                 'scripts/run-owned-search-tests.py', 'Tests/NativeIntegration/run_native_regressions.py',
                 'Tests/NativeIntegration/run_native_language_catalog.py'):
        put(root / name)
    for name in TESTS:
        text = '\n'.join('  func ' + method + '() {}' for method in METHODS) if name == TESTS[0] else '// fixture\n'
        put(root / 'Tests/NativeIntegration' / name, text)


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


def compiler_fixture(run):
    # Deliberately non-executable bytes. This tests path/map/link discrimination,
    # not real Swift compilation, signature, target execution or native behavior.
    binary = run / 'Build/arm64-apple-macosx/debug'
    groups = {
        'PadCore': [run / 'Package/Sources/PadCore/A.swift'],
        'NativeLanguageCatalogComponent': [run / 'Package/Sources/NativeLanguageCatalogComponent/NativeLanguageCatalogOwner.swift'],
        'NativeLanguageCatalogOwnerTests': [run / 'Package/Tests/NativeLanguageCatalogOwnerTests' / name for name in TESTS],
        GENERATED: [binary / (GENERATED + '.derived/runner.swift')],
    }
    commands = {}; all_objects = []
    for module, sources in groups.items():
        objects = [binary / (module + '.build') / (source.name + '.o') for source in sources]
        for source in sources: put(source)
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
                **{'Tests/NativeIntegration/' + name: 'Package/Tests/NativeLanguageCatalogOwnerTests/' + name for name in TESTS}})
            self.assertEqual(plan['tools'], {
                'scripts/swift.sh': 'Toolchain/scripts/swift.sh',
                'scripts/run-owned-search-tests.py': 'Runner/run-owned-search-tests.py',
                'Tests/NativeIntegration/run_native_regressions.py': 'Runner/receipt-verifier.py',
                'Tests/NativeIntegration/run_native_language_catalog.py': 'Runner/run_native_language_catalog.py'})

    def testFourStagesBuildThenDirectBoundClassWithoutPostCapturePlanner(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / 'Repo'; run = Path(temp) / 'Run'; repository(root)
            plan = RUNNER.build_plan(root, run)
            self.assertIsInstance(plan, dict, 'Missing fixed stage plan; deeper argv unentered')
            common = ['--package-path', str(run / 'Package'), '--scratch-path', str(run / 'Build')]
            swift = str(run / 'Toolchain/scripts/swift.sh')
            commands = [
                ('toolchain', 30, ['/usr/bin/xcrun', 'swift', '--version']),
                ('build', 180, [swift, 'build', *common, '--build-tests', '-Xswiftc', '-warnings-as-errors']),
                ('binpath', 30, [swift, 'build', *common, '--show-bin-path', '-Xswiftc', '-warnings-as-errors']),
                ('test', 180, ['/usr/bin/xcrun', 'xctest', '-XCTest', CLASS, str(run / 'Build/arm64-apple-macosx/debug' / (GENERATED + '.xctest'))]),
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


if __name__ == '__main__':
    unittest.main()
