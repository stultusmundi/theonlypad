"""Pure execute-level stop/custody contracts. Injected watcher only; no process run."""
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
ROOT = Path.cwd()
def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module
RUNNER = load('inert_real_helper_flow', HERE / 'run_native_regressions.py')
FIRST = load('real_helper_pure_fixture', ROOT / 'Tests/NativeIntegration/test_document_search_real_helper_runner.py')
MODE = FIRST.MODE
STAGES = ('toolchain', 'build', 'bin-path', *FIRST.STAGES)

class RealHelperFlowGuardsTests(unittest.TestCase):
    def fixture(self):
        owner = FIRST.RealHelperRunnerTests()
        helper, root, run = owner.fixture()
        self.addCleanup(owner.doCleanups)
        # Source capture is genuine existing freeze logic, but APP synthetic graph:
        # it is only flow setup and must never be presented as helper compiler proof.
        RUNNER.freeze(root, run, 'document-search-app')
        record, digest, binary = owner.proof_fixture(run)
        return helper, run, record, digest, binary

    def exercise(self, mutation=None, fail_name=None):
        helper, run, record, digest, binary = self.fixture()
        pending = []
        def capture(owned, output_directory, source_hash):
            self.assertEqual(Path(output_directory), binary)
            return record
        def stage(owned, name, authority):
            state = run / 'State' / name
            state.mkdir(parents=True, exist_ok=True)
            value = {'stage': name}
            if name == fail_name:
                path = state / 'unsettled-fixture'
                path.write_bytes(b'original unresolved custody')
                pending.append(path)
            return value
        def output(command):
            # Support explicit safe inert stage tokens and future actual fixed argv.
            if '--show-bin-path' in command or command[-1] == 'bin-path': return str(binary) + '\n'
            for stage_name, method in zip(FIRST.STAGES, FIRST.METHODS):
                if command[-1] == stage_name or (('--filter' in command) and command[command.index('--filter') + 1].endswith('/' + method)) or (('-XCTest' in command) and command[command.index('-XCTest') + 1].endswith('/' + method)):
                    return FIRST.RealHelperRunnerTests.success(method)
            return 'pure stage output\n'
        watch = helper.watchdog(output)
        def wrapped(argv):
            code = watch(argv)
            output_dir = Path(argv[argv.index('--output') + 1])
            name = output_dir.name
            if name == FIRST.STAGES[0] and mutation:
                if mutation == 'helper': (run / record['helper']).write_bytes(b'postcapture changed helper')
                else: (run / 'build-inputs.json').write_bytes(b'{}\n')
            if name == fail_name:
                value = json.loads((output_dir / 'status.json').read_text())
                value.update(exit=1, returnCode=1)
                FIRST.store(output_dir / 'status.json', value)
                return 1
            return code
        # Capture and stage fixture generation are injected. The actual execute
        # path MUST still call its real hash-authority verifier and stop logic.
        with patch.object(RUNNER, 'capture_real_helper_build', capture), \
             patch.object(RUNNER, 'stage_real_helper', stage), \
             patch.object(RUNNER, 'verify_real_helper_fixture', return_value=None):
            result = RUNNER.execute(run, RUNNER.parse_args([MODE]), wrapped)
        names = [Path(call[call.index('--output') + 1]).name for call in helper.calls]
        return result, names, pending, run

    def test_unchanged_flow_reaches_exact_six_stages(self):
        result, names, pending, _ = self.exercise()
        self.assertEqual(result, 0)
        self.assertEqual(names, list(STAGES))
        self.assertEqual(pending, [])

    def test_postcapture_mutation_stops_before_second_case_without_rehash_blessing(self):
        for mutation in ('helper', 'authority-record'):
            with self.subTest(mutation=mutation):
                result, names, _, run = self.exercise(mutation=mutation)
                self.assertEqual(names, list(STAGES[:4]), 'No second native case after authority changed')
                self.assertEqual(result, 125)
                if mutation == 'authority-record': self.assertEqual((run / 'build-inputs.json').read_bytes(), b'{}\n')
                else: self.assertTrue((run / 'Build/arm64-apple-macosx/debug/PadSearchWorker').read_bytes().startswith(b'postcapture'))

    def test_second_case_failure_stops_before_third_and_preserves_custody(self):
        result, names, pending, _ = self.exercise(fail_name=FIRST.STAGES[1])
        self.assertEqual(names, list(STAGES[:5]), 'Third case must remain UNENTERED after failed second case')
        self.assertEqual(result, 1)
        self.assertEqual(len(pending), 1)
        self.assertEqual(pending[0].read_bytes(), b'original unresolved custody')

if __name__ == '__main__': unittest.main()
