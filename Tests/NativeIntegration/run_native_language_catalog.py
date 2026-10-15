"""Fixed Foundation catalog-owner regression; each stage owns its direct watchdog."""
from pathlib import Path
import hashlib
import importlib.util
import json
import math
import os
import re
import shlex
import stat
import sys
import uuid

HERE = Path(__file__).absolute().parent
CLASS = 'NativeLanguageCatalogOwnerTests.NativeLanguageCatalogOwnerTests'
MUTATION_CLASS = 'NativeLanguageCatalogOwnerTests.NativeLanguageCatalogMutationTests'
GENERATED = 'NativeLanguageCatalogPackageTests'
OWNER = 'Sources/TheOnlyPad/NativeLanguageCatalogOwner.swift'
MUTATION = 'Sources/TheOnlyPad/NativeLanguageCatalogMutation.swift'
WIRE = 'Tests/PadCoreTests/CatalogTestFixture.swift'
TESTS = ('NativeLanguageCatalogOwnerTests.swift', 'NativeLanguageCatalogOwnerFixtures.swift')
MUTATION_TESTS = ('NativeLanguageCatalogMutationTests.swift', 'NativeLanguageCatalogMutationFixtures.swift')
SUPPORT = ('native-language-catalog-methods.json', 'native-language-catalog-mutation-methods.json', 'native-language-catalog-Package.swift')
LOCATION = 'Tests/NativeIntegration/run_native_language_catalog.py'
WATCH_SHA = 'd5bd867e4a65b4ee053209fe0a5822867b8d0878fd6d059f474c9b28a0f6286d'
FIELDS = set('command pid processGroup exitObserved registrationError groupSignalAttempted groupSignalError groupCleanup groupQuery waitCompleted returnCode waitError timedOut interruptedSignal truncated captureComplete failure exit captured seconds'.split())


def require(value, message):
    if not value: raise ValueError(message)


def checked(root, path, directory=False):
    root, path = Path(root).absolute(), Path(path).absolute()
    require(path.is_relative_to(root) and '..' not in path.parts, 'path outside declared root')
    for cursor in [root, *[root.joinpath(*path.relative_to(root).parts[:i]) for i in range(1, len(path.relative_to(root).parts) + 1)]]:
        require(not stat.S_ISLNK(cursor.lstat().st_mode), 'symlink refused')
    require(stat.S_ISDIR(path.lstat().st_mode) if directory else stat.S_ISREG(path.lstat().st_mode), 'wrong input kind')
    return path


def fact(root, path):
    path = checked(root, path); fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        with os.fdopen(fd, 'rb', closefd=False) as stream: data = stream.read()
        after = os.fstat(fd); named = path.lstat()
        fields = ('st_dev', 'st_ino', 'st_uid', 'st_mode', 'st_size', 'st_mtime_ns', 'st_ctime_ns')
        require(stat.S_ISREG(before.st_mode) and all(getattr(before, k) == getattr(after, k) == getattr(named, k) for k in fields), 'input changed while read')
        require(len(data) == after.st_size, 'short input read')
        return dict(path=str(path.relative_to(root)), sha256=hashlib.sha256(data).hexdigest(), **{k: getattr(after, k) for k in fields}), data
    finally: os.close(fd)


def load(root, path):
    def unique(pairs):
        value = {}
        for key, item in pairs:
            require(key not in value, 'duplicate JSON key'); value[key] = item
        return value
    return json.loads(fact(root, path)[1], object_pairs_hook=unique)


def save(path, value):
    with path.open('x') as stream: json.dump(value, stream, indent=2); stream.write('\n')


def mkdir(root, path):
    checked(root, root, True)
    for i in range(1, len(path.relative_to(root).parts) + 1):
        part = root.joinpath(*path.relative_to(root).parts[:i])
        if not part.exists(): part.mkdir(mode=0o700)
        checked(root, part, True)
        require(part.stat().st_uid == os.geteuid() and stat.S_IMODE(part.stat().st_mode) == 0o700, 'owned root must be0700')


def directory_fact(root, path):
    checked(root, path, True); info = path.lstat()
    require(info.st_uid == os.geteuid(), 'foreign directory owner')
    return dict(path=str(path.relative_to(root)), directory=True, device=info.st_dev, inode=info.st_ino, uid=info.st_uid, mode=stat.S_IMODE(info.st_mode))


def tree(root, path):
    checked(root, path, True); rows = []
    for entry in [path, *sorted(path.rglob('*'))]:
        checked(root, entry, entry.is_dir()); info = entry.lstat()
        require(info.st_uid == os.geteuid(), 'foreign owner in frozen tree')
        rows.append(directory_fact(root, entry) if entry.is_dir() else fact(root, entry)[0])
    return rows


def support():
    old = load(HERE, HERE / SUPPORT[0]); new = load(HERE, HERE / SUPPORT[1]); package = fact(HERE, HERE / SUPPORT[2])[1].decode()
    for name, methods in (('old14', old), ('new31', new)):
        expected = 14 if name == 'old14' else 31
        require(isinstance(methods, list) and len(methods) == expected and len(set(methods)) == expected and all(type(x) is str and re.fullmatch(r'test\w+', x) for x in methods), 'invalid fixed ' + name + ' roster')
    return old, new, package


def build_plan(root, run):
    old, new, package = support()
    core = sorted((root / 'Sources/PadCore').glob('*.swift'))
    require(bool(core) and core == sorted((root / 'Sources/PadCore').rglob('*.swift')), 'Core membership missing or nested')
    sources = {str(p.relative_to(root)): 'Package/Sources/PadCore/' + p.name for p in core}
    sources[OWNER] = 'Package/Sources/NativeLanguageCatalogComponent/NativeLanguageCatalogOwner.swift'
    sources[MUTATION] = 'Package/Sources/NativeLanguageCatalogComponent/NativeLanguageCatalogMutation.swift'
    sources[WIRE] = 'Package/Tests/NativeLanguageCatalogOwnerTests/CatalogTestFixture.swift'
    sources.update({'Tests/NativeIntegration/' + name: 'Package/Tests/NativeLanguageCatalogOwnerTests/' + name for name in (*TESTS, *MUTATION_TESTS)})
    for relative in sources: checked(root, root / relative)
    common = ['--package-path', str(run / 'Package'), '--scratch-path', str(run / 'BuildProducts')]
    swift = str(run / 'ToolSupport/scripts/swift.sh')
    selections = {'old14': {'class': CLASS, 'methods': old}, 'new31': {'class': MUTATION_CLASS, 'methods': new}}
    commands = [('toolchain', 30, ['/usr/bin/xcrun', 'swift', '--version']),
                ('build', 180, [swift, 'build', *common, '--build-tests', '-Xswiftc', '-warnings-as-errors']),
                ('binpath', 30, [swift, 'build', *common, '--show-bin-path', '-Xswiftc', '-warnings-as-errors']),
                ('old14', 180, ['/usr/bin/xcrun', 'xctest', '-XCTest', CLASS, str(run / 'BuildProducts/arm64-apple-macosx/debug' / (GENERATED + '.xctest'))]),
                ('new31', 180, ['/usr/bin/xcrun', 'xctest', '-XCTest', MUTATION_CLASS, str(run / 'BuildProducts/arm64-apple-macosx/debug' / (GENERATED + '.xctest'))])]
    return dict(selection=CLASS, methods=old, selections=selections, package=package, swiftInputs=sources, tools={
        'scripts/swift.sh': 'ToolSupport/scripts/swift.sh', 'scripts/run-owned-search-tests.py': 'Runner/run-owned-search-tests.py',
        'Tests/NativeIntegration/run_native_regressions.py': 'Runner/receipt-verifier.py', LOCATION: 'Runner/run_native_language_catalog.py'},
        stages=[dict(name=n, timeout=t, command=['/usr/bin/env', 'THEONLYPAD_STATE_DIRECTORY=' + str(run / 'State' / n), 'TMPDIR=' + str(run / 'Temporary' / n), *c]) for n, t, c in commands], captureAfter='binpath')


def validate_cli(argv):
    require(argv == [], 'fixed command accepts no arguments')


def parse_result(raw, exit_code, selection='old14'):
    old, new, _ = support()
    require(selection in ('old14', 'new31'), 'unknown fixed selection')
    class_name, methods = (CLASS, old) if selection == 'old14' else (MUTATION_CLASS, new)
    text = raw.decode('utf-8') if isinstance(raw, bytes) else raw
    expected = {'-[' + class_name + ' ' + name + ']' for name in methods}
    starts = re.findall(r"^Test Case '([^']+)' started\.$", text, re.M)
    ends = re.findall(r"^Test Case '([^']+)' (passed|failed|skipped) \([^\n]*\)\.$", text, re.M)
    require(len(starts) == len(methods) and set(starts) == expected, 'wrong/missing/repeated starts')
    require(len(ends) == len(methods) and {n for n, _ in ends} == expected and all(v != 'skipped' for _, v in ends), 'incomplete/foreign/skipped finishes')
    require(len(re.findall(r'^Test Case .*$', text, re.M)) == 2 * len(methods), 'unparsed case record')
    for identity, outcome in ends: require(text.index("Test Case '" + identity + "' started.") < text.index("Test Case '" + identity + "' " + outcome), 'finish before start')
    summary = re.findall(r'Executed (\d+) tests?, with (\d+) failures? \((\d+) unexpected\)', text)
    require(bool(summary), 'missing actual summary'); count, failures, unexpected = map(int, summary[-1])
    failed = sum(v == 'failed' for _, v in ends)
    require(count == len(methods) and unexpected == 0 and failures >= failed and bool(failures) == bool(failed), 'inconsistent/unexpected failures')
    require(type(exit_code) is int and exit_code == (1 if failures else 0), 'natural exit/result mismatch')
    require(not failures or 'XCTAssert' in text or ': failed - ' in text, 'ordinary failure evidence missing')
    result = dict(executed=count, failures=failures, exit=exit_code, methods=methods, observed=ends, unexpected=unexpected)
    if selection == 'new31': result['selection'] = selection
    return result


def validate_compiler_graph(run, binary):
    require(binary == run / 'BuildProducts/arm64-apple-macosx/debug', 'foreign binary path')
    description = binary / 'description.json'; commands = load(run, description).get('swiftCommands')
    names = ('PadCore', 'NativeLanguageCatalogComponent', 'NativeLanguageCatalogOwnerTests', GENERATED)
    require(isinstance(commands, dict) and len(commands) == 4, 'wrong compiler census'); groups = {}
    for row in commands.values():
        require(isinstance(row, dict) and row.get('moduleName') in names and row['moduleName'] not in groups, 'foreign/duplicate module'); groups[row['moduleName']] = row
    require(set(groups) == set(names), 'missing compiler module'); paths = {description}; objects = set(); graph = []
    for module in names:
        row = groups[module]
        prefix = 'Tests' if module == names[2] else 'Sources'
        sources = [binary / (GENERATED + '.derived/runner.swift')] if module == GENERATED else sorted((run / 'Package' / prefix / module).glob('*.swift'))
        require(bool(sources) and row.get('sources') is not None and sorted(row['sources']) == sorted(map(str, sources)), 'compiler source roster differs')
        expected = [binary / (module + '.build') / (source.name + '.o') for source in sources]
        require(len(set(expected)) == len(expected) and sorted(row.get('objects', [])) == sorted(map(str, expected)), 'compiler object pairing differs')
        require(sorted((binary / (module + '.build')).rglob('*.o')) == sorted(expected), 'foreign module object')
        filelist = binary / (module + '.build/sources'); outputmap = binary / (module + '.build/output-file-map.json')
        require(row.get('fileList') == str(filelist) and row.get('outputFileMapPath') == str(outputmap), 'foreign map path')
        require(sorted(shlex.split(fact(run, filelist)[1].decode())) == sorted(map(str, sources)), 'compiler filelist differs')
        mapping = load(run, outputmap); require(isinstance(mapping, dict) and set(mapping) == {'', *map(str, sources)}, 'output map census differs')
        for source, obj in zip(sources, expected): require(mapping[str(source)].get('object') == str(obj), 'output map pairing differs')
        args = row.get('otherArguments'); require(isinstance(args, list) and all(type(x) is str for x in args), 'bad compiler arguments')
        for flag, value in [('-target', 'arm64-apple-macosx14.0'), *([] if module == GENERATED and '-swift-version' not in args else [('-swift-version', '5')])]:
            require(args.count(flag) == 1 and args.index(flag) + 1 < len(args) and args[args.index(flag) + 1] == value, 'compiler target/language differs')
        require(args.count('-warnings-as-errors') == 1, 'warnings-as-errors missing')
        companions = sorted((binary / 'Modules').glob(module + '.*')); require(binary / 'Modules' / (module + '.swiftmodule') in companions, 'module missing')
        paths.update([*expected, filelist, outputmap, *companions]); objects.update(expected)
        if module == GENERATED:
            require(sorted((binary / (GENERATED + '.derived')).rglob('*.swift')) == sources, 'foreign generated source'); paths.update(sources)
        graph.append(dict(module=module, sources=list(map(str, sources)), objects=list(map(str, expected))))
    require(set(binary.rglob('*.o')) == objects, 'foreign object outside modules')
    require(all(any(p.name.startswith(n + '.') for n in names) for p in (binary / 'Modules').iterdir()), 'foreign module companion')
    link = binary / (GENERATED + '.product/Objects.LinkFileList'); linked = shlex.split(fact(run, link)[1].decode())
    require(len(linked) == len(objects) and set(linked) == set(map(str, objects)), 'linked object union differs/duplicates')
    paths.add(link)
    for path in paths: checked(run, path)
    return paths, graph


def validate_declarations(root, methods, class_name, filename):
    path = root / ('Tests/NativeIntegration/' + filename)
    text = fact(root, path)[1].decode('utf-8')
    classes = re.findall(r'^\s*(?:@MainActor\s+)?final\s+class\s+(\w+)(?:\s*:\s*XCTestCase)?\s*\{', text, re.M)
    require(classes == [class_name.rsplit('.', 1)[1]], 'wrong fixed test class declaration')
    declarations = re.findall(r'^\s*func\s+(test\w+)\s*\(', text, re.M)
    require(len(declarations) == len(methods) and len(set(declarations)) == len(methods) and declarations == methods, 'test declarations differ from fixed roster')


def freeze(root, run, plan):
    require(Path(__file__).absolute() == root / LOCATION, 'run only the fixed public coordinator')
    old, new, _ = support()
    validate_declarations(root, old, CLASS, TESTS[0])
    validate_declarations(root, new, MUTATION_CLASS, MUTATION_TESTS[0])
    inputs = dict(plan['swiftInputs']); inputs.update(plan['tools'])
    inputs.update({'Tests/NativeIntegration/' + name: 'Runner/' + name for name in SUPPORT})
    inputs['scripts/test-native-language-catalog.sh'] = 'Runner/test-native-language-catalog.sh'
    require(len(set(inputs.values())) == len(inputs), 'duplicate frozen destination'); originals = []; copies = []
    for source, destination in inputs.items():
        original, data = fact(root, root / source); originals.append(original)
        for relative in ('Original/' + source, destination):
            target = run / relative; mkdir(run, target.parent)
            with target.open('xb') as stream: stream.write(data)
            target.chmod(stat.S_IMODE(original['st_mode'])); copies.append(fact(run, target)[0])
        require(fact(root, root / source)[0] == original, 'source changed during freeze')
    for source, methods, class_name in ((TESTS[0], old, CLASS), (MUTATION_TESTS[0], new, MUTATION_CLASS)):
        frozen = fact(run, run / plan['swiftInputs']['Tests/NativeIntegration/' + source])[1].decode('utf-8')
        require(re.findall(r'^\s*(?:@MainActor\s+)?final\s+class\s+(\w+)(?:\s*:\s*XCTestCase)?\s*\{', frozen, re.M) == [class_name.rsplit('.', 1)[1]], 'frozen Test class differs')
        declarations = re.findall(r'^\s*func\s+(test\w+)\s*\(', frozen, re.M)
        require(declarations == methods and len(set(declarations)) == len(methods), 'frozen Test roster differs')
    require(fact(run, run / 'Runner/run-owned-search-tests.py')[0]['sha256'] == WATCH_SHA, 'unreviewed watchdog')
    target = run / 'Package/Package.swift'
    with target.open('x') as stream: stream.write(plan['package'])
    copies.append(fact(run, target)[0])
    for row in plan['stages']:
        for parent in ('State', 'Temporary'): mkdir(run, run / parent / row['name'])
    manifest = dict(originals=originals, copies=copies, plan=plan, ownedDirectories=[directory_fact(run, run / name) for name in ('.', 'ToolSupport', 'State', 'Temporary', *[parent + '/' + row['name'] for row in plan['stages'] for parent in ('State', 'Temporary')])], trees={name: tree(run, run / name) for name in ('Original', 'Package', 'Runner', 'ToolSupport/scripts')})
    save(run / 'inputs.json', manifest); return manifest


def verify_inputs(root, run, manifest):
    require(build_plan(root, run) == manifest['plan'], 'public membership/plan changed')
    for row in manifest['originals']: require(fact(root, root / row['path'])[0] == row, 'original input changed')
    for row in manifest['copies']: require(fact(run, run / row['path'])[0] == row, 'frozen input changed')
    for name, rows in manifest['trees'].items(): require(tree(run, run / name) == rows, 'frozen membership/identity changed')
    require(load(run, run / 'inputs.json') == manifest, 'input manifest changed')
    top = run / 'ToolSupport'; require({p.name for p in top.iterdir()} <= {'scripts', '.cache'}, 'unexpected ToolSupport member')
    for row in manifest['ownedDirectories']:
        require(directory_fact(run, run / row['path']) == row, 'owned root identity changed')
    if any(p.name == '.cache' for p in top.iterdir()):
        cache = checked(run, top / '.cache', True)
        for path in [cache, *cache.rglob('*')]:
            checked(run, path, path.is_dir()); require(path.lstat().st_uid == os.geteuid(), 'foreign cache entry')


def import_module(path, name):
    spec = importlib.util.spec_from_file_location(name, path); module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module; spec.loader.exec_module(module); return module


def stage(root, run, manifest, execute, verifier, row, receipts):
    verify_inputs(root, run, manifest); output = run / row['name']
    require(not output.exists(), 'stage already exists')
    command_dir = run / 'Commands'; mkdir(run, command_dir)
    command_path = command_dir / (row['name'] + '.json')
    save(command_path, dict(name=row['name'], timeout=row['timeout'], command=row['command']))
    command_fact = fact(run, command_path)[0]
    receipts.append(command_fact)
    code = execute(['--timeout', str(row['timeout']), '--output', str(output), '--', *row['command']])
    require(fact(run, command_path)[0] == command_fact, 'current command changed during child')
    verify_inputs(root, run, manifest); receipt = load(run, output / 'status.json')
    require(isinstance(receipt, dict) and set(receipt) == FIELDS, 'receipt schema differs')
    require(type(receipt['seconds']) in (int, float) and math.isfinite(receipt['seconds']) and receipt['seconds'] >= 0, 'invalid elapsed seconds')
    require(verifier.receipt_success(output, row['command'], code), 'incomplete direct owned receipt')
    require(set(receipt['captured']) == {'stdout', 'stderr'} and all(set(v) == {'stored', 'received', 'discarded'} for v in receipt['captured'].values()), 'capture schema differs')
    return code


def capture(run):
    lines = fact(run, run / 'binpath/stdout.log')[1].decode().splitlines()
    require(lines == [str(run / 'BuildProducts/arm64-apple-macosx/debug')], 'ambiguous binpath')
    binary = Path(lines[0]); paths, graph = validate_compiler_graph(run, binary)
    bundle = binary / (GENERATED + '.xctest'); members = tree(run, bundle)
    executable = bundle / 'Contents/MacOS' / GENERATED
    require(os.access(checked(run, executable), os.X_OK), 'nonexecutable test bundle')
    paths.update(run / row['path'] for row in members if not row.get('directory'))
    paths.update(run / stage_name / file for stage_name in ('toolchain', 'build', 'binpath') for file in ('status.json', 'stdout.log', 'stderr.log'))
    return dict(graph=graph, bundle=members, artifacts=[fact(run, path)[0] for path in sorted(paths)], inputManifest=fact(run, run / 'inputs.json')[0])


def main(argv):
    validate_cli(argv); root = HERE.parents[1]
    require(Path(__file__).absolute() == root / LOCATION, 'fixed public path required')
    local = root / '.local'
    if not local.exists(): local.mkdir(mode=0o700)
    checked(root, local, True); require(local.stat().st_uid == os.geteuid(), 'foreign local owner')
    base = local / 'native-language-catalog-integration'; mkdir(local, base)
    run = base / ('run.' + str(uuid.uuid4())); run.mkdir(mode=0o700); print(run, flush=True)
    result = dict(state='INCOMPLETE', exit=125, stages=[]); manifest = None; binding = None; receipts = []
    try:
        plan = build_plan(root, run); manifest = freeze(root, run, plan); verify_inputs(root, run, manifest)
        execute = import_module(run / 'Runner/run-owned-search-tests.py', 'catalog_watchdog').main
        verifier = import_module(run / 'Runner/receipt-verifier.py', 'catalog_receipts'); verify_inputs(root, run, manifest)
        for row in plan['stages']:
            for prior in receipts: require(fact(run, run / prior['path'])[0] == prior, 'prior command/receipt/capture changed')
            if binding is not None:
                artifacts_file = run / 'artifacts.json'
                require(load(run, artifacts_file) == binding and capture(run) == binding, 'compiled artifact changed before test')
            code = stage(root, run, manifest, execute, verifier, row, receipts); result['stages'].append(dict(name=row['name'], exit=code))
            receipts.extend(fact(run, run / row['name'] / name)[0] for name in ('status.json', 'stdout.log', 'stderr.log'))
            if row['name'] not in ('old14', 'new31') and code != 0:
                result.update(state='NATURAL_STAGE_FAILURE', exit=code); break
            if row['name'] == 'build':
                compiler_log = fact(run, run / 'build/stdout.log')[1] + fact(run, run / 'build/stderr.log')[1]
                require(re.search(rb'(?m)(?:^|\s)warning:', compiler_log) is None, 'compiler/build warning retained')
            if row['name'] == 'binpath':
                binding = capture(run); save(run / 'artifacts.json', binding)
                receipts.append(fact(run, run / 'artifacts.json')[0])
            if row['name'] in ('old14', 'new31'):
                selection = row['name']; raw = fact(run, run / selection / 'stdout.log')[1] + b'\n' + fact(run, run / selection / 'stderr.log')[1]
                report = parse_result(raw, code, selection=selection); save(run / (selection + '-result.json'), report)
                receipts.append(fact(run, run / (selection + '-result.json'))[0])
                result['stages'][-1]['result'] = selection + '-result.json'
                if selection == 'old14' and code != 0:
                    result.update(state='OLD14_FAILED_NEW31_UNENTERED', exit=1); break
                if selection == 'new31':
                    result.update(state='COMPLETE_PASS' if code == 0 else 'COMPLETE_ORDINARY_FAILURE', exit=code)
    except (OSError, ValueError, TypeError, KeyError, AttributeError, IndexError, OverflowError) as error:
        result.update(state='INCOMPLETE', exit=125, errorType=type(error).__name__, error=str(error))
    finally:
        try:
            for prior in receipts: require(fact(run, run / prior['path'])[0] == prior, 'command/receipt/capture changed after stage')
            if manifest is not None: verify_inputs(root, run, manifest)
            if binding is not None:
                require(load(run, run / 'artifacts.json') == binding and capture(run) == binding, 'postcapture artifact authority changed')
            result['postflightVerified'] = manifest is not None
        except (OSError, ValueError, TypeError, KeyError, AttributeError) as error:
            result.update(state='POSTFLIGHT_FAILED', exit=125, postflightVerified=False, postflightError=str(error))
        result['stateDirectoryEntries'] = sorted(str(p.relative_to(run)) for p in (run / 'State').rglob('*')) if (run / 'State').exists() else []
        save(run / 'result.json', result)
    return result['exit']


if __name__ == '__main__':
    sys.dont_write_bytecode = True
    try: raise SystemExit(main(sys.argv[1:]))
    except (OSError, ValueError) as error:
        print('catalog runner refused: ' + str(error), file=sys.stderr); raise SystemExit(125)
