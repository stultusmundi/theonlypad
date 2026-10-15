"""Pure fixed real-helper contracts. No compiler/helper/native process is executed.

First RED is ordinary missing-mode assertions; deeper guards remain UNENTERED.
Synthetic artifact records exercise sealed-byte authority only, not compiler proof.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path.cwd()
HERE = Path(__file__).resolve().parent
I = ROOT / 'Tests/NativeIntegration'
def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module
RUNNER = load('real_helper_contract_runner', I / 'run_native_regressions.py')
APP = load('real_helper_existing_fixture', I / 'test_document_search_app_runner.py')
MODE = 'document-search-real-helper'
CLASS = 'DocumentSearchRealHelperIntegrationTests'
FILE = CLASS + '.swift'
METHODS = ('testRealBundledHelperFindReplaceUndoAndApplicationJoinedQuit',
           'testRealHelperMalformedRegexRefusesAndSamePanelCanRetryThenJoinedQuit',
           'testRealHelperReplacementApprovalRefusesAfterNativeEditUndoABAThenJoinedQuit')
STAGES = ('test-happy', 'test-invalid-pattern', 'test-stale-approval')
ACCESS = APP.ACCESS
PROOF_FUNCTIONS = ('capture_real_helper_build', 'verify_real_helper_build',
                   'stage_real_helper', 'verify_real_helper_fixture')
def sha(data): return hashlib.sha256(data).hexdigest()
def store(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')
    return sha(path.read_bytes())

class RealHelperRunnerTests(unittest.TestCase):
    def require_mode(self):
        self.assertIn(MODE, RUNNER.SUITES, 'Missing fixed real-helper mode; deeper horizons UNENTERED')
    def function(self, name):
        self.assertTrue(callable(getattr(RUNNER, name, None)), 'Missing bounded interface: ' + name)
        return getattr(RUNNER, name)
    @staticmethod
    def declarations():
        return ('import XCTest\n@testable import NativeRouting\n@testable import SearchExecution\n'
                'final class ' + CLASS + ': XCTestCase {\n  func ' + METHODS[0] + '() {}\n}\n'
                'extension ' + CLASS + ' {\n' + ''.join('  func ' + x + '() {}\n' for x in METHODS[1:]) + '}\n')
    @staticmethod
    def success(method):
        return ("Test Case '-[NativeRoutingTests." + CLASS + ' ' + method + "]' passed (0.001 seconds).\n"
                "Test Suite '" + CLASS + "' passed at synthetic.\nExecuted 1 test, with 0 failures (0 unexpected)\n")
    def fixture(self, text=None):
        owner = APP.DocumentSearchAppRunnerTests()
        helper, root, run = owner.fixture()
        self.addCleanup(owner.doCleanups)
        run.chmod(0o700)
        files = {'scripts/test-document-search-real-helper.sh': '# synthetic entry; never executed\n',
                 'Tests/NativeIntegration/expected-Package.swift': (HERE / 'expected-Package.swift').read_text(),
                 'Tests/NativeIntegration/test_document_search_real_helper_runner.py': Path(__file__).read_text(),
                 'Tests/NativeIntegration/' + FILE: self.declarations() if text is None else text,
                 'Sources/PadSearchWorkerRuntime/Program.swift': '// synthetic runtime\n',
                 'Sources/PadSearchWorker/main.swift': '// synthetic worker\n'}
        for name, value in files.items():
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(value)
        return helper, root, run
    def proof_fixture(self, run):
        # A verifier-only authority record. Initial real compiler capture is NOT mocked proof.
        binary = run / 'Build/arm64-apple-macosx/debug'
        binary.mkdir(parents=True, exist_ok=True)
        names = ['PadSearchWorker', 'NativeRoutingPackageTests.xctest/Contents/MacOS/NativeRoutingPackageTests']
        names += [x + '.build/Synthetic.swift.o' for x in ('PadCore', 'SearchExecution', 'PadSearchWorkerRuntime',
                  'PadSearchWorker', 'NativeRouting', 'NativeRoutingTests', 'NativeRoutingPackageTests')]
        artifacts = []
        for name in names:
            path = binary / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(('pure synthetic artifact ' + name).encode())
            path.chmod(0o755 if name == 'PadSearchWorker' else 0o600)
            s = path.stat()
            artifacts.append(dict(path=path.relative_to(run).as_posix(), bytes=s.st_size, sha256=sha(path.read_bytes()),
                                  device=s.st_dev, inode=s.st_ino, uid=s.st_uid, mode=s.st_mode & 0o777))
        record = dict(sourceManifestSHA256=sha((run / 'sources.json').read_bytes()),
                      helper=(binary / 'PadSearchWorker').relative_to(run).as_posix(), artifacts=artifacts)
        return record, store(run / 'build-inputs.json', record), binary

    def test_fixed_cli_refuses_external_operands(self):
        self.require_mode()
        args = RUNNER.parse_args([MODE])
        self.assertEqual(args.suite, MODE)
        self.assertIsNone(args.build_path)
        for extra in (['/synthetic/build'], ['--build-path', '/synthetic/build'], ['--helper', '/synthetic/worker'],
                      ['--bundle', '/synthetic/app'], ['--filter', METHODS[0]], ['--source', '/synthetic'], ['--skip-build']):
            with self.subTest(extra=extra), self.assertRaises(SystemExit): RUNNER.parse_args([MODE, *extra])

    def test_exact_worker_native_graph_and_package(self):
        self.require_mode()
        _, root, run = self.fixture()
        manifest = RUNNER.freeze(root, run, MODE)
        self.assertEqual((run / 'Package/Package.swift').read_bytes(), (HERE / 'expected-Package.swift').read_bytes())
        for name in ('PadCore/Core.swift', 'SearchExecution/Child.swift', 'PadSearchWorkerRuntime/Program.swift',
                     'PadSearchWorkerRuntime/Unrelated.swift', 'PadSearchWorker/main.swift'):
            self.assertEqual((run / 'Package/Sources' / name).read_bytes(), (root / 'Sources' / name).read_bytes())
        for name in ('EditorDocument.swift', 'NativeApplicationSearches.swift'):
            self.assertEqual((run / 'Package/Sources/NativeRouting' / name).read_bytes(),
                             (root / 'Sources/TheOnlyPad' / name).read_bytes())
        self.assertFalse((run / 'Package/Sources/NativeRouting/TheOnlyPadApplication.swift').exists())
        self.assertEqual((run / 'Original/Sources/TheOnlyPad/TheOnlyPadApplication.swift').read_bytes(),
                         (root / 'Sources/TheOnlyPad/TheOnlyPadApplication.swift').read_bytes())
        self.assertEqual((run / 'Package/Tests/NativeRoutingTests' / FILE).read_bytes(),
                         (root / 'Tests/NativeIntegration' / FILE).read_bytes())
        RUNNER.verify(run, manifest)

    def test_four_exact_tails_no_repair_or_dirty_hooks(self):
        self.require_mode()
        _, root, run = self.fixture()
        manifest = RUNNER.freeze(root, run, MODE)
        self.assertIn('documentSearchRealHelperAccess', manifest)
        rows = manifest['documentSearchRealHelperAccess']
        self.assertEqual(len(rows), 4)
        self.assertEqual({x['target'] for x in rows}, set(ACCESS))
        for row in rows:
            raw = (root / 'Sources/TheOnlyPad' / row['target']).read_bytes()
            tail = (root / 'Tests/NativeIntegration' / ACCESS[row['target']]).read_bytes()
            generated = (run / 'Package/Sources/NativeRouting' / row['target']).read_bytes()
            self.assertEqual(generated, raw + b'\n' + tail)
            self.assertEqual(row['source'], 'Tests/NativeIntegration/' + ACCESS[row['target']])
            self.assertEqual((row['join'], row['bytes'], row['sha256']), ('LF', len(tail), sha(tail)))
            self.assertEqual((row['originalSHA256'], row['generatedSHA256']), (sha(raw), sha(generated)))
        originals = {x['source'] for x in manifest['sources']}
        for name in ('DocumentSearchNativeCloseAccess.swift', 'DocumentSearchNativeOwnerAccess.swift'):
            self.assertNotIn('Tests/NativeIntegration/' + name, originals)
        self.assertEqual(manifest['documentSearchRealHelperMethods'], [[CLASS, x] for x in METHODS])

    def test_census_accepts_same_file_extension_refuses_changed_roster(self):
        self.require_mode()
        text = self.declarations()
        _, root, run = self.fixture(text)
        RUNNER.freeze(root, run, MODE)
        line = '  func ' + METHODS[1] + '() {}\n'
        for wrong in (text.replace(line, ''), text.replace(line, line + line),
                      text.replace('extension ' + CLASS, 'extension OtherClass'),
                      text.replace(METHODS[2], 'testForeign'),
                      text + '\nfinal class ForeignTests: XCTestCase { func testUnknown() {} }\n'):
            with self.subTest(wrong=wrong):
                _, root, run = self.fixture(wrong)
                with self.assertRaises(ValueError): RUNNER.freeze(root, run, MODE)

    def test_selected_parser_refuses_false_success(self):
        self.require_mode()
        parse = self.function('real_helper_success')
        for method in METHODS:
            good = self.success(method)
            self.assertEqual(parse(good, method), {'tests': 1, 'failures': 0})
            first = good.splitlines(keepends=True)[0]
            other = METHODS[(METHODS.index(method) + 1) % len(METHODS)]
            bad = (good.replace(first, ''), first + good, good.replace(method, other), good.replace(CLASS, 'OtherClass'),
                   good.replace('passed (', 'skipped ('), good.replace('passed (', 'failed ('),
                   good.replace('Executed 1', 'Executed 0'),
                   good.replace("Test Suite '" + CLASS + "' passed at synthetic.\n", ''),
                   good + 'error: hidden failure\n', good + 'caught error: fixture failure\n',
                   good.replace('0 unexpected', '1 unexpected'))
            for value in bad:
                with self.subTest(value=value), self.assertRaises(ValueError): parse(value, method)
        with self.assertRaises(ValueError): parse(self.success(METHODS[0]), 'testCallerSupplied')

    def test_six_direct_stages_three_fixed_selectors_distinct_private_states(self):
        self.require_mode()
        for name in PROOF_FUNCTIONS: self.function(name)
        helper, root, run = self.fixture()
        RUNNER.freeze(root, run, MODE)
        record, digest, binary = self.proof_fixture(run)
        staged, checked = [], []
        def capture(owned, output_directory, source_hash):
            self.assertEqual(Path(owned), run)
            self.assertEqual(Path(output_directory), binary)
            self.assertEqual(source_hash, sha((run / 'sources.json').read_bytes()))
            return record
        def stage(owned, name, authority):
            self.assertEqual(Path(owned), run)
            self.assertIn(name, STAGES)
            self.assertEqual(authority, record)
            staged.append(name)
            return {'stage': name}
        def check(owned, value): checked.append(value['stage'])
        def output(command):
            if '--show-bin-path' in command: return str(binary) + '\n'
            if '-XCTest' in command: return self.success(command[command.index('-XCTest') + 1].split('/')[-1])
            if 'test' in command: return self.success(command[command.index('--filter') + 1].split('/')[-1])
            return 'pure injected toolchain/build\n'
        # Orchestration isolation ONLY: these patches grant no real build/artifact evidence.
        with patch.object(RUNNER, 'capture_real_helper_build', capture), \
             patch.object(RUNNER, 'verify_real_helper_build', return_value=None), \
             patch.object(RUNNER, 'stage_real_helper', stage), \
             patch.object(RUNNER, 'verify_real_helper_fixture', check):
            code = RUNNER.execute(run, RUNNER.parse_args([MODE]), helper.watchdog(output))
        self.assertEqual(code, 0)
        self.assertEqual(len(helper.calls), 6)
        self.assertEqual(staged, list(STAGES))
        self.assertTrue(set(STAGES).issubset(checked))
        self.assertEqual([x[x.index('--timeout') + 1] for x in helper.calls], ['30','180','30','180','180','180'])
        commands = [x[x.index('--') + 1:] for x in helper.calls]
        self.assertIn('--build-tests', commands[1])
        self.assertIn('--show-bin-path', commands[2])
        self.assertNotIn('--skip-build', commands[1])
        states = []
        for i, command in enumerate(commands):
            self.assertEqual(command[0], '/usr/bin/env')
            sa = [x for x in command if x.startswith('THEONLYPAD_STATE_DIRECTORY=')]
            ta = [x for x in command if x.startswith('TMPDIR=')]
            self.assertEqual((len(sa), len(ta)), (1, 1))
            state, temporary = Path(sa[0].split('=',1)[1]), Path(ta[0].split('=',1)[1])
            self.assertTrue(state.is_relative_to(run / 'State'))
            self.assertTrue(temporary.is_relative_to(run))
            self.assertFalse(state.is_symlink())
            self.assertEqual(state.stat().st_mode & 0o777, 0o700)
            states.append(state)
            if i == 1: self.assertIn('-warnings-as-errors', command)
        self.assertEqual(len(set(states)), 6)
        # Both command forms completed all six injected stages above. Only the
        # runtime contract changes: no SwiftPM planning after sealed capture.
        for command, method in zip(commands[3:], METHODS):
            self.assertEqual(command[3:], ['/usr/bin/xcrun', 'xctest', '-XCTest',
                'NativeRoutingTests.' + CLASS + '/' + method,
                str(binary / 'NativeRoutingPackageTests.xctest')])
            for forbidden in ('--skip-build', '--filter', '--package-path', '--scratch-path', 'test'):
                self.assertNotIn(forbidden, command[3:])
            self.assertFalse(any(Path(value).name in ('swift', 'swift.sh') for value in command[3:]))

    def test_missing_receipt_stops_before_build_or_helper(self):
        self.require_mode()
        helper, root, run = self.fixture()
        RUNNER.freeze(root, run, MODE)
        code = RUNNER.execute(run, RUNNER.parse_args([MODE]), helper.watchdog('', missing=True))
        self.assertEqual(code, 125)
        self.assertEqual(len(helper.calls), 1)
        self.assertFalse(list((run / 'State').rglob('PadSearchWorker')))

    def test_compile_failure_retains_evidence_and_stops(self):
        self.require_mode()
        helper, root, run = self.fixture()
        RUNNER.freeze(root, run, MODE)
        watch = helper.watchdog('pure injected output\n')
        def fail_build(argv):
            code = watch(argv)
            if len(helper.calls) == 2:
                output = Path(argv[argv.index('--output') + 1])
                value = json.loads((output / 'status.json').read_text())
                value.update(exit=1, returnCode=1)
                store(output / 'status.json', value)
                (run / 'owned-failure-evidence').write_bytes(b'retain')
                return 1
            return code
        self.assertEqual(RUNNER.execute(run, RUNNER.parse_args([MODE]), fail_build), 1)
        self.assertEqual(len(helper.calls), 2)
        self.assertEqual((run / 'owned-failure-evidence').read_bytes(), b'retain')
        self.assertFalse(list((run / 'State').rglob('PadSearchWorker')))

    def test_frozen_source_tail_or_unknown_input_refused(self):
        self.require_mode()
        for mutation in ('source', 'tail', 'extra'):
            with self.subTest(mutation=mutation):
                _, root, run = self.fixture()
                manifest = RUNNER.freeze(root, run, MODE)
                RUNNER.verify(run, manifest)
                path = {'source': run / 'Package/Sources/PadSearchWorkerRuntime/Program.swift',
                        'tail': run / 'Original/Tests/NativeIntegration/DocumentSearchAppRoutingAccess.swift',
                        'extra': run / 'Package/Sources/PadSearchWorker/Foreign.swift'}[mutation]
                path.write_bytes(b'unrecorded change')
                with self.assertRaises(ValueError): RUNNER.verify(run, manifest)

    def test_authority_rejects_record_and_source_manifest_substitution(self):
        self.require_mode()
        verify = self.function('verify_real_helper_build')
        for mutation in ('record-file', 'record-argument', 'source-manifest'):
            with self.subTest(mutation=mutation):
                _, root, run = self.fixture()
                RUNNER.freeze(root, run, MODE)
                record, digest, _ = self.proof_fixture(run)
                verify(run, record, digest)
                if mutation == 'record-file': (run / 'build-inputs.json').write_bytes(b'{}\n')
                elif mutation == 'record-argument': record['helper'] = 'Build/other-helper'
                else: (run / 'sources.json').write_bytes(b'{}\n')
                with self.assertRaises(ValueError): verify(run, record, digest)

    def test_authority_rejects_changed_missing_replaced_or_symlink_artifacts(self):
        self.require_mode()
        verify = self.function('verify_real_helper_build')
        for mutation in ('bytes', 'missing', 'inode', 'symlink', 'object-bytes'):
            with self.subTest(mutation=mutation):
                _, root, run = self.fixture()
                RUNNER.freeze(root, run, MODE)
                record, digest, _ = self.proof_fixture(run)
                verify(run, record, digest)
                target = run / record['helper']
                if mutation == 'object-bytes':
                    target = run / record['artifacts'][2]['path']
                    target.write_bytes(b'object substitution')
                elif mutation == 'bytes': target.write_bytes(b'substitution')
                elif mutation == 'missing': target.unlink()
                elif mutation == 'inode':
                    replacement = target.with_name('new-helper')
                    replacement.write_bytes(target.read_bytes())
                    replacement.chmod(target.stat().st_mode & 0o777)
                    os.replace(replacement, target)
                else:
                    original = target.with_name('original-helper')
                    target.rename(original)
                    target.symlink_to(original)
                with self.assertRaises(ValueError): verify(run, record, digest)

    def test_fixed_stage_copy_and_private_bundle(self):
        self.require_mode()
        stage, verify = self.function('stage_real_helper'), self.function('verify_real_helper_fixture')
        _, root, run = self.fixture()
        RUNNER.freeze(root, run, MODE)
        record, _, _ = self.proof_fixture(run)
        copied = stage(run, STAGES[0], record)
        target = run / 'State' / STAGES[0] / 'RealHelperFixture.app/Contents/Helpers/PadSearchWorker'
        self.assertEqual(target.read_bytes(), (run / record['helper']).read_bytes())
        self.assertEqual(target.stat().st_mode & 0o777, 0o755)
        for path in (target.parent, target.parent.parent, target.parent.parent.parent, target.parent.parent.parent.parent):
            self.assertFalse(path.is_symlink())
            self.assertEqual(path.stat().st_uid, os.getuid())
            self.assertEqual(path.stat().st_mode & 0o777, 0o700)
        verify(run, copied)
        for wrong in ('../escape', '/tmp/helper', 'caller-selected-case'):
            with self.subTest(wrong=wrong), self.assertRaises(ValueError): stage(run, wrong, record)

    def test_fixture_drift_refused_and_unresolved_bytes_retained(self):
        self.require_mode()
        stage, verify = self.function('stage_real_helper'), self.function('verify_real_helper_fixture')
        for mutation in ('unknown-fixture', 'helper-bytes', 'extra-executable'):
            with self.subTest(mutation=mutation):
                _, root, run = self.fixture()
                RUNNER.freeze(root, run, MODE)
                record, _, _ = self.proof_fixture(run)
                copied = stage(run, STAGES[0], record)
                verify(run, copied)
                state = run / 'State' / STAGES[0]
                target = {'unknown-fixture': state / 'unsettled-owned-fixture',
                          'helper-bytes': state / 'RealHelperFixture.app/Contents/Helpers/PadSearchWorker',
                          'extra-executable': state / 'RealHelperFixture.app/Contents/Helpers/OtherHelper'}[mutation]
                target.write_bytes(b'retain unresolved evidence')
                with self.assertRaises(ValueError): verify(run, copied)
                self.assertEqual(target.read_bytes(), b'retain unresolved evidence')

if __name__ == '__main__': unittest.main()
