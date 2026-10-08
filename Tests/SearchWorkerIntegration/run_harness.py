"""Freeze and verify the real fixed helper; each stage directly owns its watchdog.

No editor launch, private pilot, replacement engine, or nested process watchdog.
"""
import argparse
import difflib
import errno
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import tempfile


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# Reuse the accepted source-tree and typed owned-receipt checks unchanged.
SHARED = load_module('worker_shared_checks', Path(__file__).parents[1] / 'SearchChildIntegration/run_harness.py')
PACKAGE = '''// swift-tools-version: 6.0
import PackageDescription
let package = Package(
  name: "SearchWorkerIntegration", platforms: [.macOS(.v14)],
  products: [.executable(name: "PadSearchWorker", targets: ["PadSearchWorker"])],
  targets: [
    .target(name: "PadCore"),
    .target(name: "SearchExecution", dependencies: ["PadCore"]),
    .target(name: "PadSearchWorkerRuntime", dependencies: ["PadCore", "SearchExecution"]),
    .executableTarget(name: "PadSearchWorker", dependencies: ["PadSearchWorkerRuntime", "SearchExecution"]),
    .testTarget(name: "SearchWorkerIntegrationTests", dependencies: ["SearchExecution", "PadCore"]),
  ], swiftLanguageModes: [.v5])
'''
CASES = {
    'unicode-find': 'testUnicodeFindUsesLiteralUTF16Ranges',
    'capture-replace': 'testRegexCaptureReplacementUsesRealEngine',
    'exact-preservation': 'testNoMatchReplacementPreservesEveryLiteralCodeUnit',
    'semantic-reuse': 'testSemanticErrorThenHealthyRequestUsesSameGeneration',
    'empty-fragmented': 'testEmptyThenFragmentedSupplementaryReplacement',
}
FIXED = (
    'Sources/PadSearchWorker/PadSearchWorkerMain.swift', 'Package.swift',
    'Tests/SearchWorkerIntegration/RealSearchWorkerTests.swift',
    'Tests/SearchWorkerIntegration/run_harness.py', 'Tests/SearchWorkerIntegration/test_runner.py',
    'Tests/SearchChildIntegration/run_harness.py', 'scripts/swift.sh',
    'scripts/run-owned-search-tests.py', 'scripts/test-search-worker.sh',
)

# A literal graph gate, not execution of the Swift manifest. Fail closed on a
# dynamic manifest or an unreviewed graph; retain both whole manifests and diff.
PUBLIC_PACKAGE = '''// swift-tools-version: 6.0
import PackageDescription
let package = Package(
  name: "TheOnlyPad", platforms: [.macOS(.v14)],
  products: [
    .library(name: "PadCore", targets: ["PadCore"]),
    .executable(name: "TheOnlyPad", targets: ["TheOnlyPad"]),
    .executable(name: "PadSearchWorker", targets: ["PadSearchWorker"]),
  ],
  targets: [
    .target(name: "PadCore"),
    .target(name: "SearchExecution", dependencies: ["PadCore"]),
    .target(name: "PadSearchWorkerRuntime", dependencies: ["PadCore", "SearchExecution"]),
    .testTarget(name: "PadSearchWorkerRuntimeTests", dependencies: ["PadSearchWorkerRuntime", "PadCore", "SearchExecution"]),
    .executableTarget(name: "TheOnlyPad", dependencies: ["PadCore"]),
    .testTarget(name: "PadCoreTests", dependencies: ["PadCore"]),
    .testTarget(name: "SearchExecutionTests", dependencies: ["SearchExecution", "PadCore"]),
    .executableTarget(name: "PadSearchWorker", dependencies: ["PadSearchWorkerRuntime", "SearchExecution"]),
  ], swiftLanguageModes: [.v5])
'''


def literal_package(text):
    lines = text.splitlines()
    if not lines or not re.fullmatch(r'//\s*swift-tools-version:\s*6\.0\s*', lines[0]):
        raise ValueError('unreviewed Swift tools version')
    source = '\n'.join(lines[1:])
    pattern = re.compile(r'\s+|"(?:[^"\\]|\\.)*"|[A-Za-z_][A-Za-z_0-9]*|[.=:,()\[\]]')
    tokens, cursor = [], 0
    for match in pattern.finditer(source):
        if match.start() != cursor:
            raise ValueError('manifest is not a reviewed literal recipe')
        cursor = match.end()
        if not match.group().isspace(): tokens.append(match.group())
    if cursor != len(source): raise ValueError('unsupported manifest suffix')
    position = 0
    def pop(expected=None):
        nonlocal position
        if position >= len(tokens): raise ValueError('incomplete literal manifest')
        value = tokens[position]; position += 1
        if expected is not None and value != expected: raise ValueError('unexpected manifest token')
        return value
    def peek():
        return tokens[position] if position < len(tokens) else None
    def arguments():
        pop('('); result = []
        while peek() != ')':
            key = None
            if position + 1 < len(tokens) and tokens[position + 1] == ':':
                key = pop(); pop(':')
            result.append((key, value()))
            if peek() != ',': break
            pop(',')
        pop(')')
        return result
    def value():
        token = pop()
        if token.startswith('"'): return json.loads(token)
        if token == '[':
            items = []
            while peek() != ']':
                items.append(value())
                if peek() != ',': break
                pop(',')
            pop(']'); return items
        if token == '.':
            name = pop()
            return dict(call=name, args=arguments()) if peek() == '(' else dict(member=name)
        raise ValueError('nonliteral package value')
    for expected in ('import', 'PackageDescription', 'let', 'package', '=', 'Package'): pop(expected)
    result = arguments()
    if peek() is not None: raise ValueError('extra manifest statements')
    return result


def verify_public_recipe(text):
    actual, expected = dict(literal_package(text)), dict(literal_package(PUBLIC_PACKAGE))
    if len(actual) != len(literal_package(text)):
        raise ValueError('duplicate package fields')
    # Product/target declaration order is not semantic; all other literal fields
    # and each target's dependency order/arguments remain exact.
    for key in ('products', 'targets'):
        actual[key] = sorted(actual.get(key, []), key=lambda item: json.dumps(item, sort_keys=True))
        expected[key] = sorted(expected[key], key=lambda item: json.dumps(item, sort_keys=True))
    if actual != expected:
        raise ValueError('public helper product/target recipe differs from reviewed graph')


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument('--build-only', action='store_true')
    selection.add_argument('--case', choices=tuple(CASES))
    parser.add_argument('--application-bundle', type=Path,
                        help='test the existing final nested helper selected by the production resolver')
    return parser.parse_args(argv)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def discover(root):
    sources = []
    for module in ('PadCore', 'SearchExecution', 'PadSearchWorkerRuntime'):
        folder = SHARED.real_path(root, root / 'Sources' / module)
        if not folder.is_dir():
            raise ValueError('missing production source target')
        files = sorted(folder.glob('*.swift'))
        if not files:
            raise ValueError('empty production source target')
        sources.extend(files)
    sources.extend(root / name for name in FIXED)
    for path in sources:
        SHARED.real_path(root, path)
        if not path.is_file():
            raise ValueError('missing source file: ' + str(path.relative_to(root)))
    return sources


def freeze(root, run):
    root, run = Path(root), Path(run)
    paths = discover(root)  # Entire required inventory admitted before any dispatch.
    public = SHARED.read_source(root / 'Package.swift').decode('utf-8')
    verify_public_recipe(public)
    rows = []
    for source in paths:
        name = source.relative_to(root).as_posix()
        if name.startswith('Sources/'):
            frozen = 'Package/' + name
        elif name == 'Tests/SearchWorkerIntegration/RealSearchWorkerTests.swift':
            frozen = 'Package/Tests/SearchWorkerIntegrationTests/RealSearchWorkerTests.swift'
        else:
            frozen = 'Runner/' + name
        target = run / frozen
        target.parent.mkdir(parents=True, exist_ok=True)
        data = SHARED.read_source(source)
        target.write_bytes(data)
        mode = 0o500 if source.suffix == '.sh' else 0o400
        target.chmod(mode)
        rows.append(dict(source=name, frozen=frozen, sha256=digest(data), mode=mode))
    if discover(root) != paths:
        raise ValueError('source membership changed during freeze')
    for row in rows:
        if digest(SHARED.read_source(SHARED.real_path(root, root / row['source']))) != row['sha256']:
            raise ValueError('source bytes changed during freeze')
    package = run / 'Package/Package.swift'
    package.write_text(PACKAGE)
    package.chmod(0o400)
    difference = ''.join(difflib.unified_diff(public.splitlines(True), PACKAGE.splitlines(True),
                         fromfile='public/Package.swift', tofile='integration/Package.swift'))
    diff_path = run / 'Runner/package-derivation.diff'
    diff_path.write_text(difference); diff_path.chmod(0o400)
    manifest = dict(version=1, sources=rows, generated=[dict(
        frozen='Package/Package.swift', sha256=digest(package.read_bytes()), mode=0o400), dict(
        frozen='Runner/package-derivation.diff', sha256=digest(diff_path.read_bytes()), mode=0o400)],
        recipe='literal public graph verified; helper closure retained; app and old tests omitted; integration test target added')
    path = run / 'sources.json'
    path.write_text(json.dumps(manifest, indent=2) + '\n')
    path.chmod(0o400)
    verify_inputs(run, manifest, digest(path.read_bytes()))
    return manifest


def verify_inputs(run, manifest, manifest_hash):
    if digest((run / 'sources.json').read_bytes()) != manifest_hash:
        raise ValueError('source manifest changed')
    SHARED.verify_frozen(run, manifest)
    for row in manifest['sources'] + manifest['generated']:
        path = SHARED.real_path(run, run / row['frozen'])
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != row['mode']:
            raise ValueError('frozen input mode/type changed')


def regular_file(path, *, executable=False):
    path = Path(path)
    if not path.is_absolute() or '..' in path.parts:
        raise ValueError('noncanonical artifact path')
    SHARED.real_path(Path(path.anchor), path)
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or (executable and not info.st_mode & 0o111):
        raise ValueError('artifact must be regular and executable')
    data = SHARED.read_source(path)
    if executable and not data:
        raise ValueError('empty executable')
    return dict(path=str(path), bytes=len(data), mode=stat.S_IMODE(info.st_mode), sha256=digest(data))


def tree_snapshot(root):
    root = Path(root)
    SHARED.real_path(Path(root.anchor), root)
    if not root.is_dir():
        raise ValueError('missing artifact tree')
    rows = []
    for folder, directories, files in os.walk(root, followlinks=False):
        for name in sorted(directories + files):
            path = Path(folder) / name
            info = path.lstat()
            relative = path.relative_to(root).as_posix()
            if stat.S_ISDIR(info.st_mode):
                rows.append(dict(relative=relative, type='directory', mode=stat.S_IMODE(info.st_mode)))
            elif stat.S_ISREG(info.st_mode):
                item = regular_file(path)
                item.pop('path')
                rows.append(dict(relative=relative, type='file', **item))
            else:
                raise ValueError('symlink or special artifact refused')
    return dict(root=str(root), mode=stat.S_IMODE(root.stat().st_mode), rows=sorted(rows, key=lambda x: x['relative']))


def write_record(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')
    path.chmod(0o400)
    return digest(path.read_bytes())


def binary_directory(run, output, folder):
    lines = (output / 'stdout.log').read_text().splitlines()
    if len(lines) != 1 or not lines[0] or '\0' in lines[0]:
        raise ValueError('invalid release binary directory')
    path = Path(lines[0])
    if not path.is_absolute() or '..' in path.parts:
        raise ValueError('noncanonical release directory')
    path.relative_to(run / folder)
    SHARED.real_path(run, path)
    if not path.is_dir():
        raise ValueError('missing release directory')
    return path


def pin_helper(run, directory, source_hash, bundle):
    built = regular_file(directory / 'PadSearchWorker', executable=True)
    copied = run / 'Build/FrozenHelper/PadSearchWorker'
    copied.parent.mkdir(mode=0o700, parents=True)
    copied.write_bytes(SHARED.read_source(Path(built['path'])))
    copied.chmod(0o500)
    copy_pin = regular_file(copied, executable=True)
    if copy_pin['sha256'] != built['sha256']:
        raise ValueError('helper copy mismatch')
    artifact = dict(version=1, sourceManifestSHA256=source_hash, mode='built',
                    executable=str(copied), sha256=copy_pin['sha256'], applicationBundle=None)
    support = dict(built=built, copied=copy_pin, packaged=None)
    if bundle is not None:
        bundle = Path(bundle)
        if not bundle.is_absolute() or '..' in bundle.parts or bundle.suffix != '.app':
            raise ValueError('packaged mode requires canonical absolute .app path')
        selected = regular_file(bundle / 'Contents/Helpers/PadSearchWorker', executable=True)
        support['packaged'] = tree_snapshot(bundle)
        artifact.update(mode='packaged', executable=selected['path'], sha256=selected['sha256'],
                        applicationBundle=str(bundle))
    helper_hash = write_record(run / 'helper.json', artifact)
    support_hash = write_record(run / 'helper-artifacts.json', support)
    return artifact, helper_hash, support, support_hash


def verify_helper(run, helper_hash, support, support_hash):
    if digest((run / 'helper.json').read_bytes()) != helper_hash:
        raise ValueError('helper selection changed')
    if digest((run / 'helper-artifacts.json').read_bytes()) != support_hash:
        raise ValueError('helper evidence changed')
    for key in ('built', 'copied'):
        old = support[key]
        if regular_file(Path(old['path']), executable=True) != old:
            raise ValueError('helper artifact changed')
    if set((run / 'Build/FrozenHelper').iterdir()) != {run / 'Build/FrozenHelper/PadSearchWorker'}:
        raise ValueError('extra frozen helper entry')
    if support['packaged'] is not None and tree_snapshot(Path(support['packaged']['root'])) != support['packaged']:
        raise ValueError('packaged artifact changed')


def pin_test_bundle(run, directory):
    bundle = directory / 'SearchWorkerIntegrationPackageTests.xctest'
    binary = regular_file(bundle / 'Contents/MacOS/SearchWorkerIntegrationPackageTests', executable=True)
    value = dict(executable=binary, bundle=tree_snapshot(bundle))
    return value, write_record(run / 'test-bundle.json', value)


def verify_test_bundle(run, value, pinned):
    if digest((run / 'test-bundle.json').read_bytes()) != pinned:
        raise ValueError('test bundle evidence changed')
    if regular_file(Path(value['executable']['path']), executable=True) != value['executable']:
        raise ValueError('test executable changed')
    if tree_snapshot(Path(value['bundle']['root'])) != value['bundle']:
        raise ValueError('test bundle changed')


def verify_test_output(output, method):
    text = (output / 'stdout.log').read_text() + (output / 'stderr.log').read_text()
    # Require actual XCTest method identities, not a generic positive summary.
    identities = re.findall(r"Test Case '-\[SearchWorkerIntegrationTests\.RealSearchWorkerTests ([A-Za-z0-9_]+)\]' (started|passed|failed)", text)
    if identities != [(method, 'started'), (method, 'passed')]:
        raise ValueError('wrong or incomplete selected XCTest method')
    counts = re.findall(r'Executed (\d+) tests?, with (\d+) failures', text)
    if not counts or any(pair != ('1', '0') for pair in counts):
        raise ValueError('selected method did not execute exactly once without failure')
    receipts = re.findall(r'^WORKER-SETTLED generation=([A-F0-9-]{36}) pid=([1-9][0-9]*) exit=(exited:0|signaled:9) reaps=1 signals=([01]) released=1$', text, re.MULTILINE)
    if len(receipts) != 1:
        raise ValueError('missing exact helper settlement summary')
    generation, pid, exit_status, signals = receipts[0]
    if generation == '00000000-0000-0000-0000-000000000000' or (exit_status == 'signaled:9' and signals != '1'):
        raise ValueError('invalid helper settlement summary')
    signal_rows = re.findall(r'^WORKER-SIGNAL generation=([A-F0-9-]{36}) pid=([1-9][0-9]*) signal=([0-9]+) result=([0-9]+)$', text, re.MULTILINE)
    if len(signal_rows) != int(signals) or any(
            item[0] != generation or item[1] != pid or item[2] != '9'
            or int(item[3]) not in (0, errno.ESRCH) for item in signal_rows):
        raise ValueError('uncorrelated helper signal record')
    if exit_status == 'signaled:9' and not any(item[3] == '0' for item in signal_rows):
        raise ValueError('signal exit lacks a successful owned signal record')
    return dict(method=method, generation=generation, pid=int(pid), exit=exit_status,
                signals=[dict(signal=int(item[2]), result=int(item[3])) for item in signal_rows])


def execute(run, options, watchdog_main):
    run = Path(run)
    result = dict(version=1, exit=125, setupComplete=False, testsPassed=[], stages=[],
                  buildOnly=options.build_only, mode='packaged' if options.application_bundle else 'built')
    helper = support = test_bundle = None
    helper_hash = support_hash = bundle_hash = None
    try:
        manifest = json.loads((run / 'sources.json').read_text())
        manifest_hash = digest((run / 'sources.json').read_bytes())
        result['sourceManifestSHA256'] = manifest_hash
        common = ['--configuration', 'release', '--package-path', str(run / 'Package'),
                  '--scratch-path', str(run / 'Build')]
        helper_common = ['--configuration', 'release', '--package-path', str(run / 'Package'),
                         '--scratch-path', str(run / 'HelperBuild')]
        swift = str(run / 'Runner/scripts/swift.sh')
        stages = [('toolchain', 30, ['/usr/bin/xcrun', 'swift', '--version']),
                  ('build-helper', 240, [swift, 'build', *helper_common, '--product', 'PadSearchWorker']),
                  ('binpath', 30, [swift, 'build', *helper_common, '--show-bin-path']),
                  ('build-tests', 240, [swift, 'build', *common, '--build-tests', '-Xswiftc', '-enable-testing']),
                  ('test-binpath', 30, [swift, 'build', *common, '--show-bin-path'])]
        if not options.build_only:
            selected = [options.case] if options.case else list(CASES)
            stages += [('test-' + case, 90, [swift, 'test', *common, '--skip-build', '--filter',
                         'RealSearchWorkerTests/' + CASES[case]]) for case in selected]
        directory = None
        for stage, timeout, command in stages:
            verify_inputs(run, manifest, manifest_hash)
            if helper is not None: verify_helper(run, helper_hash, support, support_hash)
            if test_bundle is not None: verify_test_bundle(run, test_bundle, bundle_hash)
            output = run / stage
            code = watchdog_main(['--timeout', str(timeout), '--output', str(output), '--', *command])
            result['stages'].append(dict(name=stage, exit=code, command=command))
            verify_inputs(run, manifest, manifest_hash)
            if helper is not None: verify_helper(run, helper_hash, support, support_hash)
            if test_bundle is not None: verify_test_bundle(run, test_bundle, bundle_hash)
            if type(code) is not int or code != 0:
                result['exit'] = code if type(code) is int and 0 < code < 256 else 125
                return result['exit']
            if not SHARED.receipt_success(output, command):
                raise ValueError('incomplete owned stage receipt')
            if stage == 'binpath':
                directory = binary_directory(run, output, 'HelperBuild')
                helper, helper_hash, support, support_hash = pin_helper(run, directory, manifest_hash, options.application_bundle)
                result['helperManifestSHA256'] = helper_hash
                result['helperArtifactsSHA256'] = support_hash
            elif stage == 'test-binpath':
                test_directory = binary_directory(run, output, 'Build')
                test_bundle, bundle_hash = pin_test_bundle(run, test_directory)
                result['testBundleSHA256'] = bundle_hash
                result['setupComplete'] = True
            elif stage.startswith('test-'):
                case = stage.removeprefix('test-')
                result['testsPassed'].append(verify_test_output(output, CASES[case]))
        result['exit'] = 0
        return 0
    except (OSError, ValueError, TypeError, KeyError) as error:
        result['failure'] = dict(type=type(error).__name__, reason=str(error))
        return 125
    finally:
        write_record(run / 'status.json', result)


def main(argv=None):
    options = parse_args(argv)
    root = Path(__file__).absolute().parents[2]
    parent = SHARED.real_path(root, root / '.local/search-worker-integration')
    parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix='run.', dir=parent))
    print('Private real-helper evidence: ' + str(run), flush=True)
    try:
        freeze(root, run)
        watchdog = load_module('frozen_worker_watchdog', run / 'Runner/scripts/run-owned-search-tests.py')
        return execute(run, options, watchdog.main)
    except (OSError, ValueError, TypeError, ImportError) as error:
        write_record(run / 'status.json', dict(version=1, exit=125, setupComplete=False,
                     testsPassed=[], stages=[], failure=dict(type=type(error).__name__, reason=str(error))))
        return 125


if __name__ == '__main__':
    raise SystemExit(main())
