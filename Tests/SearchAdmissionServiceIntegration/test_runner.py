"""Pure discriminators. Synthetic temporary inputs; no Swift/process execution."""
from pathlib import Path
import copy
import errno
import importlib.util
import json
import os
import tempfile
import unittest

path = Path(__file__).with_name('run_harness.py')
spec = importlib.util.spec_from_file_location('admission_service_runner', path)
r = importlib.util.module_from_spec(spec)
# Load exact source bytes. No timestamp-valid bytecode or production Swift import.
exec(compile(path.read_bytes(), str(path), 'exec'), r.__dict__)


def xctest_log(names):
    return '\n'.join("Test Case '" + name + "' started.\nTest Case '" + name
                     + "' passed (0.001 seconds)." for name in names) + (
        '\nExecuted ' + str(len(names)) + ' tests, with 0 failures (0 unexpected) in 0.01 seconds\n')


def pure_log(names):
    return '\n'.join(name.rsplit('.', 1)[1] + ' (' + name + ') ... ok' for name in names) + (
        '\nRan ' + str(len(names)) + ' tests in 0.01s\n\nOK\n')


def receipt(command, stdout=b'', stderr=b'', code=0):
    return dict(command=command, pid=731, processGroup=731, exitObserved=True,
                registrationError=None, groupSignalAttempted=True, groupSignalError=None,
                groupCleanup='signaled', groupQuery=None, waitCompleted=True, returnCode=code,
                waitError=None, timedOut=False, interruptedSignal=None, truncated=False,
                captureComplete=True, failure=None, exit=code,
                captured={name: dict(received=len(data), stored=len(data), discarded=0)
                          for name, data in [('stdout', stdout), ('stderr', stderr)]})


class ParserTests(unittest.TestCase):
    def setUp(self):
        self.names = ['SearchAdmissionServiceConstructionTests.' + n for n in r.CONSTRUCTION]

    def test_exact_four_start_and_pass(self):
        self.assertEqual(r.validate_tests(xctest_log(self.names), self.names), 4)

    def test_native_xctest_names(self):
        names = ['-[SearchExecutionTests.' + n.replace('.', ' ') + ']' for n in self.names]
        self.assertEqual(r.validate_tests(xctest_log(names), self.names), 4)

    def test_missing_duplicate_and_wrong_start(self):
        for changed in (self.names[:-1], self.names + self.names[:1], self.names[:-1] + ['Wrong.testName']):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                r.validate_tests(xctest_log(changed), self.names)

    def test_missing_duplicate_and_wrong_pass(self):
        original = xctest_log(self.names)
        leaf = "Test Case '" + self.names[0] + "' passed (0.001 seconds)."
        for changed in (original.replace(leaf, ''), original + '\n' + leaf,
                        original.replace(leaf, leaf.replace(self.names[0], 'Wrong.testName'))):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                r.validate_tests(changed, self.names)

    def test_zero_empty_wrong_aggregate(self):
        for text, names in [('Executed 0 tests, with 0 failures', []),
                            (xctest_log(self.names).replace('Executed 4', 'Executed 0'), self.names),
                            (xctest_log(self.names).replace('Executed 4', 'Executed 5'), self.names)]:
            with self.subTest(text=text), self.assertRaises(ValueError):
                r.validate_tests(text, names)

    def test_skip_failure_unexpected_warning_error(self):
        original = xctest_log(self.names)
        for text in (original.replace('passed (', 'skipped ('), original.replace('passed (', 'failed ('),
                     original.replace('0 failures', '1 failures'), original.replace('0 unexpected', '1 unexpected'),
                     original + '\nwarning: synthetic\n', original + '\nerror: synthetic\n'):
            with self.subTest(text=text), self.assertRaises(ValueError):
                r.validate_tests(text, self.names)

    def test_pure_controls_require_exact_positive_names(self):
        expected = ['test_runner.SyntheticTests.test_first', 'test_runner.SyntheticTests.test_second']
        self.assertEqual(r.validate_pure(pure_log(expected), expected), 2)
        old = pure_log(expected).replace('SyntheticTests.test_first)', 'SyntheticTests)').replace(
            'SyntheticTests.test_second)', 'SyntheticTests)')
        self.assertEqual(r.validate_pure(old, expected), 2)
        for changed in (pure_log(expected[:-1]), pure_log(expected + expected[:1]),
                        pure_log(expected).replace('... ok', '... skipped'),
                        pure_log(expected).replace('Ran 2', 'Ran 0'), pure_log(expected) + '\nERROR\n'):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                r.validate_pure(changed, expected)

    def test_source_names_discriminate_conditions_and_skips(self):
        source = ('\n'.join('func ' + n + '() {}' for n in r.CONSTRUCTION)).encode()
        r.named_methods(source, r.CONSTRUCTION)
        for changed in (source + source, source.replace(r.CONSTRUCTION[0].encode(), b'testWrong'),
                        b'#if DEBUG\n' + source, source + b'\nthrow XCTSkip("x")'):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                r.named_methods(changed, r.CONSTRUCTION)

    def test_pure_source_inventory_rejects_decorated_duplicate_and_zero(self):
        self.assertEqual(r.pure_names(b'class X:\n def test_one(self): pass\n'), ['test_runner.X.test_one'])
        for source in (b'class X:\n @skip\n def test_one(self): pass\n',
                       b'class X:\n def test_one(self): pass\n def test_one(self): pass\n', b'x = 1\n'):
            with self.subTest(source=source), self.assertRaises(ValueError):
                r.pure_names(source)


class SyntheticInputs(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name).resolve()
        self.root, self.run = base / 'root', base / 'run'
        self.root.mkdir()
        self.run.mkdir()
        for name in r.FIXED:
            self.write(name, '// synthetic provenance\n')
        self.write('Sources/PadCore/Core.swift', '// synthetic core\n')
        self.write('Sources/SearchExecution/Deep/Nested.swift', '// synthetic execution\n')
        self.write(r.TASK1[0], '\n'.join('func ' + n + '() {}' for n in r.TASK1_TESTS))
        self.write(r.HERE + '/SearchAdmissionServiceConstructionTests.swift',
                   '\n'.join('func ' + n + '() {}' for n in r.CONSTRUCTION))
        self.write(r.HERE + '/test_runner.py', 'class SyntheticTests:\n def test_first(self): pass\n')
        self.write(r.HERE + '/Fixtures/AllowedClient.swift', 'import SearchExecution\nfunc allowed() {}\n')
        expressions = ('_ = await service.shutdown()', '_ = service.controller', '_ = service.driver',
                       '_ = try SearchAdmissionService<String>(driver: driver)',
                       '_ = try SearchAdmissionService<String>(controller: controller)')
        for name, expression in zip(r.NEGATIVES, expressions):
            self.write(r.HERE + '/Fixtures/' + name + '.swift',
                       'import SearchExecution\n\nfunc synthetic() {\n  ' + expression + '\n}\n')
        self.manifest = r.freeze(self.root, self.run)

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        path.chmod(0o600)
        return path

    def changed_manifest(self, mutation):
        manifest = copy.deepcopy(self.manifest)
        mutation(manifest)
        with self.assertRaises(ValueError):
            r.verify(self.run, manifest)


class FreezeTests(SyntheticInputs):
    def test_exact_five_task1_dependencies_are_compiled_in_each_six_packages(self):
        # Independent literals catch the reviewed omitted Admission harness even
        # when freeze and its fixtures both derive their inventory from TASK1.
        required = (
            'Tests/SearchExecutionTests/SearchAdmissionServiceTests.swift',
            'Tests/SearchExecutionTests/SearchAdmissionServiceTestHarness.swift',
            'Tests/SearchExecutionTests/SearchAdmissionTestHarness.swift',
            'Tests/SearchExecutionTests/SearchAdmissionJoinedTestHarness.swift',
            'Tests/SearchExecutionTests/SearchParentWireDriverTestHarness.swift',
        )
        packages = ('Package', 'Compiler/ForbiddenLegacy', 'Compiler/ForbiddenController',
                    'Compiler/ForbiddenDriver', 'Compiler/ForbiddenDriverInitializer',
                    'Compiler/ForbiddenControllerInitializer')
        self.assertEqual(r.TASK1, required)
        origins = {item['source']: item for item in self.manifest['sources']}
        self.assertTrue(set(required).issubset(origins))
        for name in required:
            item = origins[name]
            source, mode = r.read_file(self.root / name)
            wanted = [dict(frozen=package + '/Tests/SearchExecutionTests/' + Path(name).name,
                           role='compiledTests', mode=mode) for package in packages]
            self.assertEqual(item['copies'], wanted)
            for destination in wanted:
                self.assertEqual(r.read_file(self.run / destination['frozen']), (source, mode))
        removed = copy.deepcopy(self.manifest)
        removed['sources'] = [item for item in removed['sources']
                              if item['source'] != 'Tests/SearchExecutionTests/SearchAdmissionTestHarness.swift']
        with self.assertRaises(ValueError):
            r.verify(self.run, removed)

    def test_recursive_actual_sources_and_separate_package_access_clients(self):
        r.verify(self.run, self.manifest)
        origins = {i['source']: i for i in self.manifest['sources']}
        self.assertEqual(len(origins['Sources/SearchExecution/Deep/Nested.swift']['copies']), 6)
        self.assertEqual(origins['Package.swift']['copies'][0]['role'], 'publicManifestProvenance')
        for package in r.PACKAGES:
            text = (self.run / package / 'Package.swift').read_text()
            self.assertIn('.macOS(.v14)', text)
            self.assertIn('swiftLanguageModes: [.v5]', text)
            self.assertEqual('ForbiddenClient' in text, package != 'Package')
        self.assertEqual((self.run / 'Runner/scripts/swift.sh').read_bytes(),
                         (self.root / 'scripts/swift.sh').read_bytes())

    def test_origin_bytes_modes_paths_and_membership(self):
        for change in ('bytes', 'mode', 'member'):
            with self.subTest(change=change):
                path = self.root / 'Sources/PadCore/Core.swift'
                data, mode = r.read_file(path)
                extra = None
                try:
                    if change == 'bytes':
                        path.write_bytes(data + b'// changed')
                    elif change == 'mode':
                        path.chmod(0o400)
                    else:
                        extra = self.write('Sources/PadCore/Added.swift', '// extra')
                    with self.assertRaises(ValueError):
                        r.verify(self.run, self.manifest)
                finally:
                    # Ordinary users cannot restore bytes while mode is0400.
                    path.chmod(mode)
                    path.write_bytes(data)
                    if extra is not None:
                        extra.unlink()
        self.changed_manifest(lambda m: m['sources'][0].update(origin='/synthetic/wrong'))

    def test_wrapper_common_watchdog_and_fixture_origin_changes(self):
        for name in ('scripts/swift.sh', 'scripts/run-owned-search-tests.py',
                     'Tests/SearchChildIntegration/run_harness.py', r.HERE + '/Fixtures/AllowedClient.swift'):
            path = self.root / name
            data = path.read_bytes()
            with self.subTest(name=name):
                path.write_bytes(data + b'// changed')
                with self.assertRaises(ValueError):
                    r.verify(self.run, self.manifest)
                path.write_bytes(data)

    def test_frozen_bytes_and_modes(self):
        path = self.run / 'Package/Sources/PadCore/Core.swift'
        data = path.read_bytes()
        for change in ('bytes', 'mode'):
            with self.subTest(change=change):
                try:
                    path.write_bytes(data + b'changed' if change == 'bytes' else data)
                    path.chmod(0o400 if change == 'mode' else 0o600)
                    with self.assertRaises(ValueError):
                        r.verify(self.run, self.manifest)
                finally:
                    path.chmod(0o600)
                    path.write_bytes(data)

    def test_generated_manifest_hash_mode_membership_and_relationship(self):
        path = self.run / 'Package/Package.swift'
        data = path.read_bytes()
        path.write_bytes(data.replace(b'.v14', b'.v26'))
        manifest = copy.deepcopy(self.manifest)
        item = next(i for i in manifest['generated'] if i['frozen'] == 'Package/Package.swift')
        item['sha256'] = r.digest(path.read_bytes())
        with self.assertRaises(ValueError):
            r.verify(self.run, manifest)
        path.write_bytes(data)
        path.chmod(0o400)
        with self.assertRaises(ValueError):
            r.verify(self.run, self.manifest)
        path.chmod(0o600)
        self.changed_manifest(lambda m: m['generated'].pop())

    def test_extra_frozen_source_versioned_manifest_and_python_cache(self):
        for name in ('Package/Sources/PadCore/Extra.swift', 'Package/Package@swift-6.swift',
                     'Runner/Tests/SearchChildIntegration/__pycache__/unbound.pyc'):
            path = self.run / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'synthetic extra')
            with self.subTest(name=name), self.assertRaises(ValueError):
                r.verify(self.run, self.manifest)
            path.unlink()
            if path.parent.name == '__pycache__':
                path.parent.rmdir()

    def test_symlink_source_file_directory_and_root(self):
        path = self.root / 'Sources/PadCore/Core.swift'
        data = path.read_bytes()
        target = self.root / 'regular-input'
        target.write_bytes(data)
        path.unlink()
        path.symlink_to(target)
        with self.assertRaises(ValueError):
            r.verify(self.run, self.manifest)
        path.unlink()
        path.write_bytes(data)
        path.chmod(0o600)
        alias = self.root.parent / 'root-alias'
        alias.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(ValueError):
            r.discover(alias)
        directory = self.root / 'Sources/SearchExecution/Linked'
        directory.symlink_to(self.root / 'Sources/PadCore', target_is_directory=True)
        with self.assertRaises(ValueError):
            r.discover(self.root)

    def test_symlink_frozen_file_and_root(self):
        path = self.run / 'Package/Sources/PadCore/Core.swift'
        path.unlink()
        path.symlink_to(self.root / 'Sources/PadCore/Core.swift')
        with self.assertRaises(ValueError):
            r.verify(self.run, self.manifest)
        alias = self.run.parent / 'run-alias'
        alias.symlink_to(self.run, target_is_directory=True)
        with self.assertRaises(ValueError):
            r.verify(alias, self.manifest)

    def test_exempt_build_cache_never_admits_declared_provenance(self):
        cache = self.run / 'Runner/.cache'
        cache.mkdir()
        (cache / 'compiler-generated').write_bytes(b'cache')
        (self.run / 'Build').mkdir()
        r.verify(self.run, self.manifest)
        self.changed_manifest(lambda m: m['sources'][0]['copies'][0].update(frozen='Build/adopted.swift'))
        self.changed_manifest(lambda m: m.update(exempt=['Package']))
        cache.rename(self.run / 'Runner/old-cache')
        cache.symlink_to(self.run / 'Runner/old-cache', target_is_directory=True)
        with self.assertRaises(ValueError):
            r.verify(self.run, self.manifest)

    def test_copy_roles_and_origin_inventory_cannot_be_rewritten(self):
        self.changed_manifest(lambda m: m['sources'][0]['copies'][0].update(role='runnerOnly'))
        self.changed_manifest(lambda m: m['sources'].pop())
        self.changed_manifest(lambda m: m['sources'].append(m['sources'][0]))
        self.changed_manifest(lambda m: m.update(expectedTests=[]))
        self.changed_manifest(lambda m: m.update(expectedPure=[]))

    def test_build_root_and_exact_scratch_symlinks_are_refused(self):
        outside = self.run.parent / 'outside-build'
        outside.mkdir()
        path = self.run / 'Build'
        path.symlink_to(outside, target_is_directory=True)
        with self.assertRaises(ValueError):
            r.verify(self.run, self.manifest)
        path.unlink()
        path.mkdir()
        (path / 'Main').symlink_to(outside, target_is_directory=True)
        with self.assertRaises(ValueError):
            r.verify(self.run, self.manifest)

    def test_fixture_import_and_line_contract(self):
        relative = r.HERE + '/Fixtures/ForbiddenDriver.swift'
        data = (self.root / relative).read_bytes()
        for changed in (data.replace(b'import ', b'@testable import '), b'\n' + data,
                        data.replace(b'service.driver', b'service.other'), b'#if DEBUG\n' + data):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                r.validate_fixture(relative, changed)

    def test_loader_ignores_synthetic_unbound_bytecode(self):
        path = self.root / 'synthetic.py'
        path.write_bytes(b'value = 2\n')
        cached = self.root / '__pycache__'
        cached.mkdir()
        (cached / 'synthetic.cpython-313.pyc').write_bytes(b'not bound to source')
        self.assertEqual(r.load(path, 'synthetic_loader_control').value, 2)


class DiagnosticTests(unittest.TestCase):
    def setUp(self):
        self.fixture = Path('/synthetic/Compiler/ForbiddenDriver/Sources/ForbiddenClient/ForbiddenDriver.swift')
        self.message = "value of type 'SearchAdmissionService<String>' has no member 'driver'"

    def log(self, path=None, line=4, message=None):
        return str(path or self.fixture) + ':' + str(line) + ':15: error: ' + (message or self.message) + '\n'

    def test_exact_member_diagnostic_and_repeated_emission(self):
        self.assertEqual(r.validate_negative(self.log(), self.fixture)['line'], 4)
        self.assertEqual(r.validate_negative(self.log() * 2, self.fixture)['emittedErrors'], 2)
        r.validate_negative('error: emit-module command failed with exit code 1 (use -v to see invocation)\n'
                            + self.log(), self.fixture)

    def test_private_member_and_internal_initializer_categories(self):
        controller = self.fixture.with_name('ForbiddenController.swift')
        r.validate_negative(self.log(controller, message="'controller' is inaccessible due to 'private' protection level"), controller)
        for name, label in [('ForbiddenDriverInitializer', 'driver'), ('ForbiddenControllerInitializer', 'controller')]:
            fixture = self.fixture.with_name(name + '.swift')
            r.validate_negative(self.log(fixture, message="incorrect argument label in call (have '" + label
                                + ":', expected 'applicationBundle:')"), fixture)
            r.validate_negative(self.log(fixture, message="'init(" + label
                                + ":)' is inaccessible due to 'internal' protection level"), fixture)

    def test_wrong_file_line_member_and_module_syntax_errors(self):
        for changed in (self.log(self.fixture.with_name('Other.swift')), self.log(line=5),
                        self.log(message=self.message.replace("'driver'", "'shutdown'")),
                        self.log(message=self.message.replace('SearchAdmissionService<String>', 'UnrelatedType')),
                        self.log(message="cannot find type 'SearchAdmissionService' in scope"),
                        self.log(message="no such module 'SearchExecution'"),
                        self.log(message='expected expression'), self.log(message='unterminated string literal')):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                r.validate_negative(changed, self.fixture)

    def test_extra_unrelated_conversion_unlocated_warning_and_zero_errors(self):
        for changed in (self.log() + self.log(message='cannot convert value to URL'),
                        self.log() + '\nerror: compiler crashed\n', self.log() + '\nwarning: synthetic\n',
                        'Build complete!\n', 'error: emit-module command failed with exit code 1 (use -v to see invocation)\n'):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                r.validate_negative(changed, self.fixture)


class InitializerDiagnosticPairTests(unittest.TestCase):
    def observed(self, label):
        # Literal expected messages are bound to Root's two actual captured
        # initializer diagnostics, independently of the runner's classifier.
        values = {
            'driver': (
                'ForbiddenDriverInitializer', 50,
                "incorrect argument label in call (have 'driver:', expected 'applicationBundle:')",
                "cannot convert value of type 'any SearchParentWireJoining' to expected argument type 'URL'"),
            'controller': (
                'ForbiddenControllerInitializer', 54,
                "incorrect argument label in call (have 'controller:', expected 'applicationBundle:')",
                "cannot convert value of type 'SearchAdmissionController<String>' to expected argument type 'URL'"),
        }
        name, column, primary, secondary = values[label]
        fixture = Path('/synthetic/Compiler') / name / 'Sources/ForbiddenClient' / (name + '.swift')
        return fixture, column, primary, secondary

    def located(self, fixture, column, message, line=4):
        return str(fixture) + ':' + str(line) + ':' + str(column) + ': error: ' + message + '\n'

    def complete_pair(self, label):
        fixture, column, primary, secondary = self.observed(label)
        text = (self.located(fixture, 41, primary) + '  |                                         `- error: '
                + primary + '\n' + self.located(fixture, column, secondary)
                + '  |                                                  `- error: ' + secondary + '\n')
        return fixture, primary, secondary, text

    def test_observed_driver_initializer_label_and_related_conversion_pair(self):
        fixture, primary, secondary, text = self.complete_pair('driver')
        try:
            binding = r.validate_negative(text, fixture)
        except ValueError as error:
            self.fail('intended observed driver initializer pair was rejected: ' + str(error))
        self.assertEqual(binding['fixture'], str(fixture))
        self.assertEqual(binding['line'], 4)
        self.assertEqual(binding['messages'], sorted([primary, secondary]))
        self.assertEqual(binding['emittedErrors'], 2)
        repeated = r.validate_negative(text + text, fixture)
        self.assertEqual(repeated['messages'], sorted([primary, secondary]))
        self.assertEqual(repeated['emittedErrors'], 4)

    def test_observed_controller_initializer_label_and_related_conversion_pair(self):
        fixture, primary, secondary, text = self.complete_pair('controller')
        try:
            binding = r.validate_negative(text, fixture)
        except ValueError as error:
            self.fail('intended observed controller initializer pair was rejected: ' + str(error))
        self.assertEqual(binding['fixture'], str(fixture))
        self.assertEqual(binding['line'], 4)
        self.assertEqual(binding['messages'], sorted([primary, secondary]))
        self.assertEqual(binding['emittedErrors'], 2)
        repeated = r.validate_negative(text + text, fixture)
        self.assertEqual(repeated['messages'], sorted([primary, secondary]))
        self.assertEqual(repeated['emittedErrors'], 4)

    def test_related_conversion_never_alone_access_mix_or_wrong_label(self):
        for label in ('driver', 'controller'):
            fixture, column, primary, secondary = self.observed(label)
            conversion = self.located(fixture, column, secondary)
            inaccessible = "'init(" + label + ":)' is inaccessible due to 'internal' protection level"
            wrong_label = primary.replace("have '" + label + ":'", "have 'unrelated:'")
            variants = (conversion, self.located(fixture, 41, inaccessible) + conversion,
                        self.located(fixture, 41, wrong_label) + conversion,
                        self.located(fixture, 41, primary.replace('applicationBundle:', 'unrelated:')) + conversion)
            for text in variants:
                with self.subTest(label=label, text=text), self.assertRaises(ValueError):
                    r.validate_negative(text, fixture)

    def test_related_conversion_wrong_source_target_fixture_line_or_column(self):
        for label in ('driver', 'controller'):
            fixture, column, primary, secondary = self.observed(label)
            first = self.located(fixture, 41, primary)
            other_type = ('SearchAdmissionController<String>' if label == 'driver'
                          else 'any SearchParentWireJoining')
            own_type = ('any SearchParentWireJoining' if label == 'driver'
                        else 'SearchAdmissionController<String>')
            variants = (
                first + self.located(fixture, column, secondary.replace(own_type, other_type)),
                first + self.located(fixture, column, secondary.replace(own_type, 'UnrelatedType')),
                first + self.located(fixture, column, secondary.replace("'URL'", "'NSURL'")),
                first + self.located(fixture.with_name('Other.swift'), column, secondary),
                self.located(fixture.with_name('Other.swift'), 41, primary)
                + self.located(fixture, column, secondary),
                first + self.located(fixture, column, secondary, line=5),
                self.located(fixture, 41, primary, line=5) + self.located(fixture, column, secondary),
                first + self.located(fixture, 0, secondary),
            )
            for text in variants:
                with self.subTest(label=label, text=text), self.assertRaises(ValueError):
                    r.validate_negative(text, fixture)

    def test_initializer_pair_third_message_unlocated_error_and_warnings_refused(self):
        for label in ('driver', 'controller'):
            fixture, primary, secondary, pair = self.complete_pair(label)
            inaccessible = "'init(" + label + ":)' is inaccessible due to 'internal' protection level"
            variants = (
                pair + self.located(fixture, 41, inaccessible),
                pair + self.located(fixture, 41, 'expected expression'),
                pair + 'error: ' + secondary + '\n',
                pair + 'error: compiler crashed\n',
                pair + 'warning: synthetic unrelated warning\n',
                pair + str(fixture) + ':4:41: warning: synthetic warning\n',
            )
            for text in variants:
                with self.subTest(label=label, text=text), self.assertRaises(ValueError):
                    r.validate_negative(text, fixture)

    def test_excerpt_requires_exact_permitted_located_message(self):
        for label in ('driver', 'controller'):
            fixture, column, primary, secondary = self.observed(label)
            pair_fixture, _, _, pair = self.complete_pair(label)
            self.assertEqual(pair_fixture, fixture)
            variants = (
                self.located(fixture, 41, primary) + '  | `- error: ' + secondary + '\n',
                pair + "  | `- error: cannot convert value of type 'Wrong' to expected argument type 'URL'\n",
                pair + '  | `- error: ' + primary.replace('applicationBundle:', 'unrelated:') + '\n',
            )
            for text in variants:
                with self.subTest(label=label, text=text), self.assertRaises(ValueError):
                    r.validate_negative(text, fixture)


class ReceiptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.output = Path(self.temp.name).resolve()
        self.command = ['/synthetic/swift', 'build', '--target', 'ForbiddenClient']
        common = Path(__file__).absolute().parents[2] / 'Tests/SearchChildIntegration/run_harness.py'
        self.common = r.load(common, 'accepted_synthetic_receipt_parser')
        self.value = receipt(self.command, b'synthetic output\n', b'', 1)
        (self.output / 'stdout.log').write_bytes(b'synthetic output\n')
        (self.output / 'stderr.log').write_bytes(b'')
        self.persist()

    def persist(self):
        (self.output / 'status.json').write_text(json.dumps(self.value))

    def test_expected_nonzero_receipt_is_genuine_and_never_rewritten(self):
        self.assertTrue(self.common.receipt_success(self.output, self.command, expected_code=1))
        self.assertEqual(r.stage_logs(self.output, self.common, self.command, 1), ('synthetic output\n', ''))
        self.assertEqual(json.loads((self.output / 'status.json').read_text())['returnCode'], 1)
        with self.assertRaises(ValueError):
            r.stage_logs(self.output, self.common, self.command, 0)

    def test_wait_capture_timeout_truncation_signal_and_cleanup(self):
        original = copy.deepcopy(self.value)
        mutations = {'waitCompleted': False, 'captureComplete': False, 'timedOut': True,
                     'truncated': True, 'interruptedSignal': 15, 'failure': 'capture',
                     'waitError': 'TimeoutError', 'groupCleanup': 'unconfirmed',
                     'groupSignalAttempted': False, 'returnCode': 0, 'exit': 0,
                     'pid': True, 'processGroup': 732, 'registrationError': errno.EPERM,
                     'exitObserved': False}
        for key, value in mutations.items():
            self.value = copy.deepcopy(original)
            self.value[key] = value
            self.persist()
            with self.subTest(key=key), self.assertRaises(ValueError):
                r.stage_logs(self.output, self.common, self.command, 1)

    def test_command_bytes_capture_counts_and_missing_metadata(self):
        original = copy.deepcopy(self.value)
        for kind in ('command', 'counts', 'missing', 'file'):
            self.value = copy.deepcopy(original)
            if kind == 'command':
                self.value['command'] = ['/unrelated/swift']
            elif kind == 'counts':
                self.value['captured']['stdout']['discarded'] = 1
            elif kind == 'missing':
                del self.value['waitCompleted']
            else:
                (self.output / 'stdout.log').write_bytes(b'altered')
            self.persist()
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                r.stage_logs(self.output, self.common, self.command, 1)

    def test_exited_leader_only_requires_exact_complete_query(self):
        self.value.update(groupCleanup='exitedLeaderOnly', groupSignalError=errno.EPERM,
                          groupQuery=dict(processGroup=731, errorNumber=None, bufferBytes=1024,
                                          returnedBytes=4, members=[731]))
        self.persist()
        r.stage_logs(self.output, self.common, self.command, 1)
        self.value['groupQuery']['members'] = [731, 732]
        self.persist()
        with self.assertRaises(ValueError):
            r.stage_logs(self.output, self.common, self.command, 1)


class ArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.run = Path(self.temp.name).resolve()
        self.bin = self.run / 'Build/Main/arm64-apple-macosx/debug'
        name = 'SearchAdmissionServiceIntegrationPackageTests'
        self.bundle = self.bin / (name + '.xctest')
        self.executable = self.bundle / 'Contents/MacOS' / name
        self.executable.parent.mkdir(parents=True)
        self.executable.write_bytes(b'synthetic unexecutable artifact bytes')
        self.executable.chmod(0o700)
        self.manifest_hash = 'a' * 64
        self.receipt_hash = 'b' * 64
        self.artifact = r.bind_artifact(self.run, str(self.bin) + '\n', self.manifest_hash, self.receipt_hash)

    def test_matching_artifact_source_and_receipt(self):
        r.verify_artifact(self.run, self.artifact, self.manifest_hash, self.receipt_hash)

    def test_wrong_source_receipt_mode_bytes_or_membership(self):
        original = self.executable.read_bytes()
        for kind in ('source', 'receipt', 'mode', 'bytes', 'member'):
            source, receipt_hash = self.manifest_hash, self.receipt_hash
            if kind == 'source':
                source = 'c' * 64
            elif kind == 'receipt':
                receipt_hash = 'c' * 64
            elif kind == 'mode':
                self.executable.chmod(0o600)
            elif kind == 'bytes':
                self.executable.write_bytes(b'different')
            else:
                (self.bundle / 'Unexpected').write_bytes(b'extra')
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                r.verify_artifact(self.run, self.artifact, source, receipt_hash)
            self.executable.write_bytes(original)
            self.executable.chmod(0o700)
            if kind == 'member':
                (self.bundle / 'Unexpected').unlink()

    def test_wrong_binpath_origin_multiline_and_symlink(self):
        for text in ('relative\n', str(self.bin) + '\nextra\n', str(self.run / 'Outside') + '\n'):
            with self.subTest(text=text), self.assertRaises(ValueError):
                r.bind_artifact(self.run, text, self.manifest_hash, self.receipt_hash)
        self.executable.unlink()
        target = self.run / 'same-bytes'
        target.write_bytes(b'synthetic unexecutable artifact bytes')
        target.chmod(0o700)
        self.executable.symlink_to(target)
        with self.assertRaises(ValueError):
            r.bind_artifact(self.run, str(self.bin) + '\n', self.manifest_hash, self.receipt_hash)


class CommandTests(unittest.TestCase):
    def test_fixed_stage_order_positive_before_independent_negatives(self):
        run = Path('/synthetic/run')
        stages = r.stages(run)
        self.assertEqual([s[0] for s in stages], ['pure', 'toolchain', 'allowed', *r.NEGATIVES,
                                                'build-tests', 'bin-path', 'construction'])
        for name, _, command, code in stages:
            if name in r.NEGATIVES:
                self.assertEqual(code, 1)
                self.assertIn(str(run / 'Compiler' / name), command)
                self.assertIn(str(run / 'Build' / name), command)
                self.assertEqual(command[-2:], ['--target', 'ForbiddenClient'])
            elif name == 'construction':
                self.assertEqual(command[-2:], ['--filter', 'SearchAdmissionServiceConstructionTests'])
            self.assertNotIn('--skip-build', command)

    def test_entry_rejects_filter_skip_build_and_mutator_escape(self):
        for arguments in (['--filter', 'One'], ['--skip-build'], ['--mutator', 'anything']):
            with self.subTest(arguments=arguments), self.assertRaises(SystemExit):
                r.main(arguments)


class ExecutionTests(SyntheticInputs):
    def setUp(self):
        super().setUp()
        common = Path(__file__).absolute().parents[2] / 'Tests/SearchChildIntegration/run_harness.py'
        self.common = r.load(common, 'accepted_pipeline_receipt_parser')
        self.calls = []
        self.interfere = None

    def fake_watchdog(self, argv):
        # A pure collaborator, never a subprocess, signal, poll, sleep, or real wait.
        output = Path(argv[argv.index('--output') + 1])
        command = argv[argv.index('--') + 1:]
        output.mkdir(parents=True)
        name = output.name
        self.calls.append(name)
        code, text = 0, 'Build complete!\n'
        if name == 'pure':
            text = pure_log(self.manifest['expectedPure'])
        elif name == 'toolchain':
            text = 'Swift version synthetic fixture\n'
        elif name in r.NEGATIVES:
            code = 1
            fixture = self.run / 'Compiler' / name / 'Sources/ForbiddenClient' / (name + '.swift')
            if name in ('ForbiddenLegacy', 'ForbiddenController', 'ForbiddenDriver'):
                member = {'ForbiddenLegacy': 'shutdown', 'ForbiddenController': 'controller',
                          'ForbiddenDriver': 'driver'}[name]
                message = "value of type 'SearchAdmissionService<String>' has no member '" + member + "'"
            else:
                label = 'driver' if name == 'ForbiddenDriverInitializer' else 'controller'
                message = "incorrect argument label in call (have '" + label + ":', expected 'applicationBundle:')"
            text = str(fixture) + ':4:15: error: ' + message + '\n'
        elif name == 'build-tests':
            self.bin = self.run / 'Build/Main/arm64-apple-macosx/debug'
            artifact_name = 'SearchAdmissionServiceIntegrationPackageTests'
            self.executable = self.bin / (artifact_name + '.xctest') / 'Contents/MacOS' / artifact_name
            self.executable.parent.mkdir(parents=True)
            self.executable.write_bytes(b'synthetic unexecutable pipeline artifact')
            self.executable.chmod(0o700)
        elif name == 'bin-path':
            text = str(self.bin) + '\n'
        elif name == 'construction':
            text = xctest_log(self.manifest['expectedTests'])
        data = text.encode()
        (output / 'stdout.log').write_bytes(data)
        (output / 'stderr.log').write_bytes(b'')
        value = receipt(command, data, b'', code)
        if self.interfere:
            code = self.interfere(name, output, value, code)
        (output / 'status.json').write_text(json.dumps(value))
        return code

    def test_complete_synthetic_pipeline_preserves_original_negative_exit(self):
        self.assertEqual(r.execute(self.run, self.common, self.fake_watchdog), 0)
        self.assertEqual(self.calls, [s[0] for s in r.stages(self.run)])
        for name in r.NEGATIVES:
            value = json.loads((self.run / 'Stages' / name / 'status.json').read_text())
            self.assertEqual(value['exit'], 1)
            self.assertEqual(value['returnCode'], 1)
        status = json.loads((self.run / 'status.json').read_text())
        self.assertEqual(status['constructionTests'], 4)
        self.assertIn('not executed', status['eagerMutation'])

    def test_positive_failure_stops_before_any_negative(self):
        def fail(name, output, value, code):
            if name == 'allowed':
                value['exit'] = value['returnCode'] = 1
                return 1
            return code
        self.interfere = fail
        self.assertEqual(r.execute(self.run, self.common, self.fake_watchdog), 125)
        self.assertEqual(self.calls, ['pure', 'toolchain', 'allowed'])

    def test_falsely_successful_negative_fails_closed(self):
        def fail(name, output, value, code):
            if name == r.NEGATIVES[0]:
                value['exit'] = value['returnCode'] = 0
                return 0
            return code
        self.interfere = fail
        self.assertEqual(r.execute(self.run, self.common, self.fake_watchdog), 125)
        self.assertEqual(self.calls[-1], r.NEGATIVES[0])

    def test_timeout_retains_failure_and_stops_remaining_stages(self):
        def fail(name, output, value, code):
            if name == 'allowed':
                value['timedOut'] = True
                value['exit'] = 124
                value['returnCode'] = -9
                return 124
            return code
        self.interfere = fail
        self.assertEqual(r.execute(self.run, self.common, self.fake_watchdog), 125)
        self.assertEqual(self.calls, ['pure', 'toolchain', 'allowed'])

    def test_source_drift_at_actual_stage_boundary(self):
        def fail(name, output, value, code):
            if name == 'toolchain':
                (self.root / 'scripts/swift.sh').write_bytes(b'changed wrapper')
            return code
        self.interfere = fail
        self.assertEqual(r.execute(self.run, self.common, self.fake_watchdog), 125)
        self.assertEqual(self.calls, ['pure', 'toolchain'])

    def test_accepted_capture_mutation_is_rechecked_after_next_stage(self):
        def fail(name, output, value, code):
            if name == 'toolchain':
                (self.run / 'Stages/pure/stdout.log').write_bytes(b'changed previous capture')
            return code
        self.interfere = fail
        self.assertEqual(r.execute(self.run, self.common, self.fake_watchdog), 125)
        self.assertEqual(self.calls, ['pure', 'toolchain'])

    def test_artifact_mutation_during_test_cannot_be_accepted(self):
        def fail(name, output, value, code):
            if name == 'construction':
                self.executable.write_bytes(b'changed actual executed artifact')
            return code
        self.interfere = fail
        self.assertEqual(r.execute(self.run, self.common, self.fake_watchdog), 125)
        self.assertEqual(self.calls[-1], 'construction')

    def test_sealed_source_manifest_mode_and_bytes(self):
        path = self.run / 'sources.json'
        path.chmod(0o600)
        self.assertEqual(r.execute(self.run, self.common, self.fake_watchdog), 125)
        self.assertEqual(self.calls, [])


if __name__ == '__main__':
    unittest.main()
