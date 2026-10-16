"""Behavioral controls for bounded refusal diagnostics; no raw payload is emitted."""
import importlib.util
from pathlib import Path
import unittest
from unittest import mock

SOURCE = Path(__file__).resolve().parents[2] / 'scripts' / 'ci_folder_preview_trace.py'
SPEC = importlib.util.spec_from_file_location('trace_controls_target', SOURCE)
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)

ROOT_STAGES = (0, 1, 2, 3, 10, 20, 21, 23, 12, 13, 14, 15, 16, 17, 18, 19, 24, 4, 5)
SECRET = b'private collector exception payload'


def marker(event):
    if event[0] == 'outer':
        return f'CI_FOLDER_PREVIEW_TRACE p={event[1]} e={event[2]}\n'.encode()
    return f'CI_FOLDER_PREVIEW_PATH s={event[1]}\n'.encode()


def core(stage):
    return f'CI_FOLDER_PREVIEW_CORE s={stage}\n'.encode()


def selected():
    return b'CI_PREVIEW_PREDICATE c=1 m=1\n'


def wrapper(bit=0):
    return f'CI_PREVIEW_PREDICATE w={bit} m=1\n'.encode()


def valid_parser_refusal():
    events = runner._trace_grammar()
    end = events.index(('path', 8, 11))
    raw = (b''.join(marker(event) for event in events[:end])
           + b''.join(core(stage) for stage in ROOT_STAGES)
           + selected() + wrapper() + core(6) + core(7) + core(9)
           + b''.join(marker(event) for event in events[end:]))
    record = runner._ParserRefusal()
    errors = []
    for kwargs in ({}, {'refusal': record}):
        with unittest.TestCase().assertRaises(ValueError) as caught:
            runner.parse_trace(raw, b'', **kwargs)
        errors.append((type(caught.exception), caught.exception.args))
    if errors[0] != errors[1] or runner._parser_refusal_transition(record) != (6, 6):
        raise AssertionError('fixture must preserve one original Core refusal witness')
    return raw, record, errors[0]


def unavailable(record):
    progress = runner._AvailabilityProgress()
    runner._availability_enter(progress, 17)
    runner._availability_fail(progress)
    return runner._availability_output(progress, parser_refusal=record)


class RefusalDomainControlsTests(unittest.TestCase):
    def test_success_keeps_observation_without_refusal_domain(self):
        raw, record, original = valid_parser_refusal()
        accepted = raw.replace(core(6) + core(7) + core(9),
                               b''.join(core(stage) for stage in
                                        (10, 20, 21, 23, 12, 13, 14, 15, 16, 17, 18, 19, 24, 6, 7, 9)))
        accepted_result = runner.parse_trace(accepted, b'')
        self.assertEqual(runner.parse_trace(accepted, b'', refusal=record), accepted_result)
        runner._collect_predicate_observation(raw, b'', refusal=record)
        self.assertEqual(runner._predicate_observation(record), (1, 1, 1))
        output = unavailable(record)
        self.assertIn(' selected=1 calls=1 bits=1', output)
        self.assertNotIn(' collector=', output)
        with self.assertRaises(ValueError) as again:
            runner.parse_trace(raw, b'', refusal=record)
        self.assertEqual((type(again.exception), again.exception.args), original)

    def test_exact_capture_cap_is_admitted_and_first_over_cap_is_closed(self):
        raw, record, original = valid_parser_refusal()
        exact = raw + b' ' * (1048576 - len(raw))
        runner._collect_predicate_observation(exact, b'', refusal=record)
        self.assertEqual(runner._predicate_observation(record), (1, 1, 1))
        self.assertNotIn(' collector=', unavailable(record))

        raw, record, original = valid_parser_refusal()
        oversized = raw + b' ' * (1048577 - len(raw))
        runner._collect_predicate_observation(oversized, b'', refusal=record)
        output = unavailable(record)
        self.assertIn(' collector=2', output)
        self.assertLessEqual(len((output + '\n').encode('ascii')), 512)
        self.assertNotIn(SECRET.decode(), output)
        with self.assertRaises(ValueError) as after:
            runner.parse_trace(raw, b'', refusal=record)
        self.assertEqual((type(after.exception), after.exception.args), original)

    def test_stale_or_foreign_witness_withholds_new_suffix_but_keeps_old_pair(self):
        raw, record, _ = valid_parser_refusal()
        record._predicate_nonce = object()
        runner._collect_predicate_observation(raw, b'', refusal=record)
        self.assertEqual(runner._parser_refusal_transition(record), (6, 6))
        output = unavailable(record)
        self.assertEqual(output,
                         'ci-folder-preview-trace: unavailable\n'
                         'reason: incomplete-evidence\n'
                         'availability: boundary=17 parser=4 state=6 incoming=6')
        self.assertNotIn(' selected=', output)
        self.assertNotIn(' collector=', output)
        self.assertNotIn(SECRET.decode(), output)
        foreign = object()
        runner._collect_predicate_observation(raw, b'', refusal=foreign)
        self.assertNotIn(' collector=', unavailable(foreign))

    def test_internal_exception_is_first_bounded_id_without_exception_text(self):
        raw, record, original = valid_parser_refusal()
        with mock.patch.object(runner, '_predicate_window',
                               side_effect=RuntimeError(SECRET.decode())):
            runner._collect_predicate_observation(raw, b'', refusal=record)
        output = unavailable(record)
        self.assertIn(' collector=13', output)
        self.assertNotIn(SECRET.decode(), output)
        self.assertLessEqual(len((output + '\n').encode('ascii')), 512)
        runner._collect_predicate_observation(b'not a trace', b'', refusal=record)
        self.assertIn(' collector=13', unavailable(record))
        with self.assertRaises(ValueError) as after:
            runner.parse_trace(raw, b'', refusal=record)
        self.assertEqual((type(after.exception), after.exception.args), original)

    def test_wrapper_before_selected_scope_remains_ignored(self):
        raw, record, _ = valid_parser_refusal()
        runner._collect_predicate_observation(wrapper(1) + raw, b'', refusal=record)
        self.assertEqual(runner._predicate_observation(record), (1, 1, 1))
        self.assertNotIn(' collector=', unavailable(record))


if __name__ == '__main__':
    unittest.main(verbosity=2)
