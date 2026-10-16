"""Additive availability controls; no compiler or real child runs.
The existing fifteen-contract module is imported as a module, never a TestCase alias.
"""
import contextlib
import importlib.util
import inspect
import io
import json
import os
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location(
    'folder_preview_original_contract_support', HERE / 'test_ci_folder_preview_trace.py')
old = importlib.util.module_from_spec(spec)
spec.loader.exec_module(old)
runner = old.runner
UNAVAILABLE = ['ci-folder-preview-trace: unavailable', 'reason: incomplete-evidence']
SECRET = 'synthetic-private-error-DO-NOT-PRINT'


class FolderPreviewAvailabilityTests(unittest.TestCase):
    def capsule(self):
        return old.FolderPreviewTraceContractTests.capsule(self)

    def frozen(self):
        return old.FolderPreviewTraceContractTests.frozen(self)

    def progress_api(self):
        names = ('_AvailabilityProgress', '_availability_enter',
                 '_availability_fail', '_availability_line')
        values = [getattr(runner, name, None) for name in names]
        self.assertTrue(all(callable(value) for value in values),
                        'Missing closed progress API; dependent record/execute horizons UNENTERED')
        if not all(callable(value) for value in values):
            return None
        self.assertIn('progress', inspect.signature(runner.execute).parameters,
                      'Missing optional execute progress; deeper custody checks UNENTERED')
        if 'progress' not in inspect.signature(runner.execute).parameters:
            return None
        return values

    def main_call(self, root, watch, argv=None, fault=None):
        """Genuine main/preparation; replace only the hash-checked watchdog's main.
        Failure wrappers call the actual operation first, then refuse; no authority
        value or successful receipt/check result is invented by these wrappers.
        """
        real_load, real_save, real_render = runner._load_module, runner._save, runner.render
        out, err = io.StringIO(), io.StringIO()
        imported = []

        def load(run, path, name, expected):
            module = real_load(run, path, name, expected)
            imported.append(name)
            if name == 'folder_trace_watchdog':
                return SimpleNamespace(main=watch)
            return module

        def save(path, value):
            if fault == 'save' and Path(path).name == 'result.json':
                # A real exclusive-file collision, after all execution checks.
                Path(path).write_bytes(b'preserved synthetic result collision\n')
            return real_save(path, value)

        def render(value):
            actual = real_render(value)
            if fault == 'render-raise':
                raise ValueError(SECRET)
            if fault == 'render-unavailable':
                return list(UNAVAILABLE)
            return actual

        code = escaped = None
        previous_umask = os.umask(0o077)
        try:
            with mock.patch.object(runner, '__file__', str(root / runner.LOCATION)), \
                    mock.patch.object(runner, '_load_module', side_effect=load), \
                    mock.patch.object(runner, '_save', side_effect=save), \
                    mock.patch.object(runner, 'render', side_effect=render), \
                    contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                try:
                    code = runner.main([] if argv is None else argv)
                except (OSError, ValueError, TypeError, KeyError, AttributeError, RuntimeError, ImportError):
                    # Turn baseline's uncaught reporting exception into an ordinary
                    # assertion, without using its private value or treating it as output.
                    escaped = True
        finally:
            os.umask(previous_umask)
        return code, out.getvalue(), err.getvalue(), escaped, imported

    def assert_unavailable(self, result, boundary):
        code, stdout, stderr, escaped, _ = result
        self.assertIsNone(escaped, 'Reporting must fail closed rather than escape')
        self.assertEqual(code, 125)
        self.assertEqual(stdout, '\n'.join(UNAVAILABLE + [f'availability: boundary={boundary}']) + '\n')
        self.assertEqual(stderr, '')
        self.assertLessEqual(len(stdout.encode('ascii')), 512)
        self.assertNotIn(SECRET, stdout + stderr)

    def test_main_preparation_refusals_report_boundary_without_child_or_private_text(self):
        for kind, boundary in [('cli', 0), ('root', 1), ('plan', 3), ('freeze', 4)]:
            with self.subTest(kind=kind):
                root, _, _ = self.capsule()
                watch = old.ControlledWatchdog(old.trace())
                argv = []
                if kind == 'cli':
                    argv = ['--unreviewed-' + SECRET]
                elif kind == 'root':
                    script = root / runner.LOCATION
                    replacement = root / 'synthetic-script-copy.py'
                    replacement.write_bytes(script.read_bytes())
                    script.unlink()
                    script.symlink_to(replacement)
                elif kind == 'plan':
                    (root / runner.WATCH).write_bytes(b'# changed fixed helper\n')
                else:
                    target = root / runner.CORE_TARGET
                    target.write_bytes(target.read_bytes() + b'\n// source drift\n')
                # If CLI admission is bypassed, the real owned-path function fails
                # visibly through this spy rather than silently performing I/O.
                if kind == 'cli':
                    with mock.patch.object(runner, '_owned', side_effect=AssertionError('CLI performed filesystem work')):
                        result = self.main_call(root, watch, argv)
                else:
                    result = self.main_call(root, watch, argv)
                self.assertEqual(watch.calls, [])
                self.assertEqual(result[4], [])
                self.assert_unavailable(result, boundary)

    def test_execute_progress_distinguishes_real_refusals_and_retains_custody(self):
        api = self.progress_api()
        if api is None:
            return
        factory, _, _, line = api
        cases = [('pre-source', 6), ('command', 10), ('post-source', 11),
                 ('receipt-json', 12), ('capture-size', 13), ('receipt-incomplete', 14),
                 ('protocol', 17), ('final-source', 18), ('final-capture', 19)]
        for kind, boundary in cases:
            with self.subTest(kind=kind):
                state = self.frozen()
                if state is None:
                    return
                root, run, _, plan, manifest = state
                retained = run / 'State/retained-synthetic-custody'
                retained.write_bytes(b'exact custody\n')
                authority_before = json.dumps(manifest, sort_keys=True)
                progress = factory()
                real_parse, real_fact = runner.parse_trace, runner._fact
                armed = [False]

                def receipt_change(value, output):
                    if kind == 'receipt-json':
                        (output / 'status.json').write_bytes(b'{\n')
                    elif kind == 'capture-size':
                        (output / 'stdout.log').write_bytes(b'x' * 1048577)
                    elif kind == 'receipt-incomplete':
                        value['captureComplete'] = False
                        (output / 'status.json').write_text(json.dumps(value))

                def after():
                    if kind == 'command':
                        (run / 'command.json').write_bytes(b'changed current command\n')
                    elif kind == 'post-source':
                        (root / runner.TARGET).write_bytes(b'changed post-child source\n')

                def parse(stdout, stderr):
                    value = real_parse(stdout, stderr)
                    armed[0] = True
                    return value

                def fact(root_arg, path, cap=None):
                    value = real_fact(root_arg, path, cap)
                    path = Path(path)
                    target = root / runner.TARGET if kind == 'final-source' else run / 'stage/stdout.log'
                    if armed[0] and kind in ('final-source', 'final-capture') and path == target:
                        armed[0] = False
                        path.write_bytes(path.read_bytes() + b'changed after genuine read\n')
                        # The second genuine read must expose actual drift; never
                        # return fabricated authority or merely a synthetic bool.
                        return real_fact(root_arg, path, cap)
                    return value

                if kind == 'pre-source':
                    (root / runner.TARGET).write_bytes(b'changed pre-child source\n')
                payload = old.trace() + b'CI_FOLDER_PREVIEW_CORE s=\n' if kind == 'protocol' else old.trace()
                watch = old.ControlledWatchdog(payload, change=receipt_change, after=after)
                with mock.patch.object(runner, 'parse_trace', side_effect=parse), \
                        mock.patch.object(runner, '_fact', side_effect=fact):
                    result = runner.execute(root, run, plan, manifest, watch, progress=progress)
                self.assertEqual(result, {'state': 'unavailable'})
                self.assertEqual(line(progress), f'availability: boundary={boundary}')
                self.assertEqual(runner.render(result), UNAVAILABLE)
                self.assertEqual(len(watch.calls), 0 if kind == 'pre-source' else 1)
                self.assertEqual(retained.read_bytes(), b'exact custody\n')
                self.assertEqual(json.dumps(manifest, sort_keys=True), authority_before)
                if kind != 'pre-source':
                    self.assertTrue((run / 'stage/stdout.log').is_file())
                    self.assertTrue((run / 'stage/stderr.log').is_file())

    def test_main_first_refusal_survives_reporting_and_reporting_failures_are_closed(self):
        cases = [('protocol', None, 17), ('protocol', 'save', 17),
                 ('protocol', 'render-raise', 17), ('complete', 'save', 20),
                 ('complete', 'render-raise', 21), ('complete', 'render-unavailable', 21)]
        for payload_kind, fault, boundary in cases:
            with self.subTest(payload=payload_kind, fault=fault):
                root, _, _ = self.capsule()
                payload = old.trace()
                if payload_kind == 'protocol':
                    payload += b'CI_FOLDER_PREVIEW_CORE s=\n'
                watch = old.ControlledWatchdog(payload)
                result = self.main_call(root, watch, fault=fault)
                self.assertEqual(len(watch.calls), 1)
                self.assertIn('folder_trace_watchdog', result[4])
                self.assertIn('folder_trace_verifier', result[4])
                self.assert_unavailable(result, boundary)
                runs = list((root / '.local/ci-folder-preview-trace').glob('run.*'))
                self.assertEqual(len(runs), 1)
                self.assertTrue((runs[0] / 'stage/status.json').is_file())
                if fault == 'save':
                    self.assertEqual((runs[0] / 'result.json').read_bytes(),
                                     b'preserved synthetic result collision\n')
        # No third-line additions to accepted observed/not-observed paths, even
        # for a natural child1. Existing result/render semantics stay authoritative.
        for payload, child_code in [(old.trace(), 0), (old.trace(5), 1), (b'no markers\n', 1)]:
            with self.subTest(accepted_child_code=child_code, payload_bytes=len(payload)):
                root, _, _ = self.capsule()
                watch = old.ControlledWatchdog(payload, exit_code=child_code)
                result = self.main_call(root, watch)
                self.assertEqual((result[0], result[2], result[3]), (0, '', None))
                self.assertEqual(len(result[1].splitlines()), 5)
                self.assertNotIn('availability:', result[1])
                self.assertIn(f'owned: exit={child_code} returnCode={child_code}', result[1])

    def test_closed_record_default_api_and_first_refusal_are_not_acceptance_authority(self):
        api = self.progress_api()
        if api is None:
            return
        factory, enter, fail, line = api
        for boundary in (0, 21):
            progress = factory()
            self.assertIsNone(line(progress))
            enter(progress, boundary)
            self.assertIsNone(line(progress), 'Entry alone is not an unavailable outcome')
            fail(progress)
            self.assertEqual(line(progress), f'availability: boundary={boundary}')
            enter(progress, 20)
            fail(progress)
            self.assertEqual(line(progress), f'availability: boundary={boundary}')
        class Foreign:
            def __getattribute__(self, name):
                raise AssertionError('Foreign progress was inspected')
        class Subclass(factory):
            pass
        for value in (None, {}, SECRET, True, Foreign(), Subclass()):
            with self.subTest(record_type=type(value).__name__):
                self.assertIsNone(line(value))
                enter(value, 17)
                fail(value)
                self.assertIsNone(line(value))
        for invalid in (True, -1, 22, SECRET, None):
            progress = factory()
            enter(progress, invalid)
            fail(progress)
            self.assertIsNone(line(progress))
        for field in ('current', 'unavailable'):
            for invalid in (True, -1, 22, SECRET, None):
                progress = factory()
                enter(progress, 17)
                fail(progress)
                setattr(progress, field, invalid)
                with self.subTest(field=field, invalid_type=type(invalid).__name__):
                    self.assertIsNone(line(progress))
        for payload in (old.trace(), old.trace() + b'CI_FOLDER_PREVIEW_CORE s=\n'):
            state = self.frozen()
            if state is None:
                return
            root, run, _, plan, manifest = state
            result = runner.execute(root, run, plan, manifest, old.ControlledWatchdog(payload))
            if payload == old.trace():
                self.assertEqual(result['state'], 'observed')
                self.assertEqual(len(runner.render(result)), 5)
            else:
                self.assertEqual(result, {'state': 'unavailable'})
                self.assertEqual(runner.render(result), UNAVAILABLE)


if __name__ == '__main__':
    unittest.main()
