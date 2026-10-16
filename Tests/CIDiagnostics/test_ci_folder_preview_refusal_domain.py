"""Behavioral refusal-domain contract; expected to RED before diagnostics land."""
import importlib.util
from pathlib import Path
import unittest

SOURCE = Path(__file__).resolve().parents[2] / 'scripts' / 'ci_folder_preview_trace.py'
SPEC = importlib.util.spec_from_file_location('observable_trace_target', SOURCE)
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)

ROOT_STAGES = (0, 1, 2, 3, 10, 20, 21, 23, 12, 13, 14, 15, 16, 17, 18, 19, 24, 4, 5)
SECRET = b'private refusal payload'


def marker(event):
    if event[0] == 'outer':
        return f'CI_FOLDER_PREVIEW_TRACE p={event[1]} e={event[2]}\n'.encode()
    return f'CI_FOLDER_PREVIEW_PATH s={event[1]}\n'.encode()


def core(stage):
    return f'CI_FOLDER_PREVIEW_CORE s={stage}\n'.encode()


def selected():
    return b'CI_PREVIEW_PREDICATE c=1 m=1\n'


def wrapper(main=1):
    return f'CI_PREVIEW_PREDICATE w=0 m={main}\n'.encode()


def valid_parser4_refusal():
    events = runner._trace_grammar()
    end = events.index(('path', 8, 11))
    raw = (b''.join(marker(event) for event in events[:end])
           + b''.join(core(stage) for stage in ROOT_STAGES)
           + selected() + wrapper() + core(6) + core(7) + core(9)
           + b''.join(marker(event) for event in events[end:]))
    record = runner._ParserRefusal()
    with unittest.TestCase().assertRaises(ValueError) as ordinary:
        runner.parse_trace(raw, b'')
    with unittest.TestCase().assertRaises(ValueError) as witnessed:
        runner.parse_trace(raw, b'', refusal=record)
    assert type(ordinary.exception) is type(witnessed.exception)
    assert ordinary.exception.args == witnessed.exception.args
    assert runner._parser_refusal_transition(record) == (6, 6)
    return raw, record, ordinary.exception


def unavailable(record):
    progress = runner._AvailabilityProgress()
    runner._availability_enter(progress, 17)
    runner._availability_fail(progress)
    return runner._availability_output(progress, parser_refusal=record)


class ObservableRefusalDomainTests(unittest.TestCase):
    def assert_domain(self, stdout, stderr, expected_id, *, repeat=False):
        raw, record, original_exception = valid_parser4_refusal()
        runner._collect_predicate_observation(stdout(raw), stderr(raw), refusal=record)
        expected = (
            'ci-folder-preview-trace: unavailable\n'
            'reason: incomplete-evidence\n'
            f'availability: boundary=17 parser=4 state=6 incoming=6 collector={expected_id}')
        output = unavailable(record)
        self.assertEqual(output, expected)
        self.assertLessEqual(len((output + '\n').encode('ascii')), 512)
        self.assertNotIn(SECRET.decode(), output)
        with self.assertRaises(ValueError) as after:
            runner.parse_trace(raw, b'', refusal=record)
        self.assertIs(type(after.exception), type(original_exception))
        self.assertEqual(after.exception.args, original_exception.args)
        if repeat:
            runner._collect_predicate_observation(stdout(raw) + wrapper(0), stderr(raw), refusal=record)
            self.assertEqual(unavailable(record), expected)

    def test_thread_rejection_is_observable_only_as_closed_domain(self):
        self.assert_domain(lambda raw: raw.replace(wrapper(), wrapper(0), 1), lambda raw: b'', 4)

    def test_stream_rejection_is_observable_only_as_closed_domain(self):
        def move_side(raw):
            side = selected() + wrapper()
            return raw.replace(side, b'', 1)
        self.assert_domain(move_side, lambda raw: selected() + wrapper(), 5)

    def test_first_refusal_is_stable_and_sanitized(self):
        def malformed_then_wrong_thread(raw):
            return raw + b'CI_PREVIEW_PREDICATE ' + SECRET + b'\n' + wrapper(0)
        self.assert_domain(malformed_then_wrong_thread, lambda raw: b'', 3, repeat=True)

    def test_old_path_rejection_is_observable_without_changing_parser_exception(self):
        def corrupt_path(raw):
            return raw.replace(b'CI_FOLDER_PREVIEW_PATH s=8\n',
                               b'CI_FOLDER_PREVIEW_PATH s=9\n', 1)
        self.assert_domain(corrupt_path, lambda raw: b'', 11)


if __name__ == '__main__':
    unittest.main(verbosity=2)
