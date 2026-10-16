"""Synthetic contract tests for bounded XCTest event observation."""
import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

import importlib.util
import sys
from unittest import mock

_module_path = Path(__file__).resolve().parents[2] / 'scripts/ci_owned_failure_diagnostics.py'
_module_spec = importlib.util.spec_from_file_location('ci_owned_failure_diagnostics_events', _module_path)
diagnostic = importlib.util.module_from_spec(_module_spec)
sys.modules[_module_spec.name] = diagnostic
_module_spec.loader.exec_module(diagnostic)


class CoreEventObservationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='ci-event-observation-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.capture = self.root / '.local/ci-core'
        self.capture.mkdir(parents=True, mode=0o700)
        self.test_path = 'Tests/PadCoreTests/ObservedTests.swift'
        self.public = (self.test_path,)
        target = self.root / self.test_path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text('final class ObservedTests {\n    func testSynthetic() {}\n}\n')

    def receipt(self, stdout=b'', stderr=b'', **changes):
        counts = lambda data: dict(stored=len(data), received=len(data), discarded=0)
        value = dict(command=['synthetic-command'], pid=123, processGroup=123,
            exitObserved=True, registrationError=None, groupSignalAttempted=True,
            groupSignalError=None, groupCleanup='signaled', groupQuery=None,
            waitCompleted=True, returnCode=1, waitError=None, timedOut=False,
            interruptedSignal=None, truncated=False, captureComplete=True, failure=None,
            exit=1, captured=dict(stdout=counts(stdout), stderr=counts(stderr)), seconds=1.0)
        value.update(changes)
        (self.capture / 'stdout.log').write_bytes(stdout)
        (self.capture / 'stderr.log').write_bytes(stderr)
        (self.capture / 'status.json').write_text(json.dumps(value))
        return value

    def collect(self, roster=None):
        return diagnostic.collect(self.root, roster=roster or (lambda _root: self.public))

    def identity(self, lines):
        return [line for line in lines if line.startswith('xctest-id:')]

    def assertUnknown(self, stdout=b'', stderr=b'', *, roster=None, **changes):
        self.receipt(stdout, stderr, **changes)
        code, lines = self.collect(roster=roster)
        self.assertEqual(code, 0)
        self.assertEqual(self.identity(lines), ['xctest-id: unknown'])
        self.assertLessEqual(len(lines), 10)
        self.assertLessEqual(len(('\n'.join(lines) + '\n').encode('ascii')), 2048)
        return lines

    def test_exact_failed_terminal_maps_only_to_unique_source_text_candidate(self):
        log = ("Test Case '-[PadCoreTests.ObservedTests testSynthetic]' started.\n"
               "Test Case '-[PadCoreTests.ObservedTests testSynthetic]' failed (0.125 seconds).\n").encode('ascii')
        self.receipt(stderr=log)
        code, lines = self.collect()
        self.assertEqual(code, 0)
        self.assertEqual(self.identity(lines), [
            'xctest-id: reported-failure-event source-text-candidate Tests/PadCoreTests/ObservedTests.swift:2'])
        text = '\n'.join(lines)
        self.assertNotIn('testSynthetic', text)
        self.assertNotIn('-[', text)
        self.assertNotIn('Test Case ', text)

    def test_exact_dotted_start_is_unfinished_only_after_eligible_natural_exit(self):
        log = b"Test Case 'ObservedTests.testSynthetic' started.\n"
        self.receipt(stderr=log)
        code, lines = self.collect()
        self.assertEqual(code, 0)
        self.assertEqual(self.identity(lines), [
            'xctest-id: started-without-terminal-at-exit source-text-candidate Tests/PadCoreTests/ObservedTests.swift:2'])

    def test_passed_terminal_and_failed_plus_unfinished_are_unknown(self):
        passed = b"Test Case 'ObservedTests.testSynthetic' started.\nTest Case 'ObservedTests.testSynthetic' passed (1 seconds).\n"
        self.assertUnknown(stderr=passed)
        conflict = ("Test Case 'ObservedTests.testSynthetic' started.\n"
                    "Test Case 'ObservedTests.testSynthetic' failed (0 seconds).\n"
                    "Test Case 'OtherTests.testOther' started.\n").encode('ascii')
        self.assertUnknown(stderr=conflict)

    def test_event_record_variants_are_exact_and_malformed_event_lines_fail_closed(self):
        accepted_starts = [
            b"Test Case '-[Fixture.ExampleTests testSynthetic]' started.\n",
            b"Test Case 'ExampleTests.testSynthetic' started.\n",
            b"Test Case 'A.B.C.testSynthetic' started.\n",
        ]
        for line in accepted_starts:
            with self.subTest(line=line):
                self.receipt(stderr=line)
                code, lines = self.collect()
                self.assertEqual(code, 0)
                self.assertEqual(self.identity(lines), [
                    'xctest-id: started-without-terminal-at-exit source-text-candidate Tests/PadCoreTests/ObservedTests.swift:2'])
        maximum_method = 'test' + ('A' * 124)
        self.assertEqual(len(maximum_method.encode('ascii')), 128)
        (self.root / self.test_path).write_text('func ' + maximum_method + '() {}\n')
        maximum_event = ("Test Case 'A.B.C." + maximum_method + "' started.\n").encode('ascii')
        self.receipt(stderr=maximum_event)
        code, lines = self.collect()
        self.assertEqual(code, 0)
        self.assertEqual(self.identity(lines), [
            'xctest-id: started-without-terminal-at-exit source-text-candidate Tests/PadCoreTests/ObservedTests.swift:1'])
        (self.root / self.test_path).write_text('final class ObservedTests {\n    func testSynthetic() {}\n}\n')
        accepted_passes = [
            (b"Test Case '-[Fixture.ExampleTests testSynthetic]' started.\n",
             b"Test Case '-[Fixture.ExampleTests testSynthetic]' passed (1 seconds).\n"),
            (b"Test Case 'ExampleTests.testSynthetic' started.\n",
             b"Test Case 'ExampleTests.testSynthetic' passed (0.123456 seconds).\n"),
            (b"Test Case 'ExampleTests.testSynthetic' started.\n",
             b"Test Case 'ExampleTests.testSynthetic' skipped (0.1 seconds).\n"),
        ]
        for start, terminal in accepted_passes:
            with self.subTest(terminal=terminal):
                self.assertUnknown(stderr=start + terminal)
        rejected = [
            b" Test Case 'ExampleTests.testSynthetic' started.\n",
            b"\tTest Case 'ExampleTests.testSynthetic' started.\n",
            b"Test Case  'ExampleTests.testSynthetic' started.\n",
            b"Test Case 'ExampleTests.testSynthetic' started. trailing\n",
            b"Test Case 'ExampleTests.testSynthetic' passed (0.1234567 seconds).\n",
            b"Test Case 'ExampleTests.testSynthetic' passed (+1 seconds).\n",
            b"Test Case 'A.B.C.D.testSynthetic' started.\n",
            b"Test Case 'ExampleTests.notATest' started.\n",
            b"Test Case 'ExampleTests.testSynthetic' passed (1 second).\n",
            b"Test Case 'ExampleTests.testSynthetic' started.\r\n",
            b"Test Case 'ExampleTests.testSynthetic' started.",
            b"Test Case 'ExampleTests." + b'test' + b'A' * 125 + b"' started.\n",
            b"Test Case 'ExampleTests.testSynthetic' failed (1 seconds) suffix.\n",
        ]
        valid_start = b"Test Case 'ExampleTests.testSynthetic' started.\n"
        for line in rejected:
            with self.subTest(line=line):
                self.assertUnknown(stderr=valid_start + line)

    def test_same_identity_in_two_capture_streams_is_ambiguous(self):
        start = b"Test Case 'ObservedTests.testSynthetic' started.\n"
        end = b"Test Case 'ObservedTests.testSynthetic' failed (0.2 seconds).\n"
        self.assertUnknown(stdout=start, stderr=end)

    def test_duplicate_start_and_terminal_without_start_fail_closed(self):
        start = b"Test Case 'ObservedTests.testSynthetic' started.\n"
        repeated = start + b"Test Case 'ObservedTests.testSynthetic' started.\n"
        self.assertUnknown(stderr=repeated)
        objc = b"Test Case '-[ObservedTests testSynthetic]' started.\n"
        dotted = b"Test Case 'ObservedTests.testSynthetic' started.\n"
        self.assertUnknown(stderr=objc + dotted)
        terminal = b"Test Case 'ObservedTests.testSynthetic' failed (0.2 seconds).\n"
        self.assertUnknown(stderr=terminal)

    def test_unmatched_start_requires_complete_natural_positive_receipt(self):
        start = b"Test Case 'ObservedTests.testSynthetic' started.\n"
        gates = [
            dict(returnCode=0, exit=0), dict(returnCode=-9), dict(timedOut=True),
            dict(interruptedSignal=15), dict(captureComplete=False), dict(truncated=True),
            dict(waitCompleted=False), dict(exitObserved=False), dict(waitError='synthetic'),
            dict(failure='synthetic watchdog failure'),
        ]
        for gate in gates:
            with self.subTest(gate=gate):
                self.assertUnknown(stderr=start, **gate)

    def test_source_text_match_counts_comments_and_string_contents_without_claiming_declaration(self):
        target = self.root / self.test_path
        target.write_text('/*\n    func testSynthetic() {}\n*/\n')
        self.receipt(stderr=b"Test Case 'ObservedTests.testSynthetic' started.\n")
        code, lines = self.collect()
        self.assertEqual(code, 0)
        self.assertEqual(self.identity(lines), [
            'xctest-id: started-without-terminal-at-exit source-text-candidate Tests/PadCoreTests/ObservedTests.swift:2'])
        target.write_text('func testSynthetic() {}\n/*\nfunc testSynthetic() {}\n*/\n')
        self.assertUnknown(stderr=b"Test Case 'ObservedTests.testSynthetic' started.\n")
        target.write_text('let fixture = """\nfunc testSynthetic() {}\n"""\n')
        self.receipt(stderr=b"Test Case 'ObservedTests.testSynthetic' started.\n")
        code, lines = self.collect()
        self.assertEqual(code, 0)
        self.assertEqual(self.identity(lines), [
            'xctest-id: started-without-terminal-at-exit source-text-candidate Tests/PadCoreTests/ObservedTests.swift:2'])

    def test_source_candidate_requires_exact_method_line_and_unique_roster_match(self):
        target = self.root / self.test_path
        target.write_text('    func testOther() {}\n')
        self.assertUnknown(stderr=b"Test Case 'ObservedTests.testSynthetic' started.\n")
        target.write_text('func testSynthetic() {}\n')
        other = 'Tests/Other/Second.swift'
        other_path = self.root / other
        other_path.parent.mkdir(parents=True, exist_ok=True)
        other_path.write_text('func testSynthetic() {}\n')
        self.public = (self.test_path, other)
        self.assertUnknown(stderr=b"Test Case 'ObservedTests.testSynthetic' started.\n")
        self.public = (self.test_path,)
        untracked = self.root / 'Tests/Untracked/Untracked.swift'
        untracked.parent.mkdir(parents=True, exist_ok=True)
        untracked.write_text('func testSynthetic() {}\n')
        self.receipt(stderr=b"Test Case 'ObservedTests.testSynthetic' started.\n")
        code, lines = self.collect()
        self.assertEqual(code, 0)
        self.assertEqual(self.identity(lines), [
            'xctest-id: started-without-terminal-at-exit source-text-candidate Tests/PadCoreTests/ObservedTests.swift:1'])

    def test_candidate_source_read_refusals_never_emit_an_identity(self):
        event = b"Test Case 'ObservedTests.testSynthetic' started.\n"
        target = self.root / self.test_path
        target.unlink()
        self.assertUnknown(stderr=event)
        target.unlink(missing_ok=True)
        candidate = b'func testSynthetic() {}\n'
        prefix = b'//' + b'x' * (256 * 1024 - len(candidate) - 3) + b'\n'
        exact_limit_source = prefix + candidate
        self.assertEqual(len(exact_limit_source), 256 * 1024)
        target.write_bytes(exact_limit_source)
        self.receipt(stderr=event)
        code, lines = self.collect()
        self.assertEqual(code, 0)
        self.assertEqual(self.identity(lines), [
            'xctest-id: started-without-terminal-at-exit source-text-candidate Tests/PadCoreTests/ObservedTests.swift:2'])
        target.write_bytes(b'x' * (256 * 1024 + 1) + b'\nfunc testSynthetic() {}\n')
        self.assertUnknown(stderr=event)
        target.unlink()
        outside = self.root / 'synthetic-outside.swift'
        outside.write_text('func testSynthetic() {}\n')
        target.symlink_to(outside)
        self.assertUnknown(stderr=event)
        target.unlink()
        actual_directory = self.root / 'Tests/Actual'
        actual_directory.mkdir(parents=True)
        (actual_directory / 'Observed.swift').write_text('func testSynthetic() {}\n')
        alias = self.root / 'Tests/Alias'
        alias.symlink_to(actual_directory, target_is_directory=True)
        alias_path = 'Tests/Alias/Observed.swift'
        self.assertUnknown(stderr=event, roster=lambda _root: (alias_path,))

    def test_source_candidate_scan_caps_return_unknown(self):
        event = b"Test Case 'ObservedTests.testSynthetic' started.\n"
        names = []
        for index in range(512):
            name = f'Tests/Synthetic/T{index}.swift'
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('func testSynthetic() {}\n' if index == 0 else '// synthetic\n')
            names.append(name)
        self.receipt(stderr=event)
        code, lines = self.collect(roster=lambda _root: tuple(names))
        self.assertEqual(code, 0)
        self.assertEqual(self.identity(lines), [
            'xctest-id: started-without-terminal-at-exit source-text-candidate Tests/Synthetic/T0.swift:1'])
        name = 'Tests/Synthetic/T512.swift'
        path = self.root / name
        path.write_text('// nonmatching tracked source\n')
        names.append(name)
        self.assertUnknown(stderr=event, roster=lambda _root: tuple(names))
        names = []
        limit = 256 * 1024
        candidate = b'func testSynthetic() {}\n'
        for index in range(32):
            name = f'Tests/Aggregate/A{index}.swift'
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            if index == 0:
                payload = candidate + b'//' + b'x' * (limit - len(candidate) - 3) + b'\n'
            else:
                payload = b'x' * limit
            self.assertEqual(len(payload), limit)
            path.write_bytes(payload)
            names.append(name)
        self.receipt(stderr=event)
        code, lines = self.collect(roster=lambda _root: tuple(names))
        self.assertEqual(code, 0)
        self.assertEqual(self.identity(lines), [
            'xctest-id: started-without-terminal-at-exit source-text-candidate Tests/Aggregate/A0.swift:1'])
        name = 'Tests/Aggregate/A32.swift'
        path = self.root / name
        path.write_bytes(b'x' * limit)
        names.append(name)
        self.assertUnknown(stderr=event, roster=lambda _root: tuple(names))

    def test_active_event_and_event_line_caps_fail_closed(self):
        starts = ["Test Case 'ObservedTests.testSynthetic' started.\n"]
        terminals = []
        for index in range(63):
            identity = f'OtherTests.testNoise{index}'
            starts.append(f"Test Case '{identity}' started.\n")
            terminals.append(f"Test Case '{identity}' passed (0 seconds).\n")
        overflow = "Test Case 'OtherTests.testOverflow' started.\n"
        close_overflow = "Test Case 'OtherTests.testOverflow' passed (0 seconds).\n"
        discriminating = ''.join(starts) + overflow + ''.join(terminals) + close_overflow
        self.assertUnknown(stderr=discriminating.encode('ascii'))
        too_long = b"Test Case '" + b'A' * 4097 + b"' started.\n"
        self.assertUnknown(stderr=too_long)

    def test_event_record_budget_and_four_location_budget_are_closed(self):
        events = []
        for index in range(4095):
            identity = f'ObservedTests.testCase{index}'
            events.append(f"Test Case '{identity}' started.\n")
            events.append(f"Test Case '{identity}' passed (0 seconds).\n")
        target_start = "Test Case 'ObservedTests.testSynthetic' started.\n"
        events.append(target_start)
        boundary = ''.join(events).encode('ascii')
        self.assertEqual(len(events), 8191)
        self.assertLessEqual(len(boundary), 1_048_576)
        self.receipt(stderr=boundary)
        code, lines = self.collect()
        self.assertEqual(code, 0)
        self.assertEqual(self.identity(lines), [
            'xctest-id: started-without-terminal-at-exit source-text-candidate Tests/PadCoreTests/ObservedTests.swift:2'])
        (self.root / self.test_path).write_text('func testSynthetic() {}\nfunc testAdditional() {}\n')
        over = boundary + b"Test Case 'ObservedTests.testSynthetic' passed (0 seconds).\n" + b"Test Case 'AdditionalTests.testAdditional' started.\n"
        self.assertEqual(len(over.splitlines()), 8193)
        self.assertUnknown(stderr=over)

        other_paths = ('Sources/A.swift', 'Sources/B.swift', 'Sources/C.swift')
        for path in other_paths:
            target = self.root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text('// synthetic tracked source\n')
        self.public = (self.test_path,) + other_paths
        locations = ''.join(str(self.root / path) + ':4:2: error: synthetic\n'
                            for path in self.public).encode('ascii')
        event = (b"Test Case 'ObservedTests.testSynthetic' started.\n"
                 b"Test Case 'ObservedTests.testSynthetic' failed (0 seconds).\n")
        self.receipt(stderr=event + locations)
        code, lines = self.collect()
        self.assertEqual(code, 0)
        identities = self.identity(lines)
        self.assertEqual(identities, [
            'xctest-id: reported-failure-event source-text-candidate Tests/PadCoreTests/ObservedTests.swift:1'])
        location_lines = [line for line in lines if line.startswith('location:')]
        self.assertEqual(len(identities) + len(location_lines), 4)
        self.assertEqual(location_lines, [
            'location: Tests/PadCoreTests/ObservedTests.swift:4:2',
            'location: Sources/A.swift:4:2',
            'location: Sources/B.swift:4:2'])
        self.assertLessEqual(len(('\n'.join(lines) + '\n').encode('ascii')), 2048)

    def test_source_method_candidate_whitespace_uses_only_ascii_space_and_tab(self):
        target = self.root / self.test_path
        event = b"Test Case 'ObservedTests.testSynthetic' started.\n"
        accepted_lines = (
            ' func testSynthetic() {}\n',
            '\tfunc testSynthetic() {}\n',
            ' @MainActor\t override func testSynthetic() {}\n',
        )
        for source_line in accepted_lines:
            target.write_text(source_line)
            self.receipt(stderr=event)
            code, lines = self.collect()
            self.assertEqual(code, 0)
            self.assertEqual(self.identity(lines), [
                'xctest-id: started-without-terminal-at-exit source-text-candidate Tests/PadCoreTests/ObservedTests.swift:1'])
        for prefix in ('\v', '\f'):
            target.write_text(prefix + 'func testSynthetic() {}\n')
            self.assertUnknown(stderr=event)

    def test_event_looking_prefix_uses_only_ascii_space_and_tab(self):
        valid = b"Test Case 'ObservedTests.testSynthetic' started.\n"
        for prefix in (b'\v', b'\f'):
            # VT/FF are not horizontal whitespace, so these are unrelated lines;
            # the prior valid start remains the sole eligible observation.
            self.receipt(stderr=valid + prefix + b"Test Case 'OtherTests.testOther' started.\n")
            code, lines = self.collect()
            self.assertEqual(code, 0)
            self.assertEqual(self.identity(lines), [
                'xctest-id: started-without-terminal-at-exit source-text-candidate Tests/PadCoreTests/ObservedTests.swift:2'])

    def test_summary_only_keeps_unknown_identity_and_reads_no_test_source(self):
        source = self.root / self.test_path
        event = b"Test Case 'ObservedTests.testSynthetic' started.\n"
        location = (str(source) + ':2:1: error: synthetic\n').encode('ascii')
        self.receipt(stderr=event + location + b'Executed 1 test, with 0 failures (0 unexpected) in 0.1 seconds\n')
        output = io.StringIO()
        real_open = diagnostic.os.open
        def reject_source_open(path, *args, **kwargs):
            if str(path).endswith('.swift'):
                raise AssertionError('Summary mode must not read test source')
            return real_open(path, *args, **kwargs)
        with mock.patch.object(diagnostic, '__file__', str(self.root / 'scripts/ci_owned_failure_diagnostics.py')), \
             mock.patch.object(diagnostic, 'tracked_public_roster', side_effect=AssertionError('Summary mode must not query Git')), \
             mock.patch.object(diagnostic.os, 'open', side_effect=reject_source_open), \
             contextlib.redirect_stdout(output):
            code = diagnostic.main(['--summary-only'])
        self.assertEqual(code, 0)
        lines = output.getvalue().splitlines()
        self.assertEqual(self.identity(lines), ['xctest-id: unknown'])
        self.assertNotIn(str(self.root), output.getvalue())


if __name__ == '__main__':
    unittest.main()
