"""Closed parser-refusal contracts. Only the existing synthetic watchdog is fake.
No candidate compiler, Swift child, hosted job, Git or native process is executed.
Support Test modules are imported as modules, never as discoverable TestCase aliases.
"""
import importlib.util
import inspect
import json
from pathlib import Path
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location(
    'folder_preview_availability_contract_support', HERE / 'test_ci_folder_preview_availability.py')
availability = importlib.util.module_from_spec(spec)
spec.loader.exec_module(availability)
old = availability.old
runner = availability.runner
UNAVAILABLE = availability.UNAVAILABLE
SECRET = availability.SECRET


class FolderPreviewParserRefusalTests(unittest.TestCase):
    def capsule(self):
        return availability.FolderPreviewAvailabilityTests.capsule(self)

    def frozen(self):
        return availability.FolderPreviewAvailabilityTests.frozen(self)

    def main_call(self, root, watch, argv=None, fault=None):
        return availability.FolderPreviewAvailabilityTests.main_call(self, root, watch, argv, fault)

    def parser_api(self):
        factory = getattr(runner, '_ParserRefusal', None)
        read = getattr(runner, '_parser_refusal_code', None)
        self.assertTrue(callable(factory) and callable(read),
                        'Missing closed parser-refusal API; record and parser horizons UNENTERED')
        if not callable(factory) or not callable(read):
            return None
        for name, parameter in [('parse_trace', 'refusal'), ('execute', 'parser_refusal'),
                                ('_availability_output', 'parser_refusal')]:
            function = getattr(runner, name, None)
            self.assertTrue(callable(function), 'Required existing API must remain callable')
            if not callable(function):
                return None
            parameters = inspect.signature(function).parameters
            self.assertIn(parameter, parameters,
                          'Missing optional parser record; dependent calls UNENTERED')
            if parameter not in parameters:
                return None
            self.assertIsNone(parameters[parameter].default)
        return factory, read

    def assert_main_refusal(self, value, code):
        exit_code, stdout, stderr, escaped, imported = value
        self.assertIsNone(escaped)
        self.assertEqual(exit_code, 125)
        self.assertEqual(stdout, '\n'.join(
            UNAVAILABLE + [f'availability: boundary=17 parser={code}']) + '\n')
        self.assertEqual(stderr, '')
        self.assertEqual(len(stdout.splitlines()), 3)
        self.assertLessEqual(len(stdout.encode('ascii')), 512)
        self.assertNotIn(SECRET, stdout)
        self.assertIn('folder_trace_verifier', imported)

    def test_real_parser_refusal_groups_preserve_errors_and_first_refusal(self):
        api = self.parser_api()
        if api is None:
            return
        factory, read = api
        prefix = old.path_prefix(11, 7)
        self.assertTrue(prefix.endswith(b'CI_FOLDER_PREVIEW_PATH s=7\n'))
        cases = [
            ('split-stream', old.trace(1), old.trace(2), 0),
            ('total-cap', b'CI_FOLDER_PREVIEW_TRACE p=0 e=0\n' * 513, b'', 1),
            ('shape', old.trace() + b'CI_FOLDER_PREVIEW_CORE s=\n', b'', 2),
            ('partial-shape', old.trace() + b'CI_FOLDER_PREVIEW_CORE s=', b'', 2),
            ('core-outside-window', b'CI_FOLDER_PREVIEW_CORE s=0\n', b'', 3),
            ('core-transition', prefix + b'CI_FOLDER_PREVIEW_CORE s=1\n', b'', 4),
            ('premature-handoff', prefix + b'CI_FOLDER_PREVIEW_CORE s=0\n'
             + b'CI_FOLDER_PREVIEW_PATH s=8\n', b'', 5),
            ('nested-path-order', b'CI_FOLDER_PREVIEW_TRACE p=0 e=1\n', b'', 6),
        ]
        for name, stdout, stderr, expected in cases:
            with self.subTest(case=name):
                with self.assertRaises(ValueError) as original:
                    runner.parse_trace(stdout, stderr)
                record = factory()
                self.assertIsNone(read(record))
                with self.assertRaises(ValueError) as observed:
                    runner.parse_trace(stdout, stderr, refusal=record)
                self.assertEqual(observed.exception.args, original.exception.args)
                self.assertEqual(read(record), expected)
                # A different genuine refusal cannot overwrite the first group.
                later = (b'CI_FOLDER_PREVIEW_CORE s=0\n' if expected != 3
                         else b'CI_FOLDER_PREVIEW_CORE s=\n')
                with self.assertRaises(ValueError):
                    runner.parse_trace(later, b'', refusal=record)
                self.assertEqual(read(record), expected)
                # Nor may a later successful parse erase or reinterpret it.
                self.assertEqual(runner.parse_trace(old.trace(), b'', refusal=record),
                                 old._closed_report(old.expected_events()))
                self.assertEqual(read(record), expected)
        # Group7 remains static-only unless an actual byte counterexample is found.
        # No lower-parser success or authority return is monkeypatched to force it.

    def test_success_default_api_and_closed_record_cannot_grant_acceptance(self):
        api = self.parser_api()
        if api is None:
            return
        factory, read = api
        for omitted in [(), (11,), tuple(range(1, 13))]:
            events = old.expected_events(omitted)
            for count in range(43):
                selected = old._events_through_outer_count(events, count)
                payload = b''.join(old._record(event) for event in selected)
                expected = old._closed_report(selected)
                for streams in [(payload, b''), (b'', payload)]:
                    with self.subTest(omitted=omitted, count=count, stdout=bool(streams[0])):
                        record = factory()
                        self.assertEqual(runner.parse_trace(*streams), expected)
                        self.assertEqual(runner.parse_trace(*streams, refusal=record), expected)
                        self.assertIsNone(read(record))
        # Proper Core prefixes and finite real early-return branches retain exact reports.
        events = old.expected_events()
        start = next(i for i, event in enumerate(events) if event == old._path(7, 11))
        end = next(i for i, event in enumerate(events) if event == old._path(8, 11))
        variants = [events[:i + 1] for i in range(start, end)]
        for branch in [(0, 9), (0, 1, 9), (0, 1, 2, 3, 10, 20, 21, 22, 24, 9)]:
            variants.append(events[:start + 1] + [old._core(s) for s in branch] + events[end:])
        for selected in variants:
            record = factory()
            payload = b''.join(old._record(event) for event in selected)
            self.assertEqual(runner.parse_trace(payload, b'', refusal=record), old._closed_report(selected))
            self.assertIsNone(read(record))
        class Foreign:
            def __getattribute__(self, name):
                raise AssertionError('Foreign parser recorder was inspected')
        class Subclass(factory):
            pass
        invalid_records = [None, {}, SECRET, True, Foreign(), Subclass()]
        for bad in [True, -1, 8, SECRET, object()]:
            record = factory()
            record.code = bad
            invalid_records.append(record)
        missing = factory()
        del missing.code
        invalid_records.append(missing)
        for record in invalid_records:
            self.assertIsNone(read(record))
            with self.assertRaises(ValueError):
                runner.parse_trace(b'CI_FOLDER_PREVIEW_CORE s=\n', b'', refusal=record)
            self.assertIsNone(read(record))
            self.assertEqual(runner.parse_trace(old.trace(), b'', refusal=record),
                             old._closed_report(old.expected_events()))
        # A code alone is never permission to expose a suffix outside latched boundary17.
        valid = factory()
        with self.assertRaises(ValueError):
            runner.parse_trace(b'CI_FOLDER_PREVIEW_CORE s=\n', b'', refusal=valid)
        self.assertEqual(read(valid), 2)
        for boundary in [0, 16, 18, 20, 21]:
            progress = runner._AvailabilityProgress()
            runner._availability_enter(progress, boundary)
            runner._availability_fail(progress)
            plain = runner._availability_output(progress)
            self.assertEqual(runner._availability_output(progress, parser_refusal=valid), plain)
        progress = runner._AvailabilityProgress()
        runner._availability_enter(progress, 17)
        self.assertEqual(runner._availability_output(progress, parser_refusal=valid), '\n'.join(UNAVAILABLE))
        runner._availability_fail(progress)
        for record in invalid_records:
            self.assertEqual(runner._availability_output(progress, parser_refusal=record),
                             runner._availability_output(progress))
        self.assertEqual(runner._availability_line(progress), 'availability: boundary=17')
        self.assertEqual(runner._availability_output(progress, parser_refusal=valid),
                         '\n'.join(UNAVAILABLE + ['availability: boundary=17 parser=2']))

    def test_main_and_execute_keep_real_evidence_and_report_only_parser_refusal(self):
        api = self.parser_api()
        if api is None:
            return
        factory, read = api
        for kind, fault, code in [('shape', None, 2), ('shape', 'save', 2),
                                  ('shape', 'render-raise', 2), ('split', None, 0)]:
            with self.subTest(kind=kind, fault=fault):
                root, _, _ = self.capsule()
                watch = (old.ControlledWatchdog(old.trace() + b'CI_FOLDER_PREVIEW_CORE s=\n')
                         if kind == 'shape' else old.ControlledWatchdog(old.trace(2), stdout=old.trace(1)))
                value = self.main_call(root, watch, fault=fault)
                self.assert_main_refusal(value, code)
                self.assertEqual(len(watch.calls), 1)
                runs = list((root / '.local/ci-folder-preview-trace').glob('run.*'))
                self.assertEqual(len(runs), 1)
                run = runs[0]
                self.assertEqual((run / 'stage/stdout.log').read_bytes(), watch.stdout)
                self.assertEqual((run / 'stage/stderr.log').read_bytes(), watch.stderr)
                self.assertTrue((run / 'stage/status.json').is_file())
                if fault == 'save':
                    self.assertEqual((run / 'result.json').read_bytes(), b'preserved synthetic result collision\n')
        for kind in ['source-before', 'receipt-refusal', 'complete', 'prefix-one', 'no-markers']:
            with self.subTest(kind=kind):
                state = self.frozen()
                if state is None:
                    return
                root, run, _, plan, manifest = state
                custody = run / 'State/owned-synthetic-custody'
                custody.write_bytes(b'exact retained custody\n')
                before = json.dumps(manifest, sort_keys=True)
                def change(receipt, output):
                    receipt['captureComplete'] = False
                    (output / 'status.json').write_text(json.dumps(receipt))
                payload = (old.trace(5) if kind == 'prefix-one' else b'no markers\n'
                           if kind == 'no-markers' else old.trace())
                watch = old.ControlledWatchdog(payload, exit_code=1 if kind == 'prefix-one' else 0,
                                              change=change if kind == 'receipt-refusal' else None)
                if kind == 'source-before':
                    (root / runner.CORE_TARGET).write_bytes(b'changed genuine source\n')
                progress, record = runner._AvailabilityProgress(), factory()
                result = runner.execute(root, run, plan, manifest, watch,
                                        progress=progress, parser_refusal=record)
                self.assertIsNone(read(record))
                self.assertEqual(json.dumps(manifest, sort_keys=True), before)
                self.assertEqual(custody.read_bytes(), b'exact retained custody\n')
                if kind in ['source-before', 'receipt-refusal']:
                    self.assertEqual(result, {'state': 'unavailable'})
                    self.assertEqual(runner.render(result), UNAVAILABLE)
                    self.assertEqual(len(watch.calls), 0 if kind == 'source-before' else 1)
                    expected_boundary = 6 if kind == 'source-before' else 14
                    self.assertEqual(runner._availability_output(progress, parser_refusal=record),
                                     '\n'.join(UNAVAILABLE + [f'availability: boundary={expected_boundary}']))
                else:
                    self.assertEqual(len(watch.calls), 1)
                    self.assertEqual(result['state'], 'not-observed' if kind == 'no-markers' else 'observed')
                    self.assertEqual(set(result), {'state', 'ownedExit', 'ownedReturnCode',
                                                  'signalObservation', 'trace', 'evidence'})
                    lines = runner.render(result)
                    self.assertEqual(len(lines), 5)
                    self.assertFalse(any('availability:' in x or 'parser=' in x for x in lines))
                    # Re-run only synthetic dispatch in a distinct genuine freeze with default APIs.
                    other = self.frozen()
                    if other is None:
                        return
                    r2, run2, _, plan2, manifest2 = other
                    default = runner.execute(r2, run2, plan2, manifest2,
                                             old.ControlledWatchdog(payload, exit_code=watch.exit_code))
                    self.assertEqual(default['trace'], result['trace'])
                    self.assertEqual(runner.render(default), lines)


if __name__ == '__main__':
    unittest.main()
