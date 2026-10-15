"""Synthetic test-first contract. Run only under Root's frozen evidence recipe."""
import contextlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

import importlib.util
import sys

_module_path = Path(__file__).resolve().parents[2] / 'scripts/ci_owned_failure_diagnostics.py'
_module_spec = importlib.util.spec_from_file_location('ci_owned_failure_diagnostics', _module_path)
diagnostic = importlib.util.module_from_spec(_module_spec)
sys.modules[_module_spec.name] = diagnostic
_module_spec.loader.exec_module(diagnostic)


class CoreFailureDiagnosticsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='ci-diagnostic-synthetic-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.capture = self.root / '.local/ci-core'
        self.capture.mkdir(parents=True, mode=0o700)
        self.public = ('Sources/PadCore/Observed.swift', 'Tests/PadCoreTests/ObservedTests.swift')
        for name in self.public:
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text('// Synthetic public fixture\n')

    def receipt(self, stdout=b'', stderr=b'', **changes):
        counts = lambda value: dict(stored=len(value), received=len(value), discarded=0)
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

    def collect(self):
        return diagnostic.collect(self.root, roster=lambda root: self.public)

    def assertClosed(self, lines):
        text = '\n'.join(lines)
        self.assertLessEqual(len(lines), 10)
        self.assertLessEqual(len((text + '\n').encode('ascii')), 2048)
        self.assertNotIn('\x1b', text)
        self.assertNotIn('\r', text)
        self.assertNotIn('::', text)
        grammar = (r'ci-core diagnostics: (?:observed|unavailable)|reason: [a-z-]+|'
            r'watchdog: exit=\d+ returnCode=(?:-?\d+|null) timedOut=(?:true|false) '
            r'truncated=(?:true|false) captureComplete=(?:true|false) waitCompleted=(?:true|false)|'
            r'captures: stdout=\d+ stderr=\d+|xctest: (?:not-observed|tests=\d+ failures=\d+ unexpected=\d+)|'
            r'signals: compiler=\d+ test=\d+ crash=\d+ dependency=\d+ permission=\d+ resource=\d+|'
            r'xctest-id: unknown|location: (?:Sources|Tests)/[A-Za-z0-9_./-]+:\d+(?::\d+)?')
        for line in lines:
            self.assertIsNotNone(re.fullmatch(grammar, line), line)
        return text

    def assertUnavailable(self, reason):
        code, lines = self.collect()
        self.assertEqual(code, 2)
        self.assertEqual(lines, ['ci-core diagnostics: unavailable', 'reason: ' + reason])
        self.assertClosed(lines)

    def test_natural_failure_has_truthful_closed_summary(self):
        stderr = b'error: no such module SyntheticModule\n'
        self.receipt(stderr=stderr)
        before = {p.name: p.read_bytes() for p in self.capture.iterdir()}
        code, lines = self.collect()
        self.assertEqual(code, 0, 'An observed original failure needs an actual diagnostic')
        self.assertEqual(lines, ['ci-core diagnostics: observed',
            'watchdog: exit=1 returnCode=1 timedOut=false truncated=false captureComplete=true waitCompleted=true',
            'captures: stdout=0 stderr=' + str(len(stderr)), 'xctest: not-observed',
            'signals: compiler=1 test=0 crash=0 dependency=1 permission=0 resource=0',
            'xctest-id: unknown'])
        self.assertClosed(lines)
        self.assertEqual(before, {p.name: p.read_bytes() for p in self.capture.iterdir()})

    def test_xctest_totals_and_exact_tracked_relative_locations(self):
        good = str(self.root / self.public[1])
        untracked = self.root / 'Tests/private-untracked.swift'
        untracked.write_text('// never public\n')
        log = (good + ':12:3: error: synthetic failure : failed\n' + str(untracked)
            + ':9:2: error: private failure\n'
            + "Test Case '-[UntrustedClass SecretMethod]' failed (0.1 seconds).\n"
            + 'Executed 2 tests, with 1 failure (0 unexpected) in 0.1 seconds\n').encode()
        self.receipt(stderr=log)
        code, lines = self.collect()
        self.assertEqual(code, 0)
        text = self.assertClosed(lines)
        self.assertIn('xctest: tests=2 failures=1 unexpected=0', lines)
        self.assertEqual([x for x in lines if x.startswith('location:')],
            ['location: Tests/PadCoreTests/ObservedTests.swift:12:3'])
        for secret in (str(self.root), 'private-untracked', 'UntrustedClass', 'SecretMethod'):
            self.assertNotIn(secret, text)
        # XCTest failures count assertions and can exceed the number of test methods.
        self.receipt(stderr=b'Executed 2 tests, with 3 failures (2 unexpected) in 0.313 (0.313) seconds\n')
        code, lines = self.collect()
        self.assertEqual(code, 0)
        self.assertIn('xctest: tests=2 failures=3 unexpected=2', lines)
        self.assertClosed(lines)

    def test_darwin_parenthesized_elapsed_summary_is_observed(self):
        self.receipt(stderr=b'Executed 2 tests, with 1 failure (0 unexpected) in 0.313 (0.313) seconds\n')
        code, lines = self.collect()
        self.assertEqual(code, 0)
        self.assertIn('xctest: tests=2 failures=1 unexpected=0', lines)
        self.assertClosed(lines)

    def test_repeated_diagnostic_prefixes_stay_bounded_and_closed(self):
        # Near the per-log cap, both classes are deliberately repeated without
        # a terminal match. The report must remain bounded and reveal no input.
        category = ('error: synthetic-prefix dependency resolution still-running ' * 12288).encode('ascii')
        location = (':1:' * 21845).encode('ascii')
        log = category + b'\n' + location + b'\n'
        self.assertLessEqual(len(log), 1_048_576)
        self.receipt(stderr=log)
        code, lines = self.collect()
        self.assertEqual(code, 0)
        text = self.assertClosed(lines)
        self.assertIn('xctest: not-observed', lines)
        self.assertNotIn('synthetic-prefix', text)
        self.assertNotIn(':1:', text)
        self.assertEqual([line for line in lines if line.startswith('location:')], [])

    def test_four_long_verified_locations_fit_final_newline_budget(self):
        fixed = [
            'ci-core diagnostics: observed',
            'watchdog: exit=1 returnCode=1 timedOut=false truncated=false captureComplete=true waitCompleted=true',
            None,
            'xctest: not-observed',
            'signals: compiler=0 test=0 crash=0 dependency=0 permission=0 resource=0',
            'xctest-id: unknown',
        ]
        chosen = None
        for tail_length in range(150, 221):
            paths = (
                'Sources/' + ('A' * 210) + '/' + ('a' * 210) + '.swift',
                'Sources/' + ('B' * 210) + '/' + ('b' * 210) + '.swift',
                'Sources/' + ('C' * 210) + '/' + ('c' * 210) + '.swift',
                'Sources/' + ('D' * 210) + '/' + ('d' * tail_length) + '.swift',
            )
            log = ''.join(str(self.root / relative) + ':12:3: note: synthetic\n'
                          for relative in paths).encode('ascii')
            expected = list(fixed)
            expected[2] = 'captures: stdout=0 stderr=' + str(len(log))
            expected.extend('location: ' + relative + ':12:3' for relative in paths)
            expected_size = len(('\n'.join(expected) + '\n').encode('ascii'))
            if expected_size == 2049:
                chosen = paths, log, expected
                break
        self.assertIsNotNone(chosen, 'The bounded synthetic path family must reach exactly one byte over the cap')
        paths, log, all_four_lines = chosen
        self.assertEqual(len(('\n'.join(all_four_lines) + '\n').encode('ascii')), 2049)
        for relative in paths:
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text('// synthetic boundary fixture\n')
        self.public = paths
        self.receipt(stderr=log)
        code, lines = self.collect()
        self.assertEqual(code, 0)
        self.assertClosed(lines)
        locations = [line for line in lines if line.startswith('location:')]
        self.assertEqual(locations, all_four_lines[6:9])
        self.assertLessEqual(len(('\n'.join(lines) + '\n').encode('ascii')), 2048)

    def test_multiline_credentials_controls_and_commands_never_echo(self):
        secret = 'SYNTHETIC_SECRET_7ac21'
        payload = ('-----BEGIN ' + 'PRIVATE KEY-----\n' + secret + '\n-----END PRIVATE KEY-----\n'
            + 'Authorization: Bearer\n' + secret + '\n' + 'ghp_' + secret * 3
            + '\n::error::' + secret + '\n\x1b[31merror: ' + secret + '\r\n')
        self.receipt(stderr=payload.encode(), command=[secret, '/' + 'Users/' + 'synthetic/' + secret],
            failure=secret)
        code, lines = self.collect()
        self.assertEqual(code, 0)
        text = self.assertClosed(lines)
        for value in (secret, 'PRIVATE KEY', 'Bearer', 'ghp_', '/Users/', '::error::'):
            self.assertNotIn(value, text)

    def test_timeout_truncation_and_incomplete_capture_remain_visible(self):
        value = self.receipt(stderr=b'partial', exit=124, returnCode=-9,
            timedOut=True, truncated=True, captureComplete=False)
        value['captured']['stderr'].update(received=10, discarded=3)
        (self.capture / 'status.json').write_text(json.dumps(value))
        code, lines = self.collect()
        self.assertEqual(code, 0)
        self.assertIn('watchdog: exit=124 returnCode=-9 timedOut=true truncated=true captureComplete=false waitCompleted=true', lines)
        self.assertClosed(lines)

    def test_invalid_status_is_fixed_and_never_echoes_input(self):
        for raw in ('{bad SECRET}', '{"exit":1,"exit":2}', 'NaN', '[]'):
            with self.subTest(raw=raw):
                self.receipt()
                (self.capture / 'status.json').write_text(raw)
                self.assertUnavailable('invalid-status')
        for changes in (dict(exit=True), dict(timedOut='SECRET'), dict(returnCode=256)):
            with self.subTest(changes=changes):
                self.receipt(**changes)
                self.assertUnavailable('invalid-status')

    def test_missing_nonutf8_and_inconsistent_capture_refuse(self):
        self.receipt()
        (self.capture / 'stderr.log').unlink()
        self.assertUnavailable('missing-evidence')
        self.receipt(stderr=b'\xffSECRET')
        self.assertUnavailable('invalid-log-encoding')
        value = self.receipt(stderr=b'ab')
        value['captured']['stderr']['stored'] = 1
        (self.capture / 'status.json').write_text(json.dumps(value))
        self.assertUnavailable('invalid-capture')

    def test_input_bounds_and_huge_summary_numbers_are_safe(self):
        self.receipt(stderr=b'x' * (1048576 + 1))
        self.assertUnavailable('oversized-evidence')
        self.receipt()
        (self.capture / 'status.json').write_bytes(b' ' * (65536 + 1))
        self.assertUnavailable('oversized-evidence')
        self.receipt(stderr=('Executed ' + '9' * 5000 + ' tests, with 0 failures (0 unexpected)\n').encode())
        code, lines = self.collect()
        self.assertEqual(code, 0)
        self.assertIn('xctest: not-observed', lines)
        self.assertClosed(lines)

    def test_symlink_directory_leaf_and_fifo_are_refused(self):
        self.receipt()
        outside = self.root / 'outside-secret'
        outside.write_bytes(b'SYNTHETIC_DO_NOT_READ')
        (self.capture / 'stderr.log').unlink()
        (self.capture / 'stderr.log').symlink_to(outside)
        self.assertUnavailable('unsafe-evidence')
        (self.capture / 'stderr.log').unlink()
        os.mkfifo(self.capture / 'stderr.log')
        self.assertUnavailable('unsafe-evidence')
        (self.capture / 'stderr.log').unlink()
        self.receipt()
        moved = self.root / 'moved-capture'
        self.capture.rename(moved)
        self.capture.symlink_to(moved, target_is_directory=True)
        self.assertUnavailable('unsafe-evidence')
        self.assertEqual(outside.read_bytes(), b'SYNTHETIC_DO_NOT_READ')

    def test_unsafe_roster_and_locations_never_become_public_output(self):
        self.receipt(stderr=b'Sources/PadCore/Observed.swift:12:3: error: synthetic\n')
        target = self.root / self.public[0]
        target.unlink()
        target.symlink_to(self.root / self.public[1])
        self.assertUnavailable('invalid-roster')
        code, lines = diagnostic.collect(self.root, roster=lambda root: ('../SECRET.swift',))
        self.assertEqual(code, 2)
        self.assertEqual(lines, ['ci-core diagnostics: unavailable', 'reason: invalid-roster'])

    def test_fixed_git_roster_excludes_untracked_and_cli_does_not_echo_arguments(self):
        for command in (['/usr/bin/git', 'init', '-q', str(self.root)],
            ['/usr/bin/git', '-C', str(self.root), 'add', '--', *self.public]):
            subprocess.run(command, check=True, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, timeout=5)
        (self.root / 'Tests/untracked-secret.swift').write_text('// synthetic\n')
        self.assertEqual(diagnostic.tracked_public_roster(self.root), self.public)
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = diagnostic.main(['--SECRET-ARG=/Users/synthetic'])
        self.assertEqual(code, 2)
        self.assertEqual(output.getvalue(), 'ci-core diagnostics: usage\n')


if __name__ == '__main__':
    unittest.main()
