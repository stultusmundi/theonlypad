"""Pure temporary archive/receipt controls; never run Swift, AppKit or watchdogs."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import py_compile
import tempfile
import unittest
from unittest.mock import patch

path = Path(__file__).with_name('run_harness.py')
spec = importlib.util.spec_from_file_location('joined_native_runner', path)
r = importlib.util.module_from_spec(spec)
# Bind the actual source bytes, not timestamp-valid stale bytecode.
exec(compile(path.read_bytes(), str(path), 'exec'), r.__dict__)


def native_source(relative, methods=None, cls=None):
    required_cls, required_methods = r.NATIVE_CASES[relative]
    return ('import XCTest\n@MainActor final class ' + (cls or required_cls) + ': XCTestCase {\n'
            + '\n'.join('  func ' + name + '() async {}'
                        for name in (required_methods if methods is None else methods)) + '\n}\n')


def execution_log(names=None):
    names = r.EXPECTED_TESTS if names is None else names
    return ('\n'.join("Test Case '" + name + "' started.\nTest Case '" + name
                      + "' passed (0.001 seconds)." for name in names)
            + '\nExecuted ' + str(len(names)) + ' tests, with 0 failures (0 unexpected)\n')


class NamedTests(unittest.TestCase):
    def test_exact_two_classes_and_ten_methods(self):
        names = []
        for relative in r.NATIVE_CASES:
            names.extend(r.native_tests(native_source(relative), relative))
        self.assertEqual(tuple(names), r.EXPECTED_TESTS)
        self.assertEqual(r.validate_tests(execution_log(), names), 10)

    def test_missing_each_required_method_refused(self):
        for relative, (_, methods) in r.NATIVE_CASES.items():
            for absent in methods:
                with self.subTest(absent=absent), self.assertRaises(ValueError):
                    r.native_tests(native_source(relative, [name for name in methods if name != absent]), relative)

    def test_duplicate_extra_or_wrong_class_refused(self):
        for relative, (_, methods) in r.NATIVE_CASES.items():
            variants = [native_source(relative, list(methods) + [methods[0]]),
                        native_source(relative, list(methods) + ['testUnapproved']),
                        native_source(relative, cls='UnrelatedTests')]
            for text in variants:
                with self.subTest(relative=relative, text=text), self.assertRaises(ValueError):
                    r.native_tests(text, relative)

    def test_comment_cannot_supply_class_or_required_method(self):
        relative = next(iter(r.NATIVE_CASES))
        cls, methods = r.NATIVE_CASES[relative]
        variants = ['/* ' + native_source(relative) + ' */',
                    native_source(relative, list(methods)[1:]) + '\n// func ' + methods[0] + '() {}',
                    native_source(relative).replace('final class ' + cls, 'final class Other')
                    + '\n// final class ' + cls + ': XCTestCase {}']
        for text in variants:
            with self.subTest(text=text), self.assertRaises(ValueError):
                r.native_tests(text, relative)

    def test_method_outside_required_class_refused(self):
        relative = next(iter(r.NATIVE_CASES))
        _, methods = r.NATIVE_CASES[relative]
        text = native_source(relative, list(methods)[1:]) + '\nfunc ' + methods[0] + '() {}'
        with self.assertRaises(ValueError):
            r.native_tests(text, relative)

    def test_conditional_and_all_skip_spellings_refused(self):
        relative = next(iter(r.NATIVE_CASES))
        for suffix in ['\n#if DEBUG\n#endif', '\nXCTSkip()', '\nXCTSkipIf(true)', '\nXCTSkipUnless(false)']:
            with self.subTest(suffix=suffix), self.assertRaises(ValueError):
                r.native_tests(native_source(relative) + suffix, relative)

    def test_unapproved_module_and_changed_expected_allowlist_refused(self):
        with self.assertRaises(ValueError):
            r.native_tests('final class Fake {}', 'Tests/Unapproved.swift')
        for expected in [[], list(r.EXPECTED_TESTS)[:-1], list(r.EXPECTED_TESTS) + [r.EXPECTED_TESTS[0]]]:
            with self.subTest(expected=expected), self.assertRaises(ValueError):
                r.validate_tests(execution_log(), expected)

    def test_missing_duplicate_or_wrong_execution_refused(self):
        names = list(r.EXPECTED_TESTS)
        variants = [execution_log(names[:-1]), execution_log(names + [names[0]]),
                    execution_log(['Other.testWrong'] + names[1:]),
                    execution_log().replace("' started.", "' notStarted.", 1),
                    execution_log().replace("' passed (", "' notPassed (", 1)]
        for text in variants:
            with self.subTest(text=text), self.assertRaises(ValueError):
                r.validate_tests(text, names)

    def test_skipped_failed_errors_zero_and_false_counts_refused(self):
        variants = [execution_log().replace(' passed (', ' skipped (', 1),
                    execution_log().replace(' passed (', ' failed (', 1),
                    execution_log() + '\n1 skipped\n', execution_log() + '\nerror: assertion failed',
                    'Executed 0 tests, with 0 failures (0 unexpected)',
                    execution_log().replace('with 0 failures', 'with 1 failures'),
                    execution_log().replace('(0 unexpected)', '(1 unexpected)'),
                    execution_log().replace('Executed 10 tests', 'Executed 9 tests'),
                    'Executed 0 tests, with 0 failures\n' + execution_log()]
        for text in variants:
            with self.subTest(text=text), self.assertRaises(ValueError):
                r.validate_tests(text, r.EXPECTED_TESTS)

    def test_objc_and_module_qualified_real_identifiers(self):
        objc = ['-[SearchExecutionTests.' + name.replace('.', ' ') + ']' for name in r.EXPECTED_TESTS]
        qualified = ['SearchExecutionTests.' + name for name in r.EXPECTED_TESTS]
        for names in [objc, qualified]:
            self.assertEqual(r.validate_tests(execution_log(names), r.EXPECTED_TESTS), 10)

    def test_loader_ignores_stale_timestamp_bytecode(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / 'tiny.py'
            source.write_text('value = 1\n')
            before = source.stat()
            py_compile.compile(str(source), doraise=True)
            source.write_text('value = 2\n')
            os.utime(source, ns=(before.st_atime_ns, before.st_mtime_ns))
            self.assertEqual(r.load(source, 'bound_source').value, 2)

    def test_loader_refuses_symlink(self):
        with tempfile.TemporaryDirectory() as folder:
            actual = Path(folder) / 'actual.py'
            actual.write_text('value = 1\n')
            linked = Path(folder) / 'linked.py'
            linked.symlink_to(actual)
            with self.assertRaises(OSError):
                r.load(linked, 'linked_source')

    def test_arguments_cannot_filter_build_only_or_nest_supervision(self):
        for argv in [['--filter', 'one'], ['--build-only'], ['--timeout', '1'], ['--', 'swift']]:
            with self.subTest(argv=argv), self.assertRaises(SystemExit):
                r.main(argv)


class HostAndManifestTests(unittest.TestCase):
    def test_native_host_26_or_newer_explicitly_accepted(self):
        for version in ['26', '26.0', '26.6.2', '27.0']:
            self.assertEqual(r.ensure_supported_host('Darwin', version)['version'], version)

    def test_older_or_nonmac_host_refused_without_skip(self):
        for system, version in [('Darwin', '14.0'), ('Darwin', '25.9.9'),
                                ('Linux', '26.0'), ('Darwin', ''), ('Darwin', 'invalid')]:
            with self.subTest(system=system, version=version), self.assertRaisesRegex(ValueError, 'macOS26'):
                r.ensure_supported_host(system, version)

    def test_main_old_host_refuses_before_any_toolchain_or_freeze(self):
        with patch.object(r, 'ensure_supported_host', side_effect=ValueError('macOS26 required')):
            with patch.object(r, 'freeze') as freeze, patch.object(r, 'load') as load:
                with self.assertRaisesRegex(ValueError, 'macOS26'):
                    r.main([])
                freeze.assert_not_called()
                load.assert_not_called()

    def test_public_floor_and_language_are_independent_of_native_floor(self):
        public = b'let package = Package(platforms: [.macOS(.v14)], swiftLanguageModes: [.v5])\n'
        r.validate_public_manifest(public)
        self.assertIn('swift-tools-version: 6.2', r.PACKAGE)
        self.assertIn('platforms: [.macOS(.v26)]', r.PACKAGE)
        self.assertIn('swiftLanguageModes: [.v5]', r.PACKAGE)
        self.assertNotIn('executableTarget', r.PACKAGE)
        self.assertNotIn('.v26', public.decode())

    def test_changed_public_floor_or_language_refused(self):
        public = 'let package = Package(platforms: [.macOS(.v14)], swiftLanguageModes: [.v5])\n'
        for text in [public.replace('.v14', '.v26'), public.replace('.v5', '.v6'),
                     '// ' + public, public.replace('.v14', '.v15')]:
            with self.subTest(text=text), self.assertRaises(ValueError):
                r.validate_public_manifest(text.encode())


class ArchiveFixture(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve() / 'archive'
        self.root.mkdir()
        self.run = self.root.parent / 'run'
        self.run.mkdir()
        repo = next(parent for parent in Path(__file__).absolute().parents
                    if (parent / r.COMMON).is_file())
        self.common = r.load(repo / r.COMMON, 'synthetic_archive_common')
        for relative in r.FIXED:
            self.write(relative, b'// synthetic declared input\n')
        self.write(r.COMMON, (repo / r.COMMON).read_bytes())
        self.write(r.RUNNER, path.read_bytes())
        self.write(r.PURE_TESTS, Path(__file__).read_bytes())
        self.write(r.SHELL, r.ENTRYPOINT.encode(), 0o755)
        self.write('scripts/swift.sh', b'#!/bin/sh\nexit 0\n', 0o755)
        self.write('Package.swift', b'let package = Package(platforms: [.macOS(.v14)], swiftLanguageModes: [.v5])\n')
        self.write('Sources/PadCore/Example.swift', b'// synthetic core\n')
        self.write('Sources/SearchExecution/Nested/Example.swift', b'// synthetic nested execution\n')
        for relative in r.NATIVE_CASES:
            self.write(relative, native_source(relative).encode())
        self.host = patch.object(r, 'ensure_supported_host', return_value=dict(system='Darwin', version='26.0'))
        self.host.start()
        self.addCleanup(self.host.stop)
        self.calls = []
        self.receipt_mutations = {}
        self.stage_codes = {}
        self.after_stage = None
        self.stdout_override = None
        self.stderr_override = None

    def write(self, relative, data, mode=0o644):
        target = self.root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        target.chmod(mode)

    def freeze(self):
        return r.freeze(self.root, self.run, self.common)

    def watchdog(self, argv):
        # Pure synthetic substitute. It never imports or invokes watchdog.main.
        output = Path(argv[argv.index('--output') + 1])
        output.mkdir()
        command = argv[argv.index('--') + 1:]
        self.calls.append((output.name, command, argv))
        code = self.stage_codes.get(output.name, 0)
        stdout = execution_log() if output.name == 'test' else 'synthetic Swift version\n'
        if output.name == 'test' and self.stdout_override is not None:
            stdout = self.stdout_override
        stderr = self.stderr_override or ''
        (output / 'stdout.log').write_text(stdout)
        (output / 'stderr.log').write_text(stderr)
        receipt = dict(command=command, pid=123, processGroup=123, exitObserved=True,
                       registrationError=None, groupSignalAttempted=True, groupSignalError=None,
                       groupCleanup='signaled', groupQuery=None, waitCompleted=True,
                       returnCode=code, waitError=None, timedOut=False, interruptedSignal=None,
                       truncated=False, captureComplete=True, failure=None, exit=code,
                       captured={stream: dict(stored=len(text.encode()), received=len(text.encode()), discarded=0)
                                 for stream, text in [('stdout', stdout), ('stderr', stderr)]})
        receipt.update(self.receipt_mutations)
        (output / 'status.json').write_text(json.dumps(receipt))
        if self.after_stage:
            self.after_stage(output.name)
        return code

    def execute(self):
        return r.execute(self.root, self.run, self.common, self.watchdog)


class FreezeTests(ArchiveFixture):
    def test_gitless_archive_exact_recursive_sources_modes_and_origins(self):
        original_public = (self.root / 'Package.swift').read_bytes()
        manifest = self.freeze()
        self.assertFalse((self.root / '.git').exists())
        self.assertEqual(manifest['expectedTests'], list(r.EXPECTED_TESTS))
        self.assertEqual(manifest['nativeHostMinimum'], 26)
        self.assertEqual(manifest['publicDeploymentFloor'], 14)
        self.assertEqual((self.root / 'Package.swift').read_bytes(), original_public)
        for item in manifest['sources']:
            origin, frozen = self.root / item['source'], self.run / item['frozen']
            self.assertEqual(origin.read_bytes(), frozen.read_bytes())
            self.assertEqual(item['sha256'], item['originSHA256'])
            self.assertEqual(origin.stat().st_mode & 0o777, item['originMode'])
            self.assertEqual(frozen.stat().st_mode & 0o777, item['mode'])
        self.assertTrue((self.run / 'Package/Sources/SearchExecution/Nested/Example.swift').is_file())
        self.assertEqual((self.run / 'Package/Package.swift').read_text(), r.PACKAGE)
        r.verify(self.root, self.run, manifest, self.common)

    def test_only_declared_harnesses_and_ten_native_methods_compile(self):
        manifest = self.freeze()
        compiled = [item['source'] for item in manifest['sources'] if item['frozen'].startswith('Package/Tests/')]
        self.assertEqual(set(compiled), set(r.HARNESSES) | set(r.NATIVE_CASES))
        provenance = next(item for item in manifest['sources'] if item['source'] == r.PROVENANCE)
        self.assertEqual(provenance['frozen'], 'Runner/' + r.PROVENANCE)
        self.assertFalse(any('NativeBorrowBoundaryTests' in value for value in compiled))

    def test_missing_required_source_and_native_method_refused(self):
        for relative in [r.HARNESSES[0], next(iter(r.NATIVE_CASES))]:
            original = (self.root / relative).read_bytes()
            (self.root / relative).unlink()
            with self.subTest(relative=relative), self.assertRaises((OSError, ValueError)):
                self.freeze()
            self.write(relative, original)

    def test_symlink_origin_or_nested_source_directory_refused(self):
        original = self.root / 'Sources/PadCore/Example.swift'
        original.unlink()
        original.symlink_to(self.root / 'Package.swift')
        with self.assertRaises(ValueError):
            self.freeze()
        original.unlink()
        self.write('Sources/PadCore/Example.swift', b'// original\n')
        (self.root / 'Sources/PadCore/Linked').symlink_to(self.root / 'Sources/SearchExecution', target_is_directory=True)
        with self.assertRaises(ValueError):
            self.freeze()

    def test_origin_changed_after_capture_refused(self):
        manifest = self.freeze()
        self.write('Sources/PadCore/Example.swift', b'// changed origin\n')
        with self.assertRaises(ValueError):
            r.verify(self.root, self.run, manifest, self.common)

    def test_origin_membership_added_or_removed_refused(self):
        manifest = self.freeze()
        self.write('Sources/PadCore/Late.swift', b'// added\n')
        with self.assertRaises(ValueError):
            r.verify(self.root, self.run, manifest, self.common)
        (self.root / 'Sources/PadCore/Late.swift').unlink()
        (self.root / 'Sources/PadCore/Example.swift').unlink()
        with self.assertRaises(ValueError):
            r.verify(self.root, self.run, manifest, self.common)

    def test_bytes_modes_runner_and_generated_manifest_refused(self):
        manifest = self.freeze()
        names = ['Package/Sources/PadCore/Example.swift', 'Runner/' + r.RUNNER,
                 'Runner/' + r.COMMON, 'Runner/' + r.WATCHDOG, 'Runner/scripts/swift.sh',
                 'Package/Package.swift']
        for relative in names:
            target = self.run / relative
            data, mode = r.read_info(target)
            target.chmod(0o600)
            target.write_bytes(data + b'changed')
            with self.subTest(relative=relative), self.assertRaises(ValueError):
                r.verify(self.root, self.run, manifest, self.common)
            target.write_bytes(data)
            target.chmod(mode)
        target = self.run / 'Package/Sources/PadCore/Example.swift'
        target.chmod(0o600)
        with self.assertRaises(ValueError):
            r.verify(self.root, self.run, manifest, self.common)

    def test_origin_mode_changed_refused(self):
        manifest = self.freeze()
        (self.root / 'Sources/PadCore/Example.swift').chmod(0o600)
        with self.assertRaises(ValueError):
            r.verify(self.root, self.run, manifest, self.common)

    def test_compiler_versioned_manifest_and_runner_extra_membership_refused(self):
        manifest = self.freeze()
        for relative in ['Package/Package@swift-6.swift', 'Package/Tests/SearchExecutionTests/Extra.swift',
                         'Runner/extra.py', 'Runner/__pycache__/injected.pyc']:
            target = self.run / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(b'added input')
            with self.subTest(relative=relative), self.assertRaises(ValueError):
                r.verify(self.root, self.run, manifest, self.common)
            target.unlink()
            if target.parent.name == '__pycache__':
                target.parent.rmdir()

    def test_changed_compiled_digest_cannot_authorize_source_transformation(self):
        manifest = self.freeze()
        item = next(item for item in manifest['sources'] if item['source'].startswith('Sources/'))
        target = self.run / item['frozen']
        target.write_bytes(b'// transformed\n')
        item['sha256'] = self.common.digest(target.read_bytes())
        with self.assertRaises(ValueError):
            r.verify(self.root, self.run, manifest, self.common)

    def test_protected_inventory_cannot_shrink_duplicate_or_remap(self):
        manifest = self.freeze()
        variants = []
        smaller = copy.deepcopy(manifest)
        smaller['sources'] = smaller['sources'][:-1]
        variants.append(smaller)
        duplicate = copy.deepcopy(manifest)
        duplicate['sources'].append(copy.deepcopy(duplicate['sources'][0]))
        variants.append(duplicate)
        remapped = copy.deepcopy(manifest)
        remapped['sources'][0]['frozen'] = 'Runner/elsewhere.swift'
        variants.append(remapped)
        for value in variants:
            with self.subTest(value=value), self.assertRaises(ValueError):
                r.verify(self.root, self.run, value, self.common)

    def test_manifest_allowlist_host_floor_or_generated_digest_drift_refused(self):
        manifest = self.freeze()
        for field, value in [('expectedTests', manifest['expectedTests'][:-1]),
                             ('nativeHostMinimum', 14), ('publicDeploymentFloor', 26),
                             ('version', True), ('generated', []), ('outputDirectories', ['Runner'])]:
            changed = copy.deepcopy(manifest)
            changed[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                r.verify(self.root, self.run, changed, self.common)

    def test_source_and_membership_mutations_during_freeze_refused(self):
        actual_read = r.read_info
        tracked = self.root / 'Sources/PadCore/Example.swift'
        calls = 0
        def changing_read(target):
            nonlocal calls
            data = actual_read(target)
            if target == tracked:
                calls += 1
                if calls == 2:
                    target.write_bytes(data[0] + b'// concurrent mutation\n')
            return data
        with patch.object(r, 'read_info', changing_read), self.assertRaises(ValueError):
            self.freeze()

    def test_frozen_shell_command_and_mode_are_exact(self):
        manifest = self.freeze()
        shell = self.run / ('Runner/' + r.SHELL)
        self.assertEqual(shell.read_text(), r.ENTRYPOINT)
        self.assertEqual(shell.stat().st_mode & 0o777, 0o755)
        self.assertIn('exec python3 "$repo_root/' + r.RUNNER + '" "$@"', shell.read_text())
        shell.write_bytes(shell.read_bytes().replace(b'run_harness.py', b'other.py'))
        with self.assertRaises(ValueError):
            r.verify(self.root, self.run, manifest, self.common)

    def test_declared_generated_cache_and_build_are_outputs_only(self):
        manifest = self.freeze()
        cache = self.run / 'Runner/.cache/clang'
        cache.mkdir(parents=True)
        (cache / 'synthetic.pcm').write_bytes(b'generated module output')
        build = self.run / 'Build'
        build.mkdir()
        (build / 'synthetic.o').write_bytes(b'generated compiler output')
        r.verify(self.root, self.run, manifest, self.common)
        altered = copy.deepcopy(manifest)
        altered['sources'][0]['frozen'] = 'Runner/.cache/adopted.swift'
        with self.assertRaises(ValueError):
            r.verify(self.root, self.run, altered, self.common)
        (self.run / 'Runner/.cacheOther').mkdir()
        with self.assertRaises(ValueError):
            r.verify(self.root, self.run, manifest, self.common)

    def test_generated_output_root_symlink_or_file_refused(self):
        manifest = self.freeze()
        for relative in r.OUTPUT_DIRECTORIES:
            output = self.run / relative
            output.symlink_to(self.root, target_is_directory=True)
            with self.subTest(relative=relative, kind='symlink'), self.assertRaises(ValueError):
                r.verify(self.root, self.run, manifest, self.common)
            output.unlink()
            output.write_bytes(b'not a directory')
            with self.subTest(relative=relative, kind='file'), self.assertRaises(ValueError):
                r.verify(self.root, self.run, manifest, self.common)
            output.unlink()

    def test_origin_shell_change_cannot_self_authenticate_at_freeze(self):
        self.write(r.SHELL, r.ENTRYPOINT.replace('run_harness.py', 'other.py').encode(), 0o755)
        with self.assertRaises(ValueError):
            self.freeze()

    def test_origin_membership_change_during_capture_refused(self):
        actual_read = r.read_info
        tracked = self.root / 'Package.swift'
        calls = 0
        def adding_read(target):
            nonlocal calls
            data = actual_read(target)
            if target == tracked:
                calls += 1
                if calls == 2:
                    self.write('Sources/PadCore/Concurrent.swift', b'// added during capture\n')
            return data
        with patch.object(r, 'read_info', adding_read), self.assertRaises(ValueError):
            self.freeze()


class ExecuteTests(ArchiveFixture):
    def test_exact_direct_watchdog_commands_receipts_and_ten_methods(self):
        self.freeze()
        self.assertEqual(self.execute(), 0)
        self.assertEqual([name for name, _, _ in self.calls], ['toolchain', 'test'])
        self.assertEqual(self.calls[0][1], ['/usr/bin/xcrun', 'swift', '--version'])
        self.assertEqual(self.calls[1][1], [str(self.run / 'Runner/scripts/swift.sh'), 'test',
                         '--package-path', str(self.run / 'Package'), '--scratch-path', str(self.run / 'Build'),
                         '--filter', r.FILTER])
        self.assertEqual(self.calls[1][2][:2], ['--timeout', '240'])
        status = json.loads((self.run / 'status.json').read_text())
        self.assertEqual(status['exit'], 0)
        self.assertEqual(status['testsExecuted'], 10)
        self.assertEqual(status['sourceManifestSHA256'], self.common.digest((self.run / 'sources.json').read_bytes()))

    def test_older_host_starts_no_stage(self):
        self.freeze()
        with patch.object(r, 'ensure_supported_host', side_effect=ValueError('macOS26 required')):
            self.assertEqual(self.execute(), 125)
        self.assertEqual(self.calls, [])
        self.assertIn('macOS26', json.loads((self.run / 'status.json').read_text())['failure'])

    def test_nonzero_stage_has_real_checked_receipt_and_no_later_stage(self):
        self.freeze()
        self.stage_codes['toolchain'] = 1
        self.assertEqual(self.execute(), 1)
        self.assertEqual(len(self.calls), 1)

    def test_nonzero_exit_without_matching_receipt_refused(self):
        self.freeze()
        self.stage_codes['toolchain'] = 1
        self.receipt_mutations = dict(returnCode=0)
        self.assertEqual(self.execute(), 125)
        self.assertEqual(len(self.calls), 1)

    def test_boolean_or_out_of_range_stage_exit_refused(self):
        self.freeze()
        self.stage_codes['toolchain'] = False
        self.assertEqual(self.execute(), 125)

    def test_frozen_and_origin_mutations_after_stage_stop_next_stage(self):
        self.freeze()
        self.after_stage = lambda _: (self.run / 'Package/Sources/PadCore/Example.swift').write_bytes(b'changed')
        self.assertEqual(self.execute(), 125)
        self.assertEqual(len(self.calls), 1)

    def test_origin_mutation_after_stage_is_checked(self):
        self.freeze()
        self.after_stage = lambda _: (self.root / 'Sources/PadCore/Example.swift').write_bytes(b'changed')
        self.assertEqual(self.execute(), 125)
        self.assertEqual(len(self.calls), 1)

    def test_pinned_manifest_mutation_or_mode_change_stops_stages(self):
        self.freeze()
        self.after_stage = lambda _: (self.run / 'sources.json').chmod(0o600)
        self.assertEqual(self.execute(), 125)
        self.assertEqual(len(self.calls), 1)

    def test_pinned_manifest_bytes_change_with_unchanged_mode_stops_stages(self):
        self.freeze()
        def mutate(_):
            metadata = self.run / 'sources.json'
            metadata.chmod(0o600)
            metadata.write_bytes(metadata.read_bytes() + b' ')
            metadata.chmod(0o400)
        self.after_stage = mutate
        self.assertEqual(self.execute(), 125)
        self.assertEqual(len(self.calls), 1)

    def test_zero_test_execution_is_never_green(self):
        self.freeze()
        self.stdout_override = 'Executed 0 tests, with 0 failures (0 unexpected)'
        self.assertEqual(self.execute(), 125)
        self.assertEqual(json.loads((self.run / 'status.json').read_text())['testsExecuted'], None)

    def test_compiler_diagnostics_in_either_stream_require_review(self):
        self.freeze()
        self.stderr_override = 'warning: synthetic compiler warning\n'
        self.assertEqual(self.execute(), 125)
        self.assertEqual(len(self.calls), 1)

    def test_compiler_error_in_stdout_requires_review(self):
        self.freeze()
        self.stdout_override = execution_log() + '\nerror: synthetic diagnostic\n'
        self.assertEqual(self.execute(), 125)

    def test_post_final_stage_origin_mutation_invalidates_success(self):
        self.freeze()
        def mutate(stage):
            if stage == 'test':
                (self.root / 'Sources/PadCore/Example.swift').write_bytes(b'changed after test')
        self.after_stage = mutate
        self.assertEqual(self.execute(), 125)
        self.assertEqual(len(self.calls), 2)


class ReceiptTests(ArchiveFixture):
    def test_each_incomplete_receipt_field_refused(self):
        self.freeze()
        # Each mutation has a separate fresh receipt directory. No real process.
        variants = [dict(waitCompleted=False), dict(captureComplete=False), dict(timedOut=True),
                    dict(truncated=True), dict(interruptedSignal=2), dict(waitError='failed'),
                    dict(failure='setup'), dict(command=['unrelated']), dict(pid=True),
                    dict(processGroup=124), dict(exitObserved=False), dict(registrationError=1),
                    dict(groupSignalAttempted=False), dict(groupCleanup='unknown'),
                    dict(groupSignalError=1), dict(groupQuery={}), dict(returnCode=True)]
        for index, mutation in enumerate(variants):
            output = self.run / ('receipt-' + str(index))
            self.receipt_mutations = mutation
            self.watchdog(['--timeout', '1', '--output', str(output), '--', 'synthetic-stage'])
            with self.subTest(mutation=mutation):
                self.assertFalse(self.common.receipt_success(output, ['synthetic-stage']))

    def test_missing_receipt_field_and_capture_byte_mismatch_refused(self):
        self.freeze()
        output = self.run / 'receipt'
        self.watchdog(['--timeout', '1', '--output', str(output), '--', 'synthetic-stage'])
        original = json.loads((output / 'status.json').read_text())
        for field in original:
            changed = copy.deepcopy(original)
            del changed[field]
            (output / 'status.json').write_text(json.dumps(changed))
            with self.subTest(field=field):
                self.assertFalse(self.common.receipt_success(output, ['synthetic-stage']))
        changed = copy.deepcopy(original)
        changed['captured']['stdout']['received'] += 1
        (output / 'status.json').write_text(json.dumps(changed))
        self.assertFalse(self.common.receipt_success(output, ['synthetic-stage']))
        (output / 'status.json').write_text(json.dumps(original))
        (output / 'stdout.log').write_text('different bytes')
        self.assertFalse(self.common.receipt_success(output, ['synthetic-stage']))

    def test_timeout_receipt_invalidates_zero_return_before_next_stage(self):
        self.freeze()
        self.receipt_mutations = dict(timedOut=True)
        self.assertEqual(self.execute(), 125)
        self.assertEqual(len(self.calls), 1)


if __name__ == '__main__':
    unittest.main()
