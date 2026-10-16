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
PATH_MARKER = b'CI_FOLDER_PREVIEW_PATH'
STATEMENTS = [(p, e) for p in range(10) for e in (0, 1)]
SEQUENCE = STATEMENTS[:10] + [(5, 0), (5, 1)] * 12 + STATEMENTS[12:]
PATH_SOURCE_ORDER = [0, 1, 6, 9, 10, 8, 7, 2, 3, 4, 5]
CALL = re.compile(rb'(?m)^ {4,8}FileHandle\.standardError\.write\(Data\("CI_FOLDER_PREVIEW_TRACE p=([0-9]) e=([01])\\n"\.utf8\)\)\n')
PATH_CALL = re.compile(rb'(?m)^ {4,8}FileHandle\.standardError\.write\(Data\("CI_FOLDER_PREVIEW_PATH s=((?:10|[0-9]))\\n"\.utf8\)\)\n')
ORIGINAL = (ROOT / TARGET).read_bytes()
spec = importlib.util.spec_from_file_location('ci_folder_preview_trace_contract', ROOT / 'scripts/ci_folder_preview_trace.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


def _path(stage, ordinal=None):
    return ('path', stage, ordinal)


def _outer(phase, edge):
    return ('outer', phase, edge, None)


def expected_events(missing_request_handlers=()):
    """Independent golden event schedule from the selected Test and the approved 11 sites."""
    events = []

    def helper(*, wrapped=False, request=None, reader=False, missing_handler=False):
        if reader:
            events.extend((_path(0, request), _path(1, request)))
        if wrapped:
            events.append(_path(2, request))
        events.extend(_path(stage, request) for stage in (6, 7, 8, 9, 10))
        if wrapped:
            if not missing_handler:
                events.extend((_path(3, request), _path(4, request)))
            events.append(_path(5, request))

    events.extend((_outer(0, 0), _outer(0, 1), _outer(1, 0)))
    for _ in range(14):
        helper(wrapped=True)
    events.extend((_outer(1, 1), _outer(2, 0), _outer(2, 1),
                   _outer(3, 0), _outer(3, 1), _outer(4, 0), _outer(4, 1)))
    for ordinal in range(1, 13):
        events.append(_outer(5, 0))
        helper(wrapped=True, request=ordinal, reader=True,
               missing_handler=ordinal in missing_request_handlers)
        events.append(_outer(5, 1))
    events.append(_outer(6, 0))
    helper()  # exact positive preview
    for _ in range(3):
        helper(wrapped=True)  # source, retained, and match budget errors
    helper()  # zero-match positive preview
    events.extend((_outer(6, 1), _outer(7, 0)))
    helper()  # exact UTF-8 pattern boundary
    helper()  # exact UTF-8 replacement boundary
    events.extend((_outer(7, 1), _outer(8, 0)))
    helper(wrapped=True)  # final wrapped source-limit assertion
    events.extend((_outer(8, 1), _outer(9, 0), _outer(9, 1)))
    return events


def _record(event):
    if event[0] == 'outer':
        _, phase, edge, _ = event
        return f'CI_FOLDER_PREVIEW_TRACE p={phase} e={edge}\n'.encode('ascii')
    _, stage, _ = event
    return f'CI_FOLDER_PREVIEW_PATH s={stage}\n'.encode('ascii')


def _events_through_outer_count(events, count):
    if count == 0:
        return []
    selected, seen = [], 0
    for event in events:
        selected.append(event)
        if event[0] == 'outer':
            seen += 1
            if seen == count:
                return selected
    if seen != count:
        raise ValueError('golden outer prefix outside finite schedule')
    return selected


def _closed_report(events):
    outer = [event for event in events if event[0] == 'outer']
    paths = [event for event in events if event[0] == 'path']
    if outer:
        _, phase, edge, _ = outer[-1]
        records = len(outer)
        horizon = 'all-intervals-ended' if records == len(SEQUENCE) else (
            'entered-without-end' if edge == 0 else 'completed-interval')
    else:
        phase, edge, records, horizon = None, None, 0, 'not-observed'
    if paths:
        _, stage, request_ordinal = paths[-1]
        if len(paths) == 314 and stage == 5:
            path_horizon = 'all-helpers-ended'
        elif stage == 5:
            path_horizon = 'assertion-returned'
        elif stage == 10:
            path_horizon = 'helper-ended'
        else:
            path_horizon = 'observed-prefix'
    else:
        stage, request_ordinal, path_horizon = None, None, 'not-observed'
    return dict(phase=phase, edge=edge, records=records, horizon=horizon,
                pathStage=stage, requestOrdinal=request_ordinal,
                pathRecords=len(paths), pathHorizon=path_horizon)


def trace(count=42, missing_request_handlers=()):
    """One-stream golden prefix through `count` outer records; count 42 is 356 total."""
    events = expected_events(missing_request_handlers)
    selected = _events_through_outer_count(events, count)
    return b''.join(_record(event) for event in selected)


def path_prefix(request_ordinal, stage, missing_request_handlers=()):
    events = expected_events(missing_request_handlers)
    seen = 0
    selected = []
    for event in events:
        selected.append(event)
        if event[0] == 'path' and event[2] == request_ordinal and event[1] == stage:
            seen += 1
            return b''.join(_record(item) for item in selected)
    raise ValueError('golden requested path prefix outside finite schedule')


def strip_outer_projection(projected):
    """The original twenty marker statements keep their own independent inverse."""
    return CALL.sub(b'', projected)


def strip_path_projection(projected):
    """Test-owned byte inverse for the eleven helper writes and their defer-only syntax."""
    original = PATH_CALL.sub(b'', projected)
    empty_diagnostic_defer = b'    defer {\n    }\n'
    preserved_defer = b'    defer {\n      fixture.assertPreserved()\n    }\n'
    if original.count(empty_diagnostic_defer) == 1:
        original = original.replace(empty_diagnostic_defer, b'', 1)
    if original.count(preserved_defer) == 1:
        original = original.replace(preserved_defer,
                                    b'    defer { fixture.assertPreserved() }\n', 1)
    return original


def strip_projection(projected):
    return strip_path_projection(strip_outer_projection(projected))


def projection_counts(projected):
    return len(list(CALL.finditer(projected))), len(list(PATH_CALL.finditer(projected)))


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

    # Historical method name retained; the original twenty outer sites remain byte-invertible.
    # Break caught: changed outer projection, helper anchors, or original interval ordering.
    def test_projection_is_only_ten_markers_with_exact_whole_original_inverse(self):
        projected = runner.project_test(ORIGINAL)
        self.assertIsInstance(projected, bytes, 'No projection admitted; helper and inverse checks UNENTERED')
        if not isinstance(projected, bytes):
            return
        matches = list(CALL.finditer(projected))
        path_matches = list(PATH_CALL.finditer(projected))
        self.assertEqual(len(matches), 20, 'The established outer projection is a prerequisite')
        self.assertEqual(len(path_matches), 11, 'All helper boundary sites are a prerequisite')
        if len(matches) != 20 or len(path_matches) != 11:
            return
        self.assertEqual([(int(m[1]), int(m[2])) for m in matches], STATEMENTS)
        self.assertEqual(projected.count(MARKER), 20)
        self.assertEqual([int(m[1]) for m in path_matches], PATH_SOURCE_ORDER,
                         'All eleven helper boundary sites must be literal and unique')
        self.assertEqual(projected.count(PATH_MARKER), 11)
        outer_inverse = strip_outer_projection(projected)
        self.assertEqual(outer_inverse.count(MARKER), 0, 'The original outer inverse removes its twenty writes')
        self.assertEqual([int(m[1]) for m in PATH_CALL.finditer(outer_inverse)], PATH_SOURCE_ORDER,
                         'Outer inverse leaves the separately reviewed PATH projection intact')
        self.assertEqual(strip_path_projection(outer_inverse), ORIGINAL,
                         'Removing PATH writes and defer-only syntax must restore every byte')
        method = projected.index(('  func ' + METHOD + '() throws {').encode())
        body = projected.index(b'    try withFixture { fixture in\n', method)
        invalid = projected.index(b'      let invalidLimits:', body)
        long_url = projected.index(b'      let longPath = URL(', invalid)
        nul_url = projected.index(b'      let nulPath = URL(', long_url)
        requests = projected.index(b'      let requestCases:', nul_url)
        next_method = projected.index(b'  func testSecondReadFailureReturnsNoPartialPreviewAndLeavesSourcesBackups', requests)
        self.assertTrue(method < matches[0].start() < body < matches[1].start() < matches[2].start() < invalid)
        self.assertTrue(invalid < matches[3].start() < matches[4].start() < long_url)
        self.assertTrue(long_url < matches[5].start() < matches[6].start() < nul_url)
        self.assertTrue(nul_url < matches[7].start() < matches[8].start() < requests)
        self.assertTrue(requests < matches[9].start() < matches[19].start() < next_method)
        self.assertTrue(matches[19][0].startswith(b'    FileHandle'), 'Final outer marker must remain outside fixture body')
        method_source = projected[method:next_method]
        entry = (b'  func testAdmissionAndBudgetsRejectBeforeExpensiveWork() throws {\n' + matches[0][0]
                 + b'    try withFixture { fixture in\n' + matches[1][0] + matches[2][0]
                 + b'      let invalidLimits: [FolderReplacementPreviewLimits] = [\n')
        self.assertTrue(method_source.startswith(entry), 'Outer phase0/1 placement changed')
        invalid_loop = b'      for limits in invalidLimits {\n        let reader = ControlledReader()\n        assertError(.invalidLimits) {\n          try preview(fixture, builder: .init(reader: reader), limits: limits)\n        }\n        XCTAssertEqual(reader.rootCalls, 0)\n        XCTAssertEqual(reader.fileCalls, 0)\n      }\n\n'
        long_constructor = b'      let longPath = URL(\n        fileURLWithPath: fixture.root.path + "/" + String(repeating: "p", count: 4097))\n'
        nul_constructor = b'      let nulPath = URL(fileURLWithPath: fixture.root.path + "/nul\\u{0}name")\n'
        constructor_boundary = (invalid_loop + matches[3][0] + matches[4][0]
                                + long_constructor + matches[5][0] + matches[6][0]
                                + nul_constructor + matches[7][0] + matches[8][0]
                                + b'      let requestCases: [([URL], SearchQuery, String, FolderReplacementPreviewLimits)] = [\n')
        self.assertIn(constructor_boundary, method_source,
                      'Existing invalid-limit loop and both literal URL constructors must remain byte exact')
        suffix = (b'      assertError(.sourceLimit) { try preview(fixture, urls: [fixture.a]) }\n'
                  + matches[17][0] + matches[18][0] + b'    }\n' + matches[19][0] + b'  }\n\n'
                  b'  // Catches returning the first result after later file I/O or selected-content rejection.\n')
        self.assertIn(suffix, method_source, 'Outer phase8/9 placement must retain the original cleanup boundary')
        loop_reader = (b'        FileHandle.standardError.write(Data("CI_FOLDER_PREVIEW_PATH s=0\\n".utf8))\n'
                       b'        let reader = ControlledReader()\n'
                       b'        FileHandle.standardError.write(Data("CI_FOLDER_PREVIEW_PATH s=1\\n".utf8))\n'
                       b'        assertError(.invalidRequest) {\n')
        self.assertIn(loop_reader, projected, 'Reader markers must enclose only the original loop construction')
        assertion_start = projected.index(b'  private func assertError<T>(')
        fixture_start = projected.index(b'  private func withFixture(', assertion_start)
        assertion_helper = projected[assertion_start:fixture_start]
        self.assertTrue(assertion_helper.startswith(
            b'  private func assertError<T>(\n'))
        self.assertEqual(len(list(PATH_CALL.finditer(assertion_helper))), 4)
        positions = [assertion_helper.index(f'CI_FOLDER_PREVIEW_PATH s={stage}'.encode()) for stage in (2, 3, 4, 5)]
        self.assertEqual(positions, sorted(positions), 'assertError entry, handler, compare, and return must stay ordered')
        self.assertIn(b'FileHandle.standardError.write(Data("CI_FOLDER_PREVIEW_PATH s=2\\n".utf8))\n'
                      b'    XCTAssertThrowsError(try body(), file: file, line: line) {\n'
                      b'      FileHandle.standardError.write(Data("CI_FOLDER_PREVIEW_PATH s=3\\n".utf8))\n',
                      assertion_helper)
        self.assertIn(b'      XCTAssertEqual($0 as? FolderReplacementPreviewError, expected, file: file, line: line)\n'
                      b'      FileHandle.standardError.write(Data("CI_FOLDER_PREVIEW_PATH s=4\\n".utf8))\n'
                      b'    }\n'
                      b'    FileHandle.standardError.write(Data("CI_FOLDER_PREVIEW_PATH s=5\\n".utf8))\n',
                      assertion_helper)
        preview_start = projected.index(b'  private func preview(\n')
        preview_end = assertion_start
        preview_helper = projected[preview_start:preview_end]
        positions = [preview_helper.index(f'CI_FOLDER_PREVIEW_PATH s={stage}'.encode()) for stage in (6, 7, 8, 9, 10)]
        self.assertLess(positions[0], positions[3])
        self.assertLess(positions[3], positions[4])
        self.assertLess(positions[4], positions[2], 'defer registration must make s8 execute before preservation')
        self.assertLess(positions[2], positions[1], 's7 stays immediately before the unchanged return expression')
        preview_interval = (b'  ) throws -> FolderReplacementPreview {\n'
            b'    FileHandle.standardError.write(Data("CI_FOLDER_PREVIEW_PATH s=6\\n".utf8))\n'
            b'    defer {\n'
            b'      FileHandle.standardError.write(Data("CI_FOLDER_PREVIEW_PATH s=9\\n".utf8))\n'
            b'      fixture.assertPreserved()\n'
            b'      FileHandle.standardError.write(Data("CI_FOLDER_PREVIEW_PATH s=10\\n".utf8))\n'
            b'    }\n'
            b'    defer {\n'
            b'      FileHandle.standardError.write(Data("CI_FOLDER_PREVIEW_PATH s=8\\n".utf8))\n'
            b'    }\n'
            b'    FileHandle.standardError.write(Data("CI_FOLDER_PREVIEW_PATH s=7\\n".utf8))\n'
            b'    return try builder.preview(\n')
        self.assertIn(preview_interval, preview_helper,
                      'Both defer bodies and the builder call must retain exact order and arguments')
        self.assertEqual(projected[:method], ORIGINAL[:ORIGINAL.index(('  func ' + METHOD).encode())])

    # Break caught: accidentally tracing another method or accepting ambiguous/stale anchors.
    def test_projection_refuses_other_method_duplicate_anchors_or_existing_trace_without_source_write(self):
        projected = runner.project_test(ORIGINAL)
        self.assertIsInstance(projected, bytes, 'Missing positive projection; refusal horizons UNENTERED')
        if not isinstance(projected, bytes):
            return
        outer_count, path_count = projection_counts(projected)
        self.assertEqual(outer_count, 20, 'Outer projection premise is required before helper refusal checks')
        self.assertEqual(path_count, 11, 'Helper projection premise is required before drift checks')
        if outer_count != 20 or path_count != 11:
            return
        root, _, _ = self.capsule()
        before = (root / TARGET).read_bytes()
        preview_start = ORIGINAL.index(b'  private func preview(\n')
        assertion_start = ORIGINAL.index(b'  private func assertError<T>(\n', preview_start)
        duplicate_preview = ORIGINAL + ORIGINAL[preview_start:assertion_start]
        variants = [
            ORIGINAL.replace(METHOD.encode(), b'testDifferentMethod', 1),
            ORIGINAL + ORIGINAL,
            ORIGINAL.replace(b'let longPath = URL(', b'let anotherPath = URL(', 1),
            ORIGINAL.replace(b'count: 4097', b'count: 4096', 1),
            ORIGINAL + b'// CI_FOLDER_PREVIEW_TRACE p=0 e=0\n',
            ORIGINAL.replace(b'  private func preview(\n', b'  private func previewChanged(\n', 1),
            ORIGINAL.replace(b'    defer { fixture.assertPreserved() }\n',
                             b'    defer { fixture.assertPreserved() }\n    _ = 0\n', 1),
            ORIGINAL.replace(b'XCTAssertEqual($0 as? FolderReplacementPreviewError, expected, file: file, line: line)',
                             b'XCTAssertEqual($0 as? FolderReplacementPreviewError, .sourceLimit, file: file, line: line)', 1),
            ORIGINAL.replace(b'urls: urls, builder: .init(reader: reader)',
                             b'urls: [fixture.a], builder: .init(reader: reader)', 1),
            duplicate_preview,
        ]
        for data in variants:
            with self.subTest(kind=hashlib.sha256(data).hexdigest()[:8]), self.assertRaises(ValueError):
                runner.project_test(data)
        self.assertEqual((root / TARGET).read_bytes(), before)
        self.assertEqual((ROOT / TARGET).read_bytes(), ORIGINAL)

    # Break caught: discarded last BEGIN, accepted missing middle END, or log/record truncation.
    def test_decoder_accepts_complete_and_entered_without_end_but_refuses_bad_records(self):
        projected = runner.project_test(ORIGINAL)
        self.assertIsInstance(projected, bytes, 'No positive source projection; protocol decoder horizon UNENTERED')
        if not isinstance(projected, bytes):
            return
        outer_count, path_count = projection_counts(projected)
        self.assertEqual(outer_count, 20, 'Missing outer protocol premise; decoder checks UNENTERED')
        self.assertEqual(path_count, 11, 'Missing helper protocol premise; decoder checks UNENTERED')
        if outer_count != 20 or path_count != 11:
            return
        complete = runner.parse_trace(b'', trace())
        self.assertIsInstance(complete, dict, 'Complete protocol must return only a closed report')
        if not isinstance(complete, dict):
            return
        self.assertEqual(complete, _closed_report(expected_events()))
        self.assertEqual(complete, dict(phase=9, edge=1, records=42, horizon='all-intervals-ended',
            pathStage=5, requestOrdinal=None, pathRecords=314, pathHorizon='all-helpers-ended'))
        self.assertEqual(runner.parse_trace(b'ordinary stdout\n', trace(5)),
                         _closed_report(_events_through_outer_count(expected_events(), 5)))
        self.assertEqual(runner.parse_trace(b'', trace(4)),
                         _closed_report(_events_through_outer_count(expected_events(), 4)))
        self.assertEqual(runner.parse_trace(b'', b'unrelated\n'), _closed_report([]))
        bad = [trace() + trace(1), trace(1) + b'CI_FOLDER_PREVIEW_TRACE p=1 e=0\n',
               trace(5)[:-1], b'CI_FOLDER_PREVIEW_TRACE p=9 e=0\n',
               b' CI_FOLDER_PREVIEW_TRACE p=0 e=0\n',
               b'CI_FOLDER_PREVIEW_TRACE p=0 e=0 trailing\n', trace(1).replace(b'\n', b'\r\n')]
        for data in bad:
            with self.subTest(raw=data), self.assertRaises(ValueError):
                runner.parse_trace(b'', data)
        stdout_complete = runner.parse_trace(trace(), b'ordinary stderr\n')
        self.assertIsInstance(stdout_complete, dict, 'Forwarded complete protocol must remain report-only')
        if not isinstance(stdout_complete, dict):
            return
        self.assertEqual(stdout_complete, complete,
                         'The two tags travel on the same owned SwiftPM-forwarded stream')
        self.assertEqual(runner.parse_trace(trace(5), b'ordinary stderr\n'),
                         _closed_report(_events_through_outer_count(expected_events(), 5)))
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
                self.assertEqual(strip_projection(frozen), data) if name == TARGET else self.assertEqual(frozen, data)
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
        if result['state'] != 'observed':
            return
        expected = _closed_report(_events_through_outer_count(expected_events(), 5))
        self.assertEqual(result['trace'], expected)
        self.assertEqual((result['ownedExit'], result['ownedReturnCode']), (1, 1))
        self.assertEqual(result['signalObservation'], 'not-observed-for-selected-test')
        lines = runner.render(result)
        self.assertEqual(lines, ['ci-folder-preview-trace: observed',
            'trace: phase=2 edge=0 horizon=entered-without-end records=5',
            'path: stage=5 request=-1 horizon=assertion-returned records=126',
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
        self.assertEqual(done['trace'], _closed_report(expected_events()))
        self.assertEqual(done['trace']['horizon'], 'all-intervals-ended')
        self.assertEqual(done['trace']['pathHorizon'], 'all-helpers-ended')
        self.assertEqual(done['trace']['pathRecords'], 314)
        self.assertEqual(done['ownedExit'], 0)
        none_state = self.frozen()
        if none_state is None:
            return
        root, run, _, plan, manifest = none_state
        absent = runner.execute(root, run, plan, manifest, ControlledWatchdog(b'build failed\n', exit_code=1))
        self.assertEqual(absent['state'], 'not-observed')
        self.assertEqual(absent['trace'], _closed_report([]))

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
        self.assertEqual(stdout_result['trace'], _closed_report(expected_events()))
        self.assertEqual((stdout_result['ownedExit'], stdout_result['ownedReturnCode']), (0, 0))
        self.assertEqual(stdout_result['signalObservation'], 'not-observed-for-selected-test')
        stdout_lines = runner.render(stdout_result)
        self.assertEqual(stdout_lines, ['ci-folder-preview-trace: observed',
            'trace: phase=9 edge=1 horizon=all-intervals-ended records=42',
            'path: stage=5 request=-1 horizon=all-helpers-ended records=314',
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
        if result['state'] != 'observed':
            return
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


    # Break caught: fixed twelve-iteration decoder accepted after request-array or loop-body drift.
    def test_projection_refuses_request_case_membership_order_and_loop_drift(self):
        self.assertIsInstance(runner.project_test(ORIGINAL), bytes)
        first = b'        ([fixture.a, fixture.a], literal(), "X", .init()),\n'
        second = b'        ([fixture.a, fixture.b], literal(), "X", .init(maxFiles: 1)),\n'
        self.assertEqual(ORIGINAL.count(first + second), 1)
        loop = b'      for (urls, query, replacement, limits) in requestCases {\n'
        start = ORIGINAL.index(loop)
        end = ORIGINAL.index(b'      let exact = try preview(', start)
        original_loop = ORIGINAL[start:end]
        changed_loop = original_loop.replace(b'XCTAssertEqual(reader.fileCalls, 0)',
                                             b'XCTAssertEqual(reader.fileCalls, 1)', 1)
        self.assertNotEqual(original_loop, changed_loop)
        variants = {
            'removed-case': ORIGINAL.replace(first, b'', 1),
            'added-case': ORIGINAL.replace(first, first + first, 1),
            'reordered-cases': ORIGINAL.replace(first + second, second + first, 1),
            'changed-case': ORIGINAL.replace(second, second.replace(b'maxFiles: 1', b'maxFiles: 0'), 1),
            'changed-loop-oracle': ORIGINAL[:start] + changed_loop + ORIGINAL[end:],
            'changed-loop-entry': ORIGINAL.replace(loop, loop.replace(b'in requestCases', b'in requestCases.reversed()'), 1),
        }
        for kind, data in variants.items():
            self.assertNotEqual(data, ORIGINAL)
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                runner.project_test(data)
        self.assertEqual((ROOT / TARGET).read_bytes(), ORIGINAL)

    # Break caught: repeated BEGIN/END, early exit, extra iteration, or prefix ordinal discarded.
    def test_repeated_phase_five_prefixes_and_exact_twelve_iteration_boundary(self):
        projected = runner.project_test(ORIGINAL)
        self.assertIsInstance(projected, bytes)
        outer_count, path_count = projection_counts(projected) if isinstance(projected, bytes) else (0, 0)
        self.assertEqual(outer_count, 20, 'Outer protocol premise is required before nested prefix assertions')
        self.assertEqual(path_count, 11, 'Helper protocol premise is required before nested prefix assertions')
        if not isinstance(projected, bytes) or outer_count != 20 or path_count != 11:
            return
        actual = runner.parse_trace(b'', trace())
        full = _closed_report(expected_events())
        self.assertEqual(actual, full, 'Finer sequence unavailable; repeated-loop horizons UNENTERED')
        if actual != full:
            return
        for iteration in range(12):
            begin_count = 11 + 2 * iteration
            end_count = begin_count + 1
            begin_expected = _closed_report(_events_through_outer_count(expected_events(), begin_count))
            end_expected = _closed_report(_events_through_outer_count(expected_events(), end_count))
            for stdout in (False, True):
                for count, expected in ((begin_count, begin_expected), (end_count, end_expected)):
                    with self.subTest(iteration=iteration, stdout=stdout, edge=expected['edge']):
                        streams = (trace(count), b'') if stdout else (b'', trace(count))
                        self.assertEqual(runner.parse_trace(*streams), expected)
        records = [_record(event) for event in expected_events()]
        request_begins = [i for i, raw in enumerate(records)
                          if raw == b'CI_FOLDER_PREVIEW_TRACE p=5 e=0\n']
        request_ends = [i for i, raw in enumerate(records)
                        if raw == b'CI_FOLDER_PREVIEW_TRACE p=5 e=1\n']
        self.assertEqual(len(request_begins), 12)
        self.assertEqual(len(request_ends), 12)
        for iteration, (begin, end) in enumerate(zip(request_begins, request_ends)):
            variants = [records[:begin] + records[begin + 1:],
                        records[:begin + 1] + [records[begin]] + records[begin + 1:],
                        records[:begin] + records[begin:end + 1][::-1] + records[end + 1:],
                        records[:begin + 1] + records[end:]]
            for kind, variant in enumerate(variants):
                with self.subTest(iteration=iteration, malformed=kind), self.assertRaises(ValueError):
                    runner.parse_trace(b'', b''.join(variant))
        for variant in [records + [records[-1]], records[:request_begins[0]] + records[request_ends[0] + 1:],
                        records[:-1] + [records[-1], records[-1]]]:
            with self.subTest(extra_or_missing=len(variant)), self.assertRaises(ValueError):
                runner.parse_trace(b''.join(variant), b'')

    # Break caught: reporting iteration finished before zero-I/O assertions, or cleanup before return.
    def test_literal_loop_writes_and_cleanup_boundary_preserve_whole_source(self):
        projected = runner.project_test(ORIGINAL)
        self.assertIsInstance(projected, bytes)
        if not isinstance(projected, bytes):
            return
        matches = list(CALL.finditer(projected))
        path_matches = list(PATH_CALL.finditer(projected))
        self.assertEqual(len(matches), 20, 'Outer projection unavailable; loop/cleanup boundaries UNENTERED')
        self.assertEqual([int(m[1]) for m in path_matches], PATH_SOURCE_ORDER,
                         'Each helper boundary remains one literal site')
        if len(matches) != 20 or len(path_matches) != 11:
            return
        self.assertEqual([(int(m[1]), int(m[2])) for m in matches], STATEMENTS)
        self.assertEqual(strip_projection(projected), ORIGINAL)
        loop = b'      for (urls, query, replacement, limits) in requestCases {\n'
        array_start = ORIGINAL.index(b'      let requestCases:')
        loop_start = ORIGINAL.index(loop, array_start)
        array = ORIGINAL[array_start:loop_start]
        self.assertIn(array + matches[9][0] + loop + matches[10][0]
                      + b'        FileHandle.standardError.write(Data("CI_FOLDER_PREVIEW_PATH s=0\\n".utf8))\n'
                      + b'        let reader = ControlledReader()\n'
                      + b'        FileHandle.standardError.write(Data("CI_FOLDER_PREVIEW_PATH s=1\\n".utf8))\n', projected)
        self.assertTrue(matches[10][0].startswith(b'        FileHandle'))
        self.assertTrue(matches[11][0].startswith(b'        FileHandle'))
        self.assertIn(b'        XCTAssertEqual(reader.rootCalls, 0)\n'
                      b'        XCTAssertEqual(reader.fileCalls, 0)\n'
                      + matches[11][0] + b'      }\n\n' + matches[12][0]
                      + b'      let exact = try preview(\n', projected)
        self.assertIn(b'      XCTAssertEqual(zeroMatches.matchCount, 0)\n\n'
                      + matches[13][0] + matches[14][0]
                      + b'      let exactPattern = try preview(\n', projected)
        self.assertIn(b'      XCTAssertEqual(exactReplacement.outputBytes, 4096)\n\n'
                      + matches[15][0] + matches[16][0]
                      + b'      let handle = try FileHandle(forWritingTo: fixture.a)\n', projected)
        boundary = (b'      assertError(.sourceLimit) { try preview(fixture, urls: [fixture.a]) }\n'
                    + matches[17][0] + matches[18][0] + b'    }\n' + matches[19][0] + b'  }\n')
        self.assertIn(boundary, projected)
        self.assertTrue(matches[18][0].startswith(b'      FileHandle'))
        self.assertTrue(matches[19][0].startswith(b'    FileHandle'))
        for moved in [ORIGINAL.replace(b'      assertError(.sourceLimit) { try preview(fixture, urls: [fixture.a]) }\n    }',
                                        b'    }\n      assertError(.sourceLimit) { try preview(fixture, urls: [fixture.a]) }', 1),
                      ORIGINAL.replace(b'      let zeroMatches = try preview(', b'      let otherMatches = try preview(', 1)]:
            self.assertNotEqual(moved, ORIGINAL)
            with self.assertRaises(ValueError):
                runner.project_test(moved)


    # Break caught: helper/callsite drift reaches the accepted watchdog before exact source review.
    def test_helper_and_callsite_source_drift_refuses_before_watchdog(self):
        projected = runner.project_test(ORIGINAL)
        self.assertIsInstance(projected, bytes, 'No positive projection; drift refusal premises UNENTERED')
        if not isinstance(projected, bytes):
            return
        outer_count, path_count = projection_counts(projected)
        self.assertEqual(outer_count, 20, 'Missing outer projection; drift controls UNENTERED')
        self.assertEqual(path_count, 11, 'Missing helper projection; drift controls UNENTERED')
        if outer_count != 20 or path_count != 11:
            return
        variants = [
            ORIGINAL.replace(b'  private func preview(\n', b'  private func previewChanged(\n', 1),
            ORIGINAL.replace(b'    defer { fixture.assertPreserved() }\n',
                             b'    defer { fixture.assertPreserved() }\n    _ = 0\n', 1),
            ORIGINAL.replace(b'XCTAssertEqual($0 as? FolderReplacementPreviewError, expected, file: file, line: line)',
                             b'XCTAssertEqual($0 as? FolderReplacementPreviewError, .sourceLimit, file: file, line: line)', 1),
            ORIGINAL.replace(b'urls: urls, builder: .init(reader: reader)',
                             b'urls: [fixture.a], builder: .init(reader: reader)', 1),
        ]
        for changed in variants:
            self.assertNotEqual(changed, ORIGINAL)
            state = self.frozen()
            if state is None:
                return
            root, run, _, plan, manifest = state
            target = root / TARGET
            target.write_bytes(changed)
            watch = ControlledWatchdog(trace())
            result = runner.execute(root, run, plan, manifest, watch)
            self.assertEqual(result['state'], 'unavailable')
            self.assertEqual(watch.calls, [], 'Helper or callsite drift must refuse before child invocation')
            self.assertEqual(target.read_bytes(), changed)

    # Break caught: losing an inner interval boundary or misattributing the eleventh NUL request.
    def test_complete_inner_protocol_and_every_nul_request_ordinal_eleven_prefix(self):
        projected = runner.project_test(ORIGINAL)
        self.assertIsInstance(projected, bytes, 'No positive projection; protocol checks UNENTERED')
        if not isinstance(projected, bytes):
            return
        outer_count, path_count = projection_counts(projected)
        self.assertEqual(outer_count, 20, 'Missing outer projection; protocol checks UNENTERED')
        self.assertEqual(path_count, 11, 'Missing helper projection; protocol checks UNENTERED')
        if outer_count != 20 or path_count != 11:
            return
        events = expected_events()
        self.assertEqual(len(events), 356, 'Golden expected-error stream is independently source-derived')
        self.assertEqual(sum(event[0] == 'outer' for event in events), 42)
        self.assertEqual(sum(event[0] == 'path' for event in events), 314)
        phase7_begin = events.index(_outer(7, 0))
        phase7_end = events.index(_outer(7, 1))
        one_exact_call = [_path(stage) for stage in (6, 7, 8, 9, 10)]
        self.assertEqual(events[phase7_begin + 1:phase7_end], one_exact_call + one_exact_call,
                         'Both exactPattern and exactReplacement calls belong to phase 7')
        phase8_begin = events.index(_outer(8, 0))
        phase8_end = events.index(_outer(8, 1))
        self.assertEqual(events[phase8_begin + 1:phase8_end],
                         [_path(stage) for stage in (2, 6, 7, 8, 9, 10, 3, 4, 5)],
                         'The final wrapped source-limit call belongs to phase 8')
        phase9_begin = events.index(_outer(9, 0))
        self.assertFalse(any(event[0] == 'path' for event in events[phase9_begin + 1:]),
                         'Phase 9 is verification and cleanup, with no preview helper call')
        complete = runner.parse_trace(b'', trace())
        self.assertEqual(complete, dict(phase=9, edge=1, records=42, horizon='all-intervals-ended',
            pathStage=5, requestOrdinal=None, pathRecords=314, pathHorizon='all-helpers-ended'))
        stages = (0, 1, 2, 6, 7, 8, 9, 10, 3, 4, 5)
        for offset, stage in enumerate(stages, start=1):
            actual = runner.parse_trace(b'', path_prefix(11, stage))
            horizon = ('helper-ended' if stage == 10 else
                       'assertion-returned' if stage == 5 else 'observed-prefix')
            self.assertEqual(actual, dict(phase=5, edge=0, records=31,
                horizon='entered-without-end', pathStage=stage, requestOrdinal=11,
                pathRecords=236 + offset, pathHorizon=horizon),
                'Each literal NUL-request subinterval must retain ordinal eleven')
        missing_handler_events = expected_events(missing_request_handlers=(11,))
        missing = runner.parse_trace(b'', trace(missing_request_handlers=(11,)))
        self.assertEqual(missing, dict(phase=9, edge=1, records=42, horizon='all-intervals-ended',
            pathStage=5, requestOrdinal=None, pathRecords=312, pathHorizon='assertion-returned'),
            'Missing XCTest handler markers describe the observed missing-throw path, not success')
        selected_normal = path_prefix(11, 10)
        selected_without_handler = path_prefix(11, 5, missing_request_handlers=(11,))
        self.assertEqual(selected_without_handler,
                         selected_normal + b'CI_FOLDER_PREVIEW_PATH s=5\n')
        self.assertEqual(runner.parse_trace(b'', selected_without_handler),
            dict(phase=5, edge=0, records=31, horizon='entered-without-end', pathStage=5,
                 requestOrdinal=11, pathRecords=245, pathHorizon='assertion-returned'))
        self.assertEqual(sum(event[0] == 'path' for event in missing_handler_events), 312)

    # Break caught: reordered unwind, split custody, partial tags, foreign IDs, or unbounded records accepted.
    def test_nested_order_custody_partial_foreign_and_cap_refusals(self):
        projected = runner.project_test(ORIGINAL)
        self.assertIsInstance(projected, bytes, 'No positive projection; nested refusal checks UNENTERED')
        if not isinstance(projected, bytes):
            return
        outer_count, path_count = projection_counts(projected)
        self.assertEqual(outer_count, 20, 'Missing outer projection; nested refusal checks UNENTERED')
        self.assertEqual(path_count, 11, 'Missing helper projection; nested refusal checks UNENTERED')
        if outer_count != 20 or path_count != 11:
            return
        events = expected_events()
        records = [_record(event) for event in events]
        nul_start = next(i for i, event in enumerate(events)
                         if event[0] == 'path' and event[2] == 11 and event[1] == 0)
        nul_indices = [i for i in range(nul_start, len(events))
                       if events[i][0] == 'path' and events[i][2] == 11]
        self.assertEqual([events[i][1] for i in nul_indices], [0, 1, 2, 6, 7, 8, 9, 10, 3, 4, 5])
        reorder_unwind = list(records)
        reorder_unwind[nul_indices[5]], reorder_unwind[nul_indices[6]] = (
            reorder_unwind[nul_indices[6]], reorder_unwind[nul_indices[5]])
        reorder_preservation = list(records)
        reorder_preservation[nul_indices[6]], reorder_preservation[nul_indices[7]] = (
            reorder_preservation[nul_indices[7]], reorder_preservation[nul_indices[6]])
        duplicate = list(records)
        duplicate.insert(nul_indices[7] + 1, duplicate[nul_indices[7]])
        missing = []
        for missing_stage_index in (5, 6, 7, 8):
            variant = list(records)
            del variant[nul_indices[missing_stage_index]]
            missing.append(b''.join(variant))
        nul_end = next(i for i, event in enumerate(events)
                       if i > nul_indices[-1] and event == _outer(5, 1))
        crossed_boundary = list(records)
        crossed_boundary[nul_indices[-1]], crossed_boundary[nul_end] = (
            crossed_boundary[nul_end], crossed_boundary[nul_indices[-1]])
        malformed = [b''.join(reorder_unwind), b''.join(reorder_preservation),
                     b''.join(duplicate), *missing, b''.join(crossed_boundary),
                     trace() + b'CI_FOLDER_PREVIEW_PATH s=',
                     trace() + b'CI_FOLDER_PREVIEW_TRACE p=',
                     trace() + b'CI_FOLDER_PREVIEW_PATH s=11\n',
                     trace() + b'CI_FOLDER_PREVIEW_TRACE p=10 e=0\n',
                     b'CI_FOLDER_PREVIEW_PATH s=0\n' * 513]
        for raw in malformed:
            with self.subTest(bytes=len(raw)), self.assertRaises(ValueError):
                runner.parse_trace(b'', raw)
        stdout_outer = b''.join(record for event, record in zip(events, records) if event[0] == 'outer')
        stderr_inner = b''.join(record for event, record in zip(events, records) if event[0] == 'path')
        for stdout, stderr in ((stdout_outer, stderr_inner), (stderr_inner, stdout_outer),
                               (trace(1), trace(1))):
            with self.subTest(stdout_bytes=len(stdout), stderr_bytes=len(stderr)), self.assertRaises(ValueError):
                runner.parse_trace(stdout, stderr)


if __name__ == '__main__':
    unittest.main()
