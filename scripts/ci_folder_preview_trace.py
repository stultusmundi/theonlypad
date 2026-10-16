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
CORE_TARGET = 'Sources/PadCore/FolderReplacementPreview.swift'
CORE_SHA256 = '0c10c4653524bd032d649b5eb611b5253ab2b2c5fecf32166e24d705c76fd3bc'
CORE_TAG = b'CI_FOLDER_PREVIEW_CORE'
CORE_RECORD_LIMIT = 64
LOCATION = 'scripts/ci_folder_preview_trace.py'
SELECTOR = r'^PadCoreTests\.FolderReplacementPreviewTests/testAdmissionAndBudgetsRejectBeforeExpensiveWork$'
WATCH = 'scripts/run-owned-search-tests.py'
VERIFIER = 'Tests/NativeIntegration/run_native_regressions.py'
WATCH_SHA = 'd5bd867e4a65b4ee053209fe0a5822867b8d0878fd6d059f474c9b28a0f6286d'
VERIFIER_SHA = 'f4435e99ad7a547a90d01ce38c094d0813fac797a443a0e33654cce6b5ea9cef'
TAG = b'CI_FOLDER_PREVIEW_TRACE'
PATH_TAG = b'CI_FOLDER_PREVIEW_PATH'
TEST_SHA256 = '8eac403828d8e4612f273ce91f7fd414ddc9a502203f659af34f933267675e42'
RECORD_LIMIT = 512
# Phase5 is the same literal pair in each of twelve source-bound request cases.
STATEMENTS = [(phase, edge) for phase in range(10) for edge in range(2)]
SEQUENCE = ([(phase, edge) for phase in range(5) for edge in range(2)]
            + [(5, edge) for _ in range(12) for edge in range(2)]
            + [(phase, edge) for phase in range(6, 10) for edge in range(2)])
REQUEST_INTERVAL_SHA256 = '9156e200fd75e813ebdf1e17f4fd3f4ae9e67b2e14588b748fe21825bc973e41'
RECEIPT_FIELDS = set(('command pid processGroup exitObserved registrationError groupSignalAttempted '
    'groupSignalError groupCleanup groupQuery waitCompleted returnCode waitError timedOut '
    'interruptedSignal truncated captureComplete captured failure exit seconds').split())


# Separate diagnostic sites; the original Core/path grammar does not recognize this tag.
_PREDICATE_TAG = b'CI_PREVIEW_PREDICATE'
_PREDICATE_CONSTRUCTION_KEY = object()
_PREDICATE_SELECTED_SOURCE = b'    if diagnosticTrace {\n      let predicateCount = selectedURLs.count\n      let predicateSelected = predicateCount == 0 ? 0 : (predicateCount == 1 ? 1 : 2)\n      let predicateMain = Thread.isMainThread ? 1 : 0\n      FileHandle.standardError.write(Data("CI_PREVIEW_PREDICATE c=\\(predicateSelected) m=\\(predicateMain)\\n".utf8))\n    }\n'
_PREDICATE_WRAPPER_SOURCE = b'  private func validURL(_ url: URL) -> Bool {\n    let predicateBit = diagnosticTrace ? 1 : 0\n    let predicateMain = Thread.isMainThread ? 1 : 0\n    FileHandle.standardError.write(Data("CI_PREVIEW_PREDICATE w=\\(predicateBit) m=\\(predicateMain)\\n".utf8))\n    return FolderReplacementPathPolicy.valid(url, diagnosticTrace: diagnosticTrace)\n  }'


class _AvailabilityProgress:
    __slots__ = ('current', 'unavailable')

    def __init__(self):
        self.current = None
        self.unavailable = None


def _availability_boundary(value):
    return type(value) is int and 0 <= value <= 21


def _availability_fields(progress):
    if type(progress) is not _AvailabilityProgress:
        return None
    try:
        current, unavailable = progress.current, progress.unavailable
    except AttributeError:
        return None
    if not ((current is None or _availability_boundary(current))
            and (unavailable is None or _availability_boundary(unavailable))):
        return None
    return current, unavailable


def _availability_enter(progress, boundary):
    fields = _availability_fields(progress)
    if fields is not None and _availability_boundary(boundary) and fields[1] is None:
        progress.current = boundary


def _availability_fail(progress):
    fields = _availability_fields(progress)
    if fields is not None and _availability_boundary(fields[0]) and fields[1] is None:
        progress.unavailable = fields[0]


def _availability_line(progress):
    fields = _availability_fields(progress)
    if fields is None or not (_availability_boundary(fields[0])
                              and _availability_boundary(fields[1])):
        return None
    return 'availability: boundary=' + str(fields[1])


class _ParserRefusal:
    __slots__ = ('code', 'transition', 'predicate', '_predicate_attempted', '_predicate_nonce',
                 '_transition_nonce', '_collector_domain', '_collector_nonce', '_collector_transition',
                 '_collector_window_detail')

    def __init__(self):
        self.code = None
        self.transition = None
        self.predicate = None
        self._predicate_attempted = False
        self._predicate_nonce = object()
        # Bind collector freshness at construction without changing the legacy
        # parser transition witness or its public state/incoming projection.
        self._transition_nonce = self._predicate_nonce
        self._collector_domain = None
        self._collector_nonce = None
        self._collector_transition = None
        self._collector_window_detail = None


_COLLECTOR_DOMAINS = (
    'buffer-type', 'capture-cap', 'record-shape', 'thread', 'stream', 'side-cap',
    'core-cap', 'marker-presence', 'window', 'prefix', 'old-path', 'tuple',
    'collector-exception')
_COLLECTOR_DOMAIN_IDS = {name: index + 1 for index, name in enumerate(_COLLECTOR_DOMAINS)}


# Closed diagnostic identities only; the original _core_next grammar owns acceptance.
_PARSER_TRANSITION_STATES = (
    ('start', 'none', False),
    ('entry', 'none', False),
    ('limits', 'none', False),
    ('scalars', 'none', False),
    ('root-call', 'none', False),
    ('root-done', 'none', False),
    ('selected-call', 'none', False),
    ('selected-done', 'none', False),
    ('admitted', 'none', False),
    ('end', 'none', False),
    ('valid', 'root', False),
    ('serialized', 'root', False),
    ('bytes', 'root', False),
    ('nul', 'root', False),
    ('clean', 'root', False),
    ('serialized-accepted', 'root', False),
    ('file-accepted', 'root', False),
    ('host-accepted', 'root', False),
    ('decoded', 'root', False),
    ('decoded-accepted', 'root', False),
    ('directory-accepted', 'root', False),
    ('pointer', 'root', False),
    ('filesystem', 'root', False),
    ('returned', 'root', False),
    ('returned', 'root', True),
    ('valid', 'selected', False),
    ('serialized', 'selected', False),
    ('bytes', 'selected', False),
    ('nul', 'selected', False),
    ('clean', 'selected', False),
    ('serialized-accepted', 'selected', False),
    ('file-accepted', 'selected', False),
    ('host-accepted', 'selected', False),
    ('decoded', 'selected', False),
    ('decoded-accepted', 'selected', False),
    ('directory-accepted', 'selected', False),
    ('pointer', 'selected', False),
    ('filesystem', 'selected', False),
    ('returned', 'selected', False),
    ('returned', 'selected', True),
)
_PARSER_TRANSITION_STAGES = (0, 1, 2, 3, 4, 5, 6, 7, 9, 10, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24)


def _parser_refusal_code(record):
    if type(record) is not _ParserRefusal:
        return None
    try:
        code = record.code
    except AttributeError:
        return None
    return code if type(code) is int and 0 <= code <= 7 else None


def _parser_refusal_mark(record, code):
    if type(record) is not _ParserRefusal or not (type(code) is int and 0 <= code <= 7):
        return
    try:
        current = record.code
    except AttributeError:
        return
    if current is None:
        record.code = code


def _parser_require(value, record, code):
    if value:
        return
    _parser_refusal_mark(record, code)
    _require(False)


def _parser_transition_state_id(state):
    if (type(state) is not tuple or len(state) != 3
            or type(state[0]) is not str or type(state[1]) is not str
            or type(state[2]) is not bool):
        return None
    try:
        return _PARSER_TRANSITION_STATES.index(state)
    except ValueError:
        return None


def _parser_refusal_transition(record):
    if type(record) is not _ParserRefusal or _parser_refusal_code(record) != 4:
        return None
    try:
        pair = record.transition
    except AttributeError:
        return None
    if type(pair) is not tuple or len(pair) != 2:
        return None
    state_id, incoming = pair
    if (type(state_id) is not int or not 0 <= state_id < 40
            or type(incoming) is not int or incoming not in _PARSER_TRANSITION_STAGES):
        return None
    return pair


def _parser_transition_mark(record, state, stage):
    if type(record) is not _ParserRefusal:
        return
    try:
        code, pair = record.code, record.transition
    except AttributeError:
        return
    if code is not None or pair is not None:
        return
    state_id = _parser_transition_state_id(state)
    if (state_id is None or type(stage) is not int
            or stage not in _PARSER_TRANSITION_STAGES):
        return
    record.transition = (state_id, stage)


def _parser_transition_require(value, record, state, stage):
    # value is the original, once-evaluated membership Boolean at guard4.
    if value is False:
        _parser_transition_mark(record, state, stage)
    _parser_require(value, record, 4)


class _PredicateObservation:
    __slots__ = ('selected', 'calls', 'bits', '_witness', '_transition')

    def __init__(self, key, *, selected, calls, bits, witness, transition):
        if key is not _PREDICATE_CONSTRUCTION_KEY:
            raise TypeError('diagnostic construction refused')
        self.selected, self.calls, self.bits = selected, calls, bits
        self._witness, self._transition = witness, transition


def _predicate_tuple(selected, calls, bits):
    if (type(selected) is not int or type(calls) is not int or type(bits) is not int
            or not 0 <= selected <= 2 or not 0 <= calls <= 2 or not 0 <= bits <= 3):
        return None
    if not ((calls == 0 and bits == 0) or (calls == 1 and bits in (1, 2))
            or (calls == 2 and bits in (1, 2, 3))):
        return None
    if (selected == 0 and calls != 0) or (selected == 1 and calls > 1):
        return None
    return selected, calls, bits


def _predicate_pristine_refusal(record):
    if type(record) is not _ParserRefusal:
        return False
    try:
        return (record.code is None and record.transition is None and record.predicate is None
                and record._predicate_attempted is False and type(record._predicate_nonce) is object
                and record._transition_nonce is record._predicate_nonce and record._collector_domain is None
                and record._collector_nonce is None and record._collector_transition is None
                and record._collector_window_detail is None)
    except AttributeError:
        return False


def _collector_domain_mark(record, domain, nonce, pair, window_detail=None):
    if type(record) is not _ParserRefusal or domain not in _COLLECTOR_DOMAIN_IDS.values():
        return
    if window_detail is not None and (domain != _COLLECTOR_DOMAIN_IDS['window']
                                      or type(window_detail) is not int
                                      or window_detail not in (1, 2, 3, 4, 5)):
        return
    try:
        if (record.code == 4 and record._predicate_attempted is True and record.predicate is None
                and type(nonce) is object and record._predicate_nonce is nonce
                and record._transition_nonce is nonce and record.transition == pair
                and record._collector_domain is None and record._collector_nonce is None
                and record._collector_transition is None and record._collector_window_detail is None):
            record._collector_domain = domain
            record._collector_nonce = nonce
            record._collector_transition = pair
            record._collector_window_detail = window_detail
    except AttributeError:
        return


def _collector_refusal_domain(record):
    pair = _parser_refusal_transition(record)
    if pair is None or type(record) is not _ParserRefusal:
        return None
    try:
        domain, nonce, saved = (record._collector_domain, record._collector_nonce,
                                record._collector_transition)
        if (type(domain) is int and domain in _COLLECTOR_DOMAIN_IDS.values()
                and record._predicate_attempted is True and record.predicate is None
                and nonce is record._predicate_nonce is record._transition_nonce
                and saved == pair):
            return _COLLECTOR_DOMAINS[domain - 1]
    except AttributeError:
        return None
    return None


def _collector_refusal_window_detail(record):
    pair = _parser_refusal_transition(record)
    if pair is None or type(record) is not _ParserRefusal:
        return None
    try:
        detail = record._collector_window_detail
        if (record._collector_domain == _COLLECTOR_DOMAIN_IDS['window']
                and record._predicate_attempted is True and record.predicate is None
                and record._collector_nonce is record._predicate_nonce is record._transition_nonce
                and record._collector_transition == pair
                and type(detail) is int and detail in (1, 2, 3, 4, 5)):
            return detail
    except AttributeError:
        return None
    return None


def _collector_require(value, refusal, domain, nonce, pair, window_detail=None):
    if value:
        return
    _collector_domain_mark(refusal, _COLLECTOR_DOMAIN_IDS[domain], nonce, pair,
                           window_detail=window_detail)
    _require(False)


def _predicate_observation(record):
    pair = _parser_refusal_transition(record)
    if pair is None:
        return None
    try:
        observation, nonce, attempted = record.predicate, record._predicate_nonce, record._predicate_attempted
        if (type(observation) is not _PredicateObservation or type(nonce) is not object
                or attempted is not True or observation._witness is not nonce):
            return None
        saved = observation._transition
        if (type(saved) is not tuple or len(saved) != 2
                or type(saved[0]) is not int or type(saved[1]) is not int or saved != pair):
            return None
        return _predicate_tuple(observation.selected, observation.calls, observation.bits)
    except AttributeError:
        return None


def _predicate_lines(raw):
    # Already exact bytes, <=1MiB. Iterate without retaining a per-record list.
    offset = 0
    while offset < len(raw):
        end = raw.find(b'\n', offset)
        if end < 0:
            yield raw[offset:]
            return
        yield raw[offset:end + 1]
        offset = end + 1


def _predicate_private_buffers(stdout, stderr, *, refusal, nonce, pair):
    clean = []  # Exactly two bounded private byte buffers, never the owned originals.
    marker_stream = side_stream = core_stream = side_count = core_count = 0
    for stream, raw in ((1, stdout), (2, stderr)):
        kept = bytearray()
        for line in _predicate_lines(raw):
            stripped = line.strip()
            side = (_PREDICATE_TAG in line
                    or (bool(stripped) and _PREDICATE_TAG.startswith(stripped)))
            if side:
                count = re.fullmatch(rb'CI_PREVIEW_PREDICATE c=([012]) m=([01])\n', line)
                wrapper = re.fullmatch(rb'CI_PREVIEW_PREDICATE w=([01]) m=([01])\n', line)
                _collector_require(count is not None or wrapper is not None,
                                   refusal, 'record-shape', nonce, pair)
                match = count if count is not None else wrapper
                _collector_require(match[2] == b'1', refusal, 'thread', nonce, pair)
                _collector_require(side_count < 128, refusal, 'side-cap', nonce, pair)
                _collector_require(side_stream in (0, stream), refusal, 'stream', nonce, pair)
                side_stream = stream
                side_count += 1
                continue
            core = re.fullmatch(rb'CI_FOLDER_PREVIEW_CORE s=(2[0-4]|1[023-9]|[0-79])\n', line)
            if core is not None:
                _collector_require(core_count < CORE_RECORD_LIMIT,
                                   refusal, 'core-cap', nonce, pair)
                _collector_require(core_stream in (0, stream), refusal, 'stream', nonce, pair)
                core_stream = stream
                core_count += 1
                continue
            _collector_require(not (CORE_TAG in line
                          or (bool(stripped) and CORE_TAG.startswith(stripped))),
                               refusal, 'record-shape', nonce, pair)
            outer = re.fullmatch(rb'CI_FOLDER_PREVIEW_TRACE p=([0-9]) e=([01])\n', line)
            path = re.fullmatch(rb'CI_FOLDER_PREVIEW_PATH s=(10|[0-9])\n', line)
            if outer is not None or path is not None:
                _collector_require(marker_stream in (0, stream),
                                   refusal, 'stream', nonce, pair)
                marker_stream = stream
            kept.extend(line)
        clean.append(bytes(kept))
    _collector_require(marker_stream != 0 and side_stream != 0 and core_stream != 0,
                       refusal, 'marker-presence', nonce, pair)
    _collector_require(side_stream == marker_stream == core_stream,
                       refusal, 'stream', nonce, pair)
    # The original coarse4 refused before this original path parser could run.
    # This private-copy invocation validates order; its report is not acceptance.
    try:
        _parse_path_trace(*clean)
    except ValueError:
        _collector_domain_mark(refusal, _COLLECTOR_DOMAIN_IDS['old-path'], nonce, pair)
        raise
    return marker_stream


def _predicate_window(raw, *, refusal, nonce, pair):
    outer_count = calls = bits = 0
    window = seen_window = seen_five = completed = False
    selected = None
    for line in _predicate_lines(raw):
        outer = re.fullmatch(rb'CI_FOLDER_PREVIEW_TRACE p=([0-9]) e=([01])\n', line)
        path = re.fullmatch(rb'CI_FOLDER_PREVIEW_PATH s=(10|[0-9])\n', line)
        if outer is not None:
            outer_count += 1
            _collector_require(outer_count <= len(SEQUENCE),
                               refusal, 'prefix', nonce, pair)
        elif path is not None:
            current = SEQUENCE[outer_count - 1] if outer_count else None
            request = (outer_count - 11) // 2 + 1 if current == (5, 0) else None
            stage = int(path[1])
            if request == 11 and stage == 7:
                _collector_require(not seen_window, refusal, 'window', nonce, pair,
                                   window_detail=5)
                window = seen_window = True
            elif request == 11 and stage == 8:
                _collector_require(window, refusal, 'window', nonce, pair,
                                   window_detail=5)
                _collector_require(seen_five and selected is not None and completed,
                                   refusal, 'prefix', nonce, pair)
                window = False
        core = re.fullmatch(rb'CI_FOLDER_PREVIEW_CORE s=(2[0-4]|1[023-9]|[0-79])\n', line)
        if core is not None:
            _collector_require(window, refusal, 'window', nonce, pair,
                               window_detail=1 if not seen_window else 2)
            stage = int(core[1])
            if stage == 5:
                _collector_require(not seen_five and selected is None and not completed,
                                   refusal, 'prefix', nonce, pair)
                seen_five = True
            elif stage == 6:
                _collector_require(seen_five and selected is not None and not completed,
                                   refusal, 'prefix', nonce, pair)
                completed = True
        count = re.fullmatch(rb'CI_PREVIEW_PREDICATE c=([012]) m=1\n', line)
        wrapper = re.fullmatch(rb'CI_PREVIEW_PREDICATE w=([01]) m=1\n', line)
        if count is not None:
            _collector_require(window, refusal, 'window', nonce, pair,
                               window_detail=3 if not seen_window else 4)
            _collector_require(seen_five and selected is None and not completed,
                               refusal, 'prefix', nonce, pair)
            selected = int(count[1])
        elif wrapper is not None and window:
            _collector_require(seen_five and selected is not None and not completed,
                               refusal, 'prefix', nonce, pair)
            _collector_require(selected != 1 or calls == 0,
                               refusal, 'tuple', nonce, pair)
            calls = min(2, calls + 1)
            bits |= 1 << int(wrapper[1])
    _collector_require(seen_window and not window, refusal, 'window', nonce, pair,
                       window_detail=5)
    _collector_require(seen_five and completed, refusal, 'prefix', nonce, pair)
    value = _predicate_tuple(selected, calls, bits)
    _collector_require(value is not None, refusal, 'tuple', nonce, pair)
    return value


def _collect_predicate_observation(stdout, stderr, *, refusal):
    pair = _parser_refusal_transition(refusal)
    if pair is None:
        return
    try:
        nonce = refusal._predicate_nonce
        if (refusal._predicate_attempted is not False or refusal.predicate is not None
                or type(nonce) is not object or refusal._transition_nonce is not nonce
                or refusal._collector_domain is not None or refusal._collector_nonce is not None
                or refusal._collector_transition is not None
                or refusal._collector_window_detail is not None):
            return
        # Unknown is a first outcome too. Never borrow a later stream after refusal.
        refusal._predicate_attempted = True
        _collector_require(type(stdout) is bytes and type(stderr) is bytes,
                           refusal, 'buffer-type', nonce, pair)
        _collector_require(len(stdout) <= 1048576 and len(stderr) <= 1048576,
                           refusal, 'capture-cap', nonce, pair)
        stream = _predicate_private_buffers(stdout, stderr, refusal=refusal, nonce=nonce, pair=pair)
        selected, calls, bits = _predicate_window(stdout if stream == 1 else stderr,
                                                  refusal=refusal, nonce=nonce, pair=pair)
        _require(refusal._predicate_nonce is nonce and refusal._transition_nonce is nonce
                 and refusal._predicate_attempted is True and refusal.predicate is None
                 and _parser_refusal_transition(refusal) == pair)
        refusal.predicate = _PredicateObservation(_PREDICATE_CONSTRUCTION_KEY,
            selected=selected, calls=calls, bits=bits, witness=nonce, transition=pair)
    except (OSError, ValueError, TypeError, KeyError, AttributeError, RuntimeError):
        # Diagnostics cannot replace the original refusal or disclose an error payload.
        if _collector_refusal_domain(refusal) is None:
            try:
                nonce = refusal._predicate_nonce
                _collector_domain_mark(refusal, _COLLECTOR_DOMAIN_IDS['collector-exception'], nonce, pair)
            except (AttributeError, TypeError):
                pass
        return


def _availability_output(progress, parser_refusal=None):
    # Fixed literals and validated closed integers; never exception or input text.
    output = 'ci-folder-preview-trace: unavailable\nreason: incomplete-evidence'
    line = _availability_line(progress)
    code = _parser_refusal_code(parser_refusal)
    if line == 'availability: boundary=17' and code is not None:
        line += ' parser=' + str(code)
        pair = _parser_refusal_transition(parser_refusal) if code == 4 else None
        if pair is not None:
            line += ' state=' + str(pair[0]) + ' incoming=' + str(pair[1])
            observation = _predicate_observation(parser_refusal)
            if observation is not None:
                line += (' selected=' + str(observation[0]) + ' calls=' + str(observation[1])
                         + ' bits=' + str(observation[2]))
            domain = _collector_refusal_domain(parser_refusal)
            if domain is not None:
                line += ' collector=' + str(_COLLECTOR_DOMAIN_IDS[domain])
                window_detail = _collector_refusal_window_detail(parser_refusal)
                if domain == 'window' and window_detail is not None:
                    line += ' window=' + str(window_detail)
    if line is not None:
        output += '\n' + line
    _require(len((output + '\n').encode('ascii')) <= 512)
    return output


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


def _path_marker(stage, indent):
    return (b' ' * indent + b'FileHandle.standardError.write(Data("CI_FOLDER_PREVIEW_PATH s='
            + str(stage).encode('ascii') + b'\\n".utf8))\n')


def _project_path_test(original):
    _require(type(original) is bytes and TAG not in original and PATH_TAG not in original)
    # Bind the whole selected source, including both helpers and every callsite.
    # An inverse alone cannot authorize projecting a changed helper or body.
    _require(hashlib.sha256(original).hexdigest() == TEST_SHA256)
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
    request_loop = b'      for (urls, query, replacement, limits) in requestCases {\n'
    exact = b'      let exact = try preview(\n'
    unicode_boundary = b'      let exactPattern = try preview(\n'
    mutation_boundary = b'      let handle = try FileHandle(forWritingTo: fixture.a)\n'
    request_end = (b'        XCTAssertEqual(reader.fileCalls, 0)\n'
                   b'      }\n\n' + exact)
    # Bind every case, its order and every loop oracle before relying on twelve pairs.
    _require(method.count(requests) == method.count(exact) == 1)
    request_interval = method[method.index(requests):method.index(exact)]
    _require(hashlib.sha256(request_interval).hexdigest() == REQUEST_INTERVAL_SHA256)
    _require(method.count(b'      let zeroMatches = try preview(') == 1)
    for anchor in (entry + invalid, loop + long_url + nul_url + requests, suffix,
                   request_loop, request_end, unicode_boundary, mutation_boundary):
        _require(method.count(anchor) == 1)
    _require(method.startswith(entry + invalid) and method.endswith(suffix))
    modified = method.replace(entry, head + _marker(0, 0, 4)
        + b'    try withFixture { fixture in\n' + _marker(0, 1, 6) + _marker(1, 0, 6), 1)
    modified = modified.replace(loop + long_url + nul_url + requests,
        loop + _marker(1, 1, 6) + _marker(2, 0, 6) + long_url
        + _marker(2, 1, 6) + _marker(3, 0, 6) + nul_url
        + _marker(3, 1, 6) + _marker(4, 0, 6) + requests, 1)
    modified = modified.replace(request_loop,
        _marker(4, 1, 6) + request_loop + _marker(5, 0, 8), 1)
    modified = modified.replace(request_end,
        b'        XCTAssertEqual(reader.fileCalls, 0)\n' + _marker(5, 1, 8)
        + b'      }\n\n' + _marker(6, 0, 6) + exact, 1)
    modified = modified.replace(unicode_boundary,
        _marker(6, 1, 6) + _marker(7, 0, 6) + unicode_boundary, 1)
    modified = modified.replace(mutation_boundary,
        _marker(7, 1, 6) + _marker(8, 0, 6) + mutation_boundary, 1)
    final = suffix.replace(b'    }\n  }\n',
        _marker(8, 1, 6) + _marker(9, 0, 6) + b'    }\n'
        + _marker(9, 1, 4) + b'  }\n', 1)
    modified = modified.replace(suffix, final, 1)
    projected = original[:start] + modified + original[end:]
    inverse = projected
    for phase, edge in STATEMENTS:
        indent = 4 if (phase, edge) in ((0, 0), (9, 1)) else (8 if phase == 5 else 6)
        statement = _marker(phase, edge, indent)
        _require(inverse.count(statement) == 1)
        inverse = inverse.replace(statement, b'', 1)
    _require(inverse == original and projected.count(TAG) == len(STATEMENTS))
    reader = b'        let reader = ControlledReader()\n'
    reader_site = request_loop + _marker(5, 0, 8) + reader
    _require(projected.count(reader_site) == 1)
    projected = projected.replace(reader_site, request_loop + _marker(5, 0, 8)
        + _path_marker(0, 8) + reader + _path_marker(1, 8), 1)

    preview_head = b'  private func preview(\n'
    assertion_head = b'  private func assertError<T>(\n'
    fixture_head = b'  private func withFixture('
    _require(all(projected.count(anchor) == 1
                 for anchor in (preview_head, assertion_head, fixture_head)))
    preview_start = projected.index(preview_head)
    assertion_start = projected.index(assertion_head)
    fixture_start = projected.index(fixture_head)
    _require(preview_start < assertion_start < fixture_start)
    preview = projected[preview_start:assertion_start]
    assertion = projected[assertion_start:fixture_start]
    preserved = b'    defer { fixture.assertPreserved() }\n'
    preview_body = b'  ) throws -> FolderReplacementPreview {\n' + preserved
    builder_call = b'    return try builder.preview(\n'
    _require(preview.count(preview_body + builder_call) == 1)
    expanded_preservation = (b'    defer {\n' + _path_marker(9, 6)
        + b'      fixture.assertPreserved()\n' + _path_marker(10, 6) + b'    }\n')
    diagnostic_defer = b'    defer {\n' + _path_marker(8, 6) + b'    }\n'
    preview = preview.replace(preview_body + builder_call,
        b'  ) throws -> FolderReplacementPreview {\n' + _path_marker(6, 4)
        + expanded_preservation + diagnostic_defer + _path_marker(7, 4) + builder_call, 1)
    throws_call = b'    XCTAssertThrowsError(try body(), file: file, line: line) {\n'
    comparison = (b'      XCTAssertEqual($0 as? FolderReplacementPreviewError, expected, '
                  b'file: file, line: line)\n')
    assertion_body = throws_call + comparison + b'    }\n'
    _require(assertion.count(assertion_body) == 1)
    assertion = assertion.replace(assertion_body, _path_marker(2, 4) + throws_call
        + _path_marker(3, 6) + comparison + _path_marker(4, 6) + b'    }\n'
        + _path_marker(5, 4), 1)
    projected = (projected[:preview_start] + preview + assertion + projected[fixture_start:])

    # Independently undo both layers, including only the added defer syntax.
    inverse = projected
    for phase, edge in STATEMENTS:
        indent = 4 if (phase, edge) in ((0, 0), (9, 1)) else (8 if phase == 5 else 6)
        statement = _marker(phase, edge, indent)
        _require(inverse.count(statement) == 1)
        inverse = inverse.replace(statement, b'', 1)
    for stage in range(11):
        indent = 8 if stage in (0, 1) else (6 if stage in (3, 4, 8, 9, 10) else 4)
        statement = _path_marker(stage, indent)
        _require(inverse.count(statement) == 1)
        inverse = inverse.replace(statement, b'', 1)
    empty_defer = b'    defer {\n    }\n'
    plain_preservation = b'    defer {\n      fixture.assertPreserved()\n    }\n'
    _require(inverse.count(empty_defer) == inverse.count(plain_preservation) == 1)
    inverse = inverse.replace(empty_defer, b'', 1).replace(plain_preservation, preserved, 1)
    _require(inverse == original and projected.count(TAG) == 20 and projected.count(PATH_TAG) == 11)
    return projected


def _trace_grammar():
    """Fixed source-bound outer intervals and their nested helper call shapes."""
    events = []
    request = 0
    for phase, edge in SEQUENCE:
        events.append(('outer', phase, edge))
        if edge != 0:
            continue
        if phase == 1:
            calls = ('assertion',) * 14
        elif phase == 5:
            request += 1
            calls = ('request',)
        elif phase == 6:
            calls = ('helper', 'assertion', 'assertion', 'assertion', 'helper')
        elif phase == 7:
            calls = ('helper', 'helper')
        elif phase == 8:
            calls = ('assertion',)
        else:
            calls = ()
        for call in calls:
            stages = (6, 7, 8, 9, 10)
            if call != 'helper':
                stages = (2,) + stages + (3, 4, 5)
            if call == 'request':
                stages = (0, 1) + stages
            ordinal = request if phase == 5 else None
            events.extend(('path', stage, ordinal) for stage in stages)
    return events


def _trace_report(outer_count, path_count, stage, ordinal):
    if outer_count:
        phase, edge = SEQUENCE[outer_count - 1]
        horizon = 'all-intervals-ended' if outer_count == len(SEQUENCE) else (
            'entered-without-end' if edge == 0 else 'completed-interval')
    else:
        phase, edge, horizon = None, None, 'not-observed'
    if stage is None:
        path_horizon = 'not-observed'
    elif stage == 5:
        path_horizon = 'all-helpers-ended' if path_count == 314 else 'assertion-returned'
    elif stage == 10:
        path_horizon = 'helper-ended'
    else:
        path_horizon = 'observed-prefix'
    return dict(phase=phase, edge=edge, records=outer_count, horizon=horizon,
                pathStage=stage, requestOrdinal=ordinal, pathRecords=path_count,
                pathHorizon=path_horizon)


def _parse_path_trace(stdout, stderr):
    _require(type(stdout) is bytes and type(stderr) is bytes)
    grammar = _trace_grammar()
    cursor = outer_count = path_count = 0
    stage = ordinal = marker_stream = None
    for stream, raw in (('stdout', stdout), ('stderr', stderr)):
        for line in raw.splitlines(keepends=True):
            stripped = line.strip()
            potential = (b'CI_FOLDER_PREVIEW_' in line or TAG in line or PATH_TAG in line
                or (bool(stripped) and any(tag.startswith(stripped) for tag in (TAG, PATH_TAG))))
            if not potential:
                continue
            _require(marker_stream is None or marker_stream == stream)
            marker_stream = stream
            _require(outer_count + path_count < RECORD_LIMIT and cursor < len(grammar))
            outer = re.fullmatch(rb'CI_FOLDER_PREVIEW_TRACE p=([0-9]) e=([01])\n', line)
            path = re.fullmatch(rb'CI_FOLDER_PREVIEW_PATH s=(10|[0-9])\n', line)
            _require(outer is not None or path is not None)
            if outer is not None:
                event = ('outer', int(outer[1]), int(outer[2]))
            else:
                # The current outer pair determines custody; the report retains
                # this ordinal after that pair ends until another PATH arrives.
                current = SEQUENCE[outer_count - 1] if outer_count else None
                request = (outer_count - 11) // 2 + 1 if current == (5, 0) else None
                event = ('path', int(path[1]), request)
            # Original XCTAssertThrowsError can return without its handler when
            # no throw occurred. Only the complete 3,4 pair is optional.
            expected = grammar[cursor]
            if (expected[0:2] == ('path', 3)
                    and event == ('path', 5, expected[2])):
                cursor += 2
            _require(event == grammar[cursor])
            cursor += 1
            if outer is not None:
                outer_count += 1
            else:
                path_count += 1
                stage, ordinal = event[1:]
    return _trace_report(outer_count, path_count, stage, ordinal)


def _valid_trace_report(trace):
    """Validate only reachable closed reports, without accepting supplied text."""
    _require(type(trace) is dict and set(trace) == {
        'phase', 'edge', 'records', 'horizon', 'pathStage', 'requestOrdinal',
        'pathRecords', 'pathHorizon'})
    for key in ('phase', 'edge', 'pathStage', 'requestOrdinal'):
        _require(trace[key] is None or type(trace[key]) is int)
    _require(type(trace['records']) is int and type(trace['pathRecords']) is int)
    _require(type(trace['horizon']) is str and type(trace['pathHorizon']) is str)
    _require(0 <= trace['records'] <= len(SEQUENCE) and 0 <= trace['pathRecords'] <= 314)
    outer = paths = ended_assertions = 0
    stage = ordinal = None
    # Every previously returned assertion independently permits omitting 3,4.
    # Thus each canonical prefix has a finite even range of reachable counts.
    for event in [None, *_trace_grammar()]:
        if event is not None:
            if event[0] == 'outer':
                outer += 1
            else:
                paths += 1
                stage, ordinal = event[1:]
                if stage == 5:
                    ended_assertions += 1
        missing = paths - trace['pathRecords']
        if (0 <= missing <= 2 * ended_assertions and missing % 2 == 0
                and trace == _trace_report(outer, trace['pathRecords'], stage, ordinal)):
            return
    raise ValueError('diagnostic evidence refused')


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
    _require(TARGET in files and CORE_TARGET in files)
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
    projected = {TARGET: project_test(buffers[TARGET]), CORE_TARGET: project_core(buffers[CORE_TARGET])}
    for relative, destination in [*plan['inputs'].items(), *plan['tools'].items()]:
        target = run / destination
        _mkdir(run, target.parent)
        data = projected.get(relative, buffers[relative])
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
        projection=_projection_metadata(buffers, projected))
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
    projected = {TARGET: project_test(originals[TARGET]), CORE_TARGET: project_core(originals[CORE_TARGET])}
    _require(captured['projection'] == _projection_metadata(originals, projected))
    for relative, destination in [*captured['plan']['inputs'].items(), *captured['plan']['tools'].items()]:
        expected = projected.get(relative, originals[relative])
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


def execute(root, run, plan, manifest, watchdog_main, *, progress=None, parser_refusal=None):
    root, run = Path(root).absolute(), Path(run).absolute()
    unavailable = dict(state='unavailable')
    try:
        _availability_enter(progress, 6)
        verify_inputs(root, run, manifest)
        _availability_enter(progress, 7)
        _require(plan == manifest['capture']['plan'] == make_plan(root, run))
        _require(callable(watchdog_main))
        output = run / 'stage'
        _require(not output.exists() and not output.is_symlink())
        _save(run / 'command.json', dict(command=plan['command'], timeout=600))
        command_fact = _fact(run, run / 'command.json')[0]
        _availability_enter(progress, 8)
        verifier = _load_module(run, run / 'Tools/run_native_regressions.py',
                                'folder_trace_verifier', VERIFIER_SHA)
        # The accepted watchdog prints its own control summary. Retain it privately
        # so the only CI output remains this diagnostic's closed three-line projection.
        _availability_enter(progress, 9)
        with (run / 'watchdog-control.stdout.log').open('x') as control_out, \
                (run / 'watchdog-control.stderr.log').open('x') as control_err:
            with contextlib.redirect_stdout(control_out), contextlib.redirect_stderr(control_err):
                code = watchdog_main(['--timeout', '600', '--output', str(output), '--', *plan['command']])
        _availability_enter(progress, 10)
        _require(_fact(run, run / 'command.json')[0] == command_fact)
        _availability_enter(progress, 11)
        verify_inputs(root, run, manifest)
        _availability_enter(progress, 12)
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
        _availability_enter(progress, 13)
        stdout_fact, stdout = _fact(run, output / 'stdout.log', 1048576)
        stderr_fact, stderr = _fact(run, output / 'stderr.log', 1048576)
        _availability_enter(progress, 14)
        _require(verifier.receipt_success(output, plan['command'], code))
        _availability_enter(progress, 15)
        for row in (receipt_fact, stdout_fact, stderr_fact):
            _require(_fact(run, run / row['path'])[0] == row)
        _require(_fact(run, run / 'command.json')[0] == command_fact)
        _availability_enter(progress, 16)
        verify_inputs(root, run, manifest)
        _availability_enter(progress, 17)
        predicate_boundary = _predicate_pristine_refusal(parser_refusal)
        try:
            if parser_refusal is None:
                trace = parse_trace(stdout, stderr)
            else:
                trace = parse_trace(stdout, stderr, refusal=parser_refusal)
        except ValueError:
            # Only this original owned parse can supply its new first-refusal observation.
            if predicate_boundary and _parser_refusal_transition(parser_refusal) is not None:
                _collect_predicate_observation(stdout, stderr, refusal=parser_refusal)
            raise
        _availability_enter(progress, 18)
        original_after = [_fact(root, root / row['path'])[0] for row in manifest['capture']['originals']]
        copy_after = [_fact(run, run / row['path'])[0] for row in manifest['capture']['copies']]
        _require(original_after == manifest['capture']['originals']
                 and copy_after == manifest['capture']['copies'])
        _availability_enter(progress, 19)
        for row in (receipt_fact, stdout_fact, stderr_fact, command_fact):
            _require(_fact(run, run / row['path'])[0] == row)
        return dict(state='observed' if trace['records'] else 'not-observed',
                    ownedExit=receipt['exit'], ownedReturnCode=receipt['returnCode'],
                    signalObservation='not-observed-for-selected-test', trace=trace,
                    evidence=dict(inputAuthority=manifest['authority'], command=command_fact,
                                  captures=[receipt_fact, stdout_fact, stderr_fact],
                                  originalAfter=original_after, copyAfter=copy_after))
    except (OSError, ValueError, TypeError, KeyError, AttributeError, RuntimeError, ImportError):
        _availability_fail(progress)
        return unavailable


def _render_path(result):
    unavailable = ['ci-folder-preview-trace: unavailable', 'reason: incomplete-evidence']
    try:
        state, trace = result['state'], result['trace']
        _require(type(state) is str and state in ('observed', 'not-observed'))
        _valid_trace_report(trace)
        records, phase, edge, horizon = (trace[key] for key in ('records', 'phase', 'edge', 'horizon'))
        _require(state == ('observed' if records else 'not-observed'))
        _require(result['signalObservation'] == 'not-observed-for-selected-test')
        for key in ('ownedExit', 'ownedReturnCode'):
            _require(type(result[key]) is int and 0 <= result[key] < 256)
        _require(result['ownedExit'] == result['ownedReturnCode'])
        lines = ['ci-folder-preview-trace: ' + state,
            'trace: phase=' + str(-1 if phase is None else phase) + ' edge=' + str(-1 if edge is None else edge)
            + ' horizon=' + horizon + ' records=' + str(records),
            'path: stage=' + str(-1 if trace['pathStage'] is None else trace['pathStage'])
            + ' request=' + str(-1 if trace['requestOrdinal'] is None else trace['requestOrdinal'])
            + ' horizon=' + trace['pathHorizon'] + ' records=' + str(trace['pathRecords']),
            'owned: exit=' + str(result['ownedExit']) + ' returnCode=' + str(result['ownedReturnCode'])
            + ' signal=not-observed-for-selected-test']
        _require(len(('\n'.join(lines) + '\n').encode('ascii')) <= 512)
        return lines
    except (ValueError, TypeError, KeyError, AttributeError, UnicodeError):
        return unavailable


def _core_marker(stage, indent=4):
    pad = b' ' * indent
    return (pad + b'if diagnosticTrace {\n' + pad + b'  FileHandle.standardError.write(Data("'
            + CORE_TAG + b' s=' + str(stage).encode('ascii') + b'\\n".utf8))\n' + pad + b'}\n')


def project_core(original):
    """Instrument only the SHA-bound admissions; retain a complete reversible edit log."""
    _require(type(original) is bytes and hashlib.sha256(original).hexdigest() == CORE_SHA256)
    projected, edits = original, []

    def replace(old, new):
        nonlocal projected
        _require(projected.count(old) == 1 and old != new)
        projected = projected.replace(old, new, 1)
        edits.append((old, new))

    old = (b'  private let reader: any FolderReplacementSnapshotReading\n\n'
           b'  public init() { reader = FolderReplacementDefaultSnapshotReader() }\n'
           b'  init(reader: any FolderReplacementSnapshotReading) { self.reader = reader }\n')
    new = (b'  private let reader: any FolderReplacementSnapshotReading\n'
           b'  private let diagnosticTrace: Bool\n\n'
           b'  public init() { reader = FolderReplacementDefaultSnapshotReader(); diagnosticTrace = false }\n'
           b'  init(reader: any FolderReplacementSnapshotReading, diagnosticTrace: Bool = false) { '
           b'self.reader = reader; self.diagnosticTrace = diagnosticTrace }\n')
    replace(old, new)
    terms = [b'case .literal = query.mode', b'!query.pattern.isEmpty',
             b'query.pattern.utf8.count <= limits.maxPatternUTF8Bytes',
             b'replacement.utf8.count <= limits.maxReplacementUTF8Bytes',
             b'selectedURLs.count <= limits.maxFiles',
             b'FolderReplacementPathPolicy.valid(root, requiresDirectory: true)',
             b'selectedURLs.allSatisfy(validURL)']
    old = b'    guard ' + b',\n      '.join(terms) + b'\n    else { throw FolderReplacementPreviewError.invalidRequest }\n'
    traced = terms.copy()
    traced[5] = b'FolderReplacementPathPolicy.valid(root, requiresDirectory: true, diagnosticTrace: diagnosticTrace)'
    guards = [b'    guard ' + term + b' else { throw FolderReplacementPreviewError.invalidRequest }\n'
              for term in traced]
    replace(old, b''.join(guards[:5]) + _core_marker(2) + _core_marker(3)
            + guards[5] + _core_marker(4) + _core_marker(5)
            + _PREDICATE_SELECTED_SOURCE + guards[6]
            + _core_marker(6) + _core_marker(7))
    validate = b'    try validate(limits)\n'
    replace(validate, _core_marker(0) + b'    defer {\n' + _core_marker(9, 6)
            + b'    }\n' + validate + _core_marker(1))
    replace(b'  private func validURL(_ url: URL) -> Bool { FolderReplacementPathPolicy.valid(url) }',
            _PREDICATE_WRAPPER_SOURCE)
    replace(b'  private static func serializedPathContainsNUL(_ url: URL) -> Bool {',
            b'  private static func serializedPathContainsNUL(\n'
            b'    _ url: URL, diagnosticTrace: Bool = false\n  ) -> Bool {')
    replace(b'    for byte in url.absoluteString.utf8 {',
            _core_marker(20) + b'    let absoluteString = url.absoluteString\n'
            + _core_marker(21) + b'    for byte in absoluteString.utf8 {')
    serialized = (b'      if byte == 0 || (beforePrevious == 0x25 && previous == 0x30 && byte == 0x30) {\n'
                  b'        return true\n')
    replace(serialized, serialized.replace(b'        return true\n', _core_marker(22, 8) + b'        return true\n'))
    replace(b'      previous = byte\n    }\n    return false\n',
            b'      previous = byte\n    }\n' + _core_marker(23) + b'    return false\n')
    old = (b'    _ url: URL, requiresDirectory: Bool = false,\n'
           b'    decodedPath: (URL) -> String = FolderReplacementPathPolicy.path\n'
           b'  ) -> Bool {\n    guard !serializedPathContainsNUL(url),\n'
           b'      url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost"\n'
           b'    else {\n      return false\n    }\n')
    new = (b'    _ url: URL, requiresDirectory: Bool = false,\n'
           b'    decodedPath: (URL) -> String = FolderReplacementPathPolicy.path,\n'
           b'    diagnosticTrace: Bool = false\n  ) -> Bool {\n'
           + _core_marker(10) + b'    defer {\n' + _core_marker(24, 6) + b'    }\n'
           b'    guard !serializedPathContainsNUL(url, diagnosticTrace: diagnosticTrace) else { return false }\n'
           + _core_marker(12) + b'    guard url.isFileURL else { return false }\n'
           + _core_marker(13) + b'    guard url.host == nil || url.host == "" || url.host == "localhost" else { return false }\n'
           + _core_marker(14))
    replace(old, new)
    for old, new in [
        (b'    let decoded = decodedPath(url)\n', b'    let decoded = decodedPath(url)\n' + _core_marker(15)),
        (b'    // Selected regular-file inputs cannot silently shed directory-only terminal semantics.\n',
         _core_marker(16) + b'    // Selected regular-file inputs cannot silently shed directory-only terminal semantics.\n'),
        (b'    // A URI with conflicting decoded/actual filesystem views cannot choose between two files.\n',
         _core_marker(17) + b'    // A URI with conflicting decoded/actual filesystem views cannot choose between two files.\n'),
        (b'    return url.withUnsafeFileSystemRepresentation { pointer in\n',
         b'    return url.withUnsafeFileSystemRepresentation { pointer in\n' + _core_marker(18, 6)),
        (b'      guard let filesystem = String(validatingCString: pointer) else { return false }\n',
         b'      guard let filesystem = String(validatingCString: pointer) else { return false }\n' + _core_marker(19, 6))]:
        replace(old, new)
    inverse = projected
    for old, new in reversed(edits):
        _require(inverse.count(new) == 1)
        inverse = inverse.replace(new, old, 1)
    _require(inverse == original and projected.count(CORE_TAG) == 23
             and projected.count(_PREDICATE_TAG) == 2)
    return projected


def project_test(original):
    projected = _project_path_test(original)
    loop = b'      for (urls, query, replacement, limits) in requestCases {\n'
    end = b'      let exact = try preview(\n'
    _require(projected.count(loop) == projected.count(end) == 1)
    start, stop = projected.index(loop), projected.index(end)
    interval = projected[start:stop]
    builder = b'builder: .init(reader: reader)'
    _require(interval.count(builder) == 1)
    enumerated = b'      for (ordinal, (urls, query, replacement, limits)) in requestCases.enumerated() {\n'
    flagged = b'builder: .init(reader: reader, diagnosticTrace: ordinal == 10)'
    modified = interval.replace(loop, enumerated, 1).replace(builder, flagged, 1)
    inverse = modified.replace(enumerated, loop, 1).replace(flagged, builder, 1)
    _require(inverse == interval)
    return projected[:start] + modified + projected[stop:]


def _projection_metadata(originals, projected):
    return dict(target=TARGET, originalSHA256=hashlib.sha256(originals[TARGET]).hexdigest(),
                projectedSHA256=hashlib.sha256(projected[TARGET]).hexdigest(), records=len(SEQUENCE),
                coreTarget=CORE_TARGET, coreOriginalSHA256=hashlib.sha256(originals[CORE_TARGET]).hexdigest(),
                coreProjectedSHA256=hashlib.sha256(projected[CORE_TARGET]).hexdigest())


def _core_next(state):
    """Finite observed call grammar. A successful comparison may return either Bool."""
    phase, role, passing = state
    fixed = {
        'start': {0: ('entry', 'none', False)},
        'entry': {1: ('limits', 'none', False), 9: ('end', 'none', False)},
        'limits': {2: ('scalars', 'none', False), 9: ('end', 'none', False)},
        'scalars': {3: ('root-call', 'none', False)},
        'root-call': {10: ('valid', 'root', False)},
        'root-done': {5: ('selected-call', 'none', False)},
        'selected-call': {10: ('valid', 'selected', False)},
        'selected-done': {7: ('admitted', 'none', False)},
        'admitted': {9: ('end', 'none', False)}, 'end': {}}
    if phase in fixed:
        return fixed[phase]
    steps = {'valid': {20: ('serialized', False)}, 'serialized': {21: ('bytes', False)},
             'bytes': {22: ('nul', False), 23: ('clean', False)},
             'nul': {24: ('returned', False)}, 'clean': {12: ('serialized-accepted', False)},
             'serialized-accepted': {13: ('file-accepted', False), 24: ('returned', False)},
             'file-accepted': {14: ('host-accepted', False), 24: ('returned', False)},
             'host-accepted': {15: ('decoded', False)},
             'decoded': {16: ('decoded-accepted', False), 24: ('returned', False)},
             'decoded-accepted': {17: ('directory-accepted', False), 24: ('returned', False)},
             'directory-accepted': {18: ('pointer', False)},
             'pointer': {19: ('filesystem', False), 24: ('returned', False)},
             'filesystem': {24: ('returned', True)}}
    if phase == 'returned':
        result = {9: ('end', 'none', False)}
        if passing:
            result[4 if role == 'root' else 6] = (
                'root-done' if role == 'root' else 'selected-done', 'none', False)
        return result
    return {code: (next_phase, role, flag) for code, (next_phase, flag) in steps[phase].items()}


def _core_report(state, stage, count):
    return dict(coreStage=stage, coreRole=state[1], coreRecords=count,
                coreHorizon=('not-entered' if count == 0 else
                             'builder-left' if stage == 9 else 'call-entered-prefix'))


def _core_position(trace, horizon):
    """Bind a closed report to the canonical request-11 call interval."""
    outer = paths = ended = 0
    stage = ordinal = None
    position = 'before'
    for event in [None, *_trace_grammar()]:
        if event is not None:
            if event[0] == 'outer':
                outer += 1
            else:
                paths += 1
                stage, ordinal = event[1:]
                if ordinal == 11 and stage == 7:
                    position = 'window'
                elif ordinal == 11 and stage == 8:
                    position = 'after'
                if stage == 5:
                    ended += 1
        missing = paths - trace['pathRecords']
        if (0 <= missing <= 2 * ended and missing % 2 == 0
                and trace == _trace_report(outer, trace['pathRecords'], stage, ordinal)):
            _require((horizon == 'not-entered' and position in ('before', 'window'))
                     or (horizon == 'call-entered-prefix' and position == 'window')
                     or (horizon == 'builder-left' and position in ('window', 'after')))
            return
    raise ValueError('diagnostic evidence refused')


def parse_trace(stdout, stderr, *, refusal=None):
    _require(type(stdout) is bytes and type(stderr) is bytes)
    clean = []
    marker_stream = None
    total = outer_count = core_count = 0
    window = False
    state, stage = ('start', 'none', False), -1
    for stream, raw in (('stdout', stdout), ('stderr', stderr)):
        kept = []
        for line in raw.splitlines(keepends=True):
            stripped = line.strip()
            potential = (b'CI_FOLDER_PREVIEW_' in line
                         or (bool(stripped) and any(tag.startswith(stripped)
                             for tag in (TAG, PATH_TAG, CORE_TAG))))
            if not potential:
                kept.append(line)
                continue
            _parser_require(marker_stream is None or marker_stream == stream, refusal, 0)
            marker_stream = stream
            total += 1
            _parser_require(total <= RECORD_LIMIT, refusal, 1)
            core = re.fullmatch(rb'CI_FOLDER_PREVIEW_CORE s=(2[0-4]|1[023-9]|[0-79])\n', line)
            if core is not None:
                _parser_require(window and core_count < CORE_RECORD_LIMIT, refusal, 3)
                stage = int(core[1])
                transitions = _core_next(state)
                _parser_transition_require(stage in transitions, refusal, state, stage)
                state = transitions[stage]
                core_count += 1
                continue
            outer = re.fullmatch(rb'CI_FOLDER_PREVIEW_TRACE p=([0-9]) e=([01])\n', line)
            path = re.fullmatch(rb'CI_FOLDER_PREVIEW_PATH s=(10|[0-9])\n', line)
            _parser_require(outer is not None or path is not None, refusal, 2)
            if window:
                _parser_require(path is not None and int(path[1]) == 8 and state[0] == 'end', refusal, 5)
                window = False
            if outer is not None:
                outer_count += 1
            else:
                current = SEQUENCE[outer_count - 1] if 0 < outer_count <= len(SEQUENCE) else None
                request = (outer_count - 11) // 2 + 1 if current == (5, 0) else None
                if request == 11 and int(path[1]) == 7:
                    _parser_require(core_count == 0, refusal, 3)
                    window = True
            kept.append(line)
        clean.append(b''.join(kept))
    try:
        trace = _parse_path_trace(*clean)
    except ValueError:
        _parser_refusal_mark(refusal, 6)
        raise
    core = _core_report(state, stage, core_count)
    try:
        _core_position(trace, core['coreHorizon'])
    except ValueError:
        _parser_refusal_mark(refusal, 7)
        raise
    return dict(trace, **core)


def _validate_core_report(trace):
    keys = {'coreStage', 'coreRole', 'coreRecords', 'coreHorizon'}
    _require(type(trace) is dict and keys <= set(trace))
    _require(type(trace['coreStage']) is int and type(trace['coreRecords']) is int)
    _require(type(trace['coreRole']) is str and type(trace['coreHorizon']) is str)
    wanted = {key: trace[key] for key in keys}
    pending = [(('start', 'none', False), -1, 0)]
    seen = set()
    while pending:
        state, stage, count = pending.pop()
        if (state, stage, count) in seen:
            continue
        seen.add((state, stage, count))
        if wanted == _core_report(state, stage, count):
            return
        _require(count <= 35)
        pending.extend((next_state, code, count + 1)
                       for code, next_state in _core_next(state).items())
    raise ValueError('diagnostic evidence refused')


def render(result):
    if result.get('state') == 'unavailable':
        return _render_path(result)
    trace = result['trace']
    core_keys = {'coreStage', 'coreRole', 'coreRecords', 'coreHorizon'}
    path_keys = {'phase', 'edge', 'records', 'horizon', 'pathStage', 'requestOrdinal',
                 'pathRecords', 'pathHorizon'}
    _require(type(trace) is dict and set(trace) == path_keys | core_keys)
    old = {key: trace[key] for key in path_keys}
    _valid_trace_report(old)
    _validate_core_report(trace)
    _core_position(old, trace['coreHorizon'])
    lines = _render_path(dict(result, trace=old))
    if len(lines) == 2:
        return lines
    lines.insert(3, 'core: stage=' + str(trace['coreStage']) + ' role=' + trace['coreRole']
                 + ' horizon=' + trace['coreHorizon'] + ' records=' + str(trace['coreRecords']))
    _require(len(('\n'.join(lines) + '\n').encode('ascii')) <= 512)
    return lines


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    progress = _AvailabilityProgress()
    parser_refusal = _ParserRefusal()
    try:
        _availability_enter(progress, 0)
        validate_cli(argv)  # No files, imports or child work precede closed admission.
        _availability_enter(progress, 1)
        os.umask(0o077)
        path = Path(__file__).absolute()
        root = path.parents[1]
        _require(path == root / LOCATION)
        _owned(root, path)
        _availability_enter(progress, 2)
        local = root / '.local'
        if not local.exists():
            local.mkdir(mode=0o700)
        _owned(root, local, True)  # Preserve an existing shared ignored parent's mode.
        parent = local / 'ci-folder-preview-trace'
        _mkdir(local, parent)
        run = Path(tempfile.mkdtemp(prefix='run.', dir=parent))
        run.chmod(0o700)
        _availability_enter(progress, 3)
        plan = make_plan(root, run)
        _availability_enter(progress, 4)
        manifest = freeze(root, run, plan)
        _availability_enter(progress, 5)
        watchdog = _load_module(run, run / 'Tools/run-owned-search-tests.py',
                                'folder_trace_watchdog', WATCH_SHA)
        result = execute(root, run, plan, manifest, watchdog.main,
                         progress=progress, parser_refusal=parser_refusal)
        _availability_enter(progress, 20)
        _save(run / 'result.json', result)
    except (OSError, ValueError, TypeError, KeyError, AttributeError, RuntimeError, ImportError):
        _availability_fail(progress)
        result = dict(state='unavailable')
    _availability_enter(progress, 21)
    try:
        lines = render(result)
        _require(type(lines) is list and all(type(line) is str for line in lines))
        if (result.get('state') == 'unavailable'
                or lines == ['ci-folder-preview-trace: unavailable', 'reason: incomplete-evidence']):
            _availability_fail(progress)
            result = dict(state='unavailable')
            output = _availability_output(progress, parser_refusal=parser_refusal)
        else:
            _require(result.get('state') in ('observed', 'not-observed') and len(lines) == 5)
            output = '\n'.join(lines)
        _require(len((output + '\n').encode('ascii')) <= 512)
    except (OSError, ValueError, TypeError, KeyError, AttributeError, RuntimeError, ImportError,
            UnicodeError):
        _availability_fail(progress)
        result = dict(state='unavailable')
        output = _availability_output(progress, parser_refusal=parser_refusal)
    print(output)
    return 0 if result.get('state') in ('observed', 'not-observed') else 125


if __name__ == '__main__':
    raise SystemExit(main())
