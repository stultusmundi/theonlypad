"""Synthetic additive contracts for the narrow SwiftPM progress exception.

No raw CI/local crash capture is copied. These tests were first reviewed and
run against the unchanged production baseline before the parser correction.
"""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

MODULE = Path(__file__).resolve().parents[2] / 'scripts/ci_owned_failure_diagnostics.py'
spec = importlib.util.spec_from_file_location('ci_crash_progress_contract', MODULE)
d = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = d
spec.loader.exec_module(d)


def encoded(value):
    return json.dumps(value, separators=(',', ':'))


def report():
    return dict(kind='crashReport', threads=[dict(crashed=True, frames=[dict(kind='programCounter')])])


def expected_detail():
    return dict(reports=1, frames=[dict(n=1, kind=1, image=0, symbol=0, source=0, line=0)])


def rendered(value):
    return ['crash-v1: reports=1 frames=1',
            'frame-v1: n=1 kind=1 image=0 symbol=0 source=0 line=0']


class CrashProgressFilterTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='ci-crash-progress-synthetic-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.capture = self.root / '.local/ci-core'
        self.capture.mkdir(parents=True, mode=0o700)
        self.popen_guard = mock.patch.object(d.subprocess, 'Popen',
                                             side_effect=AssertionError('No child allowed'))
        self.popen_guard.start()
        self.addCleanup(self.popen_guard.stop)
        self.signal_guard = mock.patch.object(d.os, 'kill',
                                              side_effect=AssertionError('No process signal allowed'))
        self.signal_guard.start()
        self.addCleanup(self.signal_guard.stop)

    def status(self, stdout='', stderr=''):
        raw = lambda value: value.encode('utf-8')
        counts = lambda value: dict(stored=len(raw(value)), received=len(raw(value)), discarded=0)
        pid = 314
        return dict(command=['synthetic-core'], pid=pid, processGroup=pid, exitObserved=True,
                    registrationError=None, groupSignalAttempted=True, groupSignalError=1,
                    groupCleanup='exitedLeaderOnly',
                    groupQuery=dict(processGroup=pid, errorNumber=None, bufferBytes=1024,
                                    returnedBytes=4, members=[pid]),
                    waitCompleted=True, returnCode=-11, waitError=None, timedOut=False,
                    interruptedSignal=None, truncated=False, captureComplete=True, failure=None,
                    exit=139, captured=dict(stdout=counts(stdout), stderr=counts(stderr)), seconds=0.25)

    def write(self, status, stdout='', stderr=''):
        (self.capture / 'stdout.log').write_bytes(stdout.encode('utf-8'))
        (self.capture / 'stderr.log').write_bytes(stderr.encode('utf-8'))
        (self.capture / 'status.json').write_text(json.dumps(status), encoding='utf-8')

    def problem(self, reason, stdout, stderr=''):
        status = self.status(stdout, stderr)
        with self.assertRaises(d._CrashProblem) as raised:
            d.classify_crash_detail(status, stdout, stderr)
        self.assertEqual(raised.exception.reason, reason)
        self.write(status, stdout, stderr)
        self.assertEqual(d.collect_crash_detail(self.root),
                         (2, ['ci-core crash-detail: unavailable', 'reason: ' + reason]))

    def testBoundedSwiftPMProgressBeforeReportDoesNotHideReportOrEchoTaskText(self):
        progress = '[2/9] Write synthetic SwiftPM task output'
        good = encoded(report())
        stdout = progress + '\n' + good + '\n'
        status = self.status(stdout)
        try:
            actual = d.classify_crash_detail(status, stdout, '')
        except d._CrashProblem as problem:
            self.fail('bounded synthetic SwiftPM progress was treated as crash JSON: ' + problem.reason)
        self.assertEqual(actual, expected_detail())
        self.write(status, stdout, '')
        code, lines = d.collect_crash_detail(self.root)
        self.assertEqual((code, lines), (0, rendered(expected_detail())))
        self.assertNotIn(progress, '\n'.join(lines))

    def testProgressOnlyStillReportsNoCrashReport(self):
        progress = '[1/3] Build synthetic target'
        self.problem('no-crash-report', progress + '\n')

    def testProgressExceptionIsExactBoundedASCIIGrammarWithoutLeadingWhitespace(self):
        good = encoded(report())
        accepted = '[1234567890/0000000001] Any printable synthetic task text'
        stdout = accepted + '\n' + good
        status = self.status(stdout)
        try:
            self.assertEqual(d.classify_crash_detail(status, stdout, ''), expected_detail())
        except d._CrashProblem as problem:
            self.fail('valid bounded synthetic progress syntax was refused: ' + problem.reason)
        for invalid in ('[1/2]', '[1/2] ', '[12345678901/2] task', '[1/12345678901] task',
                        ' [1/2] task', '\t[1/2] task', '[1/2] task\tmore', '[1/2] task\x1b', '[1/2] tâche'):
            with self.subTest(record=repr(invalid)):
                self.problem('invalid-crash-json', invalid + '\n' + good)

    def testValidBracketJSONIsStillParsedAsJSON(self):
        self.problem('no-crash-report', '[1,2]\n')

    def testCrashReportTokenCollisionIsNeverIgnoredAsProgress(self):
        good = encoded(report())
        progress_looking = '[1/2] task mentions crashReport'
        self.problem('invalid-crash-json', progress_looking + '\n' + good)

    def testProgressRecordByteCapIsInclusiveAndOverLimitRefuses(self):
        good = encoded(report())
        prefix = '[1/2] '
        exact = prefix + ('x' * (8192 - len(prefix.encode('ascii'))))
        self.assertEqual(len(exact.encode('ascii')), 8192)
        stdout = exact + '\n' + good
        status = self.status(stdout)
        try:
            self.assertEqual(d.classify_crash_detail(status, stdout, ''), expected_detail())
        except d._CrashProblem as problem:
            self.fail('exact-limit synthetic progress record was refused: ' + problem.reason)
        oversized = prefix + ('x' * (8193 - len(prefix.encode('ascii'))))
        self.assertEqual(len(oversized.encode('ascii')), 8193)
        self.problem('crash-cap-exceeded', oversized + '\n' + good)

    def testMalformedCandidateBeforeAndAfterValidReportStillRefuses(self):
        good = encoded(report())
        progress = '[1/2] Write synthetic task'
        cases = (('before-valid-report', progress + '\n{malformed crashReport\n' + good),
                 ('after-valid-report', progress + '\n' + good + '\n[1/2] malformed crashReport'))
        for order, text in cases:
            with self.subTest(order=order):
                self.problem('invalid-crash-json', text)


if __name__ == '__main__':
    unittest.main()
