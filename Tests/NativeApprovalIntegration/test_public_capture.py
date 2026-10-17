"""Authored pure capture controls; no Swift/native children or file writes."""
import unittest
from public_capture import parse_result


CLASSES = [dict(**{'class': 'FirstTests'}, methods=['testOne', 'testTwo']),
           dict(**{'class': 'SecondTests'}, methods=['testThree'])]


def transcript(classes=CLASSES, failed=None, unexpected=0, reverse=False):
    failed = failed or {}
    rows = ["Test Suite 'Selected tests' started at fixed."]
    total = 0
    for item in reversed(classes) if reverse else classes:
        name, methods = item['class'], item['methods']
        count = sum(failed.get(method, 0) for method in methods)
        total += count
        rows.append("Test Suite '" + name + "' started at fixed.")
        for method in reversed(methods) if reverse else methods:
            identity = '-[NativeRoutingTests.' + name + ' ' + method + ']'
            rows.append("Test Case '" + identity + "' started.")
            if failed.get(method, 0):
                rows.append('fixture.swift:1: error: ' + identity + ' : XCTAssertEqual failed')
            rows.append("Test Case '" + identity + "' " + ('failed' if failed.get(method, 0) else 'passed') + ' (0.001 seconds).')
        rows += ["Test Suite '" + name + "' " + ('failed' if count else 'passed') + ' at fixed.',
                 '\t Executed ' + str(len(methods)) + ' tests, with ' + str(count) + ' failures (' + str(unexpected) + ' unexpected) in 0.001 seconds.']
    rows += ["Test Suite 'Selected tests' " + ('failed' if total else 'passed') + ' at fixed.',
             '\t Executed ' + str(sum(len(c['methods']) for c in classes)) + ' tests, with ' + str(total) + ' failures (' + str(unexpected) + ' unexpected) in 0.002 seconds.']
    return ('\n'.join(rows) + '\n').encode()


class PublicCaptureTests(unittest.TestCase):
    def refuse(self, data, code=0, classes=CLASSES):
        with self.assertRaises((ValueError, UnicodeDecodeError)):
            parse_result(data, code, classes)

    def testCompleteTwoClassPositive(self):
        report = parse_result(transcript(), 0, CLASSES)
        self.assertEqual((report['executed'], report['failures'], report['unexpected']), (3, 0, 0))

    def testReversedClassAndMethodOrderIsValid(self):
        self.assertEqual(parse_result(transcript(reverse=True), 0, CLASSES)['executed'], 3)

    def testMultipleAssertionsSumAcrossClasses(self):
        report = parse_result(transcript(failed={'testOne': 3, 'testThree': 2}), 1, CLASSES)
        self.assertEqual(report['failures'], 5)

    def testSingleClassPositive(self):
        self.assertEqual(parse_result(transcript(CLASSES[:1]), 0, CLASSES[:1])['executed'], 2)

    def testSixClassUnionPositive(self):
        classes = [{'class': name + 'Tests', 'methods': ['test' + name]} for name in ('A', 'B', 'C', 'D', 'E', 'F')]
        self.assertEqual(parse_result(transcript(classes), 0, classes)['executed'], 6)

    def testForeignClassCase(self):
        self.refuse(transcript().replace(b'NativeRoutingTests.FirstTests', b'NativeRoutingTests.ForeignTests'))

    def testDuplicateStart(self):
        data = transcript();line = next(row for row in data.splitlines(True) if b'Test Case' in row)
        self.refuse(line + data)

    def testMissingFinish(self):
        self.refuse(b'\n'.join(row for row in transcript().splitlines() if b"testTwo]' passed" not in row))

    def testSkippedFinish(self):
        self.refuse(transcript().replace(b"testTwo]' passed", b"testTwo]' skipped"))

    def testUnexpectedClassFailure(self):
        self.refuse(transcript(failed={'testOne': 1}, unexpected=1), 1)

    def testWrongClassCount(self):
        self.refuse(transcript().replace(b'Executed 2 tests', b'Executed 3 tests'))

    def testWrongAggregate(self):
        self.refuse(transcript().replace(b'Executed 3 tests', b'Executed 4 tests'))

    def testMissingAggregate(self):
        data = transcript();last = data.rfind(b'\t Executed ')
        self.refuse(data[:last])

    def testDuplicateClassTerminal(self):
        data = transcript();line = b"Test Suite 'FirstTests' passed at fixed.\n\t Executed 2 tests, with 0 failures (0 unexpected).\n"
        self.refuse(data + line)

    def testClassBoundaryOrder(self):
        self.refuse(transcript().replace(b"Test Suite 'FirstTests' started", b"Test Suite 'FirstTests' finished"))

    def testCaseOutsideItsClass(self):
        data = transcript();start = data.index(b"Test Case '-[NativeRoutingTests.FirstTests testOne]' started.")
        end = data.index(b'\n', data.index(b"testOne]' passed", start)) + 1
        block = data[start:end];data = data[:start] + data[end:]
        self.refuse(block + data)

    def testUnparsedCaseRecord(self):
        self.refuse(transcript() + b'Test Case unknown\n')

    def testExitDisagreesWithFailures(self):
        self.refuse(transcript(failed={'testThree': 1}), 0)
        self.refuse(transcript(), 1)

    def testFailureNeedsOrdinaryEvidence(self):
        self.refuse(transcript(failed={'testOne': 1}).replace(b'XCTAssertEqual failed', b'no assertion evidence'), 1)

    def testBadTypedOrDuplicateRoster(self):
        self.refuse(transcript(), True)
        self.refuse(transcript(), classes=CLASSES + CLASSES[:1])
        self.refuse(transcript(), classes=[{'class': 'FirstTests', 'methods': ['testOne', 'testOne']}])


if __name__ == '__main__':
    unittest.main()
