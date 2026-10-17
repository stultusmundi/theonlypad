"""Synthetic closed detail contract; existing33 diagnostic tests stay whole."""
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

MODULE = Path(__file__).resolve().parents[2]/'scripts/ci_owned_failure_diagnostics.py'
spec = importlib.util.spec_from_file_location('ci_error_detail_contract',MODULE)
d = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = d
spec.loader.exec_module(d)
FIELDS = {'kinds','isolation','ownedSignal','reportedSignalState','reportedSignal'}
SIGNAL = 'error: Exited with unexpected signal code '
ERROR = 'Sources/PadCore/A.swift:12:3: error: synthetic source failure'
WARNING = 'Sources/PadCore/A.swift:12:3: warning: '
FATAL = 'MainActor.swift:170: Fatal error: '


def want(**updates):
    result=dict(kinds=0,isolation=0,ownedSignal=0,reportedSignalState=0,reportedSignal=0)
    result.update(updates)
    return result


class CoreErrorDetailTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='ci-error-detail-synthetic-')
        self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name).resolve()
        self.capture=self.root/'.local/ci-core'
        self.capture.mkdir(parents=True,mode=0o700)

    def api(self):
        for name in ('classify_error_detail','render_error_detail','collect_error_detail'):
            self.assertTrue(callable(getattr(d,name,None)), 'Missing proposed closed detail API '+name)

    def receipt(self,stdout='',stderr='',**changes):
        stdout=stdout.encode('utf-8') if isinstance(stdout,str) else stdout
        stderr=stderr.encode('utf-8') if isinstance(stderr,str) else stderr
        counts=lambda data:dict(stored=len(data),received=len(data),discarded=0)
        value=dict(command=['synthetic-core'],pid=123,processGroup=123,exitObserved=True,
            registrationError=None,groupSignalAttempted=True,groupSignalError=1,
            groupCleanup='exitedLeaderOnly',groupQuery=None,waitCompleted=True,returnCode=1,
            waitError=None,timedOut=False,interruptedSignal=None,truncated=False,
            captureComplete=True,failure=None,exit=1,
            captured=dict(stdout=counts(stdout),stderr=counts(stderr)),seconds=1.0)
        value.update(changes)
        (self.capture/'stdout.log').write_bytes(stdout)
        (self.capture/'stderr.log').write_bytes(stderr)
        (self.capture/'status.json').write_text(json.dumps(value))
        return value

    def observed(self,stdout='',stderr='',expected=None,**changes):
        self.api()
        status=self.receipt(stdout,stderr,**changes)
        a=stdout.decode('utf-8') if isinstance(stdout,bytes) else stdout
        b=stderr.decode('utf-8') if isinstance(stderr,bytes) else stderr
        expected=want() if expected is None else expected
        detail=d.classify_error_detail(status,a,b)
        self.assertEqual(type(detail),dict)
        self.assertEqual(set(detail),FIELDS)
        self.assertEqual(detail,expected)
        self.assertTrue(all(type(x)is int for x in detail.values()))
        lines=['ci-core error-detail: observed',
            'detail-v1: kinds={kinds} isolation={isolation} ownedSignal={ownedSignal} '
            'reportedSignalState={reportedSignalState} reportedSignal={reportedSignal}'.format(**expected)]
        self.assertEqual(d.render_error_detail(detail),lines)
        self.assertEqual(d.collect_error_detail(self.root),(0,lines))
        text='\n'.join(lines)+'\n'
        self.assertLessEqual(len(text.encode('ascii')),256)
        self.assertEqual(len(text.splitlines()),2)
        return text

    def unavailable(self,reason):
        self.api()
        result=d.collect_error_detail(self.root)
        self.assertEqual(result,(2,['ci-core error-detail: unavailable','reason: '+reason]))
        self.assertLessEqual(len(('\n'.join(result[1])+'\n').encode('ascii')),256)

    def testAPIAdmissionIsAnOrdinaryGuardOnOriginalProducer(self):
        self.api()

    def testUnknownAndAllSixSingleRecordFamilies(self):
        self.api()
        for text,expected in [('',want()),('unknown core termination',want()),
            (ERROR,want(kinds=1)),('error: synthetic tool failure',want(kinds=2)),
            ("Test Case '-[ObservedTests testSynthetic]' failed (0.001 seconds).",want(kinds=4)),
            ("Test Case 'Module.ObservedTests.testSynthetic' failed (1 seconds).",want(kinds=4)),
            ('Fatal error: synthetic runtime failure',want(kinds=8)),
            (FATAL+'synthetic failure',want(kinds=8)),
            (SIGNAL+'6',want(kinds=16,reportedSignalState=1,reportedSignal=6)),
            ('error: fatalError',want(kinds=32))]:
            with self.subTest(expected=expected):self.observed(text,expected=expected)

    def testAllSixtyFourFamilyCombinationsAndRepeatedRecordsAreBounded(self):
        self.api()
        records=[ERROR,'error: synthetic driver failure',
            "Test Case '-[ObservedTests testSynthetic]' failed (0.1 seconds).",
            'Fatal error: synthetic runtime failure',SIGNAL+'6','error: fatalError']
        for mask in range(64):
            text='\n'.join(records[i] for i in range(6) if mask&(1<<i))
            expected=want(kinds=mask,reportedSignalState=1 if mask&16 else 0,
                          reportedSignal=6 if mask&16 else 0)
            with self.subTest(mask=mask):self.observed(text+'\n'+text,expected=expected)

    def testSeverityAndPayloadBoundariesDoNotInventCompilerOrExactFatalErrorFamily(self):
        self.api()
        unknown=[WARNING+'error: fake compiler failure',
            WARNING+'Tests/Fake.swift:2:3: error: actor-isolated fake',
            'Sources/A.swift:1:2: note: Tests/Fake.swift:2:3: error: actor-isolated fake',
            'Sources/A.swift:1:2: note: error: fake',
            'message: '+ERROR,'    '+ERROR,'"'+ERROR+'"',
            'Test.swift:0:2: error: bad line','Test.swift:01:2: error: bad line',
            'Test.swift:10000001:2: error: bad line','Test.swift:1:0: error: bad column',
            'Test.swift:1:10000001: error: bad column','error:not a recognized prefix',
            'Error: synthetic case variant','Fatal Error: wrong header',
            "Test Case '-[ObservedTests testSynthetic]' failed (0.1 seconds). trailing",
            "Test Case '-[ObservedTests notATest]' failed (0.1 seconds)."]
        for text in unknown:
            with self.subTest(length=len(text)):self.observed(text,expected=want())
        for text in ['error: fatalError trailing-private','error: fatalError ',
                     'error: "fatalError"','error: fatalerror']:
            with self.subTest(length=len(text)):self.observed(text,expected=want(kinds=2))
        self.observed('A.swift:10000000:10000000: error: synthetic',expected=want(kinds=1))
        self.observed('A.swift:1: error: synthetic',expected=want(kinds=1))
        self.observed('A.swift:1: error: payload Tests/Fake.swift:2:3: warning: fake',
                      expected=want(kinds=1))
        self.observed('A.swift:1: error: payload Tests/Fake.swift:2:3: note: fake',
                      expected=want(kinds=1))

    def testIsolationSeverityTokensHaveExactPayloadBoundaries(self):
        self.api()
        for phrase in ['main actor-isolated property','ACTOR-ISOLATED function','actor isolation mismatch']:
            self.observed('Sources/A.swift:1:2: error: '+phrase,expected=want(kinds=1,isolation=1))
            self.observed(WARNING+phrase,expected=want(isolation=2))
        for phrase in ['main actor','nonisolated','Sendable closure','actor-isolatedExtra',
                       'xactor-isolated','actor isolationist','αactor-isolated',
                       'actor isоlation','actor isolated']:
            self.observed('A.swift:1: error: '+phrase,expected=want(kinds=1))
        self.observed(WARNING+'main actor-isolated property; this is an error: in Swift 6 mode',
                      expected=want(isolation=2))
        self.observed('Sources/A.swift:1:2: note: actor isolation warning error:',expected=want())
        self.observed('error: actor-isolated text without source severity',expected=want(kinds=2))
        self.observed('A.swift:1: error: actor-isolated\n'+WARNING+'actor isolation',
                      expected=want(kinds=1,isolation=3))

    def testExecutorRuntimePhraseRequiresFatalHeaderAndSemicolonOrEOFPhraseBoundary(self):
        self.api()
        for suffix in ['', '; Expected same executor as MainActor.']:
            self.observed(FATAL+'Incorrect actor executor assumption'+suffix,
                          expected=want(kinds=8,isolation=4))
        for phrase in ['Incorrect actor executor assumptionFake',
                       'prefix Incorrect actor executor assumption',
                       '"Incorrect actor executor assumption"',
                       'Incorrect actor executor assumptioné',
                       'incorrect actor executor assumption']:
            self.observed(FATAL+phrase,expected=want(kinds=8))
        self.observed(WARNING+'Incorrect actor executor assumption',expected=want())
        self.observed('stack: MainActor.assumeIsolated\n_dispatch_assert_queue_fail',expected=want())
        self.observed('A.swift:1: error: actor isolation\n'+WARNING+'actor-isolated\n'+
                      FATAL+'Incorrect actor executor assumption',expected=want(kinds=9,isolation=7))

    def testOwnedAndReportedSignalsStayIndependentAndPositiveCodesNeverBecomeOwnedSignal(self):
        self.api()
        self.observed('unknown',returnCode=-6,exit=134,expected=want(ownedSignal=6))
        self.observed(SIGNAL+'4',returnCode=-6,exit=134,
                      expected=want(kinds=16,ownedSignal=6,reportedSignalState=1,reportedSignal=4))
        self.observed(SIGNAL+'6',expected=want(kinds=16,reportedSignalState=1,reportedSignal=6))
        self.observed('unknown',returnCode=134,exit=134,expected=want())
        self.observed(SIGNAL+'127',returnCode=-127,exit=255,
                      expected=want(kinds=16,ownedSignal=127,reportedSignalState=1,reportedSignal=127))

    def testSignalStateDuplicateConflictMalformedPriorityAndWholeRecordGrammar(self):
        self.api()
        self.observed(SIGNAL+'6\n'+SIGNAL+'6',SIGNAL+'6',
                      expected=want(kinds=16,reportedSignalState=1,reportedSignal=6))
        self.observed(SIGNAL+'6',SIGNAL+'4',expected=want(kinds=16,reportedSignalState=2))
        for number in ['', '0','00','06','-6','+6','128','9999999999999999999999999',
                       '6 trailing-private','6.','６','6 ']:
            with self.subTest(length=len(number)):
                self.observed(SIGNAL+number,expected=want(reportedSignalState=3))
                self.observed(SIGNAL+'6\n'+SIGNAL+'4',SIGNAL+number,
                              expected=want(kinds=16,reportedSignalState=3))
        self.observed(SIGNAL.rstrip(' '),expected=want(reportedSignalState=3))
        self.observed(WARNING+SIGNAL+'6',expected=want())
        self.observed('error: "Exited with unexpected signal code 6"',expected=want(kinds=2))

    def testStreamsNeverConcatenatePartialRecordsOrEstablishOrder(self):
        self.api()
        self.observed('error: Exited with unexpected ','signal code 6',expected=want(kinds=2))
        self.observed('Sources/A.swift:1: error',' actor-isolated',expected=want())
        a=ERROR+'\n'+SIGNAL+'4';b=FATAL+'Incorrect actor executor assumption\n'+SIGNAL+'6'
        expected=want(kinds=25,isolation=4,reportedSignalState=2)
        self.observed(a,b,expected=expected)
        self.observed(b,a,expected=expected)

    def testCRLFAndEOFAreRecordsAndUtf8ByteLimitIncludesTerminator(self):
        self.api()
        self.observed(ERROR+'\r\n',expected=want(kinds=1))
        self.observed(SIGNAL+'6',expected=want(kinds=16,reportedSignalState=1,reportedSignal=6))
        self.observed('unknown'+'x'*(8192-7))
        self.observed('x'*8191+'\n')
        self.observed('é'*4095+'x\n')
        for text in ['x'*8192+'\n','é'*4096+'\n','x'*8193]:
            self.receipt(text);self.unavailable('detail-scan-limit')

    def testForbiddenControlRecordsFailClosedWithoutAnsiStrippingOrNewRecordSynthesis(self):
        self.api()
        for control in ['\x00','\x01','\x08','\x0b','\x0c','\x1b','\x7f','\r']:
            self.receipt('prefix'+control+ERROR)
            self.unavailable('invalid-detail')
        self.observed('unknown\ttext\n',expected=want())
        self.receipt(ERROR+'\r');self.unavailable('invalid-detail')
        self.receipt(ERROR+'\r\r\n');self.unavailable('invalid-detail')

    def testIncompleteNaturalReceiptNeverPublishesPartialDetail(self):
        self.api()
        vectors=[dict(exitObserved=False),dict(waitCompleted=False),dict(captureComplete=False),
            dict(waitError='synthetic-wait'),dict(failure='synthetic-capture'),
            dict(registrationError=1),dict(interruptedSignal=2,exit=130),dict(timedOut=True,exit=124),
            dict(truncated=True),dict(groupCleanup='unconfirmed'),dict(groupCleanup='notStarted'),
            dict(returnCode=None),dict(returnCode=2,exit=1),dict(returnCode=-6,exit=1),
            dict(errorType='SyntheticError'),dict(errorNumber=1)]
        for change in vectors:
            with self.subTest(fields=sorted(change)):
                self.receipt(ERROR,**change);self.unavailable('incomplete-evidence')
        status=self.receipt(ERROR)
        status['captured']['stdout'].update(received=len(ERROR)+1,discarded=1)
        (self.capture/'status.json').write_text(json.dumps(status))
        self.unavailable('incomplete-evidence')
        for group in ['absent','signaled','exitedLeaderOnly']:
            self.observed(ERROR,groupCleanup=group,expected=want(kinds=1))
        self.observed(ERROR,returnCode=0,exit=0,errorNumber=None,expected=want(kinds=1))

    def testExistingReaderRejectsMissingMalformedInvalidCountsAndNonUtf8(self):
        self.api()
        self.unavailable('missing-evidence')
        self.receipt(b'\xff');self.unavailable('invalid-log-encoding')
        self.receipt(ERROR);path=self.capture/'status.json'
        path.write_text('{"exit":1,"exit":1}')
        self.unavailable('invalid-status')
        status=self.receipt(ERROR);status['captured']['stdout']['stored']+=1
        path.write_text(json.dumps(status));self.unavailable('invalid-capture')
        self.receipt(ERROR);path.write_bytes(b' '*65537);self.unavailable('oversized-evidence')
        self.receipt(ERROR,exit=True);self.unavailable('invalid-status')

    def testSymlinksFIFOsAndActualDescriptorMutationAreRefused(self):
        self.api()
        self.receipt(ERROR)
        leaf=self.capture/'stderr.log';leaf.unlink()
        outside=self.root/'outside-private';outside.write_bytes(b'SYNTHETIC_NEVER_OUTPUT')
        leaf.symlink_to(outside);self.unavailable('unsafe-evidence')
        leaf.unlink();os.mkfifo(leaf);self.unavailable('unsafe-evidence');leaf.unlink()
        self.receipt(ERROR)
        target=self.capture/'status.json';inode=target.stat().st_ino
        read=os.read;changed=False
        def change_after_actual_read(fd,count):
            nonlocal changed
            value=read(fd,count)
            if not changed and os.fstat(fd).st_ino==inode:
                changed=True
                with target.open('ab')as stream:stream.write(b' ')
            return value
        with mock.patch.object(d.os,'read',side_effect=change_after_actual_read):
            self.unavailable('unsafe-evidence')
        self.assertTrue(changed,'Real descriptor read/mutation boundary must be reached')
        self.assertEqual(outside.read_bytes(),b'SYNTHETIC_NEVER_OUTPUT')

    def testTwoAdmittedMiBStreamsRemainBoundedAndOneExtraByteRefuses(self):
        self.api()
        text=('unknown\n'*131072)  # exactly1MiB, short records; no native document fixture
        self.assertEqual(len(text),1048576)
        self.observed(text,text,expected=want())
        self.receipt(text+'x');self.unavailable('oversized-evidence')

    def testRendererRejectsArbitraryFieldsTypesMasksAndInconsistentSignalStates(self):
        self.api()
        for item in [dict(want(),kinds=True),dict(want(),kinds=-1),dict(want(),kinds=64),
            dict(want(),isolation=8),dict(want(),ownedSignal=128),
            dict(want(),reportedSignalState=4),dict(want(),reportedSignalState=1),
            dict(want(),reportedSignal=6),dict(want(),reportedSignalState=2,reportedSignal=6),
            dict(want(),reportedSignalState=3,reportedSignal=6),
            dict(want(),reportedSignalState=True),dict(want(),private='SYNTHETIC_PRIVATE'),
            {k:v for k,v in want().items()if k!='kinds'},None,[], 'SYNTHETIC_PRIVATE']:
            with self.subTest(type=type(item).__name__):
                with self.assertRaises(ValueError):d.render_error_detail(item)
        self.assertEqual(d.render_error_detail(want(kinds=63,isolation=7,ownedSignal=127,
            reportedSignalState=1,reportedSignal=127)),['ci-core error-detail: observed',
            'detail-v1: kinds=63 isolation=7 ownedSignal=127 reportedSignalState=1 reportedSignal=127'])

    def testPrivateTextCommandsStatusAndWorkflowAnnotationsNeverReachOutput(self):
        self.api()
        secret='SYNTHETIC_PRIVATE_Bearer_6e4a'
        synthetic_home = '/' + 'Users/' + 'private/'
        text='error: '+secret+' '+synthetic_home+'recovery ::error:: key=secret'
        status=self.receipt(text,command=[secret,synthetic_home+'document'],
                            groupQuery={'untrusted':secret},groupSignalError=1)
        expected=want(kinds=2)
        result=d.collect_error_detail(self.root)
        self.assertEqual(result,(0,d.render_error_detail(expected)))
        rendered='\n'.join(result[1])+'\n'
        for forbidden in [secret,'/Users/','recovery','::error::','untrusted','document','key=']:
            self.assertNotIn(forbidden,rendered)
        self.receipt(text,waitError=secret);self.unavailable('incomplete-evidence')

    def testDetailCLIUsesNoGitSourceCandidateOrChildAndNeverEchoesArguments(self):
        self.api()
        self.receipt(ERROR)
        with mock.patch.object(d,'__file__',str(self.root/'scripts/ci_owned_failure_diagnostics.py')), \
             mock.patch.object(d,'tracked_public_roster',side_effect=AssertionError('No Git')), \
             mock.patch.object(d,'_source_text_candidate',side_effect=AssertionError('No source scan')), \
             mock.patch.object(d.subprocess,'Popen',side_effect=AssertionError('No child')):
            output=io.StringIO()
            with contextlib.redirect_stdout(output):code=d.main(['--error-detail'])
            self.assertEqual(code,0)
            self.assertEqual(output.getvalue(),'ci-core error-detail: observed\n'
                'detail-v1: kinds=1 isolation=0 ownedSignal=0 reportedSignalState=0 reportedSignal=0\n')
            for args in [['--error-detail','--summary-only'],['--error-detail=/Users/SYNTHETIC_PRIVATE'],
                         ['--error-detail','/Users/SYNTHETIC_PRIVATE']]:
                output=io.StringIO()
                with contextlib.redirect_stdout(output):code=d.main(args)
                self.assertEqual((code,output.getvalue()),(2,'ci-core diagnostics: usage\n'))

    def testNewModeKeepsLegacyDefaultAndSummaryExactlyUnchangedAndLeavesEvidenceUntouched(self):
        self.api()
        self.receipt('error: synthetic driver failure\n')
        before={p.name:(p.read_bytes(),p.stat().st_mode)for p in self.capture.iterdir()}
        expected=['ci-core diagnostics: observed',
            'watchdog: exit=1 returnCode=1 timedOut=false truncated=false captureComplete=true waitCompleted=true',
            'captures: stdout=32 stderr=0','xctest: not-observed',
            'signals: compiler=1 test=0 crash=0 dependency=0 permission=0 resource=0','xctest-id: unknown']
        self.assertEqual(d.collect(self.root,roster=lambda root:()),(0,expected))
        with mock.patch.object(d,'__file__',str(self.root/'scripts/ci_owned_failure_diagnostics.py')):
            output=io.StringIO()
            with contextlib.redirect_stdout(output):code=d.main(['--summary-only'])
            self.assertEqual((code,output.getvalue()),(0,'\n'.join(expected)+'\n'))
        self.assertEqual(d.collect_error_detail(self.root),(0,d.render_error_detail(want(kinds=2))))
        self.assertEqual({p.name:(p.read_bytes(),p.stat().st_mode)for p in self.capture.iterdir()},before)


if __name__=='__main__':unittest.main()
