"""Closed stateless diagnostics; real byte parser and fake owned-watchdog capsules only.
No Swift/compiler/process/native execution. Support modules stay modules, not Test aliases.
"""
import ast
import hashlib
import importlib.util
import json
from pathlib import Path
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location(
    'predicate_transition_support', HERE / 'test_ci_folder_preview_transition_refusal.py')
support = importlib.util.module_from_spec(spec)
spec.loader.exec_module(support)
availability, old, runner = support.availability, support.old, support.runner
UNAVAILABLE, SECRET = support.UNAVAILABLE, support.SECRET
TAG = b'CI_PREVIEW_PREDICATE'
ROOT_STAGES = (0, 1, 2, 3, 10, 20, 21, 23, 12, 13, 14, 15, 16, 17, 18, 19, 24, 4, 5)


def core(stage):
    return f'CI_FOLDER_PREVIEW_CORE s={stage}\n'.encode('ascii')


def selected(count=1, main=1):
    return f'CI_PREVIEW_PREDICATE c={count} m={main}\n'.encode('ascii')


def wrapper(bit=0, main=1):
    return f'CI_PREVIEW_PREDICATE w={bit} m={main}\n'.encode('ascii')


def pieces(omitted=()):
    events = old.expected_events(omitted)
    start, end = events.index(old._path(7, 11)), events.index(old._path(8, 11))
    return (b''.join(old._record(x) for x in events[:start + 1]),
            b''.join(core(x) for x in ROOT_STAGES),
            core(6) + core(7) + core(9),
            b''.join(old._record(x) for x in events[end:]))


def payload(count=1, bits=(0,), omitted=()):
    head, root, done, tail = pieces(omitted)
    return head + root + selected(count) + b''.join(wrapper(x) for x in bits) + done + tail


# Exact UTF-8 function text from pinned original d38a55e1; AST is used only to locate spans, never to hash its version-dependent schema.
PROTECTED_SOURCE = {
  "_availability_boundary": "c6641a99ec6c454dd43653bf8c7d67623edb5571c7c06ad6008dd94e19c00f12",
  "_availability_fields": "7ea3396a44a5255c3c83cd1a2799b98568d87a659a09cd5c32f3128439cbbecf",
  "_availability_enter": "7ddede0b75a5d694f3b960b0673ced4d84b1c5642763bf8629a4c1974211196e",
  "_availability_fail": "9b899d5193532026180541c7c37959d0175d1847c49b2196020e717420f07924",
  "_availability_line": "b76ef99c123fb2d8d68c2847ce29111168a2737f6d829628c01a965704211002",
  "_parser_refusal_code": "2f4a25e408eabdc63581a2058f87461bde51ac5279bfa6c449953a9203545351",
  "_parser_refusal_mark": "15bb3568a3d184d0adcfbc4c6ba885bd9b646846cc204975dcb11d6d063fd2cb",
  "_parser_require": "c581e4e2d2aed2f890a366bf366be70cc10712b772701e958bf60bfa7f6504f0",
  "_parser_transition_state_id": "5b1450d500e3c2d4b65848f169e58b0c4ae688d4f68ea4afec970b24e4f9c4ee",
  "_parser_refusal_transition": "70310a38bf6640df33f104ac3d881c61d99ff475675552c0ed32591c58e788a4",
  "_parser_transition_mark": "e9ac2d95c501e14577e4cb94f411e024598c5852d6d4056c97c6ab7fc8df89b5",
  "_parser_transition_require": "32f2f2414aab2830ef7f535d4d25220bd76d3621c1d2476bd34c04530cdbf5bc",
  "_require": "edd77d0d5ab9c9838f6d65b150cd760fdee1fdd5ced1362df77a9446f89ec527",
  "_owned": "4a02492f4bc715d75cfe5a7dd201b265e90b7daf314aaaa47c5f56b981ef8c1a",
  "_fact": "b0b0e19d8965a81417e76543bda1f7783a57239b89c5928b1257673041d24c03",
  "_directory": "e0a6dca8534bd84c83f80bd5d50c9b158aaa27b7c28c427dcff8b4607c7e314f",
  "_json": "72a1e748449a0aafdfb1470077fac010ec37ba8c763cf5d56a46bdd4b84f65a5",
  "_save": "68d654768fb0bcf7abb4dae7290576552dbdd64f814bd9b16cdb69bd32ad7fdd",
  "_mkdir": "8dd4880ed36b766f8bb20c013385cb48b4dff4d58a59ae4516aa136dba3b3bf4",
  "validate_cli": "3978d91f93fde25a621b42afa4829770b994ade0dbb02ac05e360f046f1ce4d8",
  "_marker": "106601bbe4746a6d535a266db2b4e1ca64ed5111967a41ce76c74930dcce9c00",
  "_path_marker": "658820283acb612f06d8b40d42e733d7e4f004324a3c048898e30daed0e02f0e",
  "_project_path_test": "ebc8efa2a09372f4217744d9f1e1ea3c1b8b2943d3a7be07e8e2e1231cc4553d",
  "_trace_grammar": "b418e7574c024e5728254fa6a93786e8844924cf8e20ef8855d84142088b1134",
  "_trace_report": "27b855b247ecc8eb0224e5ef004388d6097443e08aef000774726255cd8b1993",
  "_parse_path_trace": "cea1f7aada259a42c3261a5fcbeabb34e781a7da0b4aefeb3649b70bf9c86fba",
  "_valid_trace_report": "1db5b8bac192469e2780d74c6ac829158d193feb9878b4be685611f9ed374c10",
  "_inventory": "523a34d67044fec5a046ca2e2cfd06f0590de757f82d5ed5afba425a8d0c12d8",
  "_command": "4aa2df40a3e39b2f4de104db8ead25c0ad32f5b362c4386b50783ee3f7397e35",
  "make_plan": "e25ebb15091a420574668c12263d9609d0e90fe14b76eabe5de5780be7dea3c6",
  "freeze": "54f5ed98171c9ab26993a49eb94233215a62ca0564ae0d7f2c568d817976c2ca",
  "verify_inputs": "b9cda3ee6351cb31fdbaf8f12316f9bfddc872e4b34425499faebecc80a2320e",
  "_load_module": "5db0a910aec70962283d4b31bf366d0da6fcd87a327154ff08a7294bd3c368e5",
  "_render_path": "7d07ab317782db1f35b51b796283c72db4e5ea2e956b6ceb2efe8f9916b451f4",
  "_core_marker": "5fa6ac6b9a5027ec9ae3d63d6ccc6405dcfac69f34d16dc5480d443b588b0449",
  "project_test": "e9b0a5d80738dfcf74b60e87ccac65df05c65b3c8c10be5b23dafb65a19e9443",
  "_projection_metadata": "9247b58b76a9e193bd9508552bc31f737d0684857bd04763e0de1e3e5428df40",
  "_core_next": "1804db076798e336dc03f35d68fcf777df6507025d649949fc10b1a5139af6af",
  "_core_report": "b6c409f5f0b39c157c106e5c78502c32af832fe7483b484f21a72891624d7b5d",
  "_core_position": "3198b67156a1c9dbb28e51ad294a9b59359d8c6133a7acb5d1cd5452635d790d",
  "parse_trace": "7c69ecd154a6ac1aa36f0d0d77a66883caac5abe6691e07ff0f9be6d379a21f0",
  "_validate_core_report": "4fea1b1d57c329c663c62a8a21fb3b4190c464676536f883ea1ac0601bc8ffab",
  "render": "fa399b4c0abcec86430effd394ca7805bfa70af04a039e210e478ae259aa91a2",
  "main": "318007e46fa3043c3a843cae130c9c1a891fbc8638bb306f5ee13cb73259aff7"
}


class FolderPreviewPredicateObservationTests(unittest.TestCase):
    def capsule(self):
        return availability.FolderPreviewAvailabilityTests.capsule(self)

    def api(self):
        collect = getattr(runner, '_collect_predicate_observation', None)
        read = getattr(runner, '_predicate_observation', None)
        self.assertTrue(callable(collect) and callable(read),
                        'Missing stateless predicate API; all deeper projection/collector/main controls UNENTERED')
        if not callable(collect) or not callable(read):
            return None
        record = runner._ParserRefusal()
        self.assertTrue(hasattr(record, 'predicate'), 'Missing nullable diagnostic slot; deeper controls UNENTERED')
        if not hasattr(record, 'predicate'):
            return None
        self.assertIsNone(record.predicate)
        self.assertIsNone(read(record))
        return collect, read

    def refusal(self, stdout, stderr=b''):
        record = runner._ParserRefusal()
        with self.assertRaises(ValueError) as plain:
            runner.parse_trace(stdout, stderr)
        with self.assertRaises(ValueError) as observed:
            runner.parse_trace(stdout, stderr, refusal=record)
        self.assertIs(type(observed.exception), type(plain.exception))
        self.assertEqual(observed.exception.args, plain.exception.args)
        return record

    def observe(self, collect, read, stdout, stderr=b''):
        record = self.refusal(stdout, stderr)
        before = (record.code, runner._parser_refusal_transition(record))
        self.assertIsNone(collect(stdout, stderr, refusal=record))
        self.assertEqual((record.code, runner._parser_refusal_transition(record)), before)
        return read(record), record

    def test_projection_has_exact_two_fragment_inverse_and_preserves_all_original_decisions(self):
        api = self.api()
        if api is None:
            return
        projected = runner.project_core(old.ORIGINAL_CORE)
        self.assertEqual(projected.count(TAG), 2)
        self.assertEqual(projected.count(old.PREDICATE_SELECTED_SOURCE), 1)
        self.assertEqual(projected.count(old.PREDICATE_WRAPPER_SOURCE), 1)
        self.assertEqual(old.strip_core_projection(projected), old.ORIGINAL_CORE)
        self.assertEqual(old.strip_projection(runner.project_test(old.ORIGINAL)), old.ORIGINAL)
        # Genuine root uses the policy directly; only selected validation uses validURL.
        self.assertEqual(projected.count(b'selectedURLs.allSatisfy(validURL)'), 1)
        self.assertNotIn(b'allSatisfy {', projected)
        self.assertEqual(projected.count(b'FolderReplacementPathPolicy.valid(url, diagnosticTrace: diagnosticTrace)'), 1)
        self.assertEqual(old.PREDICATE_SELECTED_SOURCE.count(b'selectedURLs.count'), 1)
        self.assertNotIn(b'if diagnosticTrace', old.PREDICATE_WRAPPER_SOURCE)
        self.assertIn(b'let predicateBit = diagnosticTrace ? 1 : 0', old.PREDICATE_WRAPPER_SOURCE)
        self.assertNotIn(b'url.', old.PREDICATE_WRAPPER_SOURCE)
        mutations = [
            projected.replace(old.PREDICATE_SELECTED_SOURCE, b'', 1),
            projected.replace(old.PREDICATE_WRAPPER_SOURCE, old.PREDICATE_LEGACY_WRAPPER, 1),
            projected.replace(old.PREDICATE_SELECTED_SOURCE, old.PREDICATE_SELECTED_SOURCE * 2, 1),
            projected.replace(b'let predicateBit = diagnosticTrace ? 1 : 0', b'let predicateBit = 1', 1),
            projected.replace(b'let predicateMain = Thread.isMainThread ? 1 : 0', b'let predicateMain = 1', 1),
            projected.replace(b'    if diagnosticTrace {\n      let predicateCount', b'    if true {\n      let predicateCount', 1),
            projected.replace(b'    return FolderReplacementPathPolicy.valid(url, diagnosticTrace: diagnosticTrace)',
                              b'    return FolderReplacementPathPolicy.valid(url, diagnosticTrace: false)', 1),
            projected.replace(b'selectedURLs.allSatisfy(validURL)', b'selectedURLs.allSatisfy { validURL($0) }', 1),
            projected.replace(b'CI_PREVIEW_PREDICATE w=', b'CI_PREVIEW_PREDICATE w=1', 1),
        ]
        # Move the canonical selected block across the original Core5 source boundary.
        five = runner._core_marker(5)
        self.assertEqual(projected.count(five + old.PREDICATE_SELECTED_SOURCE), 1)
        mutations.append(projected.replace(five + old.PREDICATE_SELECTED_SOURCE,
                                          old.PREDICATE_SELECTED_SOURCE + five, 1))
        # Move the only actual policy call ahead of the unconditional wrapper entry.
        entry = old.PREDICATE_WRAPPER_SOURCE
        call = b'    return FolderReplacementPathPolicy.valid(url, diagnosticTrace: diagnosticTrace)\n'
        moved = entry.replace(call, b'', 1).replace(b'    let predicateBit', call + b'    let predicateBit', 1)
        mutations.append(projected.replace(entry, moved, 1))
        for index, changed in enumerate(mutations):
            with self.subTest(mutation=index):
                self.assertNotEqual(changed, projected)
                with self.assertRaises(ValueError):
                    old.strip_core_projection(changed)
        module_source = (old.ROOT / runner.LOCATION).read_bytes().decode('utf-8')
        module = ast.parse(module_source)
        functions = {node.name: node for node in module.body if isinstance(node, ast.FunctionDef)}
        for name, expected in PROTECTED_SOURCE.items():
            with self.subTest(protected=name):
                self.assertIn(name, functions)
                body = ast.get_source_segment(module_source, functions[name])
                self.assertIsInstance(body, str)
                actual = hashlib.sha256(body.encode('utf-8')).hexdigest()
                self.assertEqual(actual, expected)

    def test_completed_real_byte_windows_capture_finite_tuples_without_reparsing_core(self):
        api = self.api()
        if api is None:
            return
        collect, read = api
        cases = [(0, (), (0, 0, 0)), (1, (), (1, 0, 0)),
                 (1, (0,), (1, 1, 1)), (1, (1,), (1, 1, 2)),
                 (2, (), (2, 0, 0)), (2, (0,), (2, 1, 1)), (2, (1,), (2, 1, 2)),
                 (2, (0, 0), (2, 2, 1)), (2, (1, 1), (2, 2, 2)),
                 (2, (0, 1), (2, 2, 3)), (2, (1, 0, 1), (2, 2, 3))]
        attempted = 0
        for count, bits, expected in cases:
            for omitted in ((), (11,), tuple(range(1, 13))):
                for swap in (False, True):
                    raw = wrapper(0) + payload(count, bits, omitted) + wrapper(1)
                    streams = (raw, b'') if swap else (b'', raw)
                    record = self.refusal(*streams)
                    self.assertEqual((record.code, runner._parser_refusal_transition(record)), (4, (6, 6)))
                    with mock.patch.object(runner, '_core_next', wraps=runner._core_next) as core_next, \
                            mock.patch.object(runner, 'parse_trace', wraps=runner.parse_trace) as parser, \
                            mock.patch.object(runner, '_parse_path_trace', wraps=runner._parse_path_trace) as path:
                        self.assertIsNone(collect(*streams, refusal=record))
                        self.assertEqual((parser.call_count, core_next.call_count, path.call_count), (0, 0, 1))
                    self.assertEqual(read(record), expected)
                    self.assertEqual((record.code, runner._parser_refusal_transition(record)), (4, (6, 6)))
                    # Reusing the same first witness never overwrites its first outcome.
                    self.assertIsNone(collect(payload(1, (1,)), b'', refusal=record))
                    self.assertEqual(read(record), expected)
                    attempted += 1
        self.assertEqual(attempted, 66)
        # Exact side cap, no unbounded retained record list; 128 valid entries still admitted.
        raw = wrapper(0) * 126 + payload(1, (0,))
        value, _ = self.observe(collect, read, raw)
        self.assertEqual(value, (1, 1, 1))
        value, _ = self.observe(collect, read, wrapper(0) + raw)
        self.assertIsNone(value)
        # Original successful Core NUL-rejection path may contain ignored disjoint records.
        good = old.trace().replace(core(5), core(5) + selected(), 1)
        good = good.replace(core(5) + selected() + core(10), core(5) + selected() + wrapper(1) + core(10), 1)
        fresh = runner._ParserRefusal()
        self.assertEqual(runner.parse_trace(good, b'', refusal=fresh), old._closed_report(old.expected_events()))
        self.assertIsNone(fresh.code)
        self.assertIsNone(read(fresh))

    def test_unknown_latches_malformed_streams_foreign_types_and_uncompleted_windows(self):
        api = self.api()
        if api is None:
            return
        collect, read = api
        raw = payload()
        head, root, done, tail = pieces()
        malformed = [b'CI_PREVIEW_PREDICATE', b'CI_PREVIEW_PREDICATE w=',
                     b'CI_PREVIEW_PREDICATE w=0 m=1', b'CI_PREVIEW_PREDICATE w=2 m=1\n',
                     b'CI_PREVIEW_PREDICATE c=3 m=1\n', b'CI_PREVIEW_PREDICATE c=True m=1\n',
                     b'CI_PREVIEW_PREDICATE w=0 m=2\n', b'CI_PREVIEW_PREDICATE w=0 m=1 extra=0\n',
                     b'CI_PREVIEW_PREDICAT', b'CI_PREVIEW_PREDICATE ' + SECRET.encode() + b'\n']
        invalid = [(raw + tag, b'') for tag in malformed]
        invalid.extend([
            (head + root + selected(main=0) + wrapper() + done + tail, b''),
            (head + root + selected() + wrapper(main=0) + done + tail, b''),
            (wrapper(main=0) + raw, b''),
            (head + root + selected() + done + tail, wrapper()),
            (head + root + selected() + wrapper() + wrapper() + done + tail, b''),
            (head + root + selected(0) + wrapper() + done + tail, b''),
            (head + wrapper() + root + selected() + done + tail, b''),
            (head + root + wrapper() + selected() + done + tail, b''),
            (head + root + selected() + selected() + wrapper() + done + tail, b''),
            (selected() + raw, b''),
            (head + root + selected() + core(6) + wrapper() + core(9) + tail, b''),
            (head + root.replace(core(5), b'', 1) + selected() + wrapper() + done + tail, b''),
            (head + root + core(5) + selected() + wrapper() + done + tail, b''),
            (head + root + selected() + wrapper() + core(6) + core(6) + core(9) + tail, b''),
            (head + root + selected() + wrapper() + core(9) + tail, b''),
            (head + root + selected() + wrapper() + core(6), b''),
            (head + root + selected() + wrapper() + done + tail.replace(b'CI_FOLDER_PREVIEW_PATH s=8\n', b'', 1), b''),
            (raw + b'CI_FOLDER_PREVIEW_CORE s=\n', b''),
            (raw.replace(b'CI_FOLDER_PREVIEW_TRACE p=9 e=1\n',
                         b'CI_FOLDER_PREVIEW_TRACE p=9 e=0\n', 1), b''),
        ])
        # Some prefixes are legal original parser prefixes. Give the collector the genuine
        # same first coarse4 witness, rather than forging code/pair or forcing parser success.
        for index, streams in enumerate(invalid):
            with self.subTest(invalid=index):
                record = self.refusal(raw)
                self.assertIsNone(collect(*streams, refusal=record))
                self.assertIsNone(read(record))
                self.assertIsNone(collect(raw, b'', refusal=record))
                self.assertIsNone(read(record), 'Unknown first attempt must not borrow a later complete stream')
                self.assertEqual((record.code, runner._parser_refusal_transition(record)), (4, (6, 6)))
        class BytesSubclass(bytes):
            pass
        for streams in [(bytearray(raw), b''), (BytesSubclass(raw), b''), (raw.decode('ascii'), b''),
                        (None, b''), (raw, bytearray())]:
            record = self.refusal(raw)
            self.assertIsNone(collect(*streams, refusal=record))
            self.assertIsNone(read(record))
        class Foreign:
            def __getattribute__(self, name):
                raise AssertionError('Foreign observation inspected')
            def __eq__(self, other):
                raise AssertionError('Foreign observation compared')
            def __str__(self):
                raise AssertionError('Foreign observation formatted')
        record = self.refusal(raw)
        collect(raw, b'', refusal=record)
        self.assertEqual(read(record), (1, 1, 1))
        good = record.predicate
        self.assertIsNotNone(good)
        with self.assertRaises(TypeError):
            type(good)()  # Private construction requires the collector's internal key.
        class Subclass(type(good)):
            pass
        bad_records = [None, {}, (1, 1, 1), True, SECRET, Foreign(), object.__new__(Subclass)]
        failed = runner._AvailabilityProgress()
        runner._availability_enter(failed, 17)
        runner._availability_fail(failed)
        plain_pair = '\n'.join(UNAVAILABLE + ['availability: boundary=17 parser=4 state=6 incoming=6'])
        for bad in bad_records:
            record.predicate = bad
            self.assertIsNone(read(record))
            text = runner._availability_output(failed, parser_refusal=record)
            self.assertEqual(text, plain_pair)
            self.assertNotIn(SECRET, text)
            self.assertLessEqual(len((text + '\n').encode('ascii')), 512)
        record.predicate = good
        for name, bad in [('selected', True), ('selected', -1), ('selected', 3),
                          ('calls', True), ('calls', -1), ('calls', 3),
                          ('bits', True), ('bits', -1), ('bits', 4), ('bits', Foreign())]:
            previous = getattr(good, name)
            setattr(good, name, bad)
            self.assertIsNone(read(record))
            self.assertEqual(runner._availability_output(failed, parser_refusal=record), plain_pair)
            setattr(good, name, previous)
        for count in range(3):
            for calls in range(3):
                for bits in range(4):
                    valid = ((calls == 0 and bits == 0) or (calls == 1 and bits in (1, 2))
                             or (calls == 2 and bits in (1, 2, 3)))
                    valid = valid and (count == 2 or (count == 1 and calls <= 1) or (count == 0 and calls == 0))
                    if valid:
                        continue
                    good.selected, good.calls, good.bits = count, calls, bits
                    self.assertIsNone(read(record))
        good.selected, good.calls, good.bits = 1, 1, 1
        other = self.refusal(raw)
        other.predicate = good
        self.assertIsNone(read(other), 'Equal transition values cannot replace exact first-witness identity')
        pair = record.transition
        record.transition = (0, 1)
        self.assertIsNone(read(record))
        record.transition = pair
        self.assertEqual(read(record), (1, 1, 1))
        record.code = True
        self.assertIsNone(read(record))
        record.code = 4
        del good.bits
        self.assertIsNone(read(record))
        good.bits = 1
        del record.predicate
        self.assertIsNone(read(record))
        record.predicate = good
        self.assertEqual(read(record), (1, 1, 1))
        for invalid_refusal in [None, {}, True, SECRET, Foreign()]:
            self.assertIsNone(read(invalid_refusal))
            self.assertIsNone(collect(raw, b'', refusal=invalid_refusal))
        no_pair = self.refusal(b'CI_FOLDER_PREVIEW_CORE s=\n')
        self.assertIsNone(collect(raw, b'', refusal=no_pair))
        self.assertIsNone(read(no_pair))

    def test_main_propagates_only_same_owned_refusal_and_preserves_success_receipts_and_reporting(self):
        api = self.api()
        if api is None:
            return
        collect, read = api
        for count, bits, expected in [(0, (), (0, 0, 0)), (1, (0,), (1, 1, 1)), (2, (0, 1), (2, 2, 3))]:
            for fault in (None, 'save', 'render-raise'):
                with self.subTest(count=count, bits=bits, fault=fault):
                    root, _, _ = self.capsule()
                    watch = old.ControlledWatchdog(payload(count, bits), exit_code=1)
                    with mock.patch.object(runner, 'parse_trace', wraps=runner.parse_trace) as parser, \
                            mock.patch.object(runner, '_parse_path_trace', wraps=runner._parse_path_trace) as path, \
                            mock.patch.object(runner, '_collect_predicate_observation', wraps=collect) as collector:
                        value = availability.FolderPreviewAvailabilityTests.main_call(self, root, watch, fault=fault)
                        self.assertEqual((parser.call_count, path.call_count, collector.call_count), (1, 1, 1))
                    code, stdout, stderr, escaped, imported = value
                    self.assertIsNone(escaped)
                    self.assertEqual((code, stderr, len(watch.calls)), (125, '', 1))
                    suffix = ('availability: boundary=17 parser=4 state=6 incoming=6'
                              f' selected={expected[0]} calls={expected[1]} bits={expected[2]}')
                    self.assertEqual(stdout, '\n'.join(UNAVAILABLE + [suffix]) + '\n')
                    self.assertEqual(len(stdout.splitlines()), 3)
                    self.assertLessEqual(len(stdout.encode('ascii')), 512)
                    self.assertNotIn(SECRET, stdout + stderr)
                    self.assertIn('folder_trace_verifier', imported)
                    runs = list((root / '.local/ci-folder-preview-trace').glob('run.*'))
                    self.assertEqual(len(runs), 1)
                    run = runs[0]
                    self.assertEqual((run / 'stage/stdout.log').read_bytes(), watch.stdout)
                    self.assertEqual((run / 'stage/stderr.log').read_bytes(), watch.stderr)
                    captured = json.loads((run / 'inputs.json').read_text())
                    manifest = dict(capture=captured, authority=runner._fact(run, run / 'inputs.json')[0])
                    runner.verify_inputs(root, run, manifest)
                    if fault == 'save':
                        self.assertEqual((run / 'result.json').read_bytes(), b'preserved synthetic result collision\n')
        # A genuine failed boundary17 controls public custody, not just a valid-looking tuple.
        record = self.refusal(payload())
        collect(payload(), b'', refusal=record)
        for boundary in (0, 16, 18, 20, 21):
            progress = runner._AvailabilityProgress()
            runner._availability_enter(progress, boundary)
            runner._availability_fail(progress)
            self.assertEqual(runner._availability_output(progress, parser_refusal=record),
                             runner._availability_output(progress))
        progress = runner._AvailabilityProgress()
        runner._availability_enter(progress, 17)
        self.assertEqual(runner._availability_output(progress, parser_refusal=record), '\n'.join(UNAVAILABLE))
        # Complete ordinary Core route keeps five public lines and does not collect side evidence.
        good = old.trace().replace(core(5), core(5) + selected() + wrapper(1), 1)
        root, _, _ = self.capsule()
        watch = old.ControlledWatchdog(good)
        with mock.patch.object(runner, '_collect_predicate_observation', wraps=collect) as collector:
            code, stdout, stderr, escaped, _ = availability.FolderPreviewAvailabilityTests.main_call(self, root, watch)
            self.assertEqual(collector.call_count, 0)
        self.assertIsNone(escaped)
        self.assertEqual((code, stderr), (0, ''))
        self.assertEqual(len(stdout.splitlines()), 5)
        self.assertNotIn('selected=', stdout)
        self.assertNotIn('availability:', stdout)
        self.assertNotIn('CI_PREVIEW_PREDICATE', stdout)
        # Unknown side observations preserve the same original pair, never a new outcome.
        root, _, _ = self.capsule()
        watch = old.ControlledWatchdog(payload() + b'CI_PREVIEW_PREDICATE w=2 m=1\n', exit_code=1)
        code, stdout, stderr, escaped, _ = availability.FolderPreviewAvailabilityTests.main_call(self, root, watch)
        self.assertIsNone(escaped)
        self.assertEqual((code, stderr), (125, ''))
        self.assertEqual(stdout, '\n'.join(UNAVAILABLE + [
            'availability: boundary=17 parser=4 state=6 incoming=6']) + '\n')
        # Receipt refusal occurs before original parsing and cannot borrow plausible side data.
        root, _, _ = self.capsule()
        def refuse(receipt, output):
            receipt['captureComplete'] = False
            (output / 'status.json').write_text(json.dumps(receipt))
        watch = old.ControlledWatchdog(payload(), change=refuse)
        with mock.patch.object(runner, '_collect_predicate_observation', wraps=collect) as collector:
            code, stdout, stderr, escaped, _ = availability.FolderPreviewAvailabilityTests.main_call(self, root, watch)
            self.assertEqual(collector.call_count, 0)
        self.assertIsNone(escaped)
        self.assertEqual((code, stderr), (125, ''))
        self.assertEqual(stdout, '\n'.join(UNAVAILABLE + ['availability: boundary=14']) + '\n')


if __name__ == '__main__':
    unittest.main()
