"""Pure transcript and original-snapshot regressions; no child or native execution."""
from pathlib import Path
import importlib.util
import sys
import tempfile
import unittest
from unittest import mock

HERE = Path(__file__).absolute().parent
SPEC = importlib.util.spec_from_file_location(
    'locate_boundary_fixture', HERE / 'test_disk_conflict_presentation_runner.py')
FIXTURE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = FIXTURE
SPEC.loader.exec_module(FIXTURE)
RUNNER = FIXTURE.RUNNER


def darwin_log(selection, failures=0):
    """Synthetic names/times with the three-suite shape observed on Darwin."""
    raw = FIXTURE.log(selection, failures=failures).decode('utf-8')
    cls = FIXTURE.SELECTIONS[selection]['class'].rsplit('.', 1)[1]
    stamp = '2026-10-16 00:00:00.000'
    raw = raw.replace("Test Suite 'Selected tests' started.",
        "Test Suite 'Selected tests' started at " + stamp + ".\n"
        "Test Suite 'NativeRoutingPackageTests.xctest' started at " + stamp + ".")
    raw = raw.replace("Test Suite '" + cls + "' started.",
        "Test Suite '" + cls + "' started at " + stamp + ".")
    state = 'failed' if failures else 'passed'
    selected_end = "Test Suite 'Selected tests' " + state + ' at synthetic-time.'
    bundle_end = ("Test Suite 'NativeRoutingPackageTests.xctest' " + state + ' at ' + stamp + '.\n'
        'Executed 2 tests, with ' + str(failures) + ' failures (0 unexpected) in 0.002 (0.003) seconds\n')
    return raw.replace(selected_end, bundle_end + selected_end).encode('utf-8')


class DiskConflictPresentationBoundaryTests(unittest.TestCase):
    def testDarwinTimestampedStartsAndBundleSummaryPreserveExactOrderedSelection(self):
        for selection in ('old2', 'new2'):
            with self.subTest(selection=selection):
                raw = darwin_log(selection)
                result = RUNNER.parse_result(raw, 0, selection)
                self.assertIsInstance(result, dict, 'Positive parser absent; transcript variants UNENTERED')
                if not isinstance(result, dict):
                    continue
                self.assertEqual((result.get('executed'), result.get('failures'), result.get('unexpected')), (2, 0, 0))
                ordinary = RUNNER.parse_result(darwin_log(selection, failures=3), 1, selection)
                self.assertEqual((ordinary['executed'], ordinary['failures'], ordinary['unexpected']), (2, 3, 0))
                case = '-[' + FIXTURE.SELECTIONS[selection]['class'] + ' ' + FIXTURE.SELECTIONS[selection]['methods'][0] + ']'
                start = ("Test Case '" + case + "' started.\n").encode()
                end = ("Test Case '" + case + "' passed (0.001 seconds).\n").encode()
                self.assertIn(start, raw)
                self.assertIn(end, raw)
                reordered = raw.replace(start, b'', 1).replace(end, end + start, 1)
                with self.assertRaises(ValueError):
                    RUNNER.parse_result(reordered, 0, selection)

    def testOriginalMutationImmediatelyAfterCapturedReadCannotAuthorizeOlderDerivedBytes(self):
        # Mutate the actual original after the producer's owned read returns its
        # first snapshot. Accepting newer Original facts with old derived bytes
        # would make a passing final custody check describe a different program.
        for relative in ('Sources/PadCore/A.swift', 'Tests/NativeIntegration/LocatePresentationOwnerAccess.swift'):
            with self.subTest(relative=relative), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                FIXTURE.repository(root)
                run = root / 'Candidate'
                run.mkdir(mode=0o700)
                with FIXTURE.relocated(root):
                    plan = FIXTURE.planned(self, root, run)
                    if plan is None:
                        continue
                    original_fact = getattr(RUNNER, 'fact', None)
                    self.assertTrue(callable(original_fact), 'No original-read boundary; drift horizon UNENTERED')
                    if not callable(original_fact):
                        continue
                    target = root / relative
                    mutations = []

                    def read_then_change(base, path):
                        result = original_fact(base, path)
                        if Path(base).absolute() == root.absolute() and Path(path).absolute() == target.absolute() and not mutations:
                            self.assertIsInstance(result, tuple)
                            self.assertEqual(len(result), 2)
                            captured = result[1]
                            self.assertIsInstance(captured, bytes)
                            target.write_bytes(captured + b'\n// synthetic changed original after capture\n')
                            mutations.append(relative)
                        return result

                    with mock.patch.object(RUNNER, 'fact', side_effect=read_then_change):
                        with self.assertRaises(ValueError):
                            RUNNER.freeze(root, run, plan)
                    self.assertEqual(mutations, [relative], 'Actual input read/write boundary must be reached')


if __name__ == '__main__':
    unittest.main()
