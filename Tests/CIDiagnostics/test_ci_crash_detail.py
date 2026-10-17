"""Generated synthetic closed Swift crash observations; no actual crash or child.

Old100 Tests, producer and workflow remain whole. A missing callable is an
ordinary assertion before deep controls; no raw local self-fault JSON is copied.
"""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

MODULE = Path(__file__).resolve().parents[2] / 'scripts/ci_owned_failure_diagnostics.py'
spec = importlib.util.spec_from_file_location('ci_crash_detail_contract', MODULE)
d = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = d
spec.loader.exec_module(d)

REASONS = ('missing-evidence', 'unsafe-evidence', 'oversized-evidence', 'invalid-status',
           'invalid-capture', 'invalid-log-encoding', 'incomplete-evidence', 'no-crash-report',
           'ambiguous-crash-report', 'invalid-crash-json', 'crash-cap-exceeded',
           'invalid-crash-record', 'invalid-crash-frame', 'invalid-crash-detail')
IMAGES = {'TheOnlyPadPackageTests': 1, 'xctest': 2, 'libswiftCore.dylib': 3,
          'Foundation': 4, 'libFoundation.dylib': 4, 'CoreFoundation': 5,
          'libswift_Concurrency.dylib': 6, 'dyld': 7, 'libsystem_c.dylib': 8,
          'libsystem_platform.dylib': 9, 'libsystem_kernel.dylib': 10, 'swift-frontend': 11}
SYMBOLS = {'main': 1, '_main': 1, 'start': 2, 'swift_release': 3, '_swift_release': 3,
           'swift_retain': 4, '_swift_retain': 4, 'swift_getObjectType': 5, '_swift_getObjectType': 5,
           'CFURLGetFileSystemRepresentation': 6, '_CFURLGetFileSystemRepresentation': 6,
           'swift_reportError': 7, '_swift_reportError': 7,
           'swift_runtime_on_report': 8, '_swift_runtime_on_report': 8}
SOURCES = {'FolderReplacementPreview.swift': 1, 'FolderReplacementPreviewTests.swift': 2,
           'URL.swift': 3, 'String.swift': 4, 'Array.swift': 5}
KINDS = {'programCounter': 1, 'returnAddress': 2, 'asyncResumePoint': 3,
         'omittedFrames': 4, 'truncated': 5}
FIELDS = set('command pid processGroup exitObserved registrationError groupSignalAttempted '
             'groupSignalError groupCleanup groupQuery waitCompleted returnCode waitError '
             'timedOut interruptedSignal truncated captureComplete failure exit captured seconds'.split())
SECRET = 'SYNTHETIC_PRIVATE_MARKER_7f21'
_UNSET_STATUS = object()


class DictSubclass(dict):
    pass


class ListSubclass(list):
    pass


class IntSubclass(int):
    pass


class StringSubclass(str):
    pass


def frame(**updates):
    value = dict(kind='programCounter', image='TheOnlyPadPackageTests', symbol='swift_release',
                 sourceLocation=dict(file='FolderReplacementPreview.swift', line=27))
    value.update(updates)
    return value


def report(frames=None, **updates):
    value = dict(kind='crashReport', threads=[dict(crashed=True, frames=[frame()] if frames is None else frames)])
    value.update(updates)
    return value


def encoded(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'))


def detail(frames=None):
    return dict(reports=1, frames=[dict(n=1, kind=1, image=1, symbol=3, source=1, line=27)]
                if frames is None else frames)


def rendered(value):
    return ['crash-v1: reports=1 frames=' + str(len(value['frames']))] + [
        'frame-v1: n={n} kind={kind} image={image} symbol={symbol} source={source} line={line}'.format(**item)
        for item in value['frames']]


class CoreCrashDetailTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='ci-crash-detail-synthetic-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.capture = self.root / '.local/ci-core'
        self.capture.mkdir(parents=True, mode=0o700)
        # These tests consume files/text only; any attempted child or signal is a fixture failure.
        self.process_guard = mock.patch.object(d.subprocess, 'Popen', side_effect=AssertionError('No child allowed'))
        self.process_guard.start();self.addCleanup(self.process_guard.stop)
        self.signal_guard = mock.patch.object(d.os, 'kill', side_effect=AssertionError('No process signal allowed'))
        self.signal_guard.start();self.addCleanup(self.signal_guard.stop)

    def api(self):
        for name in ('classify_crash_detail', 'render_crash_detail', 'collect_crash_detail', '_CrashProblem'):
            self.assertTrue(callable(getattr(d, name, None)), 'Missing proposed closed crash API ' + name)

    def status(self, stdout='', stderr='', cleanup='exitedLeaderOnly', **updates):
        raw = lambda value: value if type(value) is bytes else value.encode('utf-8', 'surrogatepass')
        counts = lambda value: dict(stored=len(raw(value)), received=len(raw(value)), discarded=0)
        pid = 314
        value = dict(command=['synthetic-core'], pid=pid, processGroup=pid, exitObserved=True,
                     registrationError=None, groupSignalAttempted=True, groupSignalError=1,
                     groupCleanup=cleanup, groupQuery=dict(processGroup=pid, errorNumber=None,
                         bufferBytes=1024, returnedBytes=4, members=[pid]),
                     waitCompleted=True, returnCode=-11, waitError=None, timedOut=False,
                     interruptedSignal=None, truncated=False, captureComplete=True, failure=None,
                     exit=139, captured=dict(stdout=counts(stdout), stderr=counts(stderr)), seconds=0.25)
        if cleanup == 'signaled':value.update(groupSignalError=None, groupQuery=None)
        if cleanup == 'absent':value.update(groupSignalError=3, groupQuery=None)
        if cleanup in ('notStarted', 'unconfirmed'):value.update(groupSignalError=None, groupQuery=None)
        value.update(updates)
        return value

    def write(self, status, stdout='', stderr=''):
        for name, value in [('stdout.log', stdout), ('stderr.log', stderr)]:
            raw = value if type(value) is bytes else value.encode('utf-8', 'surrogatepass')
            (self.capture / name).write_bytes(raw)
        (self.capture / 'status.json').write_text(json.dumps(status), encoding='utf-8')

    def observed(self, stdout, stderr='', expected=None, status=None, collected=True):
        self.api();expected = detail() if expected is None else expected
        status = self.status(stdout, stderr) if status is None else status
        actual = d.classify_crash_detail(status, stdout, stderr)
        self.assertEqual(type(actual), dict);self.assertEqual(actual, expected)
        self.assertIs(type(actual['reports']), int);self.assertIs(type(actual['frames']), list)
        for item in actual['frames']:
            self.assertIs(type(item), dict)
            self.assertTrue(all(type(value) is int for value in item.values()))
        lines = d.render_crash_detail(actual)
        self.assertIs(type(lines), list);self.assertTrue(all(type(line) is str for line in lines))
        self.assertEqual(lines, rendered(expected))
        if collected:
            self.write(status, stdout, stderr)
            collected_value = d.collect_crash_detail(self.root)
            self.assertIs(type(collected_value), tuple);self.assertIs(type(collected_value[0]), int)
            self.assertEqual(collected_value, (0, rendered(expected)))
        text = '\n'.join(rendered(expected)) + '\n'
        self.assertLessEqual(len(text.encode('ascii')), 4096)
        self.assertLessEqual(len(text.splitlines()), 33)
        return actual

    def problem(self, reason, stdout, stderr='', status=_UNSET_STATUS, collected=False):
        self.api();self.assertIn(reason, REASONS)
        status = self.status(stdout, stderr) if status is _UNSET_STATUS else status
        with self.assertRaises(d._CrashProblem) as raised:d.classify_crash_detail(status, stdout, stderr)
        self.assertEqual(type(raised.exception.reason), str);self.assertEqual(raised.exception.reason, reason)
        if collected:
            self.write(status, stdout, stderr);self.unavailable(reason)

    def unavailable(self, reason):
        self.assertEqual(d.collect_crash_detail(self.root),
                         (2, ['ci-core crash-detail: unavailable', 'reason: ' + reason]))

    def testMissingAPIProducesOrdinaryAssertionBeforeDeepControls(self):
        self.api()

    def testThreeExactCleanupBranchesAdmitTextIndependentlyOfParentExit(self):
        self.api();text = encoded(report())
        for cleanup in ('signaled', 'absent', 'exitedLeaderOnly'):
            for child, parent in [(-11, 139), (1, 1), (0, 0), (-127, 255), (255, 255)]:
                with self.subTest(cleanup=cleanup, returnCode=child):
                    self.observed(text, status=self.status(text, cleanup=cleanup, returnCode=child, exit=parent))
        self.assertEqual(set(self.status()), FIELDS)

    def testEPERMSingletonQueryRelationsAndOtherCleanupRelationsAreExact(self):
        self.api();text = encoded(report());base = self.status(text)
        queries = [None, {}, dict(base['groupQuery'], processGroup=315),
                   dict(base['groupQuery'], members=[]), dict(base['groupQuery'], members=[314, 314]),
                   dict(base['groupQuery'], members=[315]), dict(base['groupQuery'], members=[True]), dict(base['groupQuery'], members=[IntSubclass(314)]),
                   dict(base['groupQuery'], members=(314,)), dict(base['groupQuery'], members=ListSubclass([314])),
                   DictSubclass(base['groupQuery']), dict(base['groupQuery'], processGroup=True),
                   dict(base['groupQuery'], processGroup=314.0),
                   dict(base['groupQuery'], errorNumber=0), dict(base['groupQuery'], errorNumber=True),
                   dict(base['groupQuery'], bufferBytes=1023), dict(base['groupQuery'], bufferBytes=True),
                   dict(base['groupQuery'], bufferBytes=1024.0),
                   dict(base['groupQuery'], returnedBytes=8), dict(base['groupQuery'], returnedBytes=4.0),
                   dict(base['groupQuery'], extra=SECRET)]
        for query in queries:
            with self.subTest(query=query):self.problem('invalid-status', text, status=dict(base, groupQuery=query))
        for cleanup, errno, query in [('signaled', 1, None), ('signaled', None, {}),
                                      ('absent', None, None), ('absent', 1, None), ('absent', 3, {}),
                                      ('exitedLeaderOnly', 3, base['groupQuery']), ('exitedLeaderOnly', 1, None)]:
            with self.subTest(cleanup=cleanup, errno=errno):
                self.problem('invalid-status', text, status=dict(base, groupCleanup=cleanup,
                                                               groupSignalError=errno, groupQuery=query))

    def testStatusExactRootRequiredFieldsNoUnknownKeysOrSubclass(self):
        self.api();text = encoded(report());base = self.status(text)
        for key in FIELDS:
            bad = dict(base);del bad[key]
            with self.subTest(missing=key):self.problem('invalid-status', text, status=bad)
        for bad in [None, [], DictSubclass(base), dict(base, private=SECRET)]:
            with self.subTest(type=type(bad).__name__):self.problem('invalid-status', text, status=bad)

    def testStatusPIDFlagsNumbersStringsMappingAndExactScalarTypes(self):
        self.api();text = encoded(report());base = self.status(text)
        cases = {'pid': [None, 0, -1, True, 2**31, IntSubclass(314)],
                 'processGroup': [None, 315, True, 0],
                 'seconds': [True, IntSubclass(1), -1, float('nan'), float('inf'), '0.1'],
                 'returnCode': [-128, 256, True, None, -255], 'exit': [-1, 256, True, None, 1],
                 'registrationError': [True, -1, 65536], 'groupSignalError': [True, -1, 65536],
                 'waitError': [True, 1, 'x'*129, '\ud800'], 'failure': [True, {}, 'x'*129, '\ud800'],
                 'interruptedSignal': [0, True, 256, '11'], 'groupCleanup': ['foreign', None, 1],
                 'groupQuery': [False, [], StringSubclass('query')]}
        for key in ('exitObserved', 'groupSignalAttempted', 'waitCompleted', 'captureComplete', 'timedOut', 'truncated'):
            cases[key] = [0, 1, None, 'false']
        for key, values in cases.items():
            for value in values:
                with self.subTest(key=key, type=type(value).__name__):
                    self.problem('invalid-status', text, status=dict(base, **{key: value}))
        boundary = self.status(text, pid=2**31-1, processGroup=2**31-1, cleanup='signaled')
        self.observed(text, status=boundary, collected=False)

    def testWellTypedIncompleteStatesRefuseBeforeCrashGrammar(self):
        self.api();text = '{malformed crashReport';base = self.status(text)
        changes = [dict(exitObserved=False), dict(groupSignalAttempted=False), dict(waitCompleted=False),
                   dict(captureComplete=False), dict(timedOut=True), dict(truncated=True),
                   dict(registrationError=0), dict(waitError=SECRET), dict(failure=SECRET),
                   dict(interruptedSignal=11), dict(groupCleanup='notStarted', groupQuery=None, groupSignalError=None),
                   dict(groupCleanup='unconfirmed', groupQuery=None, groupSignalError=None)]
        for update in changes:
            with self.subTest(update=update):
                self.problem('incomplete-evidence', text, status=dict(base, **update), collected=True)

    def testErrorTypeC1AbsentNoneAndExactStringParityWithoutChangingOldReader(self):
        self.api();text = encoded(report());base = self.status(text)
        self.assertNotIn('errorType', base);self.observed(text, status=base)
        self.observed(text, status=dict(base, errorNumber=None))
        self.problem('invalid-status', text, status=dict(base, errorType=None), collected=True)
        for value in ['', 'SyntheticFailure', 'x'*128]:
            with self.subTest(length=len(value)):
                self.problem('incomplete-evidence', text, status=dict(base, errorType=value), collected=True)
        for value in [True, 1, 'x'*129, StringSubclass('SyntheticFailure')]:
            with self.subTest(type=type(value).__name__):
                self.problem('invalid-status', text, status=dict(base, errorType=value))
        for value in [0, 65535]:self.problem('incomplete-evidence', text, status=dict(base, errorNumber=value))
        for value in [True, IntSubclass(1), -1, 65536]:self.problem('invalid-status', text, status=dict(base, errorNumber=value))

    def testCommandBoundsNULUTF8AndExactContainerTypes(self):
        self.api();text = encoded(report());base = self.status(text)
        for value in [[], (), ListSubclass(['x']), [StringSubclass('x')], [1], ['x\0y'], ['\ud800'],
                      ['x']*257, ['x'*65537]]:
            with self.subTest(type=type(value).__name__):self.problem('invalid-status', text, status=dict(base, command=value))
        for value in [['x']*256, ['x'*65536]]:
            self.observed(text, status=dict(base, command=value), collected=False)

    def testCaptureExactCountsByteRelationsAndDiscardCompletion(self):
        self.api();text = encoded(report());base = self.status(text)
        for value in [None, [], DictSubclass(base['captured']), {'stdout': base['captured']['stdout']},
                      dict(base['captured'], extra={})]:
            self.problem('invalid-capture', text, status=dict(base, captured=value))
        counts = base['captured']['stdout']
        for value in [None, [], dict(counts, extra=0), {'stored': len(text)},
                      dict(counts, stored=True), dict(counts, stored=-1), dict(counts, stored=1048577),
                      dict(counts, received=16777217), dict(counts, received=-1),
                      dict(counts, discarded=True), dict(counts, discarded=-1), dict(counts, discarded=16777217),
                      DictSubclass(counts), dict(counts, stored=IntSubclass(counts['stored'])),
                      dict(counts, received=len(text)+1), dict(counts, stored=0)]:
            self.problem('invalid-capture', text, status=dict(base, captured=dict(base['captured'], stdout=value)))
        discarded = dict(counts, received=counts['stored']+1, discarded=1)
        self.problem('incomplete-evidence', text,
                     status=dict(base, captured=dict(base['captured'], stdout=discarded)), collected=True)

    def testStreamExactTypesEncodingAndStandalonePrecedence(self):
        self.api();valid = encoded(report());base = self.status(valid)
        for value in [b'bytes', None, StringSubclass(valid), 1]:
            with self.subTest(type=type(value).__name__):self.problem('invalid-capture', value, status=base)
        broken = '\ud800';status = self.status(broken, timedOut=True)
        self.problem('invalid-log-encoding', broken, status=status, collected=True)
        bad = self.status(valid, pid=True, captured={})
        self.problem('invalid-status', valid, status=bad)
        bad = self.status(valid, timedOut=True, captured={})
        self.problem('invalid-capture', valid, status=bad)
        self.problem('incomplete-evidence', '{', status=self.status('{', timedOut=True))

    def testInheritedReaderStructuralPrecedenceRemainsExplicit(self):
        self.api();text = encoded(report());status = self.status(text, pid=315, captured={})
        self.problem('invalid-status', text, status=status)  # standalone PID!=PGID first
        self.write(status, text);self.unavailable('invalid-capture')  # unchanged _status precedes classifier
        self.write(self.status(text, pid=True), text);(self.capture/'stderr.log').unlink()
        self.unavailable('missing-evidence')  # unchanged reader opens fixed three leaves before _status

    def testFiveKindsAndMissingOptionalIdentitiesHaveClosedExactRows(self):
        self.api();frames = [frame(kind=name) for name in list(KINDS)[:3]]
        frames += [dict(kind='omittedFrames', count=7), dict(kind='truncated')]
        expected = detail([dict(n=i+1, kind=i+1, image=1 if i<3 else 0,
                                symbol=3 if i<3 else 0, source=1 if i<3 else 0, line=27 if i<3 else 0)
                           for i in range(5)])
        self.observed(encoded(report(frames)), expected=expected)
        for name, kind in list(KINDS.items())[:3]:
            self.observed(encoded(report([dict(kind=name)])),
                          expected=detail([dict(n=1, kind=kind, image=0, symbol=0, source=0, line=0)]))

    def testEveryExactImageSymbolAndSourceLegendIncludingAliases(self):
        self.api()
        for name, number in IMAGES.items():
            wanted = detail();wanted['frames'][0]['image'] = number
            self.observed(encoded(report([frame(image='/synthetic/images/'+name)])), expected=wanted)
        for name, number in SYMBOLS.items():
            wanted = detail();wanted['frames'][0]['symbol'] = number
            self.observed(encoded(report([frame(symbol=name)])), expected=wanted)
        for name, number in SOURCES.items():
            wanted = detail();wanted['frames'][0].update(source=number, line=10000000)
            self.observed(encoded(report([frame(sourceLocation=dict(file='/synthetic/source/'+name, line=10000000))])), expected=wanted)

    def testIdentityBasenameControlsUnknownsAndWholeSymbolNoDescriptionFallback(self):
        self.api()
        for image in ['theonlypadpackagetests', 'TheOnlyPadPackageTestsExtra', 'libswiftCore.dylib/',
                      'xctest\\evil', 'xctest\0', 'xctest\n', 'xctest\t',
                      'bad\n/xctest', 'bad\0/xctest', 'bad\\/xctest', '\x7f/xctest', 'x'*1025, '']:
            wanted = detail();wanted['frames'][0]['image'] = 0
            self.observed(encoded(report([frame(image=image)])), expected=wanted)
        for symbol in ['SWIFT_RELEASE', 'swift_releaseExtra', '/swift_release', ' swift_release',
                       'swift_release()', 'swift_release\0', SECRET]:
            wanted = detail();wanted['frames'][0]['symbol'] = 0
            self.observed(encoded(report([frame(symbol=symbol, description='swift_release')])), expected=wanted)
        for location in [dict(file='unknown.swift', line=1), dict(file='URL.swift'), dict(line=1), {},
                         dict(file='URL.swift', line=0), dict(file='URL.swift', line=-1),
                         dict(file='URL.swift', line=10000001), dict(file='URL.swift\\bad', line=1),
                         dict(file='bad\n/URL.swift', line=1), dict(file='bad\\/URL.swift', line=1),
                         dict(file='bad\0/URL.swift', line=1)]:
            wanted = detail();wanted['frames'][0].update(source=0, line=0)
            self.observed(encoded(report([frame(sourceLocation=location)])), expected=wanted)
        for image in ['/'*1018+'xctest', '/'*1019+'xctest', 'α'*508+'/xctest', 'α'*509+'/xctest']:
            wanted = detail();wanted['frames'][0]['image'] = 2 if len(image.encode())<=1024 else 0
            self.observed(encoded(report([frame(image=image)])), expected=wanted)

    def testReportThreadCrashStructureAndFrameArrayLimits(self):
        self.api()
        for value in [dict(kind='crashReport'), report(threads=None), report(threads={}), report(threads=[]),
                      report(threads=[dict(crashed=True)]),
                      report(threads=[None]), report(threads=[dict(crashed=False, frames=[frame()])]),
                      report(threads=[dict(crashed=1, frames=[frame()])]), report(threads=[dict(frames=[frame()])]),
                      report([]), report(threads=[dict(crashed=True, frames=None)]), report([frame()]*33)]:
            self.problem('invalid-crash-record', encoded(value))
        for threads in [[dict(crashed=True, frames=[frame()])]*2,
                        [dict(crashed=True, frames=[frame()]), dict(crashed=False, frames=[frame()])]]:
            self.problem('ambiguous-crash-report', encoded(report(threads=threads)))
        frames = [frame() for _ in range(32)]
        wanted = detail([dict(n=i+1, kind=1, image=1, symbol=3, source=1, line=27) for i in range(32)])
        self.observed(encoded(report(frames)), expected=wanted)

    def testFrameKindsTypesLocationTypesAndMandatoryOmittedCount(self):
        self.api()
        bad = [None, [], {}, dict(kind=None), dict(kind='unknown'), dict(kind=1), frame(image=None),
               frame(symbol=1), frame(sourceLocation=None), frame(sourceLocation='private'),
               frame(sourceLocation=dict(file=1, line=1)), frame(sourceLocation=dict(file='URL.swift', line=True)),
               frame(sourceLocation=dict(file='URL.swift', line='1')),
               frame(sourceLocation=dict(file='unknown.swift', line=True)),
               frame(sourceLocation=dict(line=None)), dict(kind='omittedFrames'),
               dict(kind='omittedFrames', count=0), dict(kind='omittedFrames', count=-1),
               dict(kind='omittedFrames', count=1.0), dict(kind='omittedFrames', count=True),
               dict(kind='omittedFrames', count=2147483648)]
        for value in bad:
            with self.subTest(type=type(value).__name__):self.problem('invalid-crash-frame', encoded(report([value])))
        self.observed(encoded(report([dict(kind='omittedFrames', count=1)])),
                      expected=detail([dict(n=1, kind=4, image=0, symbol=0, source=0, line=0)]))
        for name in ('omittedFrames', 'truncated'):
            value = dict(kind=name, count=2147483647 if name=='omittedFrames' else {'ignored': SECRET},
                         image=['ignored'], symbol={'private': SECRET}, sourceLocation='ignored', description=SECRET)
            self.observed(encoded(report([value])),
                          expected=detail([dict(n=1, kind=KINDS[name], image=0, symbol=0, source=0, line=0)]))

    def testIndependentLFCRLFEOFAndUnrelatedJSONCandidates(self):
        self.api();good = encoded(report())
        for text in [good, good+'\n', ' \t'+good+'\t \r\n', '{}\n[]\n'+good,
                     '[1,true,null,"unrelated"]\n'+good+'\n{"kind":"other"}',
                     'unstructured secret noise\n'+good, 'prefix {unrelated fragment}\n'+good]:
            self.observed(text)
        self.observed('', good)
        self.observed(good.replace('crashReport', 'crash\\u0052eport'))
        self.observed(encoded([report()])+'\n'+good)  # Nested object is not a recognized root report.
        for text in ['', '{}\n[]', '"crashReport"', encoded(dict(kind=['crashReport'])),
                     encoded(dict(kind='CrashReport'))]:
            self.problem('no-crash-report', text, collected=True)
        self.problem('ambiguous-crash-report', good, good, collected=True)
        self.problem('ambiguous-crash-report', good+'\n'+good, collected=True)

    def testMalformedFirstAndMalformedAfterGoodNeverBorrowOrPrintPrefix(self):
        self.api();good = encoded(report())
        for bad in ['{', '[', '{"kind":"crashReport"', 'prefix '+good, good+' trailing', good+good,
                    '{\r"kind":"crashReport"}', 'crashReport incomplete', '"crashReport" trailing',
                    '\x1b[0m'+good, '\v'+good, good+'\r', good+'\r'+good, good+'\u2028'+good]:
            for variant, (stdout, stderr) in enumerate([(bad+'\n'+good, ''), (good+'\n'+bad, ''), (bad, good), (good, bad)]):
                reason = 'ambiguous-crash-report' if bad == good+'\r' and variant == 0 else 'invalid-crash-json'
                with self.subTest(length=len(bad), variant=variant):
                    self.problem(reason, stdout, stderr, collected=True)
        cut = len(good)//2
        self.problem('invalid-crash-json', good[:cut], good[cut:], collected=True)

    def testDuplicateDecodedKeysAtEveryIgnoredDepthFailClosed(self):
        self.api();good = encoded(report())
        candidates = ['{"a":1,"a":2}', '{"a":1,"\\u0061":2}',
                      good[:-1]+',"registers":{"x":1,"x":2}}',
                      good[:-1]+',"ignored":{"deep":{"r":1,"r":2}}}',
                      good.replace('"line":27', '"line":27,"line":28'),
                      good.replace('"kind":"crashReport"', '"kind":"crashReport","kind":"other"')]
        for value in candidates:
            self.problem('invalid-crash-json', value+'\n'+good, collected=True)

    def testNonstandardConstantsNonfiniteAndBadNumericGrammarRefuse(self):
        self.api();good = encoded(report())
        for token in ['NaN', 'Infinity', '-Infinity', '1e999', '00', '01', '+1']:
            self.problem('invalid-crash-json', '[%s]\n%s' % (token, good), collected=True)

    def testCandidateCountAndUTF8LineCapExactBoundaries(self):
        self.api();good = encoded(report())
        self.observed('{}\n'*31+good)
        self.problem('crash-cap-exceeded', '{}\n'*32+good, collected=True)
        self.observed('{}\n'*15+good, '{}\n'*16)
        self.problem('crash-cap-exceeded', '{}\n'*16+good, '{}\n'*16)
        exact = good+' '*(65536-len(good.encode()))
        self.assertEqual(len(exact.encode()), 65536);self.observed(exact);self.observed(exact+'\r\n')
        self.problem('crash-cap-exceeded', exact+' ', collected=True)
        self.problem('invalid-crash-json', '{bad\n'+'{}\n'*32+good)  # first malformed wins before later cap

    def testJSONDepthCountsRootOutsideEscapedStrings(self):
        self.api();good = encoded(report())
        for depth, reason in [(64, None), (65, 'crash-cap-exceeded')]:
            text = '['*depth+'0'+']'*depth+'\n'+good
            if reason:self.problem(reason, text, collected=True)
            else:self.observed(text)
        text = encoded({'quoted': '[{\\"'*1000})+'\n'+good
        self.observed(text)

    def testJSONNodeBudgetIncludesEveryPrimitiveContainerAndDictionaryKey(self):
        self.api();good = encoded(report())
        self.observed(encoded([0]*8191)+'\n'+good)  # root+8191 primitives =8192
        self.problem('crash-cap-exceeded', encoded([0]*8192)+'\n'+good, collected=True)
        #4096 dict entries require1+4096 key nodes+4096 value nodes, not4097.
        self.problem('crash-cap-exceeded', encoded({str(i): 0 for i in range(4096)})+'\n'+good, collected=True)
        self.observed(encoded({str(i): 0 for i in range(4095)})+'\n'+good)

    def testDecodedStringCharacterAndUTF8CapsApplyToIgnoredValuesAndKeys(self):
        self.api();good = encoded(report())
        for text in [encoded({'ignored': 'x'*8192}), encoded({'ignored': 'α'*4096}),
                     encoded({'x'*8192: 0})]:self.observed(text+'\n'+good)
        for text in [encoded({'ignored': 'x'*8193}), encoded({'ignored': 'α'*4097}),
                     encoded({'x'*8193: 0}), good[:-1]+',"registers":'+encoded('x'*8193)+'}']:
            self.problem('crash-cap-exceeded', text+'\n'+good, collected=True)

    def testBoundedIntegerMagnitudeAndFloatTokenBeforeDiscard(self):
        self.api();good = encoded(report());maximum = 9223372036854775807
        for number in [maximum, -maximum]:self.observed('[%d]\n%s' % (number, good))
        for number in [maximum+1, -maximum-1]:self.problem('crash-cap-exceeded', '[%d]\n%s' % (number, good))
        exact = '0.'+'0'*61+'1';self.assertEqual(len(exact), 64)
        self.observed('['+exact+']\n'+good)
        self.observed('[1e100,-1e100]\n'+good)  # Finite floats have no integer-magnitude cap.
        self.problem('crash-cap-exceeded', '['+exact+'0]\n'+good, collected=True)

    def testEachStreamMiBLimitUsesUTF8AndOversizeBeforeCandidateGrammar(self):
        self.api();good = encoded(report());noise = 'x\n'
        stdout = good+'\n'+noise*((1048576-len(good)-1)//2)
        stdout += 'x'*(1048576-len(stdout));self.assertEqual(len(stdout.encode()), 1048576)
        stderr = noise*524288;self.observed(stdout, stderr)
        # Inherited descriptor reader rejects an oversized leaf before status-count validation.
        self.write(self.status(stdout+'x', stderr), stdout+'x', stderr);self.unavailable('oversized-evidence')

    def testSensitiveIgnoredFieldsAndFailureExceptionsNeverBecomePublicOutput(self):
        self.api();home = '/'+'Users/SYNTHETIC/'
        payload = report([frame(description=SECRET, address='0xBADF00D',
            sourceLocation=dict(file=home+'unknown.swift', line=9, column=SECRET),
            extra=dict(registers=[SECRET], memory=home+'recovery', error='::error::'+SECRET))],
            registers=dict(pc=SECRET), memory=[SECRET], description=SECRET, timestamp=SECRET)
        expected = detail();expected['frames'][0].update(source=0, line=0)
        value = self.observed(encoded(payload), expected=expected,
                              status=self.status(encoded(payload), command=[home+SECRET]))
        output = '\n'.join(d.render_crash_detail(value))
        for token in [SECRET, home, '0xBADF00D', '::error::', 'recovery', 'description', 'registers']:
            self.assertNotIn(token, output)
        self.write(self.status('{'+SECRET), '{'+SECRET)
        self.unavailable('invalid-crash-json')
        with mock.patch.object(d, 'render_crash_detail', side_effect=ValueError(SECRET)):
            self.write(self.status(encoded(report())), encoded(report()));self.unavailable('invalid-crash-detail')

    def testRendererMaximumClosedCanonicalASCIIAndNoPartialOutput(self):
        self.api();frames = [dict(n=i+1, kind=3, image=11, symbol=8, source=5, line=10000000) for i in range(32)]
        value = detail(frames);self.assertEqual(d.render_crash_detail(value), rendered(value))
        text = '\n'.join(d.render_crash_detail(value))+'\n'
        self.assertEqual(len(text.splitlines()), 33);self.assertLessEqual(len(text.encode('ascii')), 4096)
        self.assertEqual([line.split(' n=')[1].split(' ')[0] for line in text.splitlines()[1:]],
                         [str(i) for i in range(1, 33)])
        output = io.StringIO()
        with contextlib.redirect_stdout(output):d.render_crash_detail(value)
        self.assertEqual(output.getvalue(), '')

    def testRendererRejectsExactRootShapeAndTypesWithOneFixedError(self):
        self.api();base = detail()
        for value in [None, [], DictSubclass(base), dict(base, private=SECRET), {'frames': base['frames']},
                      dict(base, reports=True), dict(base, reports=0), dict(base, reports=2),
                      dict(base, reports=IntSubclass(1)), dict(base, frames=()), dict(base, frames=[]),
                      dict(base, frames=ListSubclass(base['frames'])), dict(base, frames=base['frames']*33)]:
            with self.subTest(type=type(value).__name__), self.assertRaises(ValueError) as raised:
                d.render_crash_detail(value)
            self.assertEqual(str(raised.exception), 'invalid crash detail')

    def testRendererRejectsFrameKeysTypesOrderRangesAndSourceLineRelations(self):
        self.api();base = detail()['frames'][0]
        frames = [None, DictSubclass(base), dict(base, private=SECRET), {k:v for k,v in base.items() if k!='n'},
                  dict(base, n=0), dict(base, n=2), dict(base, n=True), dict(base, kind=0), dict(base, kind=6),
                  dict(base, image=-1), dict(base, image=12), dict(base, symbol=9), dict(base, source=6),
                  dict(base, line=-1), dict(base, line=10000001), dict(base, source=0, line=1),
                  dict(base, source=1, line=0), dict(base, kind=4), dict(base, kind=5),
                  dict(base, image=IntSubclass(1)), dict(base, line='27')]
        for value in frames:
            with self.subTest(value=value), self.assertRaises(ValueError) as raised:
                d.render_crash_detail(detail([value]))
            self.assertEqual(str(raised.exception), 'invalid crash detail')
        for name in ('kind', 'image', 'symbol', 'source', 'line'):
            with self.subTest(name=name), self.assertRaises(ValueError):
                d.render_crash_detail(detail([dict(base, **{name: True})]))
        with self.assertRaises(ValueError):d.render_crash_detail(detail([base, dict(base, n=1)]))
        for kind in [4, 5]:
            value = detail([dict(n=1, kind=kind, image=0, symbol=0, source=0, line=0)])
            self.assertEqual(d.render_crash_detail(value), rendered(value))

    def testCollectorFixedFilesMissingMalformedUnsafeAndOversized(self):
        self.api();self.unavailable('missing-evidence');text = encoded(report())
        for leaf in ['status.json', 'stdout.log', 'stderr.log']:
            self.write(self.status(text), text);path = self.capture/leaf;outside = self.root/'outside'
            outside.write_bytes(path.read_bytes());path.unlink();path.symlink_to(outside)
            self.unavailable('unsafe-evidence');path.unlink()
        self.write(self.status(text), text);path = self.capture/'stderr.log';path.unlink();os.mkfifo(path, 0o600)
        self.unavailable('unsafe-evidence');path.unlink()
        self.write(self.status(text), text);(self.capture/'status.json').write_bytes(b'x'*65537)
        self.unavailable('oversized-evidence')
        self.write(self.status(text), text);(self.capture/'status.json').write_bytes(b'{')
        self.unavailable('invalid-status')
        self.write(self.status(text), text)
        with mock.patch.object(d, '_owner', return_value=False):self.unavailable('unsafe-evidence')
        local = self.root/'.local';real = self.root/'retained-local';local.rename(real);local.symlink_to(real, target_is_directory=True)
        self.unavailable('unsafe-evidence')

    def testCollectorActualReadThenSameByteLeafReplacementIsRefused(self):
        self.api();text = encoded(report());raw = text.encode();self.write(self.status(text), text)
        original_read = d.os.read;changed = False
        def replace_after_actual_read(fd, count):
            nonlocal changed
            block = original_read(fd, count)
            if block == raw and not changed:
                changed = True;new = self.capture/'new-leaf';new.write_bytes(raw)
                os.replace(new, self.capture/'stdout.log')
            return block
        with mock.patch.object(d.os, 'read', side_effect=replace_after_actual_read):self.unavailable('unsafe-evidence')
        self.assertTrue(changed, 'Actual descriptor read/replacement premise must be reached')

    def testCollectorClosedExceptionMappingDoesNotCatchBaseExceptions(self):
        self.api()
        for reason in REASONS[:6]:
            with mock.patch.object(d, '_read_inputs', side_effect=d._Problem(reason)):
                self.unavailable(reason)
        for problem in [d._Problem(SECRET), d._Problem('incomplete-evidence'), ValueError(SECRET), OSError(SECRET),
                        UnicodeError(SECRET), RecursionError(SECRET), TypeError(SECRET)]:
            with mock.patch.object(d, '_read_inputs', side_effect=problem):self.unavailable('invalid-crash-detail')
        for exception in [KeyboardInterrupt(), SystemExit(17)]:
            with mock.patch.object(d, '_read_inputs', side_effect=exception), self.assertRaises(type(exception)):
                d.collect_crash_detail(self.root)

    def testCrashCLIPrintsOneClosedReportAndRejectsMixedArgumentsWithoutEcho(self):
        self.api();text = encoded(report());self.write(self.status(text), text)
        with mock.patch.object(d, '__file__', str(self.root/'scripts/ci_owned_failure_diagnostics.py')), \
             mock.patch.object(d, 'tracked_public_roster', side_effect=AssertionError('No Git')), \
             mock.patch.object(d, '_source_text_candidate', side_effect=AssertionError('No source scan')):
            output = io.StringIO()
            with contextlib.redirect_stdout(output):code = d.main(['--crash-detail'])
            self.assertEqual((code, output.getvalue()), (0, '\n'.join(rendered(detail()))+'\n'))
            self.write(self.status('{'), '{');output = io.StringIO()
            with contextlib.redirect_stdout(output):code = d.main(['--crash-detail'])
            self.assertEqual((code, output.getvalue()), (2, 'ci-core crash-detail: unavailable\nreason: invalid-crash-json\n'))
            for args in [['--crash-detail', '--summary-only'], ['--crash-detail', '--error-detail'],
                         ['--crash-detail='+SECRET], ['--crash-detail', SECRET], ['--root', SECRET]]:
                output = io.StringIO()
                with contextlib.redirect_stdout(output):code = d.main(args)
                self.assertEqual((code, output.getvalue()), (2, 'ci-core diagnostics: usage\n'))

    def testLegacyModesAndAllEvidenceBytesRemainUntouched(self):
        self.api();text = encoded(report());self.write(self.status(text), text)
        before = {p.name: (p.read_bytes(), p.stat().st_mode) for p in self.capture.iterdir()}
        with mock.patch.object(d, '__file__', str(self.root/'scripts/ci_owned_failure_diagnostics.py')):
            for args in [[], ['--summary-only']]:
                with mock.patch.object(d, 'collect', return_value=(2, ['ci-core diagnostics: unavailable', 'reason: missing-evidence'])) as old:
                    output = io.StringIO()
                    with contextlib.redirect_stdout(output):code = d.main(args)
                    self.assertEqual((code, output.getvalue()), (2, 'ci-core diagnostics: unavailable\nreason: missing-evidence\n'))
                    if args:self.assertTrue(callable(old.call_args.kwargs['roster']))
                    else:old.assert_called_once_with(self.root)
            with mock.patch.object(d, 'collect_error_detail', return_value=(0, ['legacy exact error detail'])) as old:
                output = io.StringIO()
                with contextlib.redirect_stdout(output):code = d.main(['--error-detail'])
                self.assertEqual((code, output.getvalue()), (0, 'legacy exact error detail\n'))
                old.assert_called_once_with(self.root)
        self.assertEqual({p.name: (p.read_bytes(), p.stat().st_mode) for p in self.capture.iterdir()}, before)


if __name__ == '__main__':
    unittest.main()
