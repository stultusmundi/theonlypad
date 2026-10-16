"""Finite diagnostic-contract tests; only the injected watchdog boundary is fake.
No compiler, Swift test, native program, Git or subprocess is launched here.
"""
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
TARGET = 'Tests/PadCoreTests/FolderReplacementPreviewTests.swift'
METHOD = 'testAdmissionAndBudgetsRejectBeforeExpensiveWork'
SELECTOR = r'^PadCoreTests\.FolderReplacementPreviewTests/testAdmissionAndBudgetsRejectBeforeExpensiveWork$'
MARKER = b'CI_FOLDER_PREVIEW_TRACE'
SEQUENCE = [(0, 0), (0, 1), (1, 0), (1, 1), (2, 0), (2, 1), (3, 0), (3, 1), (4, 0), (4, 1)]
CALL = re.compile(rb'(?m)^ {4,6}FileHandle\.standardError\.write\(Data\("CI_FOLDER_PREVIEW_TRACE p=([0-4]) e=([01])\\n"\.utf8\)\)\n')
ORIGINAL = (ROOT / TARGET).read_bytes()
spec = importlib.util.spec_from_file_location('ci_folder_preview_trace_contract', ROOT / 'scripts/ci_folder_preview_trace.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


def trace(count=10):
    return b''.join(f'CI_FOLDER_PREVIEW_TRACE p={p} e={e}\n'.encode('ascii') for p, e in SEQUENCE[:count])


class ControlledWatchdog:
    """Complete accepted-watchdog capture fixture; never executes command argv."""
    def __init__(self, stderr, stdout=b'', exit_code=0, change=None, after=None):
        self.stderr, self.stdout = stderr, stdout
        self.exit_code, self.change, self.after = exit_code, change, after
        self.calls = []

    def __call__(self, argv):
        self.calls.append(list(argv))
        output = Path(argv[argv.index('--output') + 1])
        output.mkdir(parents=True, exist_ok=True)
        command = argv[argv.index('--') + 1:]
        counts = lambda b: dict(received=len(b), stored=len(b), discarded=0)
        value = dict(command=command, pid=12345, processGroup=12345, exitObserved=True,
            registrationError=None, groupSignalAttempted=True, groupSignalError=None,
            groupCleanup='signaled', groupQuery=None, waitCompleted=True,
            returnCode=self.exit_code, waitError=None, timedOut=False, interruptedSignal=None,
            truncated=False, captureComplete=True, captured=dict(stdout=counts(self.stdout), stderr=counts(self.stderr)),
            failure=None, exit=self.exit_code, seconds=0.1)
        (output / 'stdout.log').write_bytes(self.stdout)
        (output / 'stderr.log').write_bytes(self.stderr)
        (output / 'status.json').write_text(json.dumps(value))
        if self.change:
            self.change(value, output)
        if self.after:
            self.after()
        return self.exit_code


class FolderPreviewTraceContractTests(unittest.TestCase):
    def capsule(self):
        temporary = tempfile.TemporaryDirectory(prefix='ci-folder-trace-')
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name) / 'Repo'
        run = Path(temporary.name) / 'Run'
        root.mkdir(mode=0o700)
        run.mkdir(mode=0o700)
        files = {
            TARGET: ORIGINAL,
            'Sources/PadCore/FolderReplacementPreview.swift': b'// synthetic source, never compiled\n',
            'Sources/SearchExecution/Other.swift': b'// synthetic search source\n',
            'Sources/TheOnlyPad/Other.swift': b'// synthetic native source\n',
            'Tests/Unrelated/Other.swift': b'// preserved unrelated Test\n',
            'Examples/Synthetic/manifest.json': b'{"synthetic":true}\n',
            'Package.swift': (ROOT / 'Package.swift').read_bytes(),
        }
        for name in ['scripts/swift.sh', 'scripts/run-owned-search-tests.py',
                     'scripts/ci_folder_preview_trace.py', 'Tests/NativeIntegration/run_native_regressions.py']:
            files[name] = (ROOT / name).read_bytes()
        for name, data in files.items():
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        return root, run, files

    def frozen(self):
        root, run, files = self.capsule()
        plan = runner.make_plan(root, run)
        self.assertIsInstance(plan, dict, 'Missing productive plan; freeze/child horizons UNENTERED')
        if not isinstance(plan, dict):
            return None
        manifest = runner.freeze(root, run, plan)
        self.assertIsInstance(manifest, dict, 'Missing real input capture; child horizons UNENTERED')
        if not isinstance(manifest, dict):
            return None
        return root, run, files, plan, manifest

    # Break caught: rewritten original statements, extra logging or wrong constructor interval.
    def test_projection_is_only_ten_markers_with_exact_whole_original_inverse(self):
        projected = runner.project_test(ORIGINAL)
        self.assertIsInstance(projected, bytes, 'No projection admitted; later byte/probe oracles UNENTERED')
        if not isinstance(projected, bytes):
            return
        matches = list(CALL.finditer(projected))
        self.assertEqual([(int(m[1]), int(m[2])) for m in matches], SEQUENCE)
        self.assertEqual(projected.count(MARKER), 10)
        self.assertEqual(CALL.sub(b'', projected), ORIGINAL)
        method = projected.index(('  func ' + METHOD + '() throws {').encode())
        body = projected.index(b'    try withFixture { fixture in\n', method)
        invalid = projected.index(b'      let invalidLimits:', body)
        long_url = projected.index(b'      let longPath = URL(', invalid)
        nul_url = projected.index(b'      let nulPath = URL(', long_url)
        requests = projected.index(b'      let requestCases:', nul_url)
        next_method = projected.index(b'  func testSecondReadFailureReturnsNoPartialPreview', requests)
        self.assertTrue(method < matches[0].start() < body < matches[1].start() < matches[2].start() < invalid)
        self.assertTrue(invalid < matches[3].start() < matches[4].start() < long_url)
        self.assertTrue(long_url < matches[5].start() < matches[6].start() < nul_url)
        self.assertTrue(nul_url < matches[7].start() < matches[8].start() < requests)
        self.assertTrue(requests < matches[9].start() < next_method)
        self.assertTrue(matches[9][0].startswith(b'    FileHandle'), 'Final marker must be outside fixture body')
        method_source = projected[method:next_method]
        entry = (b'  func testAdmissionAndBudgetsRejectBeforeExpensiveWork() throws {\n' + matches[0][0]
                 + b'    try withFixture { fixture in\n' + matches[1][0] + matches[2][0]
                 + b'      let invalidLimits: [FolderReplacementPreviewLimits] = [\n')
        self.assertTrue(method_source.startswith(entry), 'phase0 END/phase1 BEGIN must follow actual fixture entry')
        invalid_loop = b'      for limits in invalidLimits {\n        let reader = ControlledReader()\n        assertError(.invalidLimits) {\n          try preview(fixture, builder: .init(reader: reader), limits: limits)\n        }\n        XCTAssertEqual(reader.rootCalls, 0)\n        XCTAssertEqual(reader.fileCalls, 0)\n      }\n\n'
        long_constructor = b'      let longPath = URL(\n        fileURLWithPath: fixture.root.path + "/" + String(repeating: "p", count: 4097))\n'
        nul_constructor = b'      let nulPath = URL(fileURLWithPath: fixture.root.path + "/nul\\u{0}name")\n'
        constructor_boundary = (invalid_loop + matches[3][0] + matches[4][0]
                                + long_constructor + matches[5][0] + matches[6][0]
                                + nul_constructor + matches[7][0] + matches[8][0]
                                + b'      let requestCases: [([URL], SearchQuery, String, FolderReplacementPreviewLimits)] = [\n')
        self.assertIn(constructor_boundary, method_source,
                      'real loop/zero-I/O assertions and both exact URL constructors must bound the phases')
        suffix = (b'      assertError(.sourceLimit) { try preview(fixture, urls: [fixture.a]) }\n'
                  b'    }\n' + matches[9][0] + b'  }\n\n'
                  b'  // Catches returning the first result after later file I/O or selected-content rejection.\n')
        self.assertIn(suffix, method_source, 'phase4 END must follow actual final assertion and fixture return')
        self.assertEqual(projected[:method], ORIGINAL[:ORIGINAL.index(('  func ' + METHOD).encode())])

    # Break caught: accidentally tracing another method or accepting ambiguous/stale anchors.
    def test_projection_refuses_other_method_duplicate_anchors_or_existing_trace_without_source_write(self):
        projected = runner.project_test(ORIGINAL)
        self.assertIsInstance(projected, bytes, 'Missing positive projection; refusal horizons UNENTERED')
        if not isinstance(projected, bytes):
            return
        root, _, _ = self.capsule()
        before = (root / TARGET).read_bytes()
        variants = [
            ORIGINAL.replace(METHOD.encode(), b'testDifferentMethod', 1),
            ORIGINAL + ORIGINAL,
            ORIGINAL.replace(b'let longPath = URL(', b'let anotherPath = URL(', 1),
            ORIGINAL.replace(b'count: 4097', b'count: 4096', 1),
            ORIGINAL + b'// CI_FOLDER_PREVIEW_TRACE p=0 e=0\n',
        ]
        for data in variants:
            with self.subTest(kind=hashlib.sha256(data).hexdigest()[:8]), self.assertRaises(ValueError):
                runner.project_test(data)
        self.assertEqual((root / TARGET).read_bytes(), before)
        self.assertEqual((ROOT / TARGET).read_bytes(), ORIGINAL)

    # Break caught: discarded last BEGIN, accepted missing middle END, or log/record truncation.
    def test_decoder_accepts_complete_and_entered_without_end_but_refuses_bad_records(self):
        complete = runner.parse_trace(b'', trace())
        self.assertIsInstance(complete, dict, 'No trace decoder; later ordered-prefix controls UNENTERED')
        if not isinstance(complete, dict):
            return
        self.assertEqual(complete, dict(phase=4, edge=1, records=10, horizon='all-intervals-ended'))
        self.assertEqual(runner.parse_trace(b'ordinary stdout\n', trace(5)),
                         dict(phase=2, edge=0, records=5, horizon='entered-without-end'))
        self.assertEqual(runner.parse_trace(b'', trace(4)),
                         dict(phase=1, edge=1, records=4, horizon='completed-interval'))
        self.assertEqual(runner.parse_trace(b'', b'unrelated\n'),
                         dict(phase=None, edge=None, records=0, horizon='not-observed'))
        bad = [trace() + trace(1), trace(1) + b'CI_FOLDER_PREVIEW_TRACE p=1 e=0\n',
               trace(5)[:-1], b'CI_FOLDER_PREVIEW_TRACE p=9 e=0\n',
               b' CI_FOLDER_PREVIEW_TRACE p=0 e=0\n',
               b'CI_FOLDER_PREVIEW_TRACE p=0 e=0 trailing\n', trace(1).replace(b'\n', b'\r\n')]
        for data in bad:
            with self.subTest(raw=data), self.assertRaises(ValueError):
                runner.parse_trace(b'', data)
        # Actual SwiftPM forwarded the Test's stderr writes to owned parent stdout.
        # Accept one whole owned stream; never merge two unordered captures.
        try:
            stdout_complete = runner.parse_trace(trace(), b'ordinary stderr\n')
        except ValueError:
            stdout_complete = None
        self.assertIsInstance(stdout_complete, dict,
                              'Missing actual SwiftPM stdout route; deeper stream variants UNENTERED')
        if not isinstance(stdout_complete, dict):
            return
        self.assertEqual(stdout_complete, complete)
        self.assertEqual(runner.parse_trace(trace(5), b'ordinary stderr\n'),
                         dict(phase=2, edge=0, records=5, horizon='entered-without-end'))
        for data in bad:
            with self.subTest(stdout=data), self.assertRaises(ValueError):
                runner.parse_trace(data, b'ordinary stderr\n')
        for stdout, stderr in [(trace(1), trace(1)), (trace(), trace()),
                               (trace(4), trace()[len(trace(4)):]),
                               (trace()[len(trace(4)):], trace(4)),
                               (trace(), b'CI_FOLDER_PREVIEW_TRACE p=0 e=0')]:
            with self.subTest(stdout=stdout, stderr=stderr), self.assertRaises(ValueError):
                runner.parse_trace(stdout, stderr)

    # Break caught: altered selector, original Source writes, uncaptured extra/replaced inputs.
    def test_fixed_plan_freeze_and_prechild_input_refusals(self):
        state = self.frozen()
        if state is None:
            return
        root, run, files, plan, manifest = state
        self.assertEqual(plan['selector'], SELECTOR)
        self.assertEqual(plan['watchdogTimeout'], 600)
        self.assertEqual(plan['command'], ['/usr/bin/env', 'NSUnbufferedIO=YES',
            'THEONLYPAD_STATE_DIRECTORY=' + str(run / 'State'), 'TMPDIR=' + str(run / 'Temporary') + '/',
            str(run / 'Project/scripts/swift.sh'), 'test', '--scratch-path', str(run / 'BuildProducts'),
            '--filter', SELECTOR])
        self.assertIsNone(runner.validate_cli([]))
        for argv in [['--filter', METHOD], ['--source', TARGET], ['--build-path', '/synthetic/build'], ['--help']]:
            with self.subTest(argv=argv), self.assertRaises(ValueError):
                runner.validate_cli(argv)
        for name, data in files.items():
            self.assertEqual((root / name).read_bytes(), data)
            if name.startswith(('Sources/', 'Tests/', 'Examples/')) or name == 'Package.swift' or name == 'scripts/swift.sh':
                frozen = (run / 'Project' / name).read_bytes()
                self.assertEqual(CALL.sub(b'', frozen), data) if name == TARGET else self.assertEqual(frozen, data)
        self.assertIsNone(runner.verify_inputs(root, run, manifest))
        for mutation in ('source-bytes', 'extra-source', 'same-byte-inode', 'source-symlink',
                         'frozen-source', 'frozen-projected-test', 'selector-field', 'command-filter'):
            state = self.frozen()
            if state is None:
                return
            root, run, files, plan, manifest = state
            authority_before = json.dumps(manifest, sort_keys=True)
            path = root / 'Sources/PadCore/FolderReplacementPreview.swift'
            if mutation == 'source-bytes': path.write_bytes(b'changed\n')
            elif mutation == 'extra-source': (path.parent / 'Extra.swift').write_bytes(b'extra\n')
            elif mutation == 'same-byte-inode':
                other = path.with_suffix('.replacement'); other.write_bytes(path.read_bytes()); other.replace(path)
            elif mutation == 'source-symlink':
                path.unlink(); path.symlink_to(root / 'Sources/SearchExecution/Other.swift')
            elif mutation == 'frozen-source':
                (run / 'Project/Sources/PadCore/FolderReplacementPreview.swift').write_bytes(b'changed frozen Source')
            elif mutation == 'frozen-projected-test':
                target = run / 'Project' / TARGET
                data = target.read_bytes()
                changed = data.replace(b'count: 4097', b'count: 4096', 1)
                self.assertNotEqual(changed, data, 'Frozen constructor mutation must actually change the projected Test')
                target.write_bytes(changed)
            elif mutation == 'selector-field':
                plan['selector'] = SELECTOR.replace(METHOD, 'testUnrelatedSynthetic')
            else:
                plan['command'] = list(plan['command'])
                index = plan['command'].index('--filter') + 1
                plan['command'][index] = SELECTOR.replace(METHOD, 'testUnrelatedSynthetic')
            self.assertEqual(json.dumps(manifest, sort_keys=True), authority_before,
                             'Mutation must not update or alias-bless the frozen manifest authority')
            watch = ControlledWatchdog(trace())
            if mutation in ('selector-field', 'command-filter'):
                self.assertIsNone(runner.verify_inputs(root, run, manifest),
                                  'Plan-only mutation leaves frozen file authority intact')
            else:
                with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                    runner.verify_inputs(root, run, manifest)
            result = runner.execute(root, run, plan, manifest, watch)
            self.assertIsInstance(result, dict)
            if not isinstance(result, dict):
                return
            self.assertEqual(result['state'], 'unavailable')
            self.assertEqual(watch.calls, [], 'Refused changed input must prevent any actual child')

    # Break caught: treating SwiftPM1 as child signal/cause, dropping last BEGIN or printing raw logs.
    def test_natural_one_with_last_begin_is_observed_and_privacy_stays_closed(self):
        state = self.frozen()
        if state is None:
            return
        root, run, _, plan, manifest = state
        home = '/' + 'Users/' + 'synthetic/'
        secret = ('-----BEGIN ' + 'PRIVATE KEY-----\nsynthetic-secret\n' + home + '\n').encode()
        watch = ControlledWatchdog(secret + trace(5), stdout=b'raw method/path/error text\n', exit_code=1)
        result = runner.execute(root, run, plan, manifest, watch)
        self.assertIsInstance(result, dict, 'No owned execution result; deeper privacy controls UNENTERED')
        if not isinstance(result, dict):
            return
        self.assertEqual(result['state'], 'observed')
        self.assertEqual((result['ownedExit'], result['ownedReturnCode']), (1, 1))
        self.assertEqual(result['signalObservation'], 'not-observed-for-selected-test')
        self.assertEqual(result['trace'], dict(phase=2, edge=0, records=5, horizon='entered-without-end'))
        lines = runner.render(result)
        self.assertEqual(lines, ['ci-folder-preview-trace: observed',
            'trace: phase=2 edge=0 horizon=entered-without-end records=5',
            'owned: exit=1 returnCode=1 signal=not-observed-for-selected-test'])
        text = '\n'.join(lines) + '\n'
        self.assertLessEqual(len(text.encode('ascii')), 512)
        for forbidden in ['synthetic-secret', home, 'PRIVATE KEY', METHOD, TARGET, 'raw method/path/error']:
            self.assertNotIn(forbidden, text)
        self.assertEqual(len(watch.calls), 1)
        self.assertEqual(watch.calls[0][watch.calls[0].index('--') + 1:], plan['command'])
        self.assertEqual(watch.calls[0][watch.calls[0].index('--timeout') + 1], '600')
        complete_state = self.frozen()
        if complete_state is None:
            return
        root, run, _, plan, manifest = complete_state
        done = runner.execute(root, run, plan, manifest, ControlledWatchdog(trace(), exit_code=0))
        self.assertEqual(done['state'], 'observed')
        self.assertEqual(done['trace']['horizon'], 'all-intervals-ended')
        self.assertEqual(done['ownedExit'], 0)
        none_state = self.frozen()
        if none_state is None:
            return
        root, run, _, plan, manifest = none_state
        absent = runner.execute(root, run, plan, manifest, ControlledWatchdog(b'build failed\n', exit_code=1))
        self.assertEqual(absent['state'], 'not-observed')
        self.assertEqual(absent['trace']['records'], 0)

        stdout_state = self.frozen()
        if stdout_state is None:
            return
        root, run, _, plan, manifest = stdout_state
        stdout_watch = ControlledWatchdog(secret + b'ordinary stderr\n', stdout=trace(), exit_code=0)
        stdout_result = runner.execute(root, run, plan, manifest, stdout_watch)
        self.assertIsInstance(stdout_result, dict, 'Missing owned stdout execution result')
        if not isinstance(stdout_result, dict):
            return
        self.assertEqual(stdout_result.get('state'), 'observed',
                         'Actual parent stdout markers must be admitted before deeper trace/privacy checks')
        if stdout_result.get('state') != 'observed':
            return
        self.assertEqual(stdout_result['trace'], dict(phase=4, edge=1, records=10, horizon='all-intervals-ended'))
        self.assertEqual((stdout_result['ownedExit'], stdout_result['ownedReturnCode']), (0, 0))
        self.assertEqual(stdout_result['signalObservation'], 'not-observed-for-selected-test')
        stdout_lines = runner.render(stdout_result)
        self.assertEqual(stdout_lines, ['ci-folder-preview-trace: observed',
            'trace: phase=4 edge=1 horizon=all-intervals-ended records=10',
            'owned: exit=0 returnCode=0 signal=not-observed-for-selected-test'])
        stdout_text = '\n'.join(stdout_lines) + '\n'
        self.assertLessEqual(len(stdout_text.encode('ascii')), 512)
        for forbidden in ['synthetic-secret', home, 'PRIVATE KEY', METHOD, TARGET, 'ordinary stderr']:
            self.assertNotIn(forbidden, stdout_text)
        self.assertEqual(len(stdout_watch.calls), 1)
        self.assertEqual(stdout_watch.calls[0][stdout_watch.calls[0].index('--') + 1:], plan['command'])

    # Break caught: accepting bad receipt/capture or re-blessing post-child source drift/erasing custody.
    def test_incomplete_or_tampered_evidence_refuses_and_preserves_failure_custody(self):
        state = self.frozen()
        if state is None:
            return
        root, run, _, plan, manifest = state
        result = runner.execute(root, run, plan, manifest, ControlledWatchdog(trace()))
        self.assertIsInstance(result, dict, 'No positive receipt/execution premise; refusal horizons UNENTERED')
        if not isinstance(result, dict):
            return
        self.assertEqual(result['state'], 'observed')
        def change(kind):
            def apply(value, output):
                if kind == 'missing': (output / 'status.json').unlink(); return
                if kind == 'stream': (output / 'stderr.log').write_bytes(b'changed capture\n'); return
                if kind == 'extra': value['unexpected'] = 'never print this'
                elif kind == 'timeout': value['timedOut'] = True
                elif kind == 'truncated': value['truncated'] = True
                elif kind == 'capture': value['captureComplete'] = False
                elif kind == 'signal': value.update(returnCode=-6, exit=134)
                elif kind == 'seconds': value['seconds'] = -1
                (output / 'status.json').write_text(json.dumps(value))
            return apply
        for kind in ['missing', 'stream', 'extra', 'timeout', 'truncated', 'capture', 'signal', 'seconds', 'post-source']:
            state = self.frozen()
            if state is None:
                return
            root, run, _, plan, manifest = state
            retained = run / 'State/preserved-synthetic-custody'
            retained.parent.mkdir(parents=True, exist_ok=True)
            retained.write_bytes(b'preserve original diagnostic custody')
            after = (lambda: (root / TARGET).write_bytes(b'changed post-child Source\n')) if kind == 'post-source' else None
            watch = ControlledWatchdog(trace(5), exit_code=134 if kind == 'signal' else 1, change=None if kind == 'post-source' else change(kind), after=after)
            result = runner.execute(root, run, plan, manifest, watch)
            with self.subTest(kind=kind):
                self.assertEqual(result['state'], 'unavailable')
                self.assertEqual(runner.render(result), ['ci-folder-preview-trace: unavailable', 'reason: incomplete-evidence'])
                self.assertEqual(retained.read_bytes(), b'preserve original diagnostic custody')
                self.assertTrue((run / 'stage').exists(), 'Raw failure evidence must remain retained')


if __name__ == '__main__':
    unittest.main()
