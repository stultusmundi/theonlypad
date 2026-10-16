"""Fixed same-method CI diagnostic; observations never replace the original core failure."""
from pathlib import Path
import contextlib
import hashlib
import importlib.util
import json
import math
import os
import re
import stat
import sys
import tempfile

TARGET = 'Tests/PadCoreTests/FolderReplacementPreviewTests.swift'
LOCATION = 'scripts/ci_folder_preview_trace.py'
SELECTOR = r'^PadCoreTests\.FolderReplacementPreviewTests/testAdmissionAndBudgetsRejectBeforeExpensiveWork$'
WATCH = 'scripts/run-owned-search-tests.py'
VERIFIER = 'Tests/NativeIntegration/run_native_regressions.py'
WATCH_SHA = 'd5bd867e4a65b4ee053209fe0a5822867b8d0878fd6d059f474c9b28a0f6286d'
VERIFIER_SHA = 'f4435e99ad7a547a90d01ce38c094d0813fac797a443a0e33654cce6b5ea9cef'
TAG = b'CI_FOLDER_PREVIEW_TRACE'
SEQUENCE = [(phase, edge) for phase in range(5) for edge in range(2)]
RECEIPT_FIELDS = set(('command pid processGroup exitObserved registrationError groupSignalAttempted '
    'groupSignalError groupCleanup groupQuery waitCompleted returnCode waitError timedOut '
    'interruptedSignal truncated captureComplete captured failure exit seconds').split())


def _require(value):
    if not value:
        raise ValueError('diagnostic evidence refused')


def _owned(root, path, directory=False):
    root, path = Path(root).absolute(), Path(path).absolute()
    _require(path.is_relative_to(root) and '..' not in path.parts)
    for item in [root, *[root.joinpath(*path.relative_to(root).parts[:i])
                        for i in range(1, len(path.relative_to(root).parts) + 1)]]:
        info = item.lstat()
        _require(not stat.S_ISLNK(info.st_mode) and info.st_uid == os.geteuid())
        _require(stat.S_ISDIR(info.st_mode) if item != path or directory else stat.S_ISREG(info.st_mode))
    return path


def _fact(root, path, cap=None):
    path = _owned(root, path)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        _require(stat.S_ISREG(before.st_mode) and before.st_uid == os.geteuid())
        _require(cap is None or before.st_size <= cap)
        # Bound growth detection to the initial size plus one byte. Never chase growth.
        chunks, remaining = [], before.st_size + 1
        while remaining:
            block = os.read(fd, min(65536, remaining))
            if not block:
                break
            chunks.append(block)
            remaining -= len(block)
        raw = b''.join(chunks)
        after, named = os.fstat(fd), path.lstat()
        keys = ('st_dev', 'st_ino', 'st_uid', 'st_mode', 'st_size', 'st_mtime_ns', 'st_ctime_ns')
        _require(all(getattr(before, key) == getattr(after, key) == getattr(named, key) for key in keys))
        _require(len(raw) == after.st_size)
        _owned(root, path)
        return dict(path=path.relative_to(Path(root).absolute()).as_posix(), bytes=len(raw),
                    sha256=hashlib.sha256(raw).hexdigest(), device=after.st_dev, inode=after.st_ino,
                    uid=after.st_uid, mode=stat.S_IMODE(after.st_mode)), raw
    finally:
        os.close(fd)


def _directory(root, path):
    path = _owned(root, path, directory=True)
    info = path.lstat()
    return dict(path=path.relative_to(Path(root).absolute()).as_posix(), device=info.st_dev,
                inode=info.st_ino, uid=info.st_uid, mode=stat.S_IMODE(info.st_mode))


def _json(raw):
    def unique(pairs):
        value = {}
        for key, item in pairs:
            _require(key not in value)
            value[key] = item
        return value
    return json.loads(raw, object_pairs_hook=unique)


def _save(path, value):
    with Path(path).open('x', encoding='ascii') as stream:
        json.dump(value, stream, ensure_ascii=True, indent=2)
        stream.write('\n')


def _mkdir(root, path):
    root, path = Path(root).absolute(), Path(path).absolute()
    _owned(root, root, True)
    _require(path.is_relative_to(root) and '..' not in path.parts)
    for i in range(1, len(path.relative_to(root).parts) + 1):
        item = root.joinpath(*path.relative_to(root).parts[:i])
        if not item.exists():
            item.mkdir(mode=0o700)
        _owned(root, item, True)
        _require(stat.S_IMODE(item.lstat().st_mode) == 0o700)


def validate_cli(argv):
    _require(argv == [])


def _marker(phase, edge, indent):
    return (b' ' * indent + b'FileHandle.standardError.write(Data("CI_FOLDER_PREVIEW_TRACE p='
            + str(phase).encode('ascii') + b' e=' + str(edge).encode('ascii') + b'\\n".utf8))\n')


def project_test(original):
    _require(type(original) is bytes and TAG not in original)
    head = b'  func testAdmissionAndBudgetsRejectBeforeExpensiveWork() throws {\n'
    next_method = b'  func testSecondReadFailureReturnsNoPartialPreviewAndLeavesSourcesBackups() throws {\n'
    _require(original.count(head) == original.count(next_method) == 1)
    start, end = original.index(head), original.index(next_method)
    _require(start < end)
    method = original[start:end]
    entry = head + b'    try withFixture { fixture in\n'
    invalid = b'      let invalidLimits: [FolderReplacementPreviewLimits] = [\n'
    loop = (b'      for limits in invalidLimits {\n'
            b'        let reader = ControlledReader()\n'
            b'        assertError(.invalidLimits) {\n'
            b'          try preview(fixture, builder: .init(reader: reader), limits: limits)\n'
            b'        }\n'
            b'        XCTAssertEqual(reader.rootCalls, 0)\n'
            b'        XCTAssertEqual(reader.fileCalls, 0)\n'
            b'      }\n\n')
    long_url = (b'      let longPath = URL(\n'
                b'        fileURLWithPath: fixture.root.path + "/" + String(repeating: "p", count: 4097))\n')
    nul_url = b'      let nulPath = URL(fileURLWithPath: fixture.root.path + "/nul\\u{0}name")\n'
    requests = b'      let requestCases: [([URL], SearchQuery, String, FolderReplacementPreviewLimits)] = [\n'
    suffix = (b'      assertError(.sourceLimit) { try preview(fixture, urls: [fixture.a]) }\n'
              b'    }\n'
              b'  }\n\n'
              b'  // Catches returning the first result after later file I/O or selected-content rejection.\n')
    for anchor in (entry + invalid, loop + long_url + nul_url + requests, suffix):
        _require(method.count(anchor) == 1)
    _require(method.startswith(entry + invalid) and method.endswith(suffix))
    modified = method.replace(entry, head + _marker(0, 0, 4)
        + b'    try withFixture { fixture in\n' + _marker(0, 1, 6) + _marker(1, 0, 6), 1)
    modified = modified.replace(loop + long_url + nul_url + requests,
        loop + _marker(1, 1, 6) + _marker(2, 0, 6) + long_url
        + _marker(2, 1, 6) + _marker(3, 0, 6) + nul_url
        + _marker(3, 1, 6) + _marker(4, 0, 6) + requests, 1)
    final = suffix.replace(b'    }\n  }\n', b'    }\n' + _marker(4, 1, 4) + b'  }\n', 1)
    modified = modified.replace(suffix, final, 1)
    projected = original[:start] + modified + original[end:]
    inverse = projected
    for phase, edge in SEQUENCE:
        statement = _marker(phase, edge, 4 if (phase, edge) in ((0, 0), (4, 1)) else 6)
        _require(inverse.count(statement) == 1)
        inverse = inverse.replace(statement, b'', 1)
    _require(inverse == original and projected.count(TAG) == 10)
    return projected


def parse_trace(stdout, stderr):
    _require(type(stdout) is bytes and type(stderr) is bytes)
    sequence = []
    marker_stream = None
    for stream, raw in (('stdout', stdout), ('stderr', stderr)):
        for line in raw.splitlines(keepends=True):
            stripped = line.strip()
            potential = TAG in line or (bool(stripped) and TAG.startswith(stripped))
            if not potential:
                continue
            _require(marker_stream is None or marker_stream == stream)
            marker_stream = stream
            match = re.fullmatch(rb'CI_FOLDER_PREVIEW_TRACE p=([0-4]) e=([01])\n', line)
            _require(match is not None and len(sequence) < 10)
            pair = (int(match[1]), int(match[2]))
            _require(pair == SEQUENCE[len(sequence)])
            sequence.append(pair)
    if not sequence:
        return dict(phase=None, edge=None, records=0, horizon='not-observed')
    phase, edge = sequence[-1]
    horizon = 'all-intervals-ended' if len(sequence) == 10 else (
        'entered-without-end' if edge == 0 else 'completed-interval')
    return dict(phase=phase, edge=edge, records=len(sequence), horizon=horizon)


def _inventory(root):
    root = Path(root).absolute()
    files, excluded = set(), []
    for name in ('Sources', 'Tests', 'Examples'):
        base = _owned(root, root / name, True)
        for path in sorted(base.rglob('*')):
            if path.is_dir():
                _owned(root, path, True)
            else:
                _owned(root, path)
                relative = path.relative_to(root).as_posix()
                if name == 'Tests' and '__pycache__' in path.relative_to(base).parts and path.suffix == '.pyc':
                    excluded.append(relative)
                else:
                    files.add(relative)
    for relative in ('Package.swift', 'scripts/swift.sh', WATCH, VERIFIER, LOCATION):
        _owned(root, root / relative)
        files.add(relative)
    _require(TARGET in files)
    return sorted(files), sorted(excluded)


def _command(run):
    return ['/usr/bin/env', 'NSUnbufferedIO=YES',
        'THEONLYPAD_STATE_DIRECTORY=' + str(run / 'State'), 'TMPDIR=' + str(run / 'Temporary') + '/',
        str(run / 'Project/scripts/swift.sh'), 'test', '--scratch-path', str(run / 'BuildProducts'),
        '--filter', SELECTOR]


def make_plan(root, run):
    root, run = Path(root).absolute(), Path(run).absolute()
    _owned(root, root, True)
    _owned(run, run, True)
    paths, excluded = _inventory(root)
    _require(_fact(root, root / WATCH)[0]['sha256'] == WATCH_SHA)
    _require(_fact(root, root / VERIFIER)[0]['sha256'] == VERIFIER_SHA)
    mapping = {name: 'Project/' + name for name in paths
               if name.startswith(('Sources/', 'Tests/', 'Examples/'))
               or name in ('Package.swift', 'scripts/swift.sh')}
    tools = {WATCH: 'Tools/run-owned-search-tests.py', VERIFIER: 'Tools/run_native_regressions.py',
             LOCATION: 'Tools/ci_folder_preview_trace.py'}
    _require(len({name.casefold() for name in [*mapping.values(), *tools.values()]})
             == len(mapping) + len(tools))
    return dict(selector=SELECTOR, watchdogTimeout=600, command=_command(run),
                inputs=mapping, tools=tools, originals=paths, excludedGeneratedPyc=excluded)


def freeze(root, run, plan):
    root, run = Path(root).absolute(), Path(run).absolute()
    _require(make_plan(root, run) == plan)
    buffers, originals, copies = {}, [], []
    for relative in plan['originals']:
        row, data = _fact(root, root / relative)
        buffers[relative] = data
        originals.append(row)
    _require(originals == [_fact(root, root / row['path'])[0] for row in originals])
    projected = project_test(buffers[TARGET])
    for relative, destination in [*plan['inputs'].items(), *plan['tools'].items()]:
        target = run / destination
        _mkdir(run, target.parent)
        data = projected if relative == TARGET else buffers[relative]
        with target.open('xb') as stream:
            stream.write(data)
        target.chmod(stat.S_IMODE((root / relative).lstat().st_mode))
        copies.append(_fact(run, target)[0])
    for name in ('State', 'Temporary'):
        _mkdir(run, run / name)
    directories = {root}
    for relative in plan['originals']:
        directories.update(p for p in (root / relative).parents if p.is_relative_to(root))
    captured = dict(plan=json.loads(json.dumps(plan)), originals=originals, copies=copies,
        originalDirectories=[_directory(root, p) for p in sorted(directories)],
        ownedDirectories=[_directory(run, run / name) for name in ('.', 'Project', 'Tools', 'State', 'Temporary')],
        projection=dict(target=TARGET, originalSHA256=hashlib.sha256(buffers[TARGET]).hexdigest(),
                        projectedSHA256=hashlib.sha256(projected).hexdigest(), records=10))
    _save(run / 'inputs.json', captured)
    manifest = dict(capture=captured, authority=_fact(run, run / 'inputs.json')[0])
    verify_inputs(root, run, manifest)
    return manifest


def verify_inputs(root, run, manifest):
    root, run = Path(root).absolute(), Path(run).absolute()
    captured = manifest['capture']
    authority, raw = _fact(run, run / 'inputs.json')
    _require(authority == manifest['authority'] and _json(raw) == captured)
    _require(make_plan(root, run) == captured['plan'])
    for row in captured['originalDirectories']:
        _require(_directory(root, root / row['path']) == row)
    for row in captured['ownedDirectories']:
        _require(_directory(run, run / row['path']) == row)
    originals = {}
    for row in captured['originals']:
        current, raw = _fact(root, root / row['path'])
        _require(current == row)
        originals[row['path']] = raw
    for row in captured['copies']:
        current, raw = _fact(run, run / row['path'])
        _require(current == row)
    for relative, destination in [*captured['plan']['inputs'].items(), *captured['plan']['tools'].items()]:
        expected = project_test(originals[relative]) if relative == TARGET else originals[relative]
        _require(_fact(run, run / destination)[1] == expected)
    # Check complete frozen input trees, including unknown files and symlink directories.
    expected = {row['path'] for row in captured['copies']}
    for name in ('Project', 'Tools'):
        actual = set()
        for path in (run / name).rglob('*'):
            relative = path.relative_to(run).as_posix()
            # The fixed Swift wrapper owns only this compiler-cache subtree.
            if name == 'Project' and relative.startswith('Project/.cache/'):
                continue
            if path.is_dir():
                _owned(run, path, True)
            else:
                _owned(run, path)
                actual.add(relative)
        _require(actual == {p for p in expected if p.startswith(name + '/')})
    for row in captured['originals']:
        _require(_fact(root, root / row['path'])[0] == row)


def _load_module(run, path, name, expected):
    before, _ = _fact(run, path)
    _require(before['sha256'] == expected)
    spec = importlib.util.spec_from_file_location(name, path)
    _require(spec is not None and spec.loader is not None)
    module = importlib.util.module_from_spec(spec)
    prior = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        sys.modules[name] = module
        spec.loader.exec_module(module)
    finally:
        sys.dont_write_bytecode = prior
    _require(_fact(run, path)[0] == before)
    return module


def execute(root, run, plan, manifest, watchdog_main):
    root, run = Path(root).absolute(), Path(run).absolute()
    unavailable = dict(state='unavailable')
    try:
        verify_inputs(root, run, manifest)
        _require(plan == manifest['capture']['plan'] == make_plan(root, run))
        _require(callable(watchdog_main))
        output = run / 'stage'
        _require(not output.exists() and not output.is_symlink())
        _save(run / 'command.json', dict(command=plan['command'], timeout=600))
        command_fact = _fact(run, run / 'command.json')[0]
        verifier = _load_module(run, run / 'Tools/run_native_regressions.py',
                                'folder_trace_verifier', VERIFIER_SHA)
        # The accepted watchdog prints its own control summary. Retain it privately
        # so the only CI output remains this diagnostic's closed three-line projection.
        with (run / 'watchdog-control.stdout.log').open('x') as control_out, \
                (run / 'watchdog-control.stderr.log').open('x') as control_err:
            with contextlib.redirect_stdout(control_out), contextlib.redirect_stderr(control_err):
                code = watchdog_main(['--timeout', '600', '--output', str(output), '--', *plan['command']])
        _require(_fact(run, run / 'command.json')[0] == command_fact)
        verify_inputs(root, run, manifest)
        _owned(run, output, True)
        _require({p.name for p in output.iterdir()} == {'status.json', 'stdout.log', 'stderr.log'})
        receipt_fact, raw = _fact(run, output / 'status.json', 32768)
        receipt = _json(raw)
        _require(type(receipt) is dict and set(receipt) == RECEIPT_FIELDS)
        _require(type(receipt['seconds']) in (int, float) and math.isfinite(receipt['seconds'])
                 and receipt['seconds'] >= 0)
        _require(type(code) is int and 0 <= code < 256)
        _require(type(receipt['captured']) is dict and set(receipt['captured']) == {'stdout', 'stderr'})
        for counts in receipt['captured'].values():
            _require(type(counts) is dict and set(counts) == {'received', 'stored', 'discarded'})
        stdout_fact, stdout = _fact(run, output / 'stdout.log', 1048576)
        stderr_fact, stderr = _fact(run, output / 'stderr.log', 1048576)
        _require(verifier.receipt_success(output, plan['command'], code))
        for row in (receipt_fact, stdout_fact, stderr_fact):
            _require(_fact(run, run / row['path'])[0] == row)
        _require(_fact(run, run / 'command.json')[0] == command_fact)
        verify_inputs(root, run, manifest)
        trace = parse_trace(stdout, stderr)
        original_after = [_fact(root, root / row['path'])[0] for row in manifest['capture']['originals']]
        copy_after = [_fact(run, run / row['path'])[0] for row in manifest['capture']['copies']]
        _require(original_after == manifest['capture']['originals']
                 and copy_after == manifest['capture']['copies'])
        for row in (receipt_fact, stdout_fact, stderr_fact, command_fact):
            _require(_fact(run, run / row['path'])[0] == row)
        return dict(state='observed' if trace['records'] else 'not-observed',
                    ownedExit=receipt['exit'], ownedReturnCode=receipt['returnCode'],
                    signalObservation='not-observed-for-selected-test', trace=trace,
                    evidence=dict(inputAuthority=manifest['authority'], command=command_fact,
                                  captures=[receipt_fact, stdout_fact, stderr_fact],
                                  originalAfter=original_after, copyAfter=copy_after))
    except (OSError, ValueError, TypeError, KeyError, AttributeError, RuntimeError, ImportError):
        return unavailable


def render(result):
    unavailable = ['ci-folder-preview-trace: unavailable', 'reason: incomplete-evidence']
    try:
        state, trace = result['state'], result['trace']
        _require(state in ('observed', 'not-observed'))
        records = trace['records']
        _require(type(records) is int and 0 <= records <= 10)
        if records:
            phase, edge = SEQUENCE[records - 1]
            horizon = 'all-intervals-ended' if records == 10 else ('entered-without-end' if edge == 0 else 'completed-interval')
        else:
            phase, edge, horizon = None, None, 'not-observed'
        _require(trace == dict(phase=phase, edge=edge, records=records, horizon=horizon))
        _require(state == ('observed' if records else 'not-observed'))
        _require(result['signalObservation'] == 'not-observed-for-selected-test')
        for key in ('ownedExit', 'ownedReturnCode'):
            _require(type(result[key]) is int and 0 <= result[key] < 256)
        _require(result['ownedExit'] == result['ownedReturnCode'])
        lines = ['ci-folder-preview-trace: ' + state,
            'trace: phase=' + str(-1 if phase is None else phase) + ' edge=' + str(-1 if edge is None else edge)
            + ' horizon=' + horizon + ' records=' + str(records),
            'owned: exit=' + str(result['ownedExit']) + ' returnCode=' + str(result['ownedReturnCode'])
            + ' signal=not-observed-for-selected-test']
        _require(len(('\n'.join(lines) + '\n').encode('ascii')) <= 512)
        return lines
    except (ValueError, TypeError, KeyError, AttributeError, UnicodeError):
        return unavailable


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    try:
        validate_cli(argv)  # No files, imports or child work precede closed admission.
        os.umask(0o077)
        path = Path(__file__).absolute()
        root = path.parents[1]
        _require(path == root / LOCATION)
        _owned(root, path)
        local = root / '.local'
        if not local.exists():
            local.mkdir(mode=0o700)
        _owned(root, local, True)  # Preserve an existing shared ignored parent's mode.
        parent = local / 'ci-folder-preview-trace'
        _mkdir(local, parent)
        run = Path(tempfile.mkdtemp(prefix='run.', dir=parent))
        run.chmod(0o700)
        plan = make_plan(root, run)
        manifest = freeze(root, run, plan)
        watchdog = _load_module(run, run / 'Tools/run-owned-search-tests.py',
                                'folder_trace_watchdog', WATCH_SHA)
        result = execute(root, run, plan, manifest, watchdog.main)
        _save(run / 'result.json', result)
    except (OSError, ValueError, TypeError, KeyError, AttributeError, RuntimeError, ImportError):
        result = dict(state='unavailable')
    print('\n'.join(render(result)))
    return 0 if result.get('state') in ('observed', 'not-observed') else 125


if __name__ == '__main__':
    raise SystemExit(main())
