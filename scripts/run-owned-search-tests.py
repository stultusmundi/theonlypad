#!/usr/bin/env python3
"""Bounded macOS test runner with exact process-group ownership.

Observe the unreaped leader's exit, signal its still-owned group, then wait.
This is an outer guard for fixed test fixtures, not a malicious-process sandbox.
"""
from __future__ import annotations

import argparse
import ctypes
import errno
import json
import math
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import time

CAPTURE_LIMIT = 1_048_576
READ_SIZE = 65_536
READS_PER_EVENT = 4
EVENT_LIMIT = 8
POLL_SECONDS = 0.05
TAIL_SECONDS = 0.25
WAIT_SECONDS = 5.0
GROUP_MEMBER_CAPACITY = 256


class StopRequest:
    """Handlers set intent rather than raising between spawn and PID retention."""
    def __init__(self):
        self.signal = None

    def request(self, signum):
        if self.signal is None:
            self.signal = int(signum)


class ProcessRegistrationError(OSError):
    """EV_ERROR for the process filter can be delivered with later events."""


class _StopBeforeSpawn(Exception):
    """A preexisting stop request has no child ownership to clean up."""


def _sigchld_reapable():
    # Darwin's public sigaction ABI: handler union, uint32 signal mask, int flags.
    # Query only; never alter a host's signal policy to make a test run.
    class Action(ctypes.Structure):
        _fields_ = [('handler', ctypes.c_void_p), ('mask', ctypes.c_uint32),
                    ('flags', ctypes.c_int)]
    libc = ctypes.CDLL(None, use_errno=True)
    query = libc.sigaction
    query.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.POINTER(Action)]
    query.restype = ctypes.c_int
    action = Action()
    if query(signal.SIGCHLD, None, ctypes.byref(action)) != 0:
        raise OSError(ctypes.get_errno(), 'cannot inspect SIGCHLD policy')
    # SA_NOCLDWAIT is 0x0020 in Darwin sys/signal.h.
    # Any custom handler could reap this child too; standalone operation needs
    # only SIG_DFL (represented as a null pointer), never an unproved handler.
    return not action.handler and not action.flags & 0x0020


class Runtime:
    """Actual OS adapter. Only run's finally block is allowed to reap its child."""
    def __init__(self):
        required = ('kqueue', 'kevent', 'KQ_FILTER_PROC', 'KQ_NOTE_EXIT',
                    'KQ_FILTER_READ', 'KQ_EV_ADD', 'KQ_EV_ENABLE', 'KQ_EV_ONESHOT',
                    'KQ_EV_ERROR', 'KQ_EV_DELETE')
        if sys.platform != 'darwin' or any(not hasattr(select, name) for name in required):
            raise RuntimeError('macOS kqueue process observation is required')
        if not _sigchld_reapable():
            raise RuntimeError('SIGCHLD policy must preserve the owned unreaped child')
        self.queue = None
        self.streams = {}

    def now(self):
        return time.monotonic()

    def start(self, argv, environment):
        return subprocess.Popen(argv, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                env=environment, shell=False, close_fds=True,
                                start_new_session=True, restore_signals=True)

    def observe(self, child):
        self.queue = select.kqueue()
        for name, stream in [('stdout', child.stdout), ('stderr', child.stderr)]:
            fd = stream.fileno()
            os.set_blocking(fd, False)
            self.streams[name] = fd
            self.queue.control([select.kevent(
                fd, filter=select.KQ_FILTER_READ,
                flags=select.KQ_EV_ADD | select.KQ_EV_ENABLE)], 0, 0)
        self.queue.control([select.kevent(
            child.pid, filter=select.KQ_FILTER_PROC,
            flags=select.KQ_EV_ADD | select.KQ_EV_ENABLE | select.KQ_EV_ONESHOT,
            fflags=select.KQ_NOTE_EXIT)], 0, 0)

    def events(self, timeout, maximum):
        if self.queue is None:
            return []
        result = []
        for event in self.queue.control(None, maximum, timeout):
            if event.flags & select.KQ_EV_ERROR:
                if event.data:
                    error_type = (ProcessRegistrationError
                                  if event.filter == select.KQ_FILTER_PROC else OSError)
                    raise error_type(int(event.data), 'kqueue event error')
                continue
            if event.filter == select.KQ_FILTER_PROC and event.fflags & select.KQ_NOTE_EXIT:
                result.append('exit')
            elif event.filter == select.KQ_FILTER_READ:
                result.extend(name for name, fd in self.streams.items() if fd == event.ident)
        return result

    def read(self, stream, maximum):
        if stream not in self.streams:
            return b''
        data = os.read(self.streams[stream], maximum)
        if not data:
            fd = self.streams.pop(stream)
            # Do not close/reuse an integer while an old event can name it.
            # It remains open until final queue/stream teardown below.
            self.queue.control([select.kevent(fd, filter=select.KQ_FILTER_READ,
                                              flags=select.KQ_EV_DELETE)], 0, 0)
        return data

    def active_streams(self):
        return set(self.streams)

    def kill_group(self, pid):
        # Never use Popen.send_signal/kill/terminate: they can poll before signaling.
        os.killpg(pid, signal.SIGKILL)

    def group_members(self, pid):
        # Darwin libproc.h: int proc_listpids(uint32_t, uint32_t, void *, int).
        # PROC_PGRP_ONLY filters both active and zombie members. A fixed buffer
        # avoids an unbounded sizing/retry loop or any all-process query.
        libc = ctypes.CDLL(None, use_errno=True)
        query = libc.proc_listpids
        query.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_int]
        query.restype = ctypes.c_int
        members = (ctypes.c_int32 * GROUP_MEMBER_CAPACITY)()
        capacity_bytes = ctypes.sizeof(members)
        ctypes.set_errno(0)
        returned = query(2, pid, members, capacity_bytes)
        error_number = ctypes.get_errno() or None
        count = min(GROUP_MEMBER_CAPACITY, max(0, returned // ctypes.sizeof(ctypes.c_int32)))
        return {'processGroup': pid, 'returnedBytes': returned,
                'bufferBytes': capacity_bytes, 'members': list(members)[:count],
                'errorNumber': error_number}

    def wait(self, child, timeout):
        return child.wait(timeout=timeout)

    def close(self, child):
        if self.queue is not None:
            self.queue.close()
            self.queue = None
        self.streams.clear()
        if child is not None:
            for stream in (child.stdout, child.stderr):
                if stream is not None:
                    stream.close()


def sanitized_environment():
    environment = {
        'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
        'LANG': 'C', 'LC_ALL': 'C', 'PYTHONUNBUFFERED': '1', 'NSUnbufferedIO': 'YES',
    }
    # A private temporary-directory path is useful to the toolchain; no credentials
    # or loader variables are forwarded. The values are never written to evidence.
    if os.environ.get('TMPDIR'):
        environment['TMPDIR'] = os.environ['TMPDIR']
    return environment


def _drain(runtime, event, files, captured):
    if event not in files:
        return False
    truncated = False
    for _ in range(READS_PER_EVENT):
        try:
            data = runtime.read(event, READ_SIZE)
        except BlockingIOError:
            break
        except InterruptedError:
            continue
        if not data:
            break
        counts = captured[event]
        counts['received'] += len(data)
        remaining = max(0, CAPTURE_LIMIT - counts['stored'])
        stored = data[:remaining]
        files[event].write(stored)
        counts['stored'] += len(stored)
        counts['discarded'] += len(data) - len(stored)
        truncated = truncated or len(stored) != len(data)
    return truncated


def run(command, timeout, output, *, runtime=None, stop=None):
    """Run one argv under a retained group lease; return and persist its receipt.

    Injected adapters are used only by pure tests. Normal calls use Runtime.
    No signal to a group occurs after the direct leader may have been reaped.
    """
    if not command or not math.isfinite(timeout) or timeout <= 0:
        raise ValueError('command and positive finite timeout are required')
    if any(not isinstance(arg, str) or '\0' in arg for arg in command):
        raise ValueError('arguments must be NUL-free strings')
    runtime = runtime if runtime is not None else Runtime()
    stop = stop if stop is not None else StopRequest()
    started = runtime.now()
    deadline = started + timeout
    if not math.isfinite(deadline):
        raise ValueError('deadline is not representable')
    output = Path(output)
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    captured = {name: {'received': 0, 'stored': 0, 'discarded': 0}
                for name in ('stdout', 'stderr')}
    result = {
        'command': list(command), 'pid': None, 'processGroup': None,
        'exitObserved': False, 'registrationError': None,
        'groupSignalAttempted': False, 'groupSignalError': None,
        'groupCleanup': 'notStarted', 'groupQuery': None,
        'waitCompleted': False, 'returnCode': None,
        'waitError': None, 'timedOut': False, 'interruptedSignal': None,
        'truncated': False, 'captureComplete': False, 'captured': captured,
        'failure': None, 'exit': 125,
    }
    child = None
    files = {}
    try:
        for name in captured:
            files[name] = (output / (name + '.log')).open('xb')
        if stop.signal is not None:
            raise _StopBeforeSpawn()
        child = runtime.start(command, sanitized_environment())
        # Retain before any operation that can raise. Signal handlers only set
        # StopRequest, including while Popen creates/returns this owned child.
        result['pid'] = result['processGroup'] = child.pid
        registration_gone = False
        try:
            runtime.observe(child)
        except OSError as error:
            result['registrationError'] = error.errno
            if error.errno == errno.ESRCH:
                registration_gone = True
            else:
                raise
        while not registration_gone:
            if stop.signal is not None:
                result['interruptedSignal'] = stop.signal
                break
            remaining = deadline - runtime.now()
            if remaining <= 0:
                result['timedOut'] = True
                break
            events = runtime.events(min(remaining, POLL_SECONDS), EVENT_LIMIT)
            for event in events[:EVENT_LIMIT]:
                if event == 'exit':
                    result['exitObserved'] = True
                else:
                    result['truncated'] |= _drain(runtime, event, files, captured)
            if result['exitObserved'] or result['truncated']:
                break
    except _StopBeforeSpawn:
        result['captureComplete'] = True
    except ProcessRegistrationError as error:
        result['registrationError'] = error.errno
        if error.errno != errno.ESRCH:
            result['failure'] = 'observation'
    except KeyboardInterrupt:
        stop.request(signal.SIGINT)
    except BaseException as error:
        # No arbitrary exception text, environment or fixture payload is logged.
        result['failure'] = 'spawn' if child is None else 'observation'
        result['errorType'] = type(error).__name__
        result['errorNumber'] = getattr(error, 'errno', None)
    finally:
        if child is not None:
            # The direct leader is still unreaped here, pinning its group identity.
            # Every path (including normal exit) cleans the group before wait.
            result['groupSignalAttempted'] = True
            try:
                runtime.kill_group(child.pid)
                result['groupCleanup'] = 'signaled'
            except OSError as error:
                result['groupSignalError'] = error.errno
                result['groupCleanup'] = 'absent' if error.errno == errno.ESRCH else 'unconfirmed'
                if error.errno == errno.EPERM and result['exitObserved']:
                    # Darwin can return EPERM when only the exited leader is
                    # left: group signaling excludes zombies. EPERM alone is
                    # never proof. Before releasing the leader's identity,
                    # require a complete singleton snapshot of this exact group.
                    try:
                        receipt = runtime.group_members(child.pid)
                        result['groupQuery'] = receipt
                        if (receipt['processGroup'] == child.pid
                                and receipt['errorNumber'] is None
                                and receipt['bufferBytes'] == GROUP_MEMBER_CAPACITY * 4
                                and 0 < receipt['returnedBytes'] < receipt['bufferBytes']
                                and receipt['returnedBytes'] % 4 == 0
                                and receipt['returnedBytes'] == len(receipt['members']) * 4
                                and receipt['members'] == [child.pid]):
                            result['groupCleanup'] = 'exitedLeaderOnly'
                    except BaseException as query_error:
                        result['groupQuery'] = {
                            'processGroup': child.pid,
                            'errorNumber': getattr(query_error, 'errno', None),
                            'errorType': type(query_error).__name__,
                        }
            except BaseException:
                result['groupCleanup'] = 'unconfirmed'
            try:
                result['returnCode'] = runtime.wait(child, WAIT_SECONDS)
                result['waitCompleted'] = True
            except BaseException as error:
                result['waitError'] = type(error).__name__
                result['failure'] = 'unconfirmedWait'
            # Never signal again after wait, even if tail draining fails.
            tail_deadline = runtime.now() + TAIL_SECONDS
            try:
                while runtime.active_streams() and runtime.now() < tail_deadline:
                    remaining = tail_deadline - runtime.now()
                    events = runtime.events(min(remaining, POLL_SECONDS), EVENT_LIMIT)
                    for event in events[:EVENT_LIMIT]:
                        result['truncated'] |= _drain(runtime, event, files, captured)
                result['captureComplete'] = not runtime.active_streams()
            except BaseException:
                result['failure'] = result['failure'] or 'capture'
        try:
            runtime.close(child)
        except BaseException:
            result['failure'] = result['failure'] or 'captureClose'
        for file in files.values():
            file.close()

    result['interruptedSignal'] = result['interruptedSignal'] or stop.signal
    if result['interruptedSignal'] is not None:
        result['exit'] = 128 + result['interruptedSignal']
    elif result['timedOut']:
        result['exit'] = 124
    elif (result['failure'] is not None or result['truncated']
          or not result['captureComplete'] or not result['waitCompleted']
          or result['groupCleanup'] == 'unconfirmed'):
        result['exit'] = 125
    else:
        code = result['returnCode']
        result['exit'] = code if code >= 0 else 128 - code
    result['seconds'] = round(runtime.now() - started, 6)
    (output / 'status.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--timeout', type=float, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    stop = StopRequest()
    previous = {}

    def request_stop(signum, _frame):
        stop.request(signum)

    try:
        for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            previous[signum] = signal.signal(signum, request_stop)
        result = run(command, args.timeout, args.output, stop=stop)
        # Raw argv and detailed evidence remain only in the caller's private dir.
        print(json.dumps({'exit': result['exit'], 'timedOut': result['timedOut'],
                          'interruptedSignal': result['interruptedSignal'],
                          'waitCompleted': result['waitCompleted'],
                          'truncated': result['truncated']}))
        return result['exit']
    except (ValueError, OSError, RuntimeError) as error:
        print('Watchdog refused or could not record evidence: ' + type(error).__name__,
              file=sys.stderr)
        return 125
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)


if __name__ == '__main__':
    raise SystemExit(main())
