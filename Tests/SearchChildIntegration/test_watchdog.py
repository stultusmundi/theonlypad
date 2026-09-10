"""Pure watchdog contract tests. No subprocess, signal, or fixture is executed."""
import importlib.util
from pathlib import Path
import signal
import sys
import tempfile
import unittest

MODULE_PATH = Path(__file__).resolve().parents[2] / 'scripts' / 'run-owned-search-tests.py'
spec = importlib.util.spec_from_file_location('owned_search_watchdog', MODULE_PATH)
watchdog = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = watchdog
spec.loader.exec_module(watchdog)


class Child:
    pid = 12345


class Runtime:
    """Simulates only syscall outcomes; the real controller owns all decisions."""
    def __init__(self, events=None, observe_error=None, returncode=0):
        self.calls = []
        self.time = 10.0
        self.script = list(events if events is not None else [['exit']])
        self.observe_error = observe_error
        self.returncode = returncode
        self.streams = set()
        self.payloads = {}
        self.stop = None
        self.request_signal = None
        self.wait_error = None
        self.group_error = None
        self.read_sizes = []

    def now(self):
        return self.time

    def start(self, argv, environment):
        self.calls.append(('start', tuple(argv), environment))
        return Child()

    def observe(self, child):
        self.calls.append(('observe', child.pid))
        if self.observe_error:
            raise self.observe_error

    def events(self, timeout, maximum):
        self.calls.append(('events', timeout, maximum))
        self.time += min(timeout, 0.01)
        if self.request_signal:
            self.stop.request(self.request_signal)
            self.request_signal = None
        if self.script:
            events = self.script.pop(0)
            if isinstance(events, BaseException):
                raise events
            return events
        return []

    def read(self, stream, maximum):
        self.read_sizes.append(maximum)
        payload = self.payloads.get(stream, b'')
        if not payload:
            self.streams.discard(stream)
            return b''
        self.payloads[stream] = payload[maximum:]
        return payload[:maximum]

    def active_streams(self):
        return set(self.streams)

    def kill_group(self, pid):
        self.calls.append(('kill_group', pid, signal.SIGKILL))
        if self.group_error:
            raise self.group_error

    def wait(self, child, timeout):
        self.calls.append(('wait', child.pid, timeout))
        if self.wait_error:
            raise self.wait_error
        return self.returncode

    def close(self, child):
        self.calls.append(('close', child.pid if child else None))


class WatchdogTests(unittest.TestCase):
    def run_case(self, runtime, timeout=0.05):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'evidence'
            stop = watchdog.StopRequest()
            runtime.stop = stop
            result = watchdog.run(
                ['synthetic-command', 'fixed-mode'], timeout, output,
                runtime=runtime, stop=stop)
            self.assertTrue((output / 'status.json').is_file())
            for stream in ['stdout', 'stderr']:
                self.assertLessEqual((output / (stream + '.log')).stat().st_size,
                                     watchdog.CAPTURE_LIMIT)
            return result

    def assert_cleanup_order(self, runtime):
        calls = [entry[0] for entry in runtime.calls]
        self.assertEqual(calls.count('kill_group'), 1)
        self.assertEqual(calls.count('wait'), 1)
        self.assertLess(calls.index('kill_group'), calls.index('wait'))
        self.assertLess(calls.index('wait'), calls.index('close'))
        self.assertEqual(next(c for c in runtime.calls if c[0] == 'kill_group')[1], Child.pid)

    def test_normal_exit_cleans_owned_group_before_reaping_leader(self):
        runtime = Runtime(returncode=17)
        result = self.run_case(runtime)
        self.assert_cleanup_order(runtime)
        self.assertEqual(result['exit'], 17)
        self.assertTrue(result['exitObserved'])
        self.assertTrue(result['waitCompleted'])

    def test_timeout_uses_kill_and_fails_without_early_wait(self):
        runtime = Runtime(events=[], returncode=-signal.SIGKILL)
        result = self.run_case(runtime)
        self.assert_cleanup_order(runtime)
        self.assertEqual(result['exit'], 124)
        self.assertTrue(result['timedOut'])

    def test_registration_esrch_cleans_before_wait_but_is_not_exit_observation(self):
        import errno
        runtime = Runtime(observe_error=ProcessLookupError(errno.ESRCH, 'synthetic'))
        result = self.run_case(runtime)
        self.assert_cleanup_order(runtime)
        self.assertFalse(result['exitObserved'])
        self.assertEqual(result['registrationError'], errno.ESRCH)
        self.assertEqual(result['exit'], 0)

    def test_registration_and_event_errors_clean_and_fail(self):
        import errno
        for runtime in [Runtime(observe_error=OSError(errno.EINVAL, 'synthetic')),
                        Runtime(events=[OSError(errno.EIO, 'synthetic')])]:
            with self.subTest(runtime=runtime):
                result = self.run_case(runtime)
                self.assert_cleanup_order(runtime)
                self.assertEqual(result['exit'], 125)

    def test_sigint_sigterm_and_sighup_request_same_owned_cleanup(self):
        for signum in [signal.SIGINT, signal.SIGTERM, signal.SIGHUP]:
            runtime = Runtime(events=[])
            runtime.request_signal = signum
            result = self.run_case(runtime)
            self.assert_cleanup_order(runtime)
            self.assertEqual(result['interruptedSignal'], signum)
            self.assertEqual(result['exit'], 128 + signum)

    def test_keyboard_interrupt_after_spawn_still_cleans(self):
        runtime = Runtime(events=[KeyboardInterrupt()])
        result = self.run_case(runtime)
        self.assert_cleanup_order(runtime)
        self.assertEqual(result['exit'], 130)

    def test_capture_is_capped_and_unexpected_truncation_fails(self):
        runtime = Runtime(events=[['stdout']] * 20)
        runtime.streams = {'stdout'}
        runtime.payloads['stdout'] = b'x' * (watchdog.CAPTURE_LIMIT + 1)
        result = self.run_case(runtime, timeout=2)
        self.assert_cleanup_order(runtime)
        self.assertTrue(result['truncated'])
        self.assertEqual(result['exit'], 125)
        self.assertLessEqual(max(runtime.read_sizes), 65_536)
        self.assertGreater(result['captured']['stdout']['received'], watchdog.CAPTURE_LIMIT)

    def test_group_esrch_does_not_skip_wait_or_claim_signal_success(self):
        import errno
        runtime = Runtime()
        runtime.group_error = ProcessLookupError(errno.ESRCH, 'synthetic')
        result = self.run_case(runtime)
        self.assert_cleanup_order(runtime)
        self.assertEqual(result['groupSignalError'], errno.ESRCH)
        self.assertTrue(result['waitCompleted'])
        self.assertEqual(result['exit'], 0)

    def test_unconfirmed_group_cleanup_is_failure(self):
        import errno
        runtime = Runtime()
        runtime.group_error = PermissionError(errno.EPERM, 'synthetic')
        result = self.run_case(runtime)
        self.assert_cleanup_order(runtime)
        self.assertEqual(result['exit'], 125)
        self.assertEqual(result['groupCleanup'], 'unconfirmed')

    def test_incomplete_pipe_tail_is_bounded_and_fails(self):
        runtime = Runtime()
        runtime.streams = {'stdout'}
        result = self.run_case(runtime)
        self.assert_cleanup_order(runtime)
        self.assertEqual(result['exit'], 125)
        self.assertFalse(result['captureComplete'])
        self.assertLess(runtime.time, 11)

    def test_invalid_deadlines_refuse_before_spawn(self):
        for timeout in [0, -1, float('nan'), float('inf')]:
            runtime = Runtime()
            with tempfile.TemporaryDirectory() as directory:
                with self.assertRaises(ValueError):
                    watchdog.run(['fixed'], timeout, Path(directory) / 'evidence', runtime=runtime)
            self.assertFalse(runtime.calls)

    def test_environment_is_allowlisted_and_does_not_copy_secrets(self):
        from unittest.mock import patch
        with patch.dict('os.environ', {'AWS_SECRET_ACCESS_KEY': 'synthetic-secret',
                                      'DYLD_INSERT_LIBRARIES': 'synthetic-injection'}, clear=False):
            runtime = Runtime()
            self.run_case(runtime)
        environment = runtime.calls[0][2]
        self.assertNotIn('AWS_SECRET_ACCESS_KEY', environment)
        self.assertNotIn('DYLD_INSERT_LIBRARIES', environment)
        self.assertEqual(environment['LC_ALL'], 'C')

    def test_delayed_process_registration_error_uses_retained_identity(self):
        import errno
        runtime = Runtime(events=[watchdog.ProcessRegistrationError(errno.ESRCH, 'synthetic')])
        result = self.run_case(runtime)
        self.assert_cleanup_order(runtime)
        self.assertEqual(result['registrationError'], errno.ESRCH)
        self.assertFalse(result['exitObserved'])
        self.assertEqual(result['exit'], 0)

    def test_wait_failure_is_unconfirmed_and_never_resignals_after_wait(self):
        import subprocess
        runtime = Runtime()
        runtime.wait_error = subprocess.TimeoutExpired('synthetic', 5)
        result = self.run_case(runtime)
        self.assert_cleanup_order(runtime)
        self.assertFalse(result['waitCompleted'])
        self.assertEqual(result['exit'], 125)
        self.assertEqual(result['failure'], 'unconfirmedWait')

    def test_real_spawn_adapter_uses_argv_and_owned_session_without_shell(self):
        from unittest.mock import patch
        adapter = watchdog.Runtime.__new__(watchdog.Runtime)
        with patch.object(watchdog.subprocess, 'Popen', return_value=Child()) as spawn:
            adapter.start(['fixed-executable', 'fixed-mode'], {'LC_ALL': 'C'})
        positional, options = spawn.call_args
        self.assertEqual(positional, (['fixed-executable', 'fixed-mode'],))
        self.assertFalse(options['shell'])
        self.assertTrue(options['start_new_session'])
        self.assertTrue(options['close_fds'])
        self.assertTrue(options['restore_signals'])
        self.assertEqual(options['env'], {'LC_ALL': 'C'})

    def test_main_installs_and_restores_all_cleanup_signal_handlers(self):
        from unittest.mock import patch
        handlers = {}
        restored = {}
        def install(signum, handler):
            if callable(handler):
                handlers[signum] = handler
            else:
                restored[signum] = handler
            return signal.SIG_DFL
        def controlled_run(command, timeout, output, stop):
            self.assertEqual(set(handlers), {signal.SIGINT, signal.SIGTERM, signal.SIGHUP})
            handlers[signal.SIGTERM](signal.SIGTERM, None)
            self.assertEqual(stop.signal, signal.SIGTERM)
            return {'exit': 143, 'timedOut': False, 'interruptedSignal': signal.SIGTERM,
                    'waitCompleted': True, 'truncated': False}
        with patch.object(watchdog.signal, 'signal', side_effect=install), \
                patch.object(watchdog, 'run', side_effect=controlled_run), \
                patch('builtins.print'):
            code = watchdog.main(['--timeout', '1', '--output', '/synthetic/unused', '--', 'fixed'])
        self.assertEqual(code, 143)
        self.assertEqual(set(restored), {signal.SIGINT, signal.SIGTERM, signal.SIGHUP})

    def test_preexisting_stop_intent_refuses_new_launch(self):
        runtime = Runtime()
        stop = watchdog.StopRequest()
        stop.request(signal.SIGTERM)
        with tempfile.TemporaryDirectory() as directory:
            result = watchdog.run(['fixed'], 1, Path(directory) / 'evidence',
                                  runtime=runtime, stop=stop)
        self.assertFalse(any(call[0] == 'start' for call in runtime.calls))
        self.assertFalse(result['groupSignalAttempted'])
        self.assertEqual(result['exit'], 143)
        self.assertIsNone(result['failure'])

    def test_sigchld_query_accepts_only_default_non_auto_reaping_policy(self):
        import ctypes
        from types import SimpleNamespace
        from unittest.mock import patch
        class Query:
            def __init__(self, handler, flags):
                self.handler = handler
                self.flags = flags
                self.calls = []
            def __call__(self, signum, new_action, old_action):
                self.calls.append((signum, new_action))
                action = old_action._obj
                # Actual inspected Darwin64 ABI, not a mutation of signal policy.
                self.layout = (ctypes.sizeof(action), type(action).mask.offset,
                               type(action).flags.offset)
                action.handler = self.handler
                action.flags = self.flags
                return 0
        for handler, flags, expected in [(None, 0, True), (0, 0, True),
                                         (int(signal.SIG_IGN), 0, False),
                                         (0x1234, 0, False), (None, 0x20, False),
                                         (None, 0x08, True)]:
            with self.subTest(handler=handler, flags=flags):
                query = Query(handler, flags)
                with patch.object(watchdog.ctypes, 'CDLL',
                                  return_value=SimpleNamespace(sigaction=query)):
                    self.assertEqual(watchdog._sigchld_reapable(), expected)
                self.assertEqual(query.calls, [(signal.SIGCHLD, None)])
                self.assertEqual(query.layout, (16, 8, 12))

    def test_sigchld_query_failure_refuses_without_setting_policy(self):
        import errno
        from types import SimpleNamespace
        from unittest.mock import Mock, patch
        query = Mock(return_value=-1)
        with patch.object(watchdog.ctypes, 'CDLL',
                          return_value=SimpleNamespace(sigaction=query)), \
                patch.object(watchdog.ctypes, 'get_errno', return_value=errno.EIO):
            with self.assertRaises(OSError) as raised:
                watchdog._sigchld_reapable()
        self.assertEqual(raised.exception.errno, errno.EIO)
        self.assertEqual(query.call_args.args[:2], (signal.SIGCHLD, None))

    def test_missing_delete_capability_refuses_before_sigchld_query_or_spawn(self):
        from types import SimpleNamespace
        from unittest.mock import patch
        capabilities = ['kqueue', 'kevent', 'KQ_FILTER_PROC', 'KQ_NOTE_EXIT',
                        'KQ_FILTER_READ', 'KQ_EV_ADD', 'KQ_EV_ENABLE', 'KQ_EV_ONESHOT',
                        'KQ_EV_ERROR']
        partial = SimpleNamespace(**{name: object() for name in capabilities})
        with patch.object(watchdog, 'select', partial), \
                patch.object(watchdog, '_sigchld_reapable', return_value=True) as query:
            with self.assertRaises(RuntimeError):
                watchdog.Runtime()
        query.assert_not_called()

    def test_auto_reaping_policy_refuses_before_spawn(self):
        from unittest.mock import patch
        with patch.object(watchdog, '_sigchld_reapable', return_value=False), \
                patch.object(watchdog.subprocess, 'Popen') as spawn:
            with self.assertRaises(RuntimeError):
                watchdog.Runtime()
        spawn.assert_not_called()


if __name__ == '__main__':
    unittest.main()
