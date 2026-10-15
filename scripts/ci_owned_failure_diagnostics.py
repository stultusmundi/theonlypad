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
_GIT_TIMEOUT = 3.0
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
    for line in text.splitlines():
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



def _report(root, status, stdout, stderr, roster):
    combined = stdout + '\n' + stderr
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
    for location in locations[:4]:
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


def main(argv=None) -> int:
    args = sys.argv[1:] if argv is None else argv
    if args:
        print('ci-core diagnostics: usage')
        return 2
    root = Path(__file__).resolve().parent.parent
    code, lines = collect(root)
    print('\n'.join(lines))
    return code


if __name__ == '__main__':
    raise SystemExit(main())
