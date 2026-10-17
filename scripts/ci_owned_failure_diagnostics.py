"""Emit a closed, bounded summary of the retained CI core watchdog capture."""
from __future__ import annotations

import json
import math
import os
from pathlib import Path
import re
import selectors
import stat
import subprocess
import sys
import time

_STATUS_LIMIT = 65_536
_LOG_LIMIT = 1_048_576
_CAPTURE_RECEIVED_LIMIT = 16_777_216
_ROSTER_BYTES_LIMIT = 1_048_576
_ROSTER_PATHS_LIMIT = 4096
_GIT_TIMEOUT = 10.0
_READ_CHUNK = 65_536
_REASON = {
    'missing': 'missing-evidence',
    'unsafe': 'unsafe-evidence',
    'oversized': 'oversized-evidence',
    'status': 'invalid-status',
    'capture': 'invalid-capture',
    'encoding': 'invalid-log-encoding',
    'roster': 'invalid-roster',
}

class _Problem(Exception):
    def __init__(self, reason: str):
        self.reason = reason

class _DuplicateKey(ValueError):
    pass

_DIR_FLAGS = os.O_RDONLY | getattr(os, 'O_DIRECTORY', 0) | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_CLOEXEC', 0)
_FILE_FLAGS = os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_NONBLOCK', 0) | getattr(os, 'O_CLOEXEC', 0)


def _int(value, low=0, high=None):
    return type(value) is int and value >= low and (high is None or value <= high)


def _owner(uid):
    return uid == os.geteuid()


def _dir_stat(info):
    return stat.S_ISDIR(info.st_mode) and _owner(info.st_uid)


def _same_stat(a, b):
    return (a.st_dev, a.st_ino, a.st_mode, a.st_uid, a.st_nlink,
            a.st_size, a.st_mtime_ns, a.st_ctime_ns) == (
            b.st_dev, b.st_ino, b.st_mode, b.st_uid, b.st_nlink,
            b.st_size, b.st_mtime_ns, b.st_ctime_ns)


def _open_root(root):
    try:
        fd = os.open(os.fspath(root), _DIR_FLAGS)
    except FileNotFoundError:
        raise _Problem(_REASON['missing'])
    except OSError:
        raise _Problem(_REASON['unsafe'])
    try:
        if not _dir_stat(os.fstat(fd)):
            raise _Problem(_REASON['unsafe'])
        return fd
    except BaseException:
        os.close(fd)
        raise


def _open_dir(parent_fd, name):
    try:
        fd = os.open(name, _DIR_FLAGS, dir_fd=parent_fd)
    except FileNotFoundError:
        raise _Problem(_REASON['missing'])
    except OSError:
        raise _Problem(_REASON['unsafe'])
    try:
        if not _dir_stat(os.fstat(fd)):
            raise _Problem(_REASON['unsafe'])
        return fd
    except BaseException:
        os.close(fd)
        raise


def _open_capture_dir(root_fd):
    local_fd = _open_dir(root_fd, '.local')
    try:
        capture_fd = _open_dir(local_fd, 'ci-core')
    finally:
        os.close(local_fd)
    return capture_fd


def _stable_leaf(dir_fd, name, limit):
    try:
        fd = os.open(name, _FILE_FLAGS, dir_fd=dir_fd)
    except FileNotFoundError:
        raise _Problem(_REASON['missing'])
    except OSError:
        raise _Problem(_REASON['unsafe'])
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or not _owner(before.st_uid) or before.st_nlink < 1:
            raise _Problem(_REASON['unsafe'])
        if before.st_size > limit:
            raise _Problem(_REASON['oversized'])
        chunks = []
        total = 0
        while True:
            try:
                block = os.read(fd, min(_READ_CHUNK, limit + 1 - total))
            except InterruptedError:
                continue
            except OSError:
                raise _Problem(_REASON['unsafe'])
            if not block:
                break
            chunks.append(block)
            total += len(block)
            if total > limit:
                raise _Problem(_REASON['oversized'])
        after = os.fstat(fd)
        try:
            named = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
        except OSError:
            raise _Problem(_REASON['unsafe'])
        if not _same_stat(before, after) or not _same_stat(after, named) or total != after.st_size:
            raise _Problem(_REASON['unsafe'])
        return b''.join(chunks)
    finally:
        os.close(fd)


def _pairs_no_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise _DuplicateKey()
        result[key] = value
    return result


def _reject_constant(_value):
    raise ValueError()


def _status(raw):
    try:
        text = raw.decode('utf-8', 'strict')
        value = json.loads(text, object_pairs_hook=_pairs_no_duplicates, parse_constant=_reject_constant)
    except (UnicodeDecodeError, ValueError, RecursionError):
        raise _Problem(_REASON['status'])
    if type(value) is not dict:
        raise _Problem(_REASON['status'])
    required = {
        'command', 'pid', 'processGroup', 'exitObserved', 'registrationError',
        'groupSignalAttempted', 'groupSignalError', 'groupCleanup', 'groupQuery',
        'waitCompleted', 'returnCode', 'waitError', 'timedOut', 'interruptedSignal',
        'truncated', 'captureComplete', 'failure', 'exit', 'captured', 'seconds',
    }
    allowed = required | {'errorType', 'errorNumber'}
    if not required.issubset(value) or not set(value).issubset(allowed):
        raise _Problem(_REASON['status'])
    command = value['command']
    if (type(command) is not list or len(command) > 256 or
            any(type(arg) is not str or '\0' in arg for arg in command)):
        raise _Problem(_REASON['status'])
    try:
        if sum(len(arg.encode('utf-8', 'strict')) for arg in command) > _STATUS_LIMIT:
            raise _Problem(_REASON['status'])
    except UnicodeEncodeError:
        raise _Problem(_REASON['status'])
    for key in ('pid', 'processGroup'):
        if value[key] is not None and not _int(value[key], 1):
            raise _Problem(_REASON['status'])
    for key in ('exitObserved', 'groupSignalAttempted', 'waitCompleted', 'timedOut', 'truncated', 'captureComplete'):
        if type(value[key]) is not bool:
            raise _Problem(_REASON['status'])
    for key in ('registrationError', 'groupSignalError'):
        if value[key] is not None and not _int(value[key], 0, 65535):
            raise _Problem(_REASON['status'])
    if value['groupCleanup'] not in ('notStarted', 'signaled', 'absent', 'unconfirmed', 'exitedLeaderOnly'):
        raise _Problem(_REASON['status'])
    if value['groupQuery'] is not None and type(value['groupQuery']) is not dict:
        raise _Problem(_REASON['status'])
    if value['returnCode'] is not None and not _int(value['returnCode'], -255, 255):
        raise _Problem(_REASON['status'])
    if not _int(value['exit'], 0, 255):
        raise _Problem(_REASON['status'])
    if value['waitError'] is not None and (type(value['waitError']) is not str or len(value['waitError']) > 128):
        raise _Problem(_REASON['status'])
    if value['failure'] is not None and (type(value['failure']) is not str or len(value['failure']) > 128):
        raise _Problem(_REASON['status'])
    interrupted = value['interruptedSignal']
    if interrupted is not None and not _int(interrupted, 1, 255):
        raise _Problem(_REASON['status'])
    if type(value['seconds']) not in (int, float) or not math.isfinite(value['seconds']) or value['seconds'] < 0:
        raise _Problem(_REASON['status'])
    if 'errorType' in value and (type(value['errorType']) is not str or len(value['errorType']) > 128):
        raise _Problem(_REASON['status'])
    if 'errorNumber' in value and value['errorNumber'] is not None and not _int(value['errorNumber'], 0, 65535):
        raise _Problem(_REASON['status'])
    captured = value['captured']
    if type(captured) is not dict or set(captured) != {'stdout', 'stderr'}:
        raise _Problem(_REASON['capture'])
    for stream in ('stdout', 'stderr'):
        counts = captured[stream]
        if type(counts) is not dict or set(counts) != {'stored', 'received', 'discarded'}:
            raise _Problem(_REASON['capture'])
        stored, received, discarded = counts['stored'], counts['received'], counts['discarded']
        if (not _int(stored, 0, _LOG_LIMIT) or not _int(received, 0, _CAPTURE_RECEIVED_LIMIT) or
                not _int(discarded, 0, _CAPTURE_RECEIVED_LIMIT) or received != stored + discarded):
            raise _Problem(_REASON['capture'])
    return value


def _read_inputs(root):
    root_fd = _open_root(root)
    try:
        capture_fd = _open_capture_dir(root_fd)
        try:
            status_raw = _stable_leaf(capture_fd, 'status.json', _STATUS_LIMIT)
            stdout_raw = _stable_leaf(capture_fd, 'stdout.log', _LOG_LIMIT)
            stderr_raw = _stable_leaf(capture_fd, 'stderr.log', _LOG_LIMIT)
        finally:
            os.close(capture_fd)
    finally:
        os.close(root_fd)
    value = _status(status_raw)
    if any(value['captured'][name]['stored'] != len(data)
           for name, data in (('stdout', stdout_raw), ('stderr', stderr_raw))):
        raise _Problem(_REASON['capture'])
    try:
        stdout = stdout_raw.decode('utf-8', 'strict')
        stderr = stderr_raw.decode('utf-8', 'strict')
    except UnicodeDecodeError:
        raise _Problem(_REASON['encoding'])
    return value, stdout, stderr


def _safe_relative_path(path):
    if type(path) is not str or not path or len(path) > 4096:
        return False
    try:
        path.encode('ascii', 'strict')
    except UnicodeEncodeError:
        return False
    if path.startswith('/') or '\\' in path or any(ord(char) < 32 or ord(char) == 127 for char in path):
        return False
    parts = path.split('/')
    return (parts[0] in ('Sources', 'Tests') and len(parts) >= 2 and
            all(part not in ('', '.', '..') for part in parts))


def _safe_location_path(path):
    return (_safe_relative_path(path) and
            all(char in 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_./-' for char in path))


def _valid_roster(paths):
    if type(paths) is not tuple or len(paths) > _ROSTER_PATHS_LIMIT:
        return None
    total = 0
    normalized = set()
    for path in paths:
        if not _safe_relative_path(path) or path in normalized:
            return None
        total += len(path)
        if total > _ROSTER_BYTES_LIMIT:
            return None
        normalized.add(path)
    return normalized


def _bounded_git_output(root):
    command = ['/usr/bin/git', '-C', os.fspath(root), 'ls-files', '--full-name', '-z', '--', 'Sources', 'Tests']
    env = {
        'PATH': '/usr/bin:/bin', 'LC_ALL': 'C', 'GIT_CONFIG_NOSYSTEM': '1',
        'GIT_CONFIG_SYSTEM': '/dev/null', 'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_OPTIONAL_LOCKS': '0',
        'GIT_TERMINAL_PROMPT': '0', 'GIT_CONFIG_COUNT': '2',
        'GIT_CONFIG_KEY_0': 'core.hooksPath', 'GIT_CONFIG_VALUE_0': '/dev/null',
        'GIT_CONFIG_KEY_1': 'core.fsmonitor', 'GIT_CONFIG_VALUE_1': 'false',
    }
    process = None
    selector = None
    deadline = time.monotonic() + _GIT_TIMEOUT
    try:
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, cwd=os.fspath(root), env=env,
                                   close_fds=True, bufsize=0)
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        os.set_blocking(process.stdout.fileno(), False)
        output = bytearray()
        eof = False
        while not eof:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise _Problem(_REASON['roster'])
            events = selector.select(remaining)
            if not events:
                raise _Problem(_REASON['roster'])
            for key, _mask in events:
                try:
                    block = os.read(key.fd, min(_READ_CHUNK, _ROSTER_BYTES_LIMIT + 1 - len(output)))
                except BlockingIOError:
                    continue
                if not block:
                    eof = True
                    selector.unregister(process.stdout)
                    break
                output.extend(block)
                if len(output) > _ROSTER_BYTES_LIMIT:
                    raise _Problem(_REASON['roster'])
        remaining = max(0.0, deadline - time.monotonic())
        try:
            code = process.wait(timeout=remaining)
        except subprocess.TimeoutExpired:
            raise _Problem(_REASON['roster'])
        if code != 0:
            raise _Problem(_REASON['roster'])
        raw = bytes(output)
        if raw and not raw.endswith(b'\0'):
            raise _Problem(_REASON['roster'])
        try:
            entries = () if not raw else tuple(part.decode('ascii', 'strict') for part in raw[:-1].split(b'\0'))
        except UnicodeDecodeError:
            raise _Problem(_REASON['roster'])
        if _valid_roster(entries) is None:
            raise _Problem(_REASON['roster'])
        return entries
    except _Problem:
        raise
    except (OSError, ValueError, subprocess.SubprocessError, UnicodeError):
        raise _Problem(_REASON['roster'])
    finally:
        if selector is not None:
            selector.close()
        if process is not None:
            if process.poll() is None:
                try:
                    process.kill()
                except OSError:
                    pass
                try:
                    process.wait(timeout=1.0)
                except (OSError, subprocess.SubprocessError):
                    pass
            if process.stdout is not None:
                process.stdout.close()


def tracked_public_roster(root):
    """Return the bounded tracked Sources/Tests roster, or None on any refusal."""
    try:
        return _bounded_git_output(root)
    except Exception:
        return None


def _safe_tracked_file(root_fd, relative):
    if not _safe_relative_path(relative):
        return False
    parts = relative.split('/')
    current = os.dup(root_fd)
    try:
        for part in parts[:-1]:
            next_fd = _open_dir(current, part)
            os.close(current)
            current = next_fd
        try:
            before = os.stat(parts[-1], dir_fd=current, follow_symlinks=False)
        except OSError:
            return False
        if not stat.S_ISREG(before.st_mode) or not _owner(before.st_uid):
            return False
        try:
            fd = os.open(parts[-1], _FILE_FLAGS, dir_fd=current)
        except OSError:
            return False
        try:
            opened = os.fstat(fd)
            named = os.stat(parts[-1], dir_fd=current, follow_symlinks=False)
            return (stat.S_ISREG(opened.st_mode) and _owner(opened.st_uid) and
                    _same_stat(before, opened) and _same_stat(opened, named))
        except OSError:
            return False
        finally:
            os.close(fd)
    except _Problem:
        return False
    finally:
        os.close(current)


def _location_candidates(root, text):
    root_text = os.path.abspath(os.fspath(root)).rstrip(os.sep)
    absolute_prefix = root_text + os.sep
    result = []
    lines = text.splitlines()
    severity = re.compile(r'[ \t]*error:')
    for error_first in (True, False):
        for line in lines:
            absolute_line = line.startswith(absolute_prefix)
            relative_line = line.startswith(('Sources/', 'Tests/'))
            if not absolute_line and not relative_line:
                continue
            for match in re.finditer(r':([0-9]{1,16})(?::([0-9]{1,16}))?:', line):
                position = match.start()
                if absolute_line:
                    if position < len(absolute_prefix):
                        continue
                    prefix_length = position - len(absolute_prefix)
                    if prefix_length > 4096:
                        break
                    relative = line[len(absolute_prefix):position]
                else:
                    if position > 4096:
                        break
                    relative = line[:position]
                if not _safe_location_path(relative):
                    continue
                line_number = int(match.group(1))
                column = int(match.group(2)) if match.group(2) is not None else None
                if not (1 <= line_number <= 1_000_000) or (column is not None and not 1 <= column <= 1_000_000):
                    continue
                # Match at the diagnostic boundary, without copying an unbounded suffix.
                if (severity.match(line, match.end()) is not None) != error_first:
                    continue
                rendered = relative + ':' + str(line_number)
                if column is not None:
                    rendered += ':' + str(column)
                if rendered not in result:
                    result.append(rendered)
                    if len(result) >= 32:
                        return result
    return result


def _admitted_locations(root, text, roster):
    candidates = _location_candidates(root, text)
    if not candidates:
        return []
    if roster is None:
        paths = tracked_public_roster(root)
    else:
        try:
            paths = roster(root)
        except Exception:
            raise _Problem(_REASON['roster'])
    tracked = _valid_roster(paths)
    if tracked is None:
        raise _Problem(_REASON['roster'])
    root_fd = _open_root(root)
    try:
        admitted = []
        for candidate in candidates:
            path = candidate.rsplit(':', 2)[0]
            if path in tracked:
                if not _safe_tracked_file(root_fd, path):
                    raise _Problem(_REASON['roster'])
                if candidate not in admitted:
                    admitted.append(candidate)
                    if len(admitted) == 4:
                        break
        return admitted
    finally:
        os.close(root_fd)


_SUMMARY_RE = re.compile(r'^Executed ([0-9]{1,7}) tests?, with ([0-9]{1,7}) failures? \(([0-9]{1,7}) unexpected\) in [0-9]+(?:\.[0-9]+)?(?: \([0-9]+(?:\.[0-9]+)?\))? seconds?$', re.IGNORECASE)
_SIMPLE_SIGNALS = {
    'compiler': ('error:',),
    'crash': (),
    'dependency': ('no such module', 'failed to resolve dependencies'),
    'permission': ('permission denied',),
    'resource': ('no space left on device', 'out of memory', 'memory pressure'),
}


def _word_character(character):
    return character == '_' or character.isalnum()


def _has_word_after(text, word, start):
    position = start
    while True:
        position = text.find(word, position)
        if position < 0:
            return False
        end = position + len(word)
        before_boundary = position == 0 or not _word_character(text[position - 1])
        after_boundary = end == len(text) or not _word_character(text[end])
        if before_boundary and after_boundary:
            return True
        position += 1


def _contains_word_phrase(text, phrase):
    position = 0
    while True:
        position = text.find(phrase, position)
        if position < 0:
            return False
        end = position + len(phrase)
        if ((position == 0 or not _word_character(text[position - 1])) and
                (end == len(text) or not _word_character(text[end]))):
            return True
        position += 1


def _test_case_terminal_failure(line):
    folded = line.casefold()
    if not folded.startswith('test case '):
        return False
    marker = folded.rfind(' failed')
    if marker < 0:
        return False
    suffix = folded[marker + len(' failed'):]
    if suffix.endswith('.'):
        suffix = suffix[:-1]
    return (not suffix or
            (suffix.startswith(' (') and suffix.endswith(')') and
             '\r' not in suffix and '\n' not in suffix))


def _summary(text):
    last = None
    for line in text.splitlines():
        match = _SUMMARY_RE.fullmatch(line.strip())
        if not match:
            continue
        tests, failures, unexpected = (int(group) for group in match.groups())
        if max(tests, failures, unexpected) > 1_000_000 or unexpected > failures:
            continue
        last = f'xctest: tests={tests} failures={failures} unexpected={unexpected}'
    return last or 'xctest: not-observed'


def _signal_counts(text):
    counts = {'compiler': 0, 'test': 0, 'crash': 0, 'dependency': 0,
              'permission': 0, 'resource': 0}
    for line in text.splitlines():
        folded = line.casefold()
        if any(token in folded for token in _SIMPLE_SIGNALS['compiler']):
            counts['compiler'] = min(10_000, counts['compiler'] + 1)
        error_position = folded.find('error:')
        if ((error_position >= 0 and _has_word_after(folded, 'failed', error_position + len('error:')))
                or _test_case_terminal_failure(line)):
            counts['test'] = min(10_000, counts['test'] + 1)
        if (any(_contains_word_phrase(folded, token) for token in
                ('fatal error', 'segmentation fault', 'uncaught exception', 'crashed')) or
                _has_signal_number(folded)):
            counts['crash'] = min(10_000, counts['crash'] + 1)
        dependency_position = folded.find('dependency resolution')
        if (any(token in folded for token in _SIMPLE_SIGNALS['dependency']) or
                (dependency_position >= 0 and
                 folded.find('failed', dependency_position + len('dependency resolution')) >= 0)):
            counts['dependency'] = min(10_000, counts['dependency'] + 1)
        if any(token in folded for token in _SIMPLE_SIGNALS['permission']):
            counts['permission'] = min(10_000, counts['permission'] + 1)
        if any(token in folded for token in _SIMPLE_SIGNALS['resource']):
            counts['resource'] = min(10_000, counts['resource'] + 1)
    return counts


def _has_signal_number(text):
    position = 0
    marker = 'signal '
    while True:
        position = text.find(marker, position)
        if position < 0:
            return False
        if position == 0 or not _word_character(text[position - 1]):
            digit = position + len(marker)
            end = digit
            while end < len(text) and '0' <= text[end] <= '9':
                end += 1
            if end > digit and (end == len(text) or not _word_character(text[end])):
                return True
        position += 1



# These are capture-text observations, never compiled-test or failure-cause identities.
_EVENT_ID = r'[A-Za-z_][A-Za-z0-9_]{0,127}'
_EVENT_CLASS = _EVENT_ID + r'(?:\.' + _EVENT_ID + r'){0,2}'
_EVENT_METHOD = r'test[A-Za-z0-9_]{0,124}'
_EVENT_CASE = r'(?:-\[(?P<objc_class>' + _EVENT_CLASS + r') (?P<objc_method>' + _EVENT_METHOD + r')\]|(?P<dotted_class>' + _EVENT_CLASS + r')\.(?P<dotted_method>' + _EVENT_METHOD + r'))'
_EVENT_RECORD = re.compile(
    r"Test Case '" + _EVENT_CASE + r"' (?:(?P<start>started)\.|(?P<terminal>passed|failed|skipped) \([0-9]{1,6}(?:\.[0-9]{1,6})? seconds\)\.)\n", re.ASCII)


def _event_observation(status, stdout, stderr):
    if (not status['exitObserved'] or not status['waitCompleted'] or
            status['timedOut'] or status['truncated'] or not status['captureComplete'] or
            status['interruptedSignal'] is not None or status['failure'] is not None or
            status['waitError'] is not None or not _int(status['returnCode'], 1, 255) or
            status['exit'] != status['returnCode'] or
            any(counts['discarded'] or counts['stored'] != counts['received']
                for counts in status['captured'].values())):
        return None
    observed_stream = False
    selected = None
    for text in (stdout, stderr):
        seen, active, failed = set(), set(), []
        count = 0
        # Only LF separates records. VT/FF are neither separators nor horizontal whitespace.
        lines = text.split('\n')
        for index, fragment in enumerate(lines):
            if not fragment.lstrip(' \t').startswith('Test Case'):
                continue
            count += 1
            if count > 8192 or index == len(lines) - 1:
                return None
            record = fragment + '\n'
            if len(record.encode('utf-8')) > 4096:
                return None
            match = _EVENT_RECORD.fullmatch(record)
            if match is None:
                return None
            identity = (match['objc_class'] or match['dotted_class'],
                        match['objc_method'] or match['dotted_method'])
            if match['start']:
                if identity in seen:
                    return None
                seen.add(identity)
                active.add(identity)
                if len(seen) > 4096 or len(active) > 64:
                    return None
            else:
                if identity not in active:
                    return None
                active.remove(identity)
                if match['terminal'] == 'failed':
                    failed.append(identity)
        if count:
            if observed_stream:
                return None
            observed_stream = True
            if len(failed) == 1 and not active:
                selected = ('reported-failure-event', failed[0][1])
            elif not failed and len(active) == 1:
                selected = ('started-without-terminal-at-exit', next(iter(active))[1])
    return selected


def _read_test_source(root_fd, relative, remaining):
    parts = relative.split('/')
    opened = [os.dup(root_fd)]
    directories = []
    try:
        for part in parts[:-1]:
            parent = opened[-1]
            child = _open_dir(parent, part)
            opened.append(child)
            info = os.fstat(child)
            named = os.stat(part, dir_fd=parent, follow_symlinks=False)
            if not _same_stat(info, named):
                raise _Problem(_REASON['unsafe'])
            directories.append((parent, part, child, info))
        data = _stable_leaf(opened[-1], parts[-1], min(256 * 1024, remaining))
        for parent, name, child, before in directories:
            if (not _same_stat(before, os.fstat(child)) or
                    not _same_stat(before, os.stat(name, dir_fd=parent, follow_symlinks=False))):
                raise _Problem(_REASON['unsafe'])
        return data
    finally:
        for fd in reversed(opened):
            os.close(fd)


def _source_text_candidate(root, method, roster):
    try:
        paths = roster(root)
        tests = sorted(path for path in paths
                       if path.startswith('Tests/') and path.endswith('.swift'))
        if not tests or len(tests) > 512 or any(not _safe_location_path(path) for path in tests):
            return None
        pattern = re.compile(rb'[ \t]*(?:@MainActor[ \t]+)?(?:override[ \t]+)?func[ \t]+'
                             + re.escape(method.encode('ascii')) + rb'[ \t]*\(')
        total = 0
        matches = []
        root_fd = _open_root(root)
        try:
            for path in tests:
                data = _read_test_source(root_fd, path, 8 * 1024 * 1024 - total)
                total += len(data)
                if total > 8 * 1024 * 1024:
                    return None
                for number, line in enumerate(data.split(b'\n'), 1):
                    if pattern.match(line):
                        matches.append(path + ':' + str(number))
                        if len(matches) > 1:
                            return None
        finally:
            os.close(root_fd)
        return matches[0] if len(matches) == 1 else None
    except (_Problem, OSError):
        return None


def _shared_roster(root, supplier):
    # Cache refusals as well as successes; identity and location share at most one query.
    fetched = False
    accepted = None
    problem = None

    def get(_root):
        nonlocal fetched, accepted, problem
        if not fetched:
            fetched = True
            try:
                paths = tracked_public_roster(root) if supplier is None else supplier(root)
                tracked = _valid_roster(paths)
                if tracked is None:
                    raise _Problem(_REASON['roster'])
                accepted = tuple(sorted(tracked))
            except Exception:
                problem = _Problem(_REASON['roster'])
        if problem is not None:
            raise problem
        return accepted
    return get


def _report(root, status, stdout, stderr, roster):
    combined = stdout + '\n' + stderr
    roster = _shared_roster(root, roster)
    observation = _event_observation(status, stdout, stderr)
    candidate = _source_text_candidate(root, observation[1], roster) if observation else None
    locations = _admitted_locations(root, combined, roster)
    signals = _signal_counts(combined)
    result = [
        'ci-core diagnostics: observed',
        'watchdog: exit={} returnCode={} timedOut={} truncated={} captureComplete={} waitCompleted={}'.format(
            status['exit'], 'null' if status['returnCode'] is None else status['returnCode'],
            str(status['timedOut']).lower(), str(status['truncated']).lower(),
            str(status['captureComplete']).lower(), str(status['waitCompleted']).lower()),
        'captures: stdout={} stderr={}'.format(status['captured']['stdout']['stored'], status['captured']['stderr']['stored']),
        _summary(combined),
        'signals: compiler={} test={} crash={} dependency={} permission={} resource={}'.format(
            signals['compiler'], signals['test'], signals['crash'], signals['dependency'],
            signals['permission'], signals['resource']),
        'xctest-id: unknown',
    ]
    total_bytes = sum(len(line.encode('ascii')) for line in result) + len(result)
    location_limit = 4
    if candidate is not None:
        identity = 'xctest-id: ' + observation[0] + ' source-text-candidate ' + candidate
        proposed_bytes = total_bytes - len(result[-1]) + len(identity)
        if proposed_bytes <= 2048:
            result[-1] = identity
            total_bytes = proposed_bytes
            location_limit = 3
    for location in locations[:location_limit]:
        line = 'location: ' + location
        line_bytes = len(line.encode('ascii')) + 1
        if len(result) < 10 and total_bytes + line_bytes <= 2048:
            result.append(line)
            total_bytes += line_bytes
    return 0, result


def collect(root: Path, *, roster=None) -> tuple[int, list[str]]:
    """Read fixed capture evidence and return only the closed diagnostic grammar."""
    try:
        status, stdout, stderr = _read_inputs(root)
        return _report(root, status, stdout, stderr, roster)
    except _Problem as problem:
        return 2, ['ci-core diagnostics: unavailable', 'reason: ' + problem.reason]
    except Exception:
        return 2, ['ci-core diagnostics: unavailable', 'reason: invalid-status']


# Opt-in text-family observation. No source identity or causal attribution is granted.
_DETAIL_FIELDS = ('kinds', 'isolation', 'ownedSignal', 'reportedSignalState', 'reportedSignal')
_DETAIL_REASONS = frozenset(('missing-evidence', 'unsafe-evidence', 'oversized-evidence',
    'invalid-status', 'invalid-capture', 'invalid-log-encoding', 'incomplete-evidence',
    'detail-scan-limit', 'invalid-detail'))
_DETAIL_ASCII_LOWER = str.maketrans('ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz')
_DETAIL_SIGNAL = 'error: Exited with unexpected signal code'
_DETAIL_EXECUTOR = 'Incorrect actor executor assumption'
# A nested diagnostic-shaped suffix makes isolation payload attribution ambiguous.
_DETAIL_NESTED_LOCATION = re.compile(
    r'\.swift:[1-9][0-9]{0,7}(?::[1-9][0-9]{0,7})?: (?:error|warning|note|Fatal error): ', re.ASCII)
# Colons cannot be path characters here: a later location in the payload cannot
# replace the first location/severity boundary. Paths stay internal and opaque.
_DETAIL_SOURCE = re.compile(
    r"(?P<path>(?:/[^:\x00-\x1f\x7f\"']*|(?:Sources|Tests)/[^:\x00-\x1f\x7f\"']*|[A-Za-z0-9_.-]+)\.swift)"
    r":(?P<line>[1-9][0-9]{0,7})(?::(?P<column>[1-9][0-9]{0,7}))?: "
    r"(?P<severity>error|warning|note|Fatal error): (?P<payload>.*)", re.ASCII)


def _detail_complete(status):
    # The collector has already applied the existing strict _status validator.
    try:
        code = status['returnCode']
        if (any(status[key] is not True for key in ('exitObserved', 'waitCompleted', 'captureComplete'))
                or any(status[key] is not False for key in ('timedOut', 'truncated'))
                or any(status[key] is not None for key in
                       ('waitError', 'failure', 'registrationError', 'interruptedSignal'))
                or status.get('errorType') is not None or status.get('errorNumber') is not None
                or status['groupCleanup'] not in ('absent', 'signaled', 'exitedLeaderOnly')
                or not _int(code, -127, 255)
                or not _int(status['exit'], 0, 255)
                or status['exit'] != (code if code >= 0 else 128 - code)):
            return False
        captured = status['captured']
        return (type(captured) is dict and set(captured) == {'stdout', 'stderr'}
                and all(type(row) is dict and set(row) == {'stored', 'received', 'discarded'}
                        and _int(row['stored'], 0, _LOG_LIMIT)
                        and _int(row['received'], 0, _CAPTURE_RECEIVED_LIMIT)
                        and type(row['discarded']) is int and row['discarded'] == 0
                        and row['stored'] == row['received'] for row in captured.values()))
    except (KeyError, TypeError, AttributeError):
        return False


def _detail_records(text):
    start = 0
    while start < len(text):
        lf = text.find('\n', start)
        end = len(text) if lf < 0 else lf + 1
        record = text[start:end]
        if len(record.encode('utf-8')) > 8192:
            raise _Problem('detail-scan-limit')
        content = record[:-1] if lf >= 0 else record
        if lf >= 0 and content.endswith('\r'):
            content = content[:-1]
        if any((ord(char) < 32 and char != '\t') or ord(char) == 127 for char in content):
            raise _Problem('invalid-detail')
        yield content
        start = end


def _detail_isolation_payload(payload):
    if _DETAIL_NESTED_LOCATION.search(payload) is not None:
        return False
    folded = payload.translate(_DETAIL_ASCII_LOWER)
    return any(_contains_word_phrase(folded, phrase)
               for phrase in ('actor-isolated', 'actor isolation'))


def _detail_executor_payload(payload):
    return (payload.startswith(_DETAIL_EXECUTOR)
            and (len(payload) == len(_DETAIL_EXECUTOR) or payload[len(_DETAIL_EXECUTOR)] == ';'))


def classify_error_detail(status, stdout, stderr):
    """Classify bounded capture text, never its emitter, test identity or cause."""
    if not _detail_complete(status):
        raise _Problem('incomplete-evidence')
    result = dict(kinds=0, isolation=0,
                  ownedSignal=-status['returnCode'] if status['returnCode'] < 0 else 0,
                  reportedSignalState=0, reportedSignal=0)
    reported, conflict, malformed = 0, False, False
    for name, text in (('stdout', stdout), ('stderr', stderr)):
        if type(text) is not str:
            raise _Problem('invalid-detail')
        if len(text) > _LOG_LIMIT:
            raise _Problem('oversized-evidence')
        try:
            size = len(text.encode('utf-8'))
        except UnicodeEncodeError:
            raise _Problem('invalid-log-encoding')
        if size > _LOG_LIMIT:
            raise _Problem('oversized-evidence')
        if size != status['captured'][name]['stored']:
            raise _Problem('invalid-capture')
        for record in _detail_records(text):
            source = _DETAIL_SOURCE.fullmatch(record)
            if source is not None:
                if (int(source['line']) > 10_000_000
                        or (source['column'] is not None and int(source['column']) > 10_000_000)):
                    continue
                severity, payload = source['severity'], source['payload']
                if severity == 'error':
                    result['kinds'] |= 1
                    if _detail_isolation_payload(payload):
                        result['isolation'] |= 1
                elif severity == 'warning':
                    if _detail_isolation_payload(payload):
                        result['isolation'] |= 2
                elif severity == 'Fatal error' and source['column'] is None:
                    result['kinds'] |= 8
                    if _detail_executor_payload(payload):
                        result['isolation'] |= 4
                continue
            if record == _DETAIL_SIGNAL or record.startswith(_DETAIL_SIGNAL + ' '):
                number = record[len(_DETAIL_SIGNAL):]
                if re.fullmatch(r' [1-9][0-9]{0,2}', number, re.ASCII) and int(number) <= 127:
                    value = int(number)
                    result['kinds'] |= 16
                    if reported == 0:
                        reported = value
                    elif reported != value:
                        conflict = True
                else:
                    malformed = True
            elif record == 'error: fatalError':
                result['kinds'] |= 32
            elif record.startswith('error: '):
                result['kinds'] |= 2
            elif record.startswith('Fatal error: '):
                result['kinds'] |= 8
                if _detail_executor_payload(record[len('Fatal error: '):]):
                    result['isolation'] |= 4
            else:
                terminal = _EVENT_RECORD.fullmatch(record + '\n')
                if terminal is not None and terminal['terminal'] == 'failed':
                    result['kinds'] |= 4
    state = 3 if malformed else 2 if conflict else 1 if reported else 0
    result['reportedSignalState'] = state
    result['reportedSignal'] = reported if state == 1 else 0
    return result


def render_error_detail(detail):
    if (type(detail) is not dict or set(detail) != set(_DETAIL_FIELDS)
            or any(type(detail[key]) is not int for key in _DETAIL_FIELDS)
            or not 0 <= detail['kinds'] <= 63 or not 0 <= detail['isolation'] <= 7
            or not 0 <= detail['ownedSignal'] <= 127
            or not 0 <= detail['reportedSignalState'] <= 3
            or not 0 <= detail['reportedSignal'] <= 127
            or ((detail['reportedSignalState'] == 1) != (detail['reportedSignal'] != 0))):
        raise ValueError('invalid closed error detail')
    lines = ['ci-core error-detail: observed',
        'detail-v1: kinds={kinds} isolation={isolation} ownedSignal={ownedSignal} '
        'reportedSignalState={reportedSignalState} reportedSignal={reportedSignal}'.format(**detail)]
    if len(('\n'.join(lines) + '\n').encode('ascii')) > 256:
        raise ValueError('invalid closed error detail')
    return lines


def collect_error_detail(root):
    try:
        status, stdout, stderr = _read_inputs(root)
        return 0, render_error_detail(classify_error_detail(status, stdout, stderr))
    except _Problem as problem:
        reason = problem.reason if type(problem.reason) is str and problem.reason in _DETAIL_REASONS else 'invalid-detail'
        return 2, ['ci-core error-detail: unavailable', 'reason: ' + reason]
    except Exception:
        return 2, ['ci-core error-detail: unavailable', 'reason: invalid-detail']


def main(argv=None) -> int:
    args = sys.argv[1:] if argv is None else argv
    if args == ['--error-detail']:
        root = Path(__file__).resolve().parent.parent
        code, lines = collect_error_detail(root)
        print('\n'.join(lines))
        return code
    if args not in ([], ['--summary-only']):
        print('ci-core diagnostics: usage')
        return 2
    root = Path(__file__).resolve().parent.parent
    # This explicit fallback carries no file-location authority and never queries Git.
    code, lines = collect(root, roster=lambda _root: ()) if args else collect(root)
    print('\n'.join(lines))
    return code


if __name__ == '__main__':
    raise SystemExit(main())
