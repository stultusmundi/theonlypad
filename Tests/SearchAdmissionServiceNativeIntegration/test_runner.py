"""Synthetic pure controls only; never run Swift, AppKit, helpers or watchdogs."""
from pathlib import Path
import ast
import copy
import errno
import importlib.util
import json
import tempfile
import unittest
from unittest.mock import patch

path = Path(__file__).with_name('run_harness.py')
spec = importlib.util.spec_from_file_location('native_service_runner', path)
r = importlib.util.module_from_spec(spec)
# Direct source bytes, without reading or writing a stale Python cache.
exec(compile(path.read_bytes(), str(path), 'exec'), r.__dict__)


def native_source(methods=None, cls='NativeAdmissionServiceTests'):
    methods = r.METHODS if methods is None else methods
    return ('import XCTest\n@MainActor final class ' + cls + ': XCTestCase {\n'
            + '\n'.join('  func ' + name + '() async throws { XCTAssertTrue(true) }'
                        for name in methods) + '\n}\n').encode()


def native_log(names=None):
    names = r.EXPECTED if names is None else names
    return '\n'.join("Test Case '" + name + "' started.\nTest Case '" + name
                     + "' passed (0.001 seconds)." for name in names) + (
        '\nExecuted ' + str(len(names)) + ' tests, with 0 failures (0 unexpected) in 0.01 seconds\n')


def pure_log(names):
    return '\n'.join(name.rsplit('.', 1)[1] + ' (' + name + ') ... ok' for name in names) + (
        '\nRan ' + str(len(names)) + ' tests in 0.01s\n\nOK\n')


def receipt(command, stdout=b'', stderr=b''):
    return dict(command=command, pid=941, processGroup=941, exitObserved=True,
                registrationError=None, groupSignalAttempted=True, groupSignalError=None,
                groupCleanup='signaled', groupQuery=None, waitCompleted=True, returnCode=0,
                waitError=None, timedOut=False, interruptedSignal=None, truncated=False,
                captureComplete=True, failure=None, exit=0,
                captured={name: dict(received=len(data), stored=len(data), discarded=0)
                          for name, data in [('stdout', stdout), ('stderr', stderr)]})


class NativeSourceTests(unittest.TestCase):
    def test_independent_exact_two_class_method_names(self):
        required = ('testCaptureRefusalThroughFacadePreservesAdmission',
                    'testJoinedFacadeInsideBorrowPreservesResidualCreditUntilRealReturn')
        self.assertEqual(r.METHODS, required)
        self.assertEqual(r.native_tests(native_source()),
                         ['NativeAdmissionServiceTests.' + name for name in required])

    def test_each_missing_duplicate_and_extra_method(self):
        for changed in (r.METHODS[:1], r.METHODS[1:], (*r.METHODS, r.METHODS[0]),
                        (*r.METHODS, 'testExtra')):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                r.native_tests(native_source(changed))

    def test_wrong_duplicate_or_missing_xctest_class(self):
        for source in (native_source(cls='Wrong'), native_source() + native_source(),
                       b'final class NativeAdmissionServiceTests {}'):
            with self.subTest(source=source), self.assertRaises(ValueError):
                r.native_tests(source)

    def test_commented_or_string_named_declarations_cannot_supply_test(self):
        first = r.METHODS[0]
        partial = native_source(r.METHODS[1:])
        variants = (b'/* ' + native_source() + b' */',
                    partial + ('// func ' + first + '() async throws {}\n').encode(),
                    partial + ('let message = "func ' + first + '() async throws {}"\n').encode())
        for source in variants:
            with self.subTest(source=source), self.assertRaises(ValueError):
                r.native_tests(source)

    def test_method_outside_class_and_wrong_signature(self):
        misplaced = native_source(r.METHODS[1:]) + ('func ' + r.METHODS[0]
                     + '() async throws { XCTAssertTrue(true) }\n').encode()
        for source in (misplaced, native_source().replace(b'async throws', b'async', 1),
                       native_source().replace(b'async throws', b'', 1)):
            with self.subTest(source=source), self.assertRaises(ValueError):
                r.native_tests(source)

    def test_empty_or_comment_only_method_is_not_native_coverage(self):
        for body in (b'', b'/* XCTAssertTrue(true) */', b'let text = "XCTAssertTrue(true)"'):
            source = native_source().replace(b'XCTAssertTrue(true)', body, 1)
            with self.subTest(body=body), self.assertRaises(ValueError):
                r.native_tests(source)

    def test_native_conditional_and_skip_spellings(self):
        for suffix in (b'#if DEBUG\n#endif', b'XCTSkip()', b'XCTSkipIf(true)', b'XCTSkipUnless(false)'):
            with self.subTest(suffix=suffix), self.assertRaises(ValueError):
                r.native_tests(native_source() + suffix)

    def test_masker_nested_comments_strings_and_unterminated_source(self):
        source = native_source() + b'/* outer /* inner */ tail */\nlet s = "{ #if XCTSkip() }"\n'
        self.assertEqual(r.native_tests(source), list(r.EXPECTED))
        for bad in (b'/* never ended', b'"never ended', b'"""never ended',
                    native_source()[:-2]):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                r.native_tests(bad)

    def test_public_deployment_floor_and_language_mode(self):
        valid = b'platforms: [.macOS(.v14)], swiftLanguageModes: [.v5]\n'
        r.validate_public_manifest(valid)
        for source in (valid.replace(b'.v14', b'.v26'), valid.replace(b'.v5', b'.v6'),
                       b'// ' + valid, valid + b'platforms: [.macOS(.v26)]'):
            with self.subTest(source=source), self.assertRaises(ValueError):
                r.validate_public_manifest(source)


class NativeLogTests(unittest.TestCase):
    def test_exact_two_named_starts_passes_and_count(self):
        self.assertEqual(r.validate_tests(native_log(), r.EXPECTED), 2)

    def test_objective_c_and_module_qualified_identifiers(self):
        objc = ['-[SearchExecutionTests.' + name.replace('.', ' ') + ']' for name in r.EXPECTED]
        qualified = ['SearchExecutionTests.' + name for name in r.EXPECTED]
        for names in (objc, qualified):
            self.assertEqual(r.validate_tests(native_log(names), r.EXPECTED), 2)

    def test_missing_duplicate_wrong_starts_and_passes(self):
        original = native_log()
        for changed in (native_log(r.EXPECTED[:1]), native_log((*r.EXPECTED, r.EXPECTED[0])),
                        native_log(('Wrong.testName', r.EXPECTED[1])),
                        original.replace("' started.", "' notStarted.", 1),
                        original.replace("' passed (", "' notPassed (", 1)):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                r.validate_tests(changed, r.EXPECTED)

    def test_zero_wrong_counts_failed_and_unexpected_aggregates(self):
        original = native_log()
        for changed in ('Executed 0 tests, with 0 failures\n',
                        original.replace('Executed 2', 'Executed 1'),
                        'Executed 0 tests, with 0 failures\n' + original,
                        original.replace('0 failures', '1 failures'),
                        original.replace('0 unexpected', '1 unexpected')):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                r.validate_tests(changed, r.EXPECTED)

    def test_skips_failure_warning_error_emergency_deadline_and_missing_handle(self):
        original = native_log()
        for changed in (original.replace(' passed (', ' failed (', 1),
                        original.replace(' passed (', ' skipped (', 1),
                        *(original + '\n' + text for text in (
                            'warning: synthetic', 'error: synthetic', 'XCTSkipIf(true)',
                            'native modal loop required emergency release',
                            'deadline release is never an actual native caller return',
                            'actual native fixture event missing',
                            'registered immediate task has no retained handle'))):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                r.validate_tests(changed, r.EXPECTED)

    def test_expected_allowlist_cannot_be_lowered_or_duplicated(self):
        for expected in ([], r.EXPECTED[:1], (*r.EXPECTED, r.EXPECTED[0])):
            with self.subTest(expected=expected), self.assertRaises(ValueError):
                r.validate_tests(native_log(), expected)

    def test_pure_names_counts_zero_duplicate_skip_failure_and_old_format(self):
        expected = ['test_runner.Synthetic.test_one', 'test_runner.Synthetic.test_two']
        self.assertEqual(r.validate_pure(pure_log(expected), expected), 2)
        old = pure_log(expected).replace('Synthetic.test_one)', 'Synthetic)').replace(
            'Synthetic.test_two)', 'Synthetic)')
        self.assertEqual(r.validate_pure(old, expected), 2)
        for text in (pure_log(expected[:1]), pure_log((*expected, expected[0])),
                     pure_log(expected).replace('Ran 2', 'Ran 0'),
                     pure_log(expected).replace('... ok', '... skipped'),
                     pure_log(expected) + '\nFAIL\n'):
            with self.subTest(text=text), self.assertRaises(ValueError):
                r.validate_pure(text, expected)

    def test_pure_source_names_are_unique_positive_undecorated(self):
        self.assertEqual(r.pure_names(b'class X:\n def test_one(self): pass\n'), ['test_runner.X.test_one'])
        for source in (b'x=1\n', b'class X:\n @skip\n def test_one(self): pass\n',
                       b'class X:\n def test_one(self): pass\n def test_one(self): pass\n'):
            with self.subTest(source=source), self.assertRaises(ValueError):
                r.pure_names(source)


class HostTests(unittest.TestCase):
    def test_supported_host_versions(self):
        for version in ('26', '26.0', '26.6.2', '27.1'):
            self.assertEqual(r.ensure_supported_host('Darwin', version), dict(system='Darwin', version=version))

    def test_old_nonmac_invalid_or_boolean_host_refused_without_skip(self):
        for system, version in (('Darwin', '25.9'), ('Darwin', '14.0'), ('Linux', '26.0'),
                                ('Darwin', ''), ('Darwin', '26.beta'), ('Darwin', '26.1.2.3'),
                                ('Darwin', True), (True, '26.0')):
            with self.subTest(system=system, version=version), self.assertRaises(ValueError):
                r.ensure_supported_host(system, version)


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
        self.write('Sources/SearchExecution/Deep/Actual.swift', '// synthetic recursive execution\n')
        self.write(r.NATIVE, native_source().decode())
        self.write('Package.swift', 'platforms: [.macOS(.v14)], swiftLanguageModes: [.v5]\n')
        self.write(r.PURE, 'class Synthetic:\n def test_one(self): pass\n')
        self.write(r.SHELL, r.ENTRYPOINT).chmod(0o755)
        self.manifest = r.freeze(self.root, self.run)

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        path.chmod(0o600)
        return path


class FreezeTests(SyntheticInputs):
    def test_independent_required_four_harnesses_compiled_and_no_old_tests(self):
        required = (
            'Tests/SearchExecutionTests/SearchAdmissionServiceTestHarness.swift',
            'Tests/SearchExecutionTests/SearchAdmissionTestHarness.swift',
            'Tests/SearchExecutionTests/SearchAdmissionJoinedTestHarness.swift',
            'Tests/SearchExecutionTests/SearchParentWireDriverTestHarness.swift',
        )
        self.assertEqual(r.HARNESSES, required)
        origins = {item['source']: item for item in self.manifest['sources']}
        for name in required:
            item = origins[name]
            self.assertEqual(item['role'], 'compiledTests')
            self.assertEqual(item['frozen'], 'Package/Tests/SearchExecutionTests/' + Path(name).name)
            self.assertEqual(r.read_file(self.run / item['frozen']), r.read_file(self.root / name))
        compiled = [item['source'] for item in self.manifest['sources'] if item['role'] == 'compiledTests']
        self.assertEqual(set(compiled), {*required, 'Tests/SearchAdmissionServiceNativeIntegration/NativeAdmissionServiceTests.swift'})
        self.assertEqual(len(compiled), 5)
        self.assertNotIn('Tests/SearchExecutionTests/SearchAdmissionServiceTests.swift', origins)
        self.assertFalse(any('JoinedNativeIntegration' in name for name in origins))

    def test_missing_each_harness_or_native_source_refused(self):
        for name in (*r.HARNESSES, r.NATIVE):
            path = self.root / name
            data, mode = r.read_file(path)
            try:
                path.unlink()
                with self.subTest(name=name), self.assertRaises(ValueError):
                    r.verify(self.run, self.manifest)
            finally:
                path.write_bytes(data)
                path.chmod(mode)

    def test_recursive_production_and_explicit_public_manifest_provenance(self):
        origins = {item['source']: item for item in self.manifest['sources']}
        self.assertEqual(origins['Sources/SearchExecution/Deep/Actual.swift']['role'], 'compiledProduction')
        self.assertEqual(origins['Package.swift']['role'], 'publicManifestProvenance')
        self.assertEqual(origins['scripts/swift.sh']['role'], 'runnerOnly')
        text = (self.run / 'Package/Package.swift').read_text()
        self.assertIn('.macOS(.v26)', text)
        self.assertIn('swiftLanguageModes: [.v5]', text)
        self.assertNotIn('.executableTarget', text)
        self.assertEqual(self.manifest['nativeHostMinimum'], 26)
        self.assertEqual(self.manifest['publicDeploymentFloor'], 14)
        self.assertEqual(r.read_file(self.run / 'Runner/scripts/swift.sh'), r.read_file(self.root / 'scripts/swift.sh'))

    def test_origin_and_frozen_byte_or_mode_changes_refused_with_safe_restore(self):
        for path in (self.root / 'Sources/PadCore/Core.swift', self.run / 'Package/Sources/PadCore/Core.swift'):
            data, mode = r.read_file(path)
            for change in ('bytes', 'mode'):
                try:
                    if change == 'bytes':
                        path.write_bytes(data + b'changed')
                    else:
                        path.chmod(0o400)
                    with self.subTest(path=path, change=change), self.assertRaises(ValueError):
                        r.verify(self.run, self.manifest)
                finally:
                    path.chmod(mode)
                    path.write_bytes(data)

    def test_wrapper_common_watchdog_shell_and_native_changes_refused(self):
        for name in ('scripts/swift.sh', r.COMMON, r.WATCHDOG, r.SHELL, r.NATIVE):
            path = self.root / name
            data, mode = r.read_file(path)
            try:
                path.write_bytes(data + b'// changed\n')
                with self.subTest(name=name), self.assertRaises(ValueError):
                    r.verify(self.run, self.manifest)
            finally:
                path.chmod(mode)
                path.write_bytes(data)

    def test_generated_manifest_derivation_mode_and_metadata_cannot_change(self):
        path = self.run / 'Package/Package.swift'
        data, mode = r.read_file(path)
        for change in ('bytes', 'mode'):
            try:
                path.chmod(0o600)
                if change == 'bytes':
                    path.write_bytes(data.replace(b'.v26', b'.v14'))
                    path.chmod(mode)
                altered = copy.deepcopy(self.manifest)
                altered['generated'][0]['sha256'] = r.digest(path.read_bytes())
                with self.subTest(change=change), self.assertRaises(ValueError):
                    r.verify(self.run, altered)
            finally:
                path.chmod(0o600)
                path.write_bytes(data)
                path.chmod(mode)

    def test_origin_and_frozen_membership_extra_source_manifest_or_cache(self):
        names = ('Package/Sources/PadCore/Extra.swift', 'Package/Package@swift-6.swift',
                 'Runner/Tests/SearchChildIntegration/__pycache__/unbound.pyc')
        for name in names:
            path = self.run / name
            path.parent.mkdir(parents=True, exist_ok=True)
            try:
                path.write_bytes(b'additional synthetic input')
                with self.subTest(name=name), self.assertRaises(ValueError):
                    r.verify(self.run, self.manifest)
            finally:
                path.unlink()
                if path.parent.name == '__pycache__':
                    path.parent.rmdir()
        path = self.write('Sources/PadCore/Added.swift', '// extra origin')
        try:
            with self.assertRaises(ValueError):
                r.verify(self.run, self.manifest)
        finally:
            path.unlink()

    def test_manifest_schema_roles_paths_counts_host_and_exemptions(self):
        mutations = (
            lambda m: m.update(nativeHostMinimum=14), lambda m: m.update(publicDeploymentFloor=26),
            lambda m: m.update(expectedTests=[]), lambda m: m.update(expectedPure=[]),
            lambda m: m.update(exempt=['Package']), lambda m: m.update(version=True),
            lambda m: m.update(unknown='field'), lambda m: m['sources'].pop(),
            lambda m: m['sources'][0].update(role='runnerOnly'),
            lambda m: m['sources'][0].update(origin='/wrong/origin'),
            lambda m: m['sources'][0].update(frozen='Build/adopted.swift'),
        )
        for mutation in mutations:
            changed = copy.deepcopy(self.manifest)
            mutation(changed)
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                r.verify(self.run, changed)

    def test_source_root_file_directory_and_frozen_symlinks(self):
        for base in (self.root, self.run):
            alias = base.parent / (base.name + '-alias')
            alias.symlink_to(base, target_is_directory=True)
            try:
                with self.subTest(alias=alias), self.assertRaises(ValueError):
                    r.real_path(alias, alias)
            finally:
                alias.unlink()
        path = self.run / 'Package/Sources/PadCore/Core.swift'
        data, mode = r.read_file(path)
        try:
            path.unlink()
            path.symlink_to(self.root / 'Sources/PadCore/Core.swift')
            with self.assertRaises(ValueError):
                r.verify(self.run, self.manifest)
        finally:
            path.unlink()
            path.write_bytes(data)
            path.chmod(mode)
        linked = self.root / 'Sources/SearchExecution/Linked'
        linked.symlink_to(self.root / 'Sources/PadCore', target_is_directory=True)
        with self.assertRaises(ValueError):
            r.discover(self.root)

    def test_generated_cache_exemption_rejects_symlink_root(self):
        cache = self.run / 'Runner/.cache'
        cache.mkdir()
        (cache / 'generated').write_bytes(b'generated cache')
        r.verify(self.run, self.manifest)
        cache.rename(self.run / 'Runner/old-cache')
        cache.symlink_to(self.run / 'Runner/old-cache', target_is_directory=True)
        with self.assertRaises(ValueError):
            r.verify(self.run, self.manifest)

    def test_generated_build_root_symlink_refused(self):
        outside = self.run.parent / 'outside-build'
        outside.mkdir()
        (self.run / 'Build').symlink_to(outside, target_is_directory=True)
        with self.assertRaises(ValueError):
            r.verify(self.run, self.manifest)

    def test_exact_shell_bytes_and_mode_are_contract(self):
        path = self.run / ('Runner/' + r.SHELL)
        data, mode = r.read_file(path)
        path.chmod(0o600)
        with self.assertRaises(ValueError):
            r.verify(self.run, self.manifest)
        path.chmod(mode)
        path.write_bytes(data.replace(b'python3 -B', b'python3'))
        with self.assertRaises(ValueError):
            r.verify(self.run, self.manifest)

    def test_loader_ignores_unbound_cache_and_refuses_symlink(self):
        path = self.root / 'synthetic.py'
        path.write_bytes(b'value = 2\n')
        cache = self.root / '__pycache__'
        cache.mkdir()
        (cache / 'synthetic.cpython-313.pyc').write_bytes(b'unbound synthetic bytecode')
        self.assertEqual(r.load(path, 'synthetic_native_loader').value, 2)
        alias = self.root / 'linked.py'
        alias.symlink_to(path)
        with self.assertRaises(ValueError):
            r.load(alias, 'linked_native_loader')


class ReceiptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.output = Path(self.temp.name).resolve()
        self.command = ['/synthetic/swift', 'test', '--filter', 'NativeAdmissionServiceTests']
        common = Path(__file__).absolute().parents[2] / 'Tests/SearchChildIntegration/run_harness.py'
        self.common = r.load(common, 'native_pure_accepted_receipt_parser')
        self.value = receipt(self.command, b'synthetic output\n')
        (self.output / 'stdout.log').write_bytes(b'synthetic output\n')
        (self.output / 'stderr.log').write_bytes(b'')
        self.persist()

    def persist(self):
        (self.output / 'status.json').write_text(json.dumps(self.value))

    def test_complete_exact_expected_zero_receipt(self):
        self.assertEqual(r.stage_logs(self.output, self.common, self.command), ('synthetic output\n', ''))

    def test_wait_capture_timeout_truncation_and_return_errors(self):
        original = copy.deepcopy(self.value)
        changes = dict(waitCompleted=False, captureComplete=False, timedOut=True, truncated=True,
                       waitError='TimeoutError', interruptedSignal=15, failure='capture',
                       returnCode=1, exit=1, groupSignalAttempted=False, groupCleanup='unconfirmed',
                       pid=True, processGroup=942, registrationError=errno.EPERM, exitObserved=False)
        for key, value in changes.items():
            self.value = copy.deepcopy(original)
            self.value[key] = value
            self.persist()
            with self.subTest(key=key), self.assertRaises(ValueError):
                r.stage_logs(self.output, self.common, self.command)

    def test_wrong_command_counts_stream_size_and_missing_receipt_field(self):
        original = copy.deepcopy(self.value)
        for kind in ('command', 'counts', 'missing', 'file'):
            self.value = copy.deepcopy(original)
            if kind == 'command':
                self.value['command'] = ['/wrong/compiler']
            elif kind == 'counts':
                self.value['captured']['stdout']['discarded'] = 1
            elif kind == 'missing':
                del self.value['waitCompleted']
            else:
                (self.output / 'stdout.log').write_bytes(b'changed')
            self.persist()
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                r.stage_logs(self.output, self.common, self.command)

    def test_exact_exited_leader_only_query_or_esrch_cleanup(self):
        self.value.update(groupCleanup='exitedLeaderOnly', groupSignalError=errno.EPERM,
                          groupQuery=dict(processGroup=941, errorNumber=None, bufferBytes=1024,
                                          returnedBytes=4, members=[941]))
        self.persist()
        r.stage_logs(self.output, self.common, self.command)
        self.value['groupQuery']['members'] = [941, 942]
        self.persist()
        with self.assertRaises(ValueError):
            r.stage_logs(self.output, self.common, self.command)
        self.value.update(groupCleanup='absent', groupSignalError=errno.ESRCH, groupQuery=None)
        self.persist()
        r.stage_logs(self.output, self.common, self.command)


class ArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.run = Path(self.temp.name).resolve()
        self.bin = self.run / 'Build/arm64-apple-macosx/debug'
        name = 'SearchAdmissionServiceNativeIntegrationPackageTests'
        self.bundle = self.bin / (name + '.xctest')
        self.executable = self.bundle / 'Contents/MacOS' / name
        self.executable.parent.mkdir(parents=True)
        self.executable.write_bytes(b'synthetic unexecutable native artifact')
        self.executable.chmod(0o700)
        self.source_hash, self.receipt_hash = 'a' * 64, 'b' * 64
        self.artifact = r.bind_artifact(self.run, str(self.bin) + '\n', self.source_hash, self.receipt_hash)

    def test_complete_source_build_and_artifact_binding(self):
        r.verify_artifact(self.run, self.artifact, self.source_hash, self.receipt_hash)

    def test_wrong_source_receipt_bytes_mode_and_membership(self):
        data = self.executable.read_bytes()
        for kind in ('source', 'receipt', 'bytes', 'mode', 'member'):
            source_hash, receipt_hash = self.source_hash, self.receipt_hash
            try:
                if kind == 'source':
                    source_hash = 'c' * 64
                elif kind == 'receipt':
                    receipt_hash = 'c' * 64
                elif kind == 'bytes':
                    self.executable.write_bytes(b'changed')
                elif kind == 'mode':
                    self.executable.chmod(0o600)
                else:
                    (self.bundle / 'Extra').write_bytes(b'extra member')
                with self.subTest(kind=kind), self.assertRaises(ValueError):
                    r.verify_artifact(self.run, self.artifact, source_hash, receipt_hash)
            finally:
                self.executable.chmod(0o700)
                self.executable.write_bytes(data)
                if kind == 'member':
                    (self.bundle / 'Extra').unlink()

    def test_binpath_origin_multiline_noncanonical_and_symlink(self):
        for text in ('relative\n', str(self.bin) + '\nextra\n', str(self.run / 'Outside') + '\n',
                     str(self.bin / '../debug') + '\n'):
            with self.subTest(text=text), self.assertRaises(ValueError):
                r.bind_artifact(self.run, text, self.source_hash, self.receipt_hash)
        data = self.executable.read_bytes()
        target = self.run / 'same-bytes'
        target.write_bytes(data)
        target.chmod(0o700)
        self.executable.unlink()
        self.executable.symlink_to(target)
        with self.assertRaises(ValueError):
            r.bind_artifact(self.run, str(self.bin) + '\n', self.source_hash, self.receipt_hash)


class CommandTests(unittest.TestCase):
    def test_complete_fixed_stages_only_and_exact_native_filter(self):
        run = Path('/synthetic/run')
        stages = r.stages(run)
        self.assertEqual([stage[0] for stage in stages], ['pure', 'toolchain', 'build-tests', 'bin-path', 'native2'])
        self.assertEqual(stages[-1][2][-2:], ['--filter', 'NativeAdmissionServiceTests'])
        self.assertEqual(stages[0][2][1], '-B')
        for name, _, command in stages:
            self.assertNotIn('--skip-build', command)
            if name in ('build-tests', 'bin-path', 'native2'):
                self.assertEqual(command[0], str(run / 'Runner/scripts/swift.sh'))
                self.assertIn(str(run / 'Package'), command)
                self.assertIn(str(run / 'Build'), command)

    def test_entry_rejects_filter_skip_build_mutator_and_nested_supervisor(self):
        for arguments in (['--filter', 'One'], ['--skip-build'], ['--mutator', 'Anything'],
                          ['--timeout', '1'], ['--', 'swift']):
            with self.subTest(arguments=arguments), self.assertRaises(SystemExit):
                r.main(arguments)

    def test_private_draft_location_cannot_run_as_canonical_entry(self):
        with patch.object(r, '__file__', '/synthetic/private/run_harness.py'), self.assertRaises(ValueError):
            r.main([])


class ExecutionTests(SyntheticInputs):
    def setUp(self):
        super().setUp()
        common = Path(__file__).absolute().parents[2] / 'Tests/SearchChildIntegration/run_harness.py'
        self.common = r.load(common, 'native_pipeline_accepted_receipt_parser')
        self.calls, self.interfere = [], None
        self.host = dict(system='Darwin', version='26.0')

    def fake_watchdog(self, argv):
        # Pure collaborator: no subprocess, AppKit, signals, polling or real wait.
        output = Path(argv[argv.index('--output') + 1])
        command = argv[argv.index('--') + 1:]
        output.mkdir(parents=True)
        name = output.name
        self.calls.append(name)
        text, code = 'Build complete!\n', 0
        if name == 'pure':
            text = pure_log(self.manifest['expectedPure'])
        elif name == 'toolchain':
            text = 'Swift version synthetic fixture\n'
        elif name == 'build-tests':
            self.bin = self.run / 'Build/arm64-apple-macosx/debug'
            artifact_name = 'SearchAdmissionServiceNativeIntegrationPackageTests'
            self.executable = self.bin / (artifact_name + '.xctest') / 'Contents/MacOS' / artifact_name
            self.executable.parent.mkdir(parents=True)
            self.executable.write_bytes(b'synthetic unexecutable pipeline artifact')
            self.executable.chmod(0o700)
        elif name == 'bin-path':
            text = str(self.bin) + '\n'
        elif name == 'native2':
            text = native_log()
        data = text.encode()
        (output / 'stdout.log').write_bytes(data)
        (output / 'stderr.log').write_bytes(b'')
        value = receipt(command, data)
        if self.interfere:
            code = self.interfere(name, output, value)
        (output / 'status.json').write_text(json.dumps(value))
        return code

    def execute(self):
        with patch.object(r, 'ensure_supported_host', side_effect=lambda: copy.deepcopy(self.host)):
            return r.execute(self.run, self.common, self.fake_watchdog)

    def test_complete_synthetic_pipeline_requires_exact_native2(self):
        self.assertEqual(self.execute(), 0)
        self.assertEqual(self.calls, ['pure', 'toolchain', 'build-tests', 'bin-path', 'native2'])
        status = json.loads((self.run / 'status.json').read_text())
        self.assertEqual(status['nativeTests'], 2)
        self.assertFalse(status['searchHelperExecutionStageIncluded'])
        self.assertFalse(status['shownWindowStageIncluded'])

    def test_unsupported_host_fails_before_any_stage_without_skip(self):
        with patch.object(r, 'ensure_supported_host', side_effect=ValueError('unsupported synthetic host')):
            self.assertEqual(r.execute(self.run, self.common, self.fake_watchdog), 125)
        self.assertEqual(self.calls, [])

    def test_toolchain_failure_or_timeout_cannot_reach_native(self):
        def fail(name, output, value):
            if name == 'toolchain':
                value.update(exit=124, returnCode=-9, timedOut=True)
                return 124
            return 0
        self.interfere = fail
        self.assertEqual(self.execute(), 125)
        self.assertEqual(self.calls, ['pure', 'toolchain'])

    def test_source_drift_at_stage_boundary(self):
        def fail(name, output, value):
            if name == 'toolchain':
                (self.root / 'scripts/swift.sh').write_bytes(b'changed wrapper')
            return 0
        self.interfere = fail
        self.assertEqual(self.execute(), 125)
        self.assertEqual(self.calls, ['pure', 'toolchain'])

    def test_sealed_manifest_bytes_drift_at_stage_boundary(self):
        def fail(name, output, value):
            if name == 'toolchain':
                path = self.run / 'sources.json'
                path.chmod(0o600)
                path.write_bytes(path.read_bytes() + b'\n')
                path.chmod(0o400)
            return 0
        self.interfere = fail
        self.assertEqual(self.execute(), 125)
        self.assertEqual(self.calls, ['pure', 'toolchain'])

    def test_host_binding_change_during_stage_refused(self):
        def fail(name, output, value):
            if name == 'toolchain':
                self.host['version'] = '27.0'
            return 0
        self.interfere = fail
        self.assertEqual(self.execute(), 125)
        self.assertEqual(self.calls, ['pure', 'toolchain'])

    def test_accepted_receipt_capture_metadata_rechecked_at_next_stage(self):
        def fail(name, output, value):
            if name == 'toolchain':
                (self.run / 'Stages/pure/stdout.log').write_bytes(b'changed previous output')
            return 0
        self.interfere = fail
        self.assertEqual(self.execute(), 125)
        self.assertEqual(self.calls, ['pure', 'toolchain'])

    def test_native_artifact_changed_during_execution_rejected(self):
        def fail(name, output, value):
            if name == 'native2':
                self.executable.write_bytes(b'changed actual artifact')
            return 0
        self.interfere = fail
        self.assertEqual(self.execute(), 125)
        self.assertEqual(self.calls[-1], 'native2')

    def test_sealed_manifest_mode_refused_before_first_stage(self):
        (self.run / 'sources.json').chmod(0o600)
        self.assertEqual(self.execute(), 125)
        self.assertEqual(self.calls, [])


if __name__ == '__main__':
    unittest.main()
