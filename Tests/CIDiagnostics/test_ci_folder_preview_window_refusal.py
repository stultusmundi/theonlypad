"""Closed selected-window subcodes; original grammar and refusal stay authoritative."""
import importlib.util
from pathlib import Path
import unittest

SOURCE = Path(__file__).resolve().parents[2] / 'scripts' / 'ci_folder_preview_trace.py'
SPEC = importlib.util.spec_from_file_location('window_refusal_target', SOURCE)
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)

ROOT_STAGES = (0, 1, 2, 3, 10, 20, 21, 23, 12, 13, 14, 15, 16, 17, 18, 19, 24, 4, 5)
SECRET = b'private selected-window payload'


def marker(event):
    if event[0] == 'outer':
        return f'CI_FOLDER_PREVIEW_TRACE p={event[1]} e={event[2]}\n'.encode()
    return f'CI_FOLDER_PREVIEW_PATH s={event[1]}\n'.encode()


def path(stage):
    return f'CI_FOLDER_PREVIEW_PATH s={stage}\n'.encode()


def core(stage):
    return f'CI_FOLDER_PREVIEW_CORE s={stage}\n'.encode()


def selected():
    return b'CI_PREVIEW_PREDICATE c=1 m=1\n'


def wrapper():
    return b'CI_PREVIEW_PREDICATE w=0 m=1\n'


def schedule():
    events = runner._trace_grammar()
    open_i = events.index(('path', 7, 11))
    close_i = events.index(('path', 8, 11))
    prefix = b''.join(marker(event) for event in events[:open_i])
    open_marker = marker(events[open_i])
    close_marker = marker(events[close_i])
    tail = b''.join(marker(event) for event in events[close_i + 1:])
    block = (b''.join(core(stage) for stage in ROOT_STAGES) + selected() + wrapper()
             + core(6) + core(7) + core(9))
    raw = prefix + open_marker + block + close_marker + tail
    close_offset = len(prefix + open_marker + block)
    return raw, prefix, open_marker, block, close_marker, tail, close_offset


def parser4_refusal(raw):
    record = runner._ParserRefusal()
    errors = []
    for kwargs in ({}, {'refusal': record}):
        with unittest.TestCase().assertRaises(ValueError) as caught:
            runner.parse_trace(raw, b'', **kwargs)
        errors.append((type(caught.exception), caught.exception.args))
    if errors[0] != errors[1] or runner._parser_refusal_transition(record) != (6, 6):
        raise AssertionError('fixture must retain the original parser4 state6/incoming6 refusal')
    return record, errors[0]


def unavailable(record):
    progress = runner._AvailabilityProgress()
    runner._availability_enter(progress, 17)
    runner._availability_fail(progress)
    return runner._availability_output(progress, parser_refusal=record)


def assert_no_secret(test, output):
    test.assertNotIn(SECRET.decode(), output)
    test.assertLessEqual(len((output + '\n').encode('ascii')), 512)


class WindowRefusalSubcodeTests(unittest.TestCase):
    def assert_integrated_subcode(self, raw, subcode):
        record, original = parser4_refusal(raw)
        runner._collect_predicate_observation(raw, b'', refusal=record)
        output = unavailable(record)
        self.assertIn(f'collector=9 window={subcode}', output)
        self.assertEqual(runner._parser_refusal_transition(record), (6, 6))
        assert_no_secret(self, output)
        with self.assertRaises(ValueError) as again:
            runner.parse_trace(raw, b'', refusal=record)
        self.assertEqual((type(again.exception), again.exception.args), original)
        return record, output

    def test_valid_canonical_window_has_parent_domain_behavior_only_when_core_refuses(self):
        raw, *_ = schedule()
        record, _ = parser4_refusal(raw)
        runner._collect_predicate_observation(raw, b'', refusal=record)
        self.assertNotIn('collector=', unavailable(record))
        self.assertEqual(runner._predicate_observation(record), (1, 1, 1))
        self.assertEqual(runner._parser_refusal_transition(record), (6, 6))

    def test_existing_domain_legend_and_parse_count_contract_stay_fixed(self):
        self.assertEqual(runner._COLLECTOR_DOMAIN_IDS, {
            'buffer-type': 1, 'capture-cap': 2, 'record-shape': 3, 'thread': 4,
            'stream': 5, 'side-cap': 6, 'core-cap': 7, 'marker-presence': 8,
            'window': 9, 'prefix': 10, 'old-path': 11, 'tuple': 12,
            'collector-exception': 13,
        })
        raw, *_ = schedule()
        record, _ = parser4_refusal(raw)
        original_path_parse = runner._parse_path_trace
        original_core_parse = runner.parse_trace
        path_calls = []

        def counted_path_parse(*buffers):
            path_calls.append(1)
            return original_path_parse(*buffers)

        def forbidden_core_replay(*args, **kwargs):
            raise AssertionError('collector replayed the original Core parser')

        runner._parse_path_trace = counted_path_parse
        runner.parse_trace = forbidden_core_replay
        try:
            runner._collect_predicate_observation(raw, b'', refusal=record)
        finally:
            runner._parse_path_trace = original_path_parse
            runner.parse_trace = original_core_parse
        self.assertEqual(len(path_calls), 1)
        self.assertEqual(runner._predicate_observation(record), (1, 1, 1))

    def test_core_after_close_is_subcode_two(self):
        raw, prefix, opening, block, closing, tail, _ = schedule()
        # Keep the parser4 Core6 refusal inside the window; a later Core9 is
        # visible to the full-buffer collector after the same valid PATH8 close.
        core_before_close = block.rsplit(core(9), 1)[0]
        moved = prefix + opening + core_before_close + closing + core(9) + tail
        self.assert_integrated_subcode(moved, 2)

    def test_selected_count_before_open_is_subcode_three(self):
        _, prefix, opening, block, closing, tail, _ = schedule()
        # Preserve the valid in-window count and add a second count before it.
        moved = prefix + selected() + opening + block + closing + tail
        self.assert_integrated_subcode(moved, 3)

    def test_selected_count_after_close_is_subcode_four(self):
        _, prefix, opening, block, closing, tail, _ = schedule()
        # Preserve the valid in-window count and add a second count after it.
        moved = prefix + opening + block + closing + selected() + tail
        self.assert_integrated_subcode(moved, 4)

    def test_core_before_open_is_subcode_one_at_window_guard(self):
        raw, prefix, opening, block, closing, tail, _ = schedule()
        record, _ = parser4_refusal(raw)
        nonce = record._predicate_nonce
        pair = runner._parser_refusal_transition(record)
        record._predicate_attempted = True
        moved = prefix + core(0) + opening + block.replace(core(0), b'', 1) + closing + tail
        with self.assertRaises(ValueError):
            runner._predicate_window(moved, refusal=record, nonce=nonce, pair=pair)
        output = unavailable(record)
        self.assertIn('collector=9 window=1', output)
        assert_no_secret(self, output)

    def test_incomplete_window_invariant_is_subcode_five(self):
        raw, prefix, opening, block, closing, tail, close_offset = schedule()
        record, _ = parser4_refusal(raw)
        nonce = record._predicate_nonce
        pair = runner._parser_refusal_transition(record)
        record._predicate_attempted = True
        incomplete = prefix + opening + block + tail
        with self.assertRaises(ValueError):
            runner._predicate_window(incomplete, refusal=record, nonce=nonce, pair=pair)
        output = unavailable(record)
        self.assertIn('collector=9 window=5', output)
        assert_no_secret(self, output)

    def test_malformed_path_still_wins_as_domain_eleven_without_window_detail(self):
        raw, prefix, opening, block, closing, tail, close_offset = schedule()
        malformed = raw[:close_offset] + path(9) + raw[close_offset + len(closing):]
        record, _ = parser4_refusal(malformed)
        runner._collect_predicate_observation(malformed, b'', refusal=record)
        output = unavailable(record)
        self.assertIn('collector=11', output)
        self.assertNotIn('window=', output)
        assert_no_secret(self, output)

    def test_first_subcode_latches_and_stale_or_foreign_witness_withholds_it(self):
        raw, prefix, opening, block, closing, tail, _ = schedule()
        after_count = prefix + opening + block + closing + selected() + tail
        record, _ = self.assert_integrated_subcode(after_count, 4)
        before_count = prefix + selected() + opening + block + closing + tail
        runner._collect_predicate_observation(before_count, b'', refusal=record)
        self.assertIn('collector=9 window=4', unavailable(record))
        record._predicate_nonce = object()
        output = unavailable(record)
        self.assertNotIn('collector=', output)
        self.assertNotIn('window=', output)
        self.assertIn('state=6 incoming=6', output)
        foreign = object()
        runner._collect_predicate_observation(raw, b'', refusal=foreign)
        self.assertNotIn('collector=', runner._availability_output(
            runner._AvailabilityProgress(), parser_refusal=foreign))


if __name__ == '__main__':
    unittest.main(verbosity=2)
