"""Rejected-transition observations only; real byte parser, synthetic watchdog boundary.
No compiler, Swift child, hosted workflow, native app or Git operation is executed.
The frozen literal map is a Test fixture, never obtained from the production map.
"""
import importlib.util
import inspect
import json
from pathlib import Path
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location(
    'transition_refusal_support', HERE / 'test_ci_folder_preview_parser_refusal.py')
support = importlib.util.module_from_spec(spec)
spec.loader.exec_module(support)
availability, old, runner = support.availability, support.old, support.runner
UNAVAILABLE, SECRET = support.UNAVAILABLE, support.SECRET
STAGES = (0, 1, 2, 3, 4, 5, 6, 7, 9, 10, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24)
FIXTURES = (
    (0, ('start', 'none', False), (), (0,)),
    (1, ('entry', 'none', False), (0,), (1, 9)),
    (2, ('limits', 'none', False), (0, 1), (2, 9)),
    (3, ('scalars', 'none', False), (0, 1, 2), (3,)),
    (4, ('root-call', 'none', False), (0, 1, 2, 3), (10,)),
    (5, ('root-done', 'none', False), (0, 1, 2, 3, 10, 20, 21, 23, 12, 13, 14, 15, 16, 17, 18, 19, 24, 4), (5,)),
    (6, ('selected-call', 'none', False), (0, 1, 2, 3, 10, 20, 21, 23, 12, 13, 14, 15, 16, 17, 18, 19, 24, 4, 5), (10,)),
    (7, ('selected-done', 'none', False), (0, 1, 2, 3, 10, 20, 21, 23, 12, 13, 14, 15, 16, 17, 18, 19, 24, 4, 5, 10, 20, 21, 23, 12, 13, 14, 15, 16, 17, 18, 19, 24, 6), (7,)),
    (8, ('admitted', 'none', False), (0, 1, 2, 3, 10, 20, 21, 23, 12, 13, 14, 15, 16, 17, 18, 19, 24, 4, 5, 10, 20, 21, 23, 12, 13, 14, 15, 16, 17, 18, 19, 24, 6, 7), (9,)),
    (9, ('end', 'none', False), (0, 9), ()),
    (10, ('valid', 'root', False), (0, 1, 2, 3, 10), (20,)),
    (11, ('serialized', 'root', False), (0, 1, 2, 3, 10, 20), (21,)),
    (12, ('bytes', 'root', False), (0, 1, 2, 3, 10, 20, 21), (22, 23)),
    (13, ('nul', 'root', False), (0, 1, 2, 3, 10, 20, 21, 22), (24,)),
    (14, ('clean', 'root', False), (0, 1, 2, 3, 10, 20, 21, 23), (12,)),
    (15, ('serialized-accepted', 'root', False), (0, 1, 2, 3, 10, 20, 21, 23, 12), (13, 24)),
    (16, ('file-accepted', 'root', False), (0, 1, 2, 3, 10, 20, 21, 23, 12, 13), (14, 24)),
    (17, ('host-accepted', 'root', False), (0, 1, 2, 3, 10, 20, 21, 23, 12, 13, 14), (15,)),
    (18, ('decoded', 'root', False), (0, 1, 2, 3, 10, 20, 21, 23, 12, 13, 14, 15), (16, 24)),
    (19, ('decoded-accepted', 'root', False), (0, 1, 2, 3, 10, 20, 21, 23, 12, 13, 14, 15, 16), (17, 24)),
    (20, ('directory-accepted', 'root', False), (0, 1, 2, 3, 10, 20, 21, 23, 12, 13, 14, 15, 16, 17), (18,)),
    (21, ('pointer', 'root', False), (0, 1, 2, 3, 10, 20, 21, 23, 12, 13, 14, 15, 16, 17, 18), (19, 24)),
    (22, ('filesystem', 'root', False), (0, 1, 2, 3, 10, 20, 21, 23, 12, 13, 14, 15, 16, 17, 18, 19), (24,)),
    (23, ('returned', 'root', False), (0, 1, 2, 3, 10, 20, 21, 22, 24), (9,)),
    (24, ('returned', 'root', True), (0, 1, 2, 3, 10, 20, 21, 23, 12, 13, 14, 15, 16, 17, 18, 19, 24), (4, 9)),
    (25, ('valid', 'selected', False), (0, 1, 2, 3, 10, 20, 21, 23, 12, 13, 14, 15, 16, 17, 18, 19, 24, 4, 5, 10), (20,)),
    (26, ('serialized', 'selected', False), (0, 1, 2, 3, 10, 20, 21, 23, 12, 13, 14, 15, 16, 17, 18, 19, 24, 4, 5, 10, 20), (21,)),
    (27, ('bytes', 'selected', False), (0, 1, 2, 3, 10, 20, 21, 23, 12, 13, 14, 15, 16, 17, 18, 19, 24, 4, 5, 10, 20, 21), (22, 23)),
    (28, ('nul', 'selected', False), (0, 1, 2, 3, 10, 20, 21, 23, 12, 13, 14, 15, 16, 17, 18, 19, 24, 4, 5, 10, 20, 21, 22), (24,)),
    (29, ('clean', 'selected', False), (0, 1, 2, 3, 10, 20, 21, 23, 12, 13, 14, 15, 16, 17, 18, 19, 24, 4, 5, 10, 20, 21, 23), (12,)),
    (30, ('serialized-accepted', 'selected', False), (0, 1, 2, 3, 10, 20, 21, 23, 12, 13, 14, 15, 16, 17, 18, 19, 24, 4, 5, 10, 20, 21, 23, 12), (13, 24)),
    (31, ('file-accepted', 'selected', False), (0, 1, 2, 3, 10, 20, 21, 23, 12, 13, 14, 15, 16, 17, 18, 19, 24, 4, 5, 10, 20, 21, 23, 12, 13), (14, 24)),
    (32, ('host-accepted', 'selected', False), (0, 1, 2, 3, 10, 20, 21, 23, 12, 13, 14, 15, 16, 17, 18, 19, 24, 4, 5, 10, 20, 21, 23, 12, 13, 14), (15,)),
    (33, ('decoded', 'selected', False), (0, 1, 2, 3, 10, 20, 21, 23, 12, 13, 14, 15, 16, 17, 18, 19, 24, 4, 5, 10, 20, 21, 23, 12, 13, 14, 15), (16, 24)),
    (34, ('decoded-accepted', 'selected', False), (0, 1, 2, 3, 10, 20, 21, 23, 12, 13, 14, 15, 16, 17, 18, 19, 24, 4, 5, 10, 20, 21, 23, 12, 13, 14, 15, 16), (17, 24)),
    (35, ('directory-accepted', 'selected', False), (0, 1, 2, 3, 10, 20, 21, 23, 12, 13, 14, 15, 16, 17, 18, 19, 24, 4, 5, 10, 20, 21, 23, 12, 13, 14, 15, 16, 17), (18,)),
    (36, ('pointer', 'selected', False), (0, 1, 2, 3, 10, 20, 21, 23, 12, 13, 14, 15, 16, 17, 18, 19, 24, 4, 5, 10, 20, 21, 23, 12, 13, 14, 15, 16, 17, 18), (19, 24)),
    (37, ('filesystem', 'selected', False), (0, 1, 2, 3, 10, 20, 21, 23, 12, 13, 14, 15, 16, 17, 18, 19, 24, 4, 5, 10, 20, 21, 23, 12, 13, 14, 15, 16, 17, 18, 19), (24,)),
    (38, ('returned', 'selected', False), (0, 1, 2, 3, 10, 20, 21, 23, 12, 13, 14, 15, 16, 17, 18, 19, 24, 4, 5, 10, 20, 21, 22, 24), (9,)),
    (39, ('returned', 'selected', True), (0, 1, 2, 3, 10, 20, 21, 23, 12, 13, 14, 15, 16, 17, 18, 19, 24, 4, 5, 10, 20, 21, 23, 12, 13, 14, 15, 16, 17, 18, 19, 24), (6, 9)),
)


def core_bytes(stages):
    return b''.join(('CI_FOLDER_PREVIEW_CORE s=' + str(s) + '\n').encode('ascii') for s in stages)


def prefix_report(stages, role):
    events = old.expected_events()
    end = events.index(old._path(7, 11))
    report = old._closed_report(events[:end + 1])
    report.update(coreStage=stages[-1] if stages else -1,
                  coreRole=role, coreRecords=len(stages),
                  coreHorizon='builder-left' if stages and stages[-1] == 9 else
                  'call-entered-prefix' if stages else 'not-entered')
    return report


class FolderPreviewTransitionRefusalTests(unittest.TestCase):
    def capsule(self):
        return availability.FolderPreviewAvailabilityTests.capsule(self)

    def api(self):
        reader = getattr(runner, '_parser_refusal_transition', None)
        self.assertTrue(callable(reader),
                        'Missing transition observation API; pair/parser/main horizons UNENTERED')
        if not callable(reader):
            return None
        factory = runner._ParserRefusal
        record = factory()
        self.assertTrue(hasattr(record, 'transition'), 'Missing slot; dependent controls UNENTERED')
        if not hasattr(record, 'transition'):
            return None
        self.assertIsNone(record.transition)
        self.assertIsNone(reader(record))
        return factory, reader

    def parse_refusal(self, record, stages):
        with self.assertRaises(ValueError):
            runner.parse_trace(old.path_prefix(11, 7) + core_bytes(stages), b'', refusal=record)

    def test_real_transition_refusals_report_exact_closed_state_and_incoming_stage(self):
        api = self.api()
        if api is None:
            return
        factory, reader = api
        attempted = 0
        for identity, state, prefix, allowed in FIXTURES:
            payload = old.path_prefix(11, 7) + core_bytes(prefix)
            self.assertLessEqual(len(payload.splitlines()) + 1, 512)
            self.assertLess(len(prefix), 64)
            for swap in (False, True):
                streams = (b'', payload) if swap else (payload, b'')
                blank = factory()
                self.assertEqual(runner.parse_trace(*streams, refusal=blank),
                                 prefix_report(prefix, state[1]))
                self.assertIsNone(blank.code)
                self.assertIsNone(reader(blank))
                for incoming in STAGES:
                    if incoming in allowed:
                        continue
                    with self.subTest(state=identity, incoming=incoming, stderr=swap):
                        bad = payload + core_bytes((incoming,))
                        streams = (b'', bad) if swap else (bad, b'')
                        with self.assertRaises(ValueError) as original:
                            runner.parse_trace(*streams)
                        record = factory()
                        with self.assertRaises(ValueError) as observed:
                            runner.parse_trace(*streams, refusal=record)
                        self.assertIs(type(observed.exception), type(original.exception))
                        self.assertEqual(observed.exception.args, original.exception.args)
                        self.assertEqual(record.code, 4)
                        self.assertEqual(reader(record), (identity, incoming))
                        attempted += 1
        self.assertEqual(attempted, 865 * 2)

    def test_accepted_transitions_prefixes_and_default_api_remain_exact(self):
        api = self.api()
        if api is None:
            return
        factory, reader = api
        for function, name in [(runner.parse_trace, 'refusal'), (runner.execute, 'parser_refusal'),
                               (runner._availability_output, 'parser_refusal')]:
            self.assertIsNone(inspect.signature(function).parameters[name].default)
        accepted = 0
        for _, state, prefix, allowed in FIXTURES:
            for incoming in allowed:
                stages = prefix + (incoming,)
                role = ('root' if state[0] == 'root-call' else 'selected') if incoming == 10 else (
                    'none' if incoming in (0, 1, 2, 3, 4, 5, 6, 7, 9) else state[1])
                expected = prefix_report(stages, role)
                payload = old.path_prefix(11, 7) + core_bytes(stages)
                for streams in [(payload, b''), (b'', payload)]:
                    record = factory()
                    self.assertEqual(runner.parse_trace(*streams), expected)
                    self.assertEqual(runner.parse_trace(*streams, refusal=record), expected)
                    self.assertIsNone(record.code)
                    self.assertIsNone(reader(record))
                    accepted += 1
        self.assertEqual(accepted, 55 * 2)
        for omitted in [(), (11,), tuple(range(1, 13))]:
            events = old.expected_events(omitted)
            for count in range(43):
                selected = old._events_through_outer_count(events, count)
                payload = b''.join(old._record(x) for x in selected)
                for streams in [(payload, b''), (b'', payload)]:
                    record = factory()
                    self.assertEqual(runner.parse_trace(*streams, refusal=record), old._closed_report(selected))
                    self.assertIsNone(reader(record))
                    self.assertIsNone(record.code)

    def test_first_transition_pair_and_invalid_records_cannot_grant_acceptance_or_disclose_text(self):
        api = self.api()
        if api is None:
            return
        factory, reader = api
        record = factory()
        self.parse_refusal(record, (1,))
        self.assertEqual(reader(record), (0, 1))
        self.parse_refusal(record, (0, 0))
        with self.assertRaises(ValueError):
            runner.parse_trace(b'CI_FOLDER_PREVIEW_CORE s=\n', b'', refusal=record)
        self.assertEqual(runner.parse_trace(old.trace(), b'', refusal=record),
                         old._closed_report(old.expected_events()))
        self.assertEqual((record.code, reader(record)), (4, (0, 1)))
        other = factory()
        with self.assertRaises(ValueError):
            runner.parse_trace(b'CI_FOLDER_PREVIEW_CORE s=\n', b'', refusal=other)
        self.parse_refusal(other, (1,))
        self.assertEqual(other.code, 2)
        self.assertIsNone(reader(other))
        coarse = factory()
        coarse.code = 4
        self.parse_refusal(coarse, (1,))
        self.assertIsNone(reader(coarse))
        class Foreign:
            def __getattribute__(self, name):
                raise AssertionError('Foreign data accessed')
            def __hash__(self):
                raise AssertionError('Foreign data hashed')
            def __eq__(self, other):
                raise AssertionError('Foreign data compared')
            def __str__(self):
                raise AssertionError('Foreign data formatted')
        class Subclass(factory):
            pass
        class TupleSubclass(tuple):
            pass
        invalid = [None, {}, SECRET, True, Foreign(), Subclass()]
        for pair in [None, (), (0,), (0, 1, 2), TupleSubclass((0, 1)),
                     (True, 1), (0, True), (-1, 1), (40, 1), (0, -1), (0, 8), (0, 11), (0, 25),
                     (SECRET * 10000, 1), (Foreign(), 1), (0, Foreign())]:
            bad = factory(); bad.code = 4; bad.transition = pair; invalid.append(bad)
        missing = factory(); missing.code = 4; del missing.transition; invalid.append(missing)
        missing_code = factory(); missing_code.transition = (0, 1); del missing_code.code
        invalid.append(missing_code)
        for code in [None, True, -1, 8, SECRET, Foreign()]:
            bad = factory(); bad.code = code; bad.transition = (0, 1); invalid.append(bad)
        progress = runner._AvailabilityProgress()
        runner._availability_enter(progress, 17); runner._availability_fail(progress)
        for bad in invalid:
            self.assertIsNone(reader(bad))
            code = runner._parser_refusal_code(bad)
            expected = '\n'.join(UNAVAILABLE + ['availability: boundary=17' +
                                  ('' if code is None else ' parser=' + str(code))])
            text = runner._availability_output(progress, parser_refusal=bad)
            self.assertEqual(text, expected)
            self.assertNotIn(SECRET, text)
            self.assertLessEqual(len((text + '\n').encode('ascii')), 512)
            self.assertEqual(len(text.splitlines()), 3)
            self.parse_refusal(bad, (1,))
        for boundary in [0, 16, 18, 20, 21]:
            p = runner._AvailabilityProgress()
            runner._availability_enter(p, boundary); runner._availability_fail(p)
            self.assertEqual(runner._availability_output(p, parser_refusal=record),
                             runner._availability_output(p))
        p = runner._AvailabilityProgress(); runner._availability_enter(p, 17)
        self.assertEqual(runner._availability_output(p, parser_refusal=record), '\n'.join(UNAVAILABLE))

    def test_main_real_refusal4_keeps_first_pair_through_reporting_failures(self):
        api = self.api()
        if api is None:
            return
        for stages, pair in [((1,), (0, 1)), ((0, 0), (1, 0))]:
            for fault in (None, 'save', 'render-raise'):
                root, _, _ = availability.FolderPreviewAvailabilityTests.capsule(self)
                watch = old.ControlledWatchdog(old.path_prefix(11, 7) + core_bytes(stages))
                value = availability.FolderPreviewAvailabilityTests.main_call(self, root, watch, fault=fault)
                code, stdout, stderr, escaped, imported = value
                self.assertIsNone(escaped); self.assertEqual(code, 125); self.assertEqual(stderr, '')
                self.assertEqual(stdout, '\n'.join(UNAVAILABLE + [
                    f'availability: boundary=17 parser=4 state={pair[0]} incoming={pair[1]} collector=8']) + '\n')
                self.assertLessEqual(len(stdout.encode('ascii')), 512)
                self.assertEqual(len(stdout.splitlines()), 3)
                self.assertNotIn(SECRET, stdout); self.assertEqual(len(watch.calls), 1)
                self.assertIn('folder_trace_verifier', imported)
                runs = list((root / '.local/ci-folder-preview-trace').glob('run.*'))
                self.assertEqual(len(runs), 1); run = runs[0]
                self.assertEqual((run / 'stage/stdout.log').read_bytes(), watch.stdout)
                self.assertEqual((run / 'stage/stderr.log').read_bytes(), watch.stderr)
                captured = json.loads((run / 'inputs.json').read_text())
                manifest = dict(capture=captured,
                                authority=runner._fact(run, run / 'inputs.json')[0])
                runner.verify_inputs(root, run, manifest)
                self.assertTrue((run / 'stage/status.json').is_file())
                if fault == 'save':
                    self.assertEqual((run / 'result.json').read_bytes(), b'preserved synthetic result collision\n')
        for kind in ('source-before', 'receipt-refusal', 'complete', 'prefix-one', 'no-markers'):
            state = availability.FolderPreviewAvailabilityTests.frozen(self)
            if state is None:
                return
            root, run, _, plan, manifest = state
            custody = run / 'State/owned-synthetic-custody'; custody.write_bytes(b'exact retained custody\n')
            before = json.dumps(manifest, sort_keys=True)
            def change(receipt, output):
                receipt['captureComplete'] = False
                (output / 'status.json').write_text(json.dumps(receipt))
            payload = old.trace(5) if kind == 'prefix-one' else b'no markers\n' if kind == 'no-markers' else old.trace()
            watch = old.ControlledWatchdog(payload, exit_code=1 if kind == 'prefix-one' else 0,
                                          change=change if kind == 'receipt-refusal' else None)
            if kind == 'source-before':
                (root / runner.CORE_TARGET).write_bytes(b'changed genuine source\n')
            progress, record = runner._AvailabilityProgress(), api[0]()
            result = runner.execute(root, run, plan, manifest, watch, progress=progress, parser_refusal=record)
            self.assertIsNone(api[1](record)); self.assertIsNone(record.code)
            self.assertEqual(json.dumps(manifest, sort_keys=True), before)
            self.assertEqual(custody.read_bytes(), b'exact retained custody\n')
            self.assertEqual(len(watch.calls), 0 if kind == 'source-before' else 1)
            if kind in ('source-before', 'receipt-refusal'):
                self.assertEqual(result, {'state': 'unavailable'})
                self.assertNotIn(' state=', runner._availability_output(progress, parser_refusal=record))
                self.assertNotIn(' incoming=', runner._availability_output(progress, parser_refusal=record))
            else:
                lines = runner.render(result)
                self.assertEqual(len(lines), 5)
                self.assertFalse(any('availability:' in x or ' state=' in x or ' incoming=' in x for x in lines))
                r2, run2, _, plan2, manifest2 = availability.FolderPreviewAvailabilityTests.frozen(self)
                default = runner.execute(r2, run2, plan2, manifest2,
                                         old.ControlledWatchdog(payload, exit_code=watch.exit_code))
                self.assertEqual(default['trace'], result['trace'])
                self.assertEqual(runner.render(default), lines)


if __name__ == '__main__':
    unittest.main()
