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
CORE_MARKER = b'CI_FOLDER_PREVIEW_CORE'
STATEMENTS = [(p, e) for p in range(10) for e in (0, 1)]
SEQUENCE = STATEMENTS[:10] + [(5, 0), (5, 1)] * 12 + STATEMENTS[12:]
PATH_SOURCE_ORDER = [0, 1, 6, 9, 10, 8, 7, 2, 3, 4, 5]
CALL = re.compile(rb'(?m)^ {4,8}FileHandle\.standardError\.write\(Data\("CI_FOLDER_PREVIEW_TRACE p=([0-9]) e=([01])\\n"\.utf8\)\)\n')
PATH_CALL = re.compile(rb'(?m)^ {4,8}FileHandle\.standardError\.write\(Data\("CI_FOLDER_PREVIEW_PATH s=((?:10|[0-9]))\\n"\.utf8\)\)\n')
CORE_CALL = re.compile(rb'(?m)^ {4,16}FileHandle\.standardError\.write\(Data\("CI_FOLDER_PREVIEW_CORE s=(2[0-4]|1[0-9]|[0-9])\\n"\.utf8\)\)\n')
ORIGINAL = (ROOT / TARGET).read_bytes()
CORE_TARGET = 'Sources/PadCore/FolderReplacementPreview.swift'
ORIGINAL_CORE = (ROOT / CORE_TARGET).read_bytes()
spec = importlib.util.spec_from_file_location('ci_folder_preview_trace_contract', ROOT / 'scripts/ci_folder_preview_trace.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


def _path(stage, ordinal=None):
    return ('path', stage, ordinal)


def _outer(phase, edge):
    return ('outer', phase, edge, None)


def _core(stage, role='none'):
    return ('core', stage, role)


# Source-derived ordinary branch: valid root, then serialized NUL rejection of request 11.
CORE_NUL_EVENTS = (
    _core(0), _core(1), _core(2), _core(3),
    _core(10, 'root'), _core(20, 'root'), _core(21, 'root'), _core(23, 'root'),
    _core(12, 'root'), _core(13, 'root'), _core(14, 'root'), _core(15, 'root'),
    _core(16, 'root'), _core(17, 'root'), _core(18, 'root'), _core(19, 'root'),
    _core(24, 'root'), _core(4), _core(5),
    _core(10, 'selected'), _core(20, 'selected'), _core(21, 'selected'),
    _core(22, 'selected'), _core(24, 'selected'), _core(9),
)


def expected_events(missing_request_handlers=()):
    """Independent golden event schedule from the selected Test and the approved 11 sites."""
    events = []

    def helper(*, wrapped=False, request=None, reader=False, missing_handler=False):
        if reader:
            events.extend((_path(0, request), _path(1, request)))
        if wrapped:
            events.append(_path(2, request))
        for stage in (6, 7):
            events.append(_path(stage, request))
            if stage == 7 and request == 11:
                events.extend(CORE_NUL_EVENTS)
        events.extend(_path(stage, request) for stage in (8, 9, 10))
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
    if event[0] == 'path':
        _, stage, _ = event
        return f'CI_FOLDER_PREVIEW_PATH s={stage}\n'.encode('ascii')
    _, stage, _ = event
    return f'CI_FOLDER_PREVIEW_CORE s={stage}\n'.encode('ascii')


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
    core = [event for event in events if event[0] == 'core']
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
    if core:
        _, core_stage, core_role = core[-1]
        core_horizon = 'builder-left' if core_stage == 9 else 'call-entered-prefix'
    else:
        core_stage, core_role, core_horizon = -1, 'none', 'not-entered'
    return dict(phase=phase, edge=edge, records=records, horizon=horizon,
                pathStage=stage, requestOrdinal=request_ordinal,
                pathRecords=len(paths), pathHorizon=path_horizon,
                coreStage=core_stage, coreRole=core_role, coreRecords=len(core),
                coreHorizon=core_horizon)


def trace(count=42, missing_request_handlers=()):
    """One-stream golden prefix through `count` outer records; normal complete prediction is 381."""
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
    # Undo the fixed ordinal-11-only request binding after the independent marker/defer inverse.
    original = strip_path_projection(strip_outer_projection(projected))
    diagnostic_loop = (b'      for (ordinal, (urls, query, replacement, limits)) '
                       b'in requestCases.enumerated() {\n')
    ordinary_loop = b'      for (urls, query, replacement, limits) in requestCases {\n'
    diagnostic_builder = b'builder: .init(reader: reader, diagnosticTrace: ordinal == 10)'
    ordinary_builder = b'builder: .init(reader: reader)'
    if original.count(diagnostic_loop) != 1 or original.count(diagnostic_builder) != 1:
        raise ValueError('ordinal-11 Test projection inverse refused')
    original = original.replace(diagnostic_loop, ordinary_loop, 1)
    original = original.replace(diagnostic_builder, ordinary_builder, 1)
    return original


def _expected_core_without_markers():
    """Independently specify the only non-marker Core substitutions admitted by design."""
    expected = ORIGINAL_CORE

    def replace_once(old, new):
        nonlocal expected
        if expected.count(old) != 1:
            raise ValueError('Core inverse template anchor is not unique')
        expected = expected.replace(old, new, 1)

    replace_once(
        b'  private let reader: any FolderReplacementSnapshotReading\n\n'
        b'  public init() { reader = FolderReplacementDefaultSnapshotReader() }\n'
        b'  init(reader: any FolderReplacementSnapshotReading) { self.reader = reader }\n',
        b'  private let reader: any FolderReplacementSnapshotReading\n'
        b'  private let diagnosticTrace: Bool\n\n'
        b'  public init() { reader = FolderReplacementDefaultSnapshotReader(); diagnosticTrace = false }\n'
        b'  init(reader: any FolderReplacementSnapshotReading, diagnosticTrace: Bool = false) { '
        b'self.reader = reader; self.diagnosticTrace = diagnosticTrace }\n')

    original_gate = (
        b'    guard case .literal = query.mode,\n'
        b'      !query.pattern.isEmpty,\n'
        b'      query.pattern.utf8.count <= limits.maxPatternUTF8Bytes,\n'
        b'      replacement.utf8.count <= limits.maxReplacementUTF8Bytes,\n'
        b'      selectedURLs.count <= limits.maxFiles,\n'
        b'      FolderReplacementPathPolicy.valid(root, requiresDirectory: true),\n'
        b'      selectedURLs.allSatisfy(validURL)\n'
        b'    else { throw FolderReplacementPreviewError.invalidRequest }\n')
    split_gate = (
        b'    guard case .literal = query.mode else { throw FolderReplacementPreviewError.invalidRequest }\n'
        b'    guard !query.pattern.isEmpty else { throw FolderReplacementPreviewError.invalidRequest }\n'
        b'    guard query.pattern.utf8.count <= limits.maxPatternUTF8Bytes '
        b'else { throw FolderReplacementPreviewError.invalidRequest }\n'
        b'    guard replacement.utf8.count <= limits.maxReplacementUTF8Bytes '
        b'else { throw FolderReplacementPreviewError.invalidRequest }\n'
        b'    guard selectedURLs.count <= limits.maxFiles '
        b'else { throw FolderReplacementPreviewError.invalidRequest }\n'
        b'    guard FolderReplacementPathPolicy.valid(root, requiresDirectory: true, '
        b'diagnosticTrace: diagnosticTrace) '
        b'else { throw FolderReplacementPreviewError.invalidRequest }\n'
        b'    guard selectedURLs.allSatisfy(validURL) '
        b'else { throw FolderReplacementPreviewError.invalidRequest }\n')
    replace_once(original_gate, split_gate)
    replace_once(
        b'  private func validURL(_ url: URL) -> Bool { FolderReplacementPathPolicy.valid(url) }',
        b'  private func validURL(_ url: URL) -> Bool { '
        b'FolderReplacementPathPolicy.valid(url, diagnosticTrace: diagnosticTrace) }')

    replace_once(
        b'  private static func serializedPathContainsNUL(_ url: URL) -> Bool {',
        b'  private static func serializedPathContainsNUL(\n'
        b'    _ url: URL, diagnosticTrace: Bool = false\n'
        b'  ) -> Bool {')
    replace_once(
        b'    for byte in url.absoluteString.utf8 {',
        b'    let absoluteString = url.absoluteString\n'
        b'    for byte in absoluteString.utf8 {')
    replace_once(
        b'    _ url: URL, requiresDirectory: Bool = false,\n'
        b'    decodedPath: (URL) -> String = FolderReplacementPathPolicy.path\n'
        b'  ) -> Bool {\n'
        b'    guard !serializedPathContainsNUL(url),\n'
        b'      url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost"\n'
        b'    else {\n'
        b'      return false\n'
        b'    }\n',
        b'    _ url: URL, requiresDirectory: Bool = false,\n'
        b'    decodedPath: (URL) -> String = FolderReplacementPathPolicy.path,\n'
        b'    diagnosticTrace: Bool = false\n'
        b'  ) -> Bool {\n'
        b'    guard !serializedPathContainsNUL(url, diagnosticTrace: diagnosticTrace) '
        b'else { return false }\n'
        b'    guard url.isFileURL else { return false }\n'
        b'    guard url.host == nil || url.host == "" || url.host == "localhost" '
        b'else { return false }\n')
    return expected


def strip_core_projection(projected):
    """Test-owned inverse for the only two Core regions admitted by the frozen transform."""
    if type(projected) is not bytes or CORE_MARKER not in projected:
        raise ValueError('Core projection premise absent')
    codes = [int(match[1]) for match in CORE_CALL.finditer(projected)]
    expected_codes = [0, 9, 1, 2, 3, 4, 5, 6, 7, 10, 24, 12, 13, 14, 15,
                      16, 17, 18, 19, 20, 21, 22, 23]
    if sorted(codes) != sorted(expected_codes) or projected.count(CORE_MARKER) != 23:
        raise ValueError('Core literal inventory drift')
    # Admission expressions and policy call order remain visible, once, in transformed bytes.
    builder_start = projected.index(b'public struct FolderReplacementPreviewBuilder {')
    builder_end = projected.index(b'struct FolderReplacementFilesystemIdentity: Equatable, Hashable {', builder_start)
    builder = projected[builder_start:builder_end]
    builder_codes = [int(m[1]) for m in CORE_CALL.finditer(builder)]
    if builder_codes != [0, 9, 1, 2, 3, 4, 5, 6, 7]:
        raise ValueError('Builder marker source order drift')
    if builder.count(b'try validate(limits)') != 1:
        raise ValueError('Original limits validation call drift')
    terms = (b'case .literal = query.mode', b'!query.pattern.isEmpty',
             b'query.pattern.utf8.count <= limits.maxPatternUTF8Bytes',
             b'replacement.utf8.count <= limits.maxReplacementUTF8Bytes',
             b'selectedURLs.count <= limits.maxFiles',
             b'FolderReplacementPathPolicy.valid(root, requiresDirectory: true',
             b'selectedURLs.allSatisfy(validURL)')
    positions = [builder.find(term) for term in terms]
    if (any(pos < 0 for pos in positions) or positions != sorted(positions)
            or any(builder.count(term) != 1 for term in terms)):
        raise ValueError('Core admission order drift')
    if builder.count(b'throw FolderReplacementPreviewError.invalidRequest') != 9:
        raise ValueError('Core admission refusal branches drift')
    if builder.count(b'selectedURLs.allSatisfy(validURL)') != 1:
        raise ValueError('Core selected admission invocation drift')
    if (builder.count(b'private let diagnosticTrace: Bool') != 1
            or builder.count(b'public init() { reader = FolderReplacementDefaultSnapshotReader(); '
                      b'diagnosticTrace = false }') != 1
            or builder.count(b'diagnosticTrace: Bool = false') != 1):
        raise ValueError('Core diagnostic defaults are not closed false')
    if builder.count(b'FolderReplacementPathPolicy.valid(url, diagnosticTrace: diagnosticTrace)') != 1:
        raise ValueError('Core flag does not remain an immutable policy input')
    serialized_start = projected.index(b'  private static func serializedPathContainsNUL(')
    components_start = projected.index(b'  static func components(', serialized_start)
    path_region = projected[serialized_start:components_start]
    path_codes = [int(m[1]) for m in CORE_CALL.finditer(path_region)]
    if path_codes != [20, 21, 22, 23, 10, 24, 12, 13, 14, 15, 16, 17, 18, 19]:
        raise ValueError('Core path-policy marker source order drift')
    if (path_region.count(b'let absoluteString = url.absoluteString') != 1
            or path_region.count(b'for byte in absoluteString.utf8') != 1
            or b'for byte in url.absoluteString.utf8' in path_region
            or path_region.count(b'url.host') != 3
            or path_region.count(b'url.host == nil || url.host == "" || url.host == "localhost"') != 1):
        raise ValueError('Serialized-path getter/view binding drift')
    markerless = CORE_CALL.sub(b'', projected)
    # Empty wrappers are the exact residue of removing only fixed diagnostic writes.
    markerless = re.sub(rb'(?m)^([ ]{0,16})if diagnosticTrace \{\n\1\}\n', b'', markerless)
    # Protect the complete post-admission builder body byte-for-byte. This includes the
    # maxMatches allowance, splice, reader revalidation, cancellation and final-root checks.
    protected_start = b'    let urls = selectedURLs\n'
    valid_helper = b'  private func validURL(_ url: URL) -> Bool'
    original_protected_start = ORIGINAL_CORE.index(protected_start)
    original_valid_helper = ORIGINAL_CORE.index(valid_helper, original_protected_start)
    projected_protected_start = markerless.index(protected_start)
    projected_valid_helper = markerless.index(valid_helper, projected_protected_start)
    if markerless[projected_protected_start:projected_valid_helper] != \
            ORIGINAL_CORE[original_protected_start:original_valid_helper]:
        raise ValueError('Post-admission builder body drift')
    # The path-policy tail contains decoded bounds and the C-string closure. It is not
    # an authorized instrumentation interval and must remain an exact protected gap.
    decoded_guard = (b'    guard !decoded.contains("\\0"), decoded.utf8.count <= 4_096, '
                    b'decoded.hasPrefix("/") else {\n      return false\n    }\n')
    directory_tail = b'    // Selected regular-file inputs cannot silently shed directory-only terminal semantics.\n'
    if projected.count(decoded_guard) != 1 or projected.count(directory_tail) != 1:
        raise ValueError('Decoded-path protected predicate drift')
    original_tail_start = ORIGINAL_CORE.index(directory_tail)
    original_components = ORIGINAL_CORE.index(b'  static func components(', original_tail_start)
    projected_tail_start = markerless.index(directory_tail)
    projected_components = markerless.index(b'  static func components(', projected_tail_start)
    if markerless[projected_tail_start:projected_components] != \
            ORIGINAL_CORE[original_tail_start:original_components]:
        raise ValueError('Decoded path/C-string protected tail drift')
    empty_defer = b'    defer {\n    }\n'
    if markerless.count(empty_defer) != 2:
        raise ValueError('Core diagnostic exit-defer inventory drift')
    markerless = markerless.replace(empty_defer, b'', 2)
    if markerless != _expected_core_without_markers():
        raise ValueError('Core contains a non-authorized or non-exact source transformation')
    # Exact permitted fragments have been reversed by whole-template equality, so this
    # result is the complete original authority rather than a span-overwrite reconstruction.
    return ORIGINAL_CORE


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
    def _require_ordinal_projection(self):
        project_test = getattr(runner, 'project_test', None)
        self.assertTrue(callable(project_test), 'Missing Test projection API; dependent checks UNENTERED')
        if not callable(project_test):
            return False
        projected = project_test(ORIGINAL)
        self.assertIsInstance(projected, bytes, 'Missing projected Test bytes; dependent checks UNENTERED')
        if not isinstance(projected, bytes):
            return False
        counts = (projected.count(b'requestCases.enumerated()'),
                  projected.count(b'diagnosticTrace: ordinal == 10'))
        self.assertEqual(counts, (1, 1),
                         'Ordinal-11 projection must be admitted before parser/inverse/execute checks')
        return counts == (1, 1)

    def capsule(self):
        temporary = tempfile.TemporaryDirectory(prefix='ci-folder-trace-')
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name) / 'Repo'
        run = Path(temporary.name) / 'Run'
        root.mkdir(mode=0o700)
        run.mkdir(mode=0o700)
        files = {
            TARGET: ORIGINAL,
            CORE_TARGET: ORIGINAL_CORE,
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
        project_core = getattr(runner, 'project_core', None)
        self.assertTrue(callable(project_core), 'Missing Core projection API; dependent assertions UNENTERED')
        if not callable(project_core):
            return
        if not self._require_ordinal_projection():
            return
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
        ordinal_loop_count = outer_inverse.count(b'requestCases.enumerated()')
        ordinal_flag_count = outer_inverse.count(b'diagnosticTrace: ordinal == 10')
        self.assertEqual((ordinal_loop_count, ordinal_flag_count), (1, 1),
                         'Ordinal projection premise must hold before the whole-Test inverse')
        if (ordinal_loop_count, ordinal_flag_count) != (1, 1):
            return
        self.assertEqual(strip_projection(outer_inverse), ORIGINAL,
                         'Removing outer/PATH writes and exact ordinal binding must restore every byte')
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
        project_core = getattr(runner, 'project_core', None)
        self.assertTrue(callable(project_core), 'Missing Core projection API; dependent assertions UNENTERED')
        if not callable(project_core):
            return
        if not self._require_ordinal_projection():
            return
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
        project_core = getattr(runner, 'project_core', None)
        self.assertTrue(callable(project_core), 'Missing Core projection API; dependent assertions UNENTERED')
        if not callable(project_core):
            return
        if not self._require_ordinal_projection():
            return
        parse_trace = getattr(runner, 'parse_trace', None)
        self.assertTrue(callable(parse_trace), 'Missing trace parser API; dependent checks UNENTERED')
        if not callable(parse_trace):
            return
        projected = runner.project_test(ORIGINAL)
        self.assertIsInstance(projected, bytes, 'No positive source projection; protocol decoder horizon UNENTERED')
        if not isinstance(projected, bytes):
            return
        outer_count, path_count = projection_counts(projected)
        self.assertEqual(outer_count, 20, 'Missing outer protocol premise; decoder checks UNENTERED')
        self.assertEqual(path_count, 11, 'Missing helper protocol premise; decoder checks UNENTERED')
        if outer_count != 20 or path_count != 11:
            return
        complete = parse_trace(b'', trace())
        self.assertIsInstance(complete, dict, 'Complete protocol must return only a closed report')
        if not isinstance(complete, dict):
            return
        self.assertEqual(complete, _closed_report(expected_events()))
        self.assertEqual(complete, dict(phase=9, edge=1, records=42, horizon='all-intervals-ended',
            pathStage=5, requestOrdinal=None, pathRecords=314, pathHorizon='all-helpers-ended',
            coreStage=9, coreRole='none', coreRecords=25, coreHorizon='builder-left'))
        self.assertEqual(parse_trace(b'ordinary stdout\n', trace(5)),
                         _closed_report(_events_through_outer_count(expected_events(), 5)))
        self.assertEqual(parse_trace(b'', trace(4)),
                         _closed_report(_events_through_outer_count(expected_events(), 4)))
        self.assertEqual(parse_trace(b'', b'unrelated\n'), _closed_report([]))
        bad = [trace() + trace(1), trace(1) + b'CI_FOLDER_PREVIEW_TRACE p=1 e=0\n',
               trace(5)[:-1], b'CI_FOLDER_PREVIEW_TRACE p=9 e=0\n',
               b' CI_FOLDER_PREVIEW_TRACE p=0 e=0\n',
               b'CI_FOLDER_PREVIEW_TRACE p=0 e=0 trailing\n', trace(1).replace(b'\n', b'\r\n')]
        for data in bad:
            with self.subTest(raw=data), self.assertRaises(ValueError):
                parse_trace(b'', data)
        stdout_complete = parse_trace(trace(), b'ordinary stderr\n')
        self.assertIsInstance(stdout_complete, dict, 'Forwarded complete protocol must remain report-only')
        if not isinstance(stdout_complete, dict):
            return
        self.assertEqual(stdout_complete, complete,
                         'All three tags travel on the same owned SwiftPM-forwarded stream')
        self.assertEqual(parse_trace(trace(5), b'ordinary stderr\n'),
                         _closed_report(_events_through_outer_count(expected_events(), 5)))
        for data in bad:
            with self.subTest(stdout=data), self.assertRaises(ValueError):
                parse_trace(data, b'ordinary stderr\n')
        for stdout, stderr in [(trace(1), trace(1)), (trace(), trace()),
                               (trace(4), trace()[len(trace(4)):]),
                               (trace()[len(trace(4)):], trace(4)),
                               (trace(), b'CI_FOLDER_PREVIEW_TRACE p=0 e=0')]:
            with self.subTest(stdout=stdout, stderr=stderr), self.assertRaises(ValueError):
                parse_trace(stdout, stderr)

    # Break caught: altered selector, original Source writes, uncaptured extra/replaced inputs.
    def test_fixed_plan_freeze_and_prechild_input_refusals(self):
        project_core = getattr(runner, 'project_core', None)
        self.assertTrue(callable(project_core), 'Missing Core projection API; dependent assertions UNENTERED')
        if not callable(project_core):
            return
        if not self._require_ordinal_projection():
            return
        expected_core = project_core(ORIGINAL_CORE)
        self.assertIsInstance(expected_core, bytes, 'Missing derived Core bytes; freeze checks UNENTERED')
        if not isinstance(expected_core, bytes):
            return
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
                if name == TARGET:
                    ordinal_counts = (frozen.count(b'requestCases.enumerated()'),
                                      frozen.count(b'diagnosticTrace: ordinal == 10'))
                    self.assertEqual(ordinal_counts, (1, 1),
                                     'Frozen Test ordinal projection must be present before inversion')
                    if ordinal_counts != (1, 1):
                        return
                    self.assertEqual(strip_projection(frozen), data)
                elif name == CORE_TARGET:
                    self.assertEqual(frozen, expected_core,
                                     'Frozen Core is the exact reviewed diagnostic derivative')
                else:
                    self.assertEqual(frozen, data)
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
        project_core = getattr(runner, 'project_core', None)
        self.assertTrue(callable(project_core), 'Missing Core projection API; dependent assertions UNENTERED')
        if not callable(project_core):
            return
        if not self._require_ordinal_projection():
            return
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
            'core: stage=-1 role=none horizon=not-entered records=0',
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
            'core: stage=9 role=none horizon=builder-left records=25',
            'owned: exit=0 returnCode=0 signal=not-observed-for-selected-test'])
        stdout_text = '\n'.join(stdout_lines) + '\n'
        self.assertLessEqual(len(stdout_text.encode('ascii')), 512)
        for forbidden in ['synthetic-secret', home, 'PRIVATE KEY', METHOD, TARGET, 'ordinary stderr']:
            self.assertNotIn(forbidden, stdout_text)
        self.assertEqual(len(stdout_watch.calls), 1)
        self.assertEqual(stdout_watch.calls[0][stdout_watch.calls[0].index('--') + 1:], plan['command'])

    # Break caught: accepting bad receipt/capture or re-blessing post-child source drift/erasing custody.
    def test_incomplete_or_tampered_evidence_refuses_and_preserves_failure_custody(self):
        project_core = getattr(runner, 'project_core', None)
        self.assertTrue(callable(project_core), 'Missing Core projection API; dependent assertions UNENTERED')
        if not callable(project_core):
            return
        if not self._require_ordinal_projection():
            return
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
        project_core = getattr(runner, 'project_core', None)
        self.assertTrue(callable(project_core), 'Missing Core projection API; dependent assertions UNENTERED')
        if not callable(project_core):
            return
        if not self._require_ordinal_projection():
            return
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
        project_core = getattr(runner, 'project_core', None)
        self.assertTrue(callable(project_core), 'Missing Core projection API; dependent assertions UNENTERED')
        if not callable(project_core):
            return
        if not self._require_ordinal_projection():
            return
        parse_trace = getattr(runner, 'parse_trace', None)
        self.assertTrue(callable(parse_trace), 'Missing trace parser API; dependent checks UNENTERED')
        if not callable(parse_trace):
            return
        projected = runner.project_test(ORIGINAL)
        self.assertIsInstance(projected, bytes)
        outer_count, path_count = projection_counts(projected) if isinstance(projected, bytes) else (0, 0)
        self.assertEqual(outer_count, 20, 'Outer protocol premise is required before nested prefix assertions')
        self.assertEqual(path_count, 11, 'Helper protocol premise is required before nested prefix assertions')
        if not isinstance(projected, bytes) or outer_count != 20 or path_count != 11:
            return
        actual = parse_trace(b'', trace())
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
                        self.assertEqual(parse_trace(*streams), expected)
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
                    parse_trace(b'', b''.join(variant))
        for variant in [records + [records[-1]], records[:request_begins[0]] + records[request_ends[0] + 1:],
                        records[:-1] + [records[-1], records[-1]]]:
            with self.subTest(extra_or_missing=len(variant)), self.assertRaises(ValueError):
                parse_trace(b''.join(variant), b'')

    # Break caught: reporting iteration finished before zero-I/O assertions, or cleanup before return.
    def test_literal_loop_writes_and_cleanup_boundary_preserve_whole_source(self):
        project_core = getattr(runner, 'project_core', None)
        self.assertTrue(callable(project_core), 'Missing Core projection API; dependent assertions UNENTERED')
        if not callable(project_core):
            return
        if not self._require_ordinal_projection():
            return
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
        ordinal_counts = (projected.count(b'requestCases.enumerated()'),
                          projected.count(b'diagnosticTrace: ordinal == 10'))
        self.assertEqual(ordinal_counts, (1, 1),
                         'Ordinal projection premise must hold before whole-Test inversion')
        if ordinal_counts != (1, 1):
            return
        self.assertEqual(strip_projection(projected), ORIGINAL)
        loop = (b'      for (ordinal, (urls, query, replacement, limits)) '
                b'in requestCases.enumerated() {\n')
        ordinary_loop = b'      for (urls, query, replacement, limits) in requestCases {\n'
        array_start = ORIGINAL.index(b'      let requestCases:')
        loop_start = ORIGINAL.index(ordinary_loop, array_start)
        array = ORIGINAL[array_start:loop_start]
        self.assertIn(array + matches[9][0] + loop + matches[10][0]
                      + b'        FileHandle.standardError.write(Data("CI_FOLDER_PREVIEW_PATH s=0\\n".utf8))\n'
                      + b'        let reader = ControlledReader()\n'
                      + b'        FileHandle.standardError.write(Data("CI_FOLDER_PREVIEW_PATH s=1\\n".utf8))\n', projected)
        self.assertIn(b'builder: .init(reader: reader, diagnosticTrace: ordinal == 10)', projected)
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
        project_core = getattr(runner, 'project_core', None)
        self.assertTrue(callable(project_core), 'Missing Core projection API; dependent assertions UNENTERED')
        if not callable(project_core):
            return
        if not self._require_ordinal_projection():
            return
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
        project_core = getattr(runner, 'project_core', None)
        self.assertTrue(callable(project_core), 'Missing Core projection API; dependent assertions UNENTERED')
        if not callable(project_core):
            return
        if not self._require_ordinal_projection():
            return
        parse_trace = getattr(runner, 'parse_trace', None)
        self.assertTrue(callable(parse_trace), 'Missing trace parser API; dependent checks UNENTERED')
        if not callable(parse_trace):
            return
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
        self.assertEqual(len(events), 381, 'Golden stream includes source-derived ordinal-11 Core path')
        self.assertEqual(sum(event[0] == 'outer' for event in events), 42)
        self.assertEqual(sum(event[0] == 'path' for event in events), 314)
        self.assertEqual(sum(event[0] == 'core' for event in events), 25,
                         '25 is the normal predicted branch, not the only legal Core trace')
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
        complete = parse_trace(b'', trace())
        self.assertEqual(complete, dict(phase=9, edge=1, records=42, horizon='all-intervals-ended',
            pathStage=5, requestOrdinal=None, pathRecords=314, pathHorizon='all-helpers-ended',
            coreStage=9, coreRole='none', coreRecords=25, coreHorizon='builder-left'))
        stages = (0, 1, 2, 6, 7, 8, 9, 10, 3, 4, 5)
        for offset, stage in enumerate(stages, start=1):
            actual = parse_trace(b'', path_prefix(11, stage))
            horizon = ('helper-ended' if stage == 10 else
                       'assertion-returned' if stage == 5 else 'observed-prefix')
            self.assertEqual(actual, dict(phase=5, edge=0, records=31,
                horizon='entered-without-end', pathStage=stage, requestOrdinal=11,
                pathRecords=236 + offset, pathHorizon=horizon,
                coreStage=(9 if stage in (8, 9, 10, 3, 4, 5) else -1),
                coreRole='none', coreRecords=(25 if stage in (8, 9, 10, 3, 4, 5) else 0),
                coreHorizon=('builder-left' if stage in (8, 9, 10, 3, 4, 5) else 'not-entered')),
                'Each literal NUL-request subinterval must retain ordinal eleven')
        missing_handler_events = expected_events(missing_request_handlers=(11,))
        missing = parse_trace(b'', trace(missing_request_handlers=(11,)))
        self.assertEqual(missing, dict(phase=9, edge=1, records=42, horizon='all-intervals-ended',
            pathStage=5, requestOrdinal=None, pathRecords=312, pathHorizon='assertion-returned',
            coreStage=9, coreRole='none', coreRecords=25, coreHorizon='builder-left'),
            'Missing XCTest handler markers describe the observed missing-throw path, not success')
        selected_normal = path_prefix(11, 10)
        selected_without_handler = path_prefix(11, 5, missing_request_handlers=(11,))
        self.assertEqual(selected_without_handler,
                         selected_normal + b'CI_FOLDER_PREVIEW_PATH s=5\n')
        self.assertEqual(parse_trace(b'', selected_without_handler),
            dict(phase=5, edge=0, records=31, horizon='entered-without-end', pathStage=5,
                 requestOrdinal=11, pathRecords=245, pathHorizon='assertion-returned',
                 coreStage=9, coreRole='none', coreRecords=25, coreHorizon='builder-left'))
        self.assertEqual(sum(event[0] == 'path' for event in missing_handler_events), 312)

    # Break caught: reordered unwind, split custody, partial tags, foreign IDs, or unbounded records accepted.
    def test_nested_order_custody_partial_foreign_and_cap_refusals(self):
        project_core = getattr(runner, 'project_core', None)
        self.assertTrue(callable(project_core), 'Missing Core projection API; dependent assertions UNENTERED')
        if not callable(project_core):
            return
        if not self._require_ordinal_projection():
            return
        parse_trace = getattr(runner, 'parse_trace', None)
        self.assertTrue(callable(parse_trace), 'Missing trace parser API; dependent checks UNENTERED')
        if not callable(parse_trace):
            return
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
                parse_trace(b'', raw)
        stdout_outer = b''.join(record for event, record in zip(events, records) if event[0] == 'outer')
        stderr_inner = b''.join(record for event, record in zip(events, records) if event[0] == 'path')
        for stdout, stderr in ((stdout_outer, stderr_inner), (stderr_inner, stdout_outer),
                               (trace(1), trace(1))):
            with self.subTest(stdout_bytes=len(stdout), stderr_bytes=len(stderr)), self.assertRaises(ValueError):
                parse_trace(stdout, stderr)

    # Break caught: Core projection drift, incomplete inverse, or tracing outside ordinal 11.
    def test_dual_projection_inverse_gating_and_source_drift(self):
        project_core = getattr(runner, 'project_core', None)
        self.assertTrue(callable(project_core), 'Missing Core projection API; Core checks UNENTERED')
        if not callable(project_core):
            return
        project_test = getattr(runner, 'project_test', None)
        self.assertTrue(callable(project_test), 'Missing Test projection API; source checks UNENTERED')
        if not callable(project_test):
            return
        core_projected = project_core(ORIGINAL_CORE)
        self.assertIsInstance(core_projected, bytes, 'Missing Core projection bytes; inverse UNENTERED')
        if not isinstance(core_projected, bytes):
            return
        self.assertEqual(strip_core_projection(core_projected), ORIGINAL_CORE,
                         'Independent Core inverse must recover the whole frozen source')
        protected_mutations = (
            (b'maxMatches: limits.maxMatches - matchCount',
             b'maxMatches: limits.maxMatches - matchCount - 1'),
            (b'decoded.utf8.count <= 4_096', b'decoded.utf8.count <= 4_095'),
            (b'guard url.isFileURL else { return false }',
             b'guard url.isFileURL else { return true }'),
            (b'guard url.host == nil || url.host == "" || url.host == "localhost" '
             b'else { return false }',
             b'guard url.host == nil || url.host == "" || url.host == "localhost" '
             b'else { return true }'),
            (b'return true\n      }', b'return false\n      }'),
        )
        for original_statement, changed_statement in protected_mutations:
            self.assertEqual(core_projected.count(original_statement), 1,
                             'Protected source mutation anchor must be unique')
            mutated = core_projected.replace(original_statement, changed_statement, 1)
            self.assertNotEqual(mutated, core_projected)
            with self.subTest(protected=original_statement), self.assertRaises(ValueError):
                strip_core_projection(mutated)
        core_codes = [int(match[1]) for match in CORE_CALL.finditer(core_projected)]
        self.assertEqual(sorted(core_codes), sorted(
            [0, 9, 1, 2, 3, 4, 5, 6, 7, 10, 24, 12, 13, 14, 15,
             16, 17, 18, 19, 20, 21, 22, 23]))
        for match in CORE_CALL.finditer(core_projected):
            line_start = core_projected.rfind(b'\n', 0, match.start()) + 1
            previous_start = core_projected.rfind(b'\n', 0, line_start - 1) + 1
            previous_line = core_projected[previous_start:line_start].strip()
            self.assertEqual(previous_line, b'if diagnosticTrace {',
                             'Every fixed Core write stays behind the immutable false-by-default flag')

        test_projected = project_test(ORIGINAL)
        self.assertIsInstance(test_projected, bytes, 'Missing Test projection bytes; inverse UNENTERED')
        if not isinstance(test_projected, bytes):
            return
        ordinal_counts = (test_projected.count(b'requestCases.enumerated()'),
                          test_projected.count(b'diagnosticTrace: ordinal == 10'))
        self.assertEqual(ordinal_counts, (1, 1),
                         'Ordinal projection premise must hold before whole-Test inversion')
        if ordinal_counts != (1, 1):
            return
        self.assertEqual(strip_projection(test_projected), ORIGINAL,
                         'Independent Test inverse must recover the whole selected fixture')
        self.assertEqual(projection_counts(test_projected), (20, 11))
        self.assertEqual(test_projected.count(b'requestCases.enumerated()'), 1)
        self.assertEqual(test_projected.count(b'diagnosticTrace: ordinal == 10'), 1,
                         'Only the fixed eleventh request receives the immutable diagnostic flag')
        self.assertNotIn(b'url.absoluteString', test_projected,
                         'The Test loop may not inspect a URL to decide whether to trace')

        changed_core = ORIGINAL_CORE.replace(b'url.host == "localhost"',
                                             b'url.host == "changed.example"', 1)
        self.assertNotEqual(changed_core, ORIGINAL_CORE)
        with self.assertRaises(ValueError):
            project_core(changed_core)
        changed_test = ORIGINAL.replace(b'for (urls, query, replacement, limits) in requestCases {',
                                        b'for (urls, query, replacement, limits) in requestCases.reversed() {', 1)
        self.assertNotEqual(changed_test, ORIGINAL)
        with self.assertRaises(ValueError):
            project_test(changed_test)

    # Break caught: invalid Core finite-state branches, early prefix, stream split, or loose cap.
    def test_core_fsm_prefix_branches_malformed_streams_and_caps(self):
        project_core = getattr(runner, 'project_core', None)
        self.assertTrue(callable(project_core), 'Missing Core API; FSM checks UNENTERED')
        if not callable(project_core):
            return
        parse_trace = getattr(runner, 'parse_trace', None)
        self.assertTrue(callable(parse_trace), 'Missing trace parser; FSM checks UNENTERED')
        if not callable(parse_trace):
            return
        projected = runner.project_test(ORIGINAL)
        self.assertIsInstance(projected, bytes, 'Missing Test projection; FSM premises UNENTERED')
        if not isinstance(projected, bytes):
            return
        events = expected_events()
        path7 = next(i for i, event in enumerate(events)
                     if event == _path(7, 11))
        path8 = next(i for i, event in enumerate(events)
                     if event == _path(8, 11))
        self.assertEqual(events[path7 + 1:path8], list(CORE_NUL_EVENTS),
                         'Request 11 Core markers must be nested between PATH 7 and PATH 8')
        core_positions = [i for i in range(path7 + 1, path8) if events[i][0] == 'core']
        for end in core_positions:
            prefix = events[:end + 1]
            self.assertEqual(parse_trace(b'', b''.join(_record(event) for event in prefix)),
                             _closed_report(prefix),
                             'Every proper source-ordered Core prefix has one closed report')

        # PATH 7 with no Core 0 is an unobserved body-entry prefix; PATH 8 requires closure.
        no_body = events[:path7 + 1]
        body_unobserved = parse_trace(b'', b''.join(_record(event) for event in no_body))
        self.assertEqual(body_unobserved, _closed_report(no_body))
        self.assertEqual((body_unobserved['coreStage'], body_unobserved['coreRole'],
                          body_unobserved['coreRecords'], body_unobserved['coreHorizon']),
                         (-1, 'none', 0, 'not-entered'))
        no_core_complete = [event for event in events if event[0] != 'core']
        with self.assertRaises(ValueError):
            parse_trace(b'', b''.join(_record(event) for event in no_core_complete))

        # Guard exits before entering either valid call remain legal closed builder prefixes.
        for stages in ((0, 9), (0, 1, 9),
                       (0, 1, 2, 3, 10, 20, 21, 22, 24, 9)):
            branch = [_core(stage) for stage in stages]
            alternate = events[:path7 + 1] + branch + events[path8:]
            self.assertEqual(parse_trace(b'', b''.join(_record(event) for event in alternate)),
                             _closed_report(alternate))

        records = [_record(event) for event in events]
        core_start, core_end = core_positions[0], core_positions[-1]
        malformed = []
        reordered = list(records)
        reordered[core_start], reordered[core_start + 1] = reordered[core_start + 1], reordered[core_start]
        malformed.append(b''.join(reordered))
        duplicated = list(records)
        duplicated.insert(core_start + 1, duplicated[core_start])
        malformed.append(b''.join(duplicated))
        missing_valid_exit = list(records)
        del missing_valid_exit[core_end - 1]
        malformed.append(b''.join(missing_valid_exit))
        malformed.extend([
            b''.join(records) + b'CI_FOLDER_PREVIEW_CORE s=',
            b''.join(records) + b'CI_FOLDER_PREVIEW_CORE s=25\n',
            b''.join(records) + b'CI_FOLDER_PREVIEW_CORE s=0\n',
            b'CI_FOLDER_PREVIEW_CORE s=0\n' + b''.join(records),
            b'CI_FOLDER_PREVIEW_CORE s=0\n' * 65,
            b'CI_FOLDER_PREVIEW_CORE s=0\n' * 513,
        ])
        for raw in malformed:
            with self.subTest(size=len(raw)), self.assertRaises(ValueError):
                parse_trace(b'', raw)
        # A legal Core line split to the other capture stream still violates common custody.
        before = b''.join(records[:core_start])
        core_line = records[core_start]
        after = b''.join(records[core_start + 1:])
        with self.assertRaises(ValueError):
            parse_trace(before + after, core_line)

    # Break caught: open report keys, missing Core renderer line, custody drift, or raw leakage.
    def test_core_renderer_closed_ascii_custody_and_dual_input_inventory(self):
        project_core = getattr(runner, 'project_core', None)
        self.assertTrue(callable(project_core), 'Missing Core API; custody checks UNENTERED')
        if not callable(project_core):
            return
        render = getattr(runner, 'render', None)
        self.assertTrue(callable(render), 'Missing renderer API; closed-field checks UNENTERED')
        if not callable(render):
            return
        parse_trace = getattr(runner, 'parse_trace', None)
        self.assertTrue(callable(parse_trace), 'Missing parser API; renderer checks UNENTERED')
        if not callable(parse_trace):
            return
        result_trace = parse_trace(b'', trace())
        self.assertEqual(set(result_trace), {
            'phase', 'edge', 'records', 'horizon', 'pathStage', 'requestOrdinal',
            'pathRecords', 'pathHorizon', 'coreStage', 'coreRole', 'coreRecords', 'coreHorizon'})
        self.assertEqual(result_trace, _closed_report(expected_events()))
        state = self.frozen()
        if state is None:
            return
        root, run, _, plan, manifest = state
        capture = manifest['capture']
        projection = capture['projection']
        self.assertEqual(projection['target'], TARGET)
        self.assertEqual(projection['originalSHA256'], hashlib.sha256(ORIGINAL).hexdigest())
        self.assertEqual(projection['coreTarget'], CORE_TARGET)
        self.assertEqual(projection['coreOriginalSHA256'], hashlib.sha256(ORIGINAL_CORE).hexdigest())
        self.assertEqual(plan['inputs'][CORE_TARGET], 'Project/' + CORE_TARGET)
        originals = {row['path']: row for row in capture['originals']}
        copies = {row['path']: row for row in capture['copies']}
        self.assertEqual(originals[CORE_TARGET]['sha256'], hashlib.sha256(ORIGINAL_CORE).hexdigest())
        self.assertEqual(originals[TARGET]['sha256'], hashlib.sha256(ORIGINAL).hexdigest())
        self.assertEqual(copies['Project/' + CORE_TARGET]['sha256'], projection['coreProjectedSHA256'])
        self.assertEqual(copies['Project/' + TARGET]['sha256'], projection['projectedSHA256'])

        secret = b'CORE raw synthetic URL, exception text, and document bytes must never render\n'
        watch = ControlledWatchdog(secret + trace(), stdout=b'private source details\n', exit_code=1)
        result = runner.execute(root, run, plan, manifest, watch)
        self.assertEqual(result['state'], 'observed')
        if result['state'] != 'observed':
            return
        self.assertEqual(result['trace'], result_trace)
        forged_reports = []
        for key, value in [('coreStage', 8), ('coreRole', 'foreign'),
                           ('coreHorizon', 'future-state')]:
            forged = dict(result)
            forged_trace = dict(result['trace'])
            forged_trace[key] = value
            forged['trace'] = forged_trace
            forged_reports.append(forged)
        forged_unknown = dict(result)
        forged_trace = dict(result['trace'])
        forged_trace['unreviewed'] = 1
        forged_unknown['trace'] = forged_trace
        forged_reports.append(forged_unknown)
        for forged in forged_reports:
            with self.subTest(trace=forged['trace']), self.assertRaises(ValueError):
                render(forged)
        output = render(result)
        self.assertEqual(len(output), 5)
        self.assertTrue(any(line.startswith('core: stage=9 role=none horizon=builder-left records=')
                            for line in output))
        rendered = '\n'.join(output) + '\n'
        self.assertLessEqual(len(rendered.encode('ascii')), 512)
        for forbidden in (secret.decode().strip(), 'private source details', 'url.absoluteString',
                          'FolderReplacementPathPolicy', CORE_TARGET, TARGET):
            self.assertNotIn(forbidden, rendered)
        self.assertEqual(len(watch.calls), 1)
        self.assertEqual(watch.calls[0][watch.calls[0].index('--timeout') + 1], '600')
        copied_core = run / 'Project' / CORE_TARGET
        copied_core.write_bytes(copied_core.read_bytes() + b'// post-freeze drift\n')
        with self.assertRaises(ValueError):
            runner.verify_inputs(root, run, manifest)
        retained = run / 'stage'
        self.assertTrue(retained.exists(), 'Failure/source custody remains owned after refusal')


if __name__ == '__main__':
    unittest.main()
