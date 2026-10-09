"""Complete hidden joined-admission native suite; direct same-process watchdog.

No arguments, arbitrary filter, build-only mode or nested supervisor is allowed.
Adopt this file at Tests/SearchAdmissionJoinedNativeIntegration/run_harness.py
before execution. The isolated test host is macOS26; the public app stays macOS14.
"""
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import stat
import sys
import tempfile

RUNNER = 'Tests/SearchAdmissionJoinedNativeIntegration/run_harness.py'
PURE_TESTS = 'Tests/SearchAdmissionJoinedNativeIntegration/test_runner.py'
SHELL = 'scripts/test-search-admission-joined-native.sh'
COMMON = 'Tests/SearchChildIntegration/run_harness.py'
WATCHDOG = 'scripts/run-owned-search-tests.py'
NATIVE_CASES = {
    'Tests/SearchAdmissionJoinedNativeIntegration/NativeJoinedAdmissionTests.swift': (
        'NativeJoinedAdmissionTests', (
            'testJoinedObservationsReturnInsideBorrowWithResidualCredit',
            'testCaptureReentryRefusesBeforeModeOrReservationMutation',
            'testAccountingReentryRefusesBeforeCaptureAndLeavesConsumerUsable',
            'testDeliveryReentryRefusesWhileOuterCompletionIsLive',
            'testObservationReentryRefusesBeforeWorkerCallbackReturns',
            'testRetryScheduleReentryRefusesBeforeTokenInstallation',
            'testRetryCancelReentryRefusesWhileJoinedCloseSetupIsLive',
            'testInlineRetryFailureCancelReentryRefusesBeforeFailClosedReturns',
        )),
    'Tests/SearchAdmissionJoinedNativeIntegration/NativeJoinedRetirementTests.swift': (
        'NativeJoinedRetirementTests', (
            'testQueuedJoinedRequestObservesRetirementAfterDestructorReturns',
            'testQueuedLegacyRequestPreservesOriginalReceiptAfterDestructorReturns',
        )),
}
HARNESSES = (
    'Tests/SearchExecutionTests/SearchAdmissionTestHarness.swift',
    'Tests/SearchExecutionTests/SearchParentWireDriverTestHarness.swift',
    'Tests/SearchExecutionTests/SearchAdmissionJoinedTestHarness.swift',
)
# The reviewed27 tests are captured as provenance only, never compiled/selected.
PROVENANCE = 'Tests/SearchExecutionTests/SearchAdmissionJoinedShutdownTests.swift'
FIXED = (*NATIVE_CASES, *HARNESSES, PROVENANCE, RUNNER, PURE_TESTS, SHELL,
         COMMON, WATCHDOG, 'scripts/swift.sh', 'Package.swift')
EXPECTED_TESTS = tuple(cls + '.' + method for cls, methods in NATIVE_CASES.values()
                       for method in methods)
FILTER = 'NativeJoinedAdmissionTests|NativeJoinedRetirementTests'
OUTPUT_DIRECTORIES = ['Build', 'Runner/.cache']
PACKAGE = '''// swift-tools-version: 6.2
import PackageDescription
let package = Package(
  name: "SearchAdmissionJoinedNativeIntegration", platforms: [.macOS(.v26)],
  targets: [
    .target(name: "PadCore"),
    .target(name: "SearchExecution", dependencies: ["PadCore"]),
    .testTarget(name: "SearchExecutionTests", dependencies: ["PadCore", "SearchExecution"]),
  ], swiftLanguageModes: [.v5])
'''
ENTRYPOINT = '''#!/bin/sh
# Complete hidden native suite. Invoke directly; never nest another watchdog.
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec python3 "$repo_root/Tests/SearchAdmissionJoinedNativeIntegration/run_harness.py" "$@"
'''


def read_info(path):
    """Read declared source bytes and mode from the same non-symlink descriptor."""
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'rb') as source:
        metadata = os.fstat(source.fileno())
        if not stat.S_ISREG(metadata.st_mode):
            raise ValueError('source is not a regular file')
        return source.read(), stat.S_IMODE(metadata.st_mode)


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    data, _ = read_info(path)
    # Execute these source bytes directly; never use timestamp-valid stale pyc.
    exec(compile(data, str(path), 'exec'), module.__dict__)
    return module


def ensure_supported_host(system=None, version=None):
    system = platform.system() if system is None else system
    version = platform.mac_ver()[0] if version is None else version
    if system != 'Darwin' or not re.fullmatch(r'\d+(?:\.\d+){0,2}', version or ''):
        raise ValueError('macOS26 test host required for public Task.immediate; no tests skipped')
    if int(version.split('.')[0]) < 26:
        raise ValueError('macOS26 test host required for public Task.immediate; app floor remains macOS14')
    return dict(system=system, version=version)


def swift_code(text):
    """Mask comments/string contents before inspecting declarations and braces."""
    result = list(text)
    index = 0
    while index < len(text):
        end = None
        if text.startswith('//', index):
            end = text.find('\n', index)
            if end < 0:
                end = len(text)
        elif text.startswith('/*', index):
            cursor, depth = index + 2, 1
            while cursor < len(text) and depth:
                if text.startswith('/*', cursor):
                    depth += 1
                    cursor += 2
                elif text.startswith('*/', cursor):
                    depth -= 1
                    cursor += 2
                else:
                    cursor += 1
            if depth:
                raise ValueError('unterminated Swift comment')
            end = cursor
        elif text[index] == '"':
            delimiter = '"""' if text.startswith('"""', index) else '"'
            cursor = index + len(delimiter)
            while cursor < len(text):
                if text[cursor] == '\\':
                    cursor += 2
                elif text.startswith(delimiter, cursor):
                    cursor += len(delimiter)
                    end = cursor
                    break
                else:
                    cursor += 1
            if end is None:
                raise ValueError('unterminated Swift string')
        if end is None:
            index += 1
        else:
            for cursor in range(index, end):
                if result[cursor] != '\n':
                    result[cursor] = ' '
            index = end
    return ''.join(result)


def native_tests(text, relative):
    if relative not in NATIVE_CASES:
        raise ValueError('undeclared native module')
    code = swift_code(text)
    if re.search(r'#\s*(?:if|elseif|else|endif)\b|\bXCTSkip\w*\b', code):
        raise ValueError('conditional or skipped native tests refused')
    cls, required = NATIVE_CASES[relative]
    declarations = list(re.finditer(
        r'\bfinal\s+class\s+' + re.escape(cls) + r'\s*:\s*XCTestCase\s*\{', code))
    if len(declarations) != 1:
        raise ValueError('missing or duplicate required XCTest class')
    start = declarations[0].end()
    end, depth = start, 1
    while end < len(code) and depth:
        depth += (code[end] == '{') - (code[end] == '}')
        end += 1
    if depth:
        raise ValueError('unterminated native XCTest class')
    declared = re.findall(r'\bfunc\s+(test\w+)\s*\(', code)
    inside = re.findall(r'\bfunc\s+(test\w+)\s*\(', code[start:end - 1])
    if (len(declared) != len(set(declared)) or set(declared) != set(required)
            or sorted(inside) != sorted(required)):
        raise ValueError('missing, extra, misplaced or duplicate native method')
    return [cls + '.' + name for name in required]


def validate_tests(text, expected):
    if tuple(expected) != EXPECTED_TESTS or len(set(expected)) != 10:
        raise ValueError('native expected-test allowlist changed')

    def normalized(value):
        match = re.fullmatch(r'-\[SearchExecutionTests\.(\w+) (test\w+)\]', value)
        if match:
            return match[1] + '.' + match[2]
        return value.removeprefix('SearchExecutionTests.')

    starts = [normalized(value) for value in re.findall(r"Test Case '([^']+)' started\.", text)]
    passes = [normalized(value) for value in re.findall(r"Test Case '([^']+)' passed \(", text)]
    counts = re.findall(r'Executed (\d+) tests?, with (\d+) failures(?: \((\d+) unexpected\))?', text)
    if (sorted(starts) != sorted(expected) or sorted(passes) != sorted(expected)
            or len(starts) != 10 or len(passes) != 10 or not counts
            or tuple(map(int, counts[-1][:2])) != (10, 0)
            or any(not 0 < int(count) <= 10 or int(failed) or int(unexpected or '0')
                   for count, failed, unexpected in counts)
            or re.search(r"Test Case '[^']+' (?:failed|skipped)\b", text)
            or re.search(r'\b(?:XCTSkip\w*|skipped)\b|\berror:', text, re.IGNORECASE)):
        raise ValueError('incomplete, failed, skipped or nonunique actual XCTest execution')
    return 10


def validate_public_manifest(data):
    code = swift_code(data.decode('utf-8'))
    if (re.findall(r'\.macOS\s*\(\s*\.v(\d+)\s*\)', code) != ['14']
            or not re.search(r'\bswiftLanguageModes\s*:\s*\[\s*\.v5\s*\]', code)):
        raise ValueError('public macOS14/Swift5 manifest contract changed')


def frozen_name(relative):
    if relative.startswith('Sources/'):
        return 'Package/' + relative
    if relative in HARNESSES or relative in NATIVE_CASES:
        return 'Package/Tests/SearchExecutionTests/' + Path(relative).name
    return 'Runner/' + relative


def discover(root, common):
    paths = []
    for name in ('PadCore', 'SearchExecution'):
        directory = common.real_path(root, root / 'Sources' / name)
        if not directory.is_dir():
            raise ValueError('missing production source target')
        found = []
        for folder, directories, files in os.walk(directory, followlinks=False):
            for entry in directories + files:
                common.real_path(root, Path(folder) / entry)
            found.extend(Path(folder) / name for name in files if name.endswith('.swift'))
        if not found:
            raise ValueError('empty production source target')
        paths.extend(sorted(found))
    paths.extend(root / name for name in FIXED)
    if len(paths) != len(set(paths)):
        raise ValueError('duplicate source inventory')
    for source in paths:
        common.real_path(root, source)
        read_info(source)
    return paths


def tree_membership(run, prefix):
    directory = run / prefix
    if not directory.is_dir() or directory.is_symlink():
        raise ValueError('missing real frozen input tree')
    result = set()
    for folder, directories, files in os.walk(directory, followlinks=False):
        for kind, names in (('directory', directories), ('file', files)):
            for name in list(names):
                path = Path(folder) / name
                if path.is_symlink():
                    raise ValueError('symlink frozen input refused')
                if path.relative_to(run).as_posix() == 'Runner/.cache':
                    if kind != 'directory':
                        raise ValueError('declared compiler cache is not a real directory')
                    # The unchanged swift.sh owns these generated module caches.
                    # No other Runner path or Package path is exempt from input inventory.
                    directories.remove(name)
                    continue
                result.add((kind, path.relative_to(run).as_posix()))
    return result


def expected_membership(items, prefix):
    result = set()
    for item in items:
        name = Path(item['frozen'])
        if not name.is_relative_to(prefix):
            continue
        result.add(('file', name.as_posix()))
        for parent in name.parents:
            if parent == Path(prefix):
                break
            result.add(('directory', parent.as_posix()))
    return result


def freeze(root, run, common):
    paths = discover(root, common)
    items = []
    for source in paths:
        relative = source.relative_to(root).as_posix()
        data, mode = read_info(source)
        target = run / frozen_name(relative)
        target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        target.write_bytes(data)
        target.chmod(mode)
        items.append(dict(source=relative, frozen=target.relative_to(run).as_posix(),
                          sha256=common.digest(data), originSHA256=common.digest(data),
                          mode=mode, originMode=mode))
    package = run / 'Package/Package.swift'
    package.write_bytes(PACKAGE.encode('utf-8'))
    package.chmod(0o400)
    manifest = dict(version=2, sources=items, expectedTests=list(EXPECTED_TESTS),
                    nativeHostMinimum=26, publicDeploymentFloor=14,
                    outputDirectories=OUTPUT_DIRECTORIES.copy(),
                    generated=[dict(frozen='Package/Package.swift',
                                    sha256=common.digest(PACKAGE.encode('utf-8')), mode=0o400)])
    verify(root, run, manifest, common)
    metadata = run / 'sources.json'
    metadata.write_text(json.dumps(manifest, indent=2) + '\n')
    metadata.chmod(0o400)
    return manifest


def verify(root, run, manifest, common):
    if (not isinstance(manifest, dict) or set(manifest) != {
            'version', 'sources', 'generated', 'expectedTests',
            'nativeHostMinimum', 'publicDeploymentFloor', 'outputDirectories'}
            or type(manifest['version']) is not int or manifest['version'] != 2
            or type(manifest['nativeHostMinimum']) is not int or manifest['nativeHostMinimum'] != 26
            or type(manifest['publicDeploymentFloor']) is not int or manifest['publicDeploymentFloor'] != 14
            or manifest['expectedTests'] != list(EXPECTED_TESTS)
            or manifest['outputDirectories'] != OUTPUT_DIRECTORIES):
        raise ValueError('invalid native source manifest')
    sources = manifest['sources']
    paths = discover(root, common)
    if (not isinstance(sources, list)
            or [item.get('source') for item in sources] != [p.relative_to(root).as_posix() for p in paths]):
        raise ValueError('origin or protected source inventory changed')
    for item in sources:
        if (set(item) != {'source', 'frozen', 'sha256', 'originSHA256', 'mode', 'originMode'}
                or item['frozen'] != frozen_name(item['source'])
                or type(item['sha256']) is not str or not re.fullmatch(r'[0-9a-f]{64}', item['sha256'])
                or item['sha256'] != item['originSHA256']
                or type(item['mode']) is not int or not 0 <= item['mode'] <= 0o777
                or item['mode'] != item['originMode'] or type(item['originMode']) is not int):
            raise ValueError('source origin/hash/mode contract changed')
        frozen = common.real_path(run, run / item['frozen'])
        origin = common.real_path(root, root / item['source'])
        for path, expected_digest, expected_mode in (
                (frozen, item['sha256'], item['mode']),
                (origin, item['originSHA256'], item['originMode'])):
            data, mode = read_info(path)
            if common.digest(data) != expected_digest or mode != expected_mode:
                raise ValueError('frozen or origin bytes/mode changed')
        if item['source'] in NATIVE_CASES:
            native_tests(read_info(frozen)[0].decode('utf-8'), item['source'])
    generated = [dict(frozen='Package/Package.swift',
                      sha256=common.digest(PACKAGE.encode('utf-8')), mode=0o400)]
    if manifest['generated'] != generated:
        raise ValueError('generated native package declaration changed')
    for item in generated:
        data, mode = read_info(common.real_path(run, run / item['frozen']))
        if common.digest(data) != item['sha256'] or mode != item['mode']:
            raise ValueError('generated package bytes/mode changed')
    for relative in OUTPUT_DIRECTORIES:
        output = common.real_path(run, run / relative)
        if output.exists() and not output.is_dir():
            raise ValueError('declared toolchain output is not a real directory')
    for prefix in ('Package', 'Runner'):
        if tree_membership(run, prefix) != expected_membership(sources + generated, prefix):
            raise ValueError('frozen compiler or runner membership changed')
    common.verify_frozen(run, manifest)
    public = read_info(run / 'Runner/Package.swift')[0]
    validate_public_manifest(public)
    shell, mode = read_info(run / ('Runner/' + SHELL))
    if shell != ENTRYPOINT.encode('utf-8') or mode != 0o755:
        raise ValueError('frozen shell command or executable mode changed')


def execute(root, run, common, watchdog_main):
    result = dict(exit=125, stages=[], testsExecuted=None)
    try:
        result['host'] = ensure_supported_host()
        manifest_bytes, manifest_mode = read_info(run / 'sources.json')
        if manifest_mode != 0o400:
            raise ValueError('source manifest mode changed')
        manifest = json.loads(manifest_bytes)
        result['sourceManifestSHA256'] = common.digest(manifest_bytes)

        def checked_inputs():
            if read_info(run / 'sources.json') != (manifest_bytes, manifest_mode):
                raise ValueError('pinned source manifest bytes/mode changed')
            verify(root, run, manifest, common)

        swift = str(run / 'Runner/scripts/swift.sh')
        stages = (
            ('toolchain', 30, ['/usr/bin/xcrun', 'swift', '--version']),
            ('test', 240, [swift, 'test', '--package-path', str(run / 'Package'),
                           '--scratch-path', str(run / 'Build'), '--filter', FILTER]),
        )
        for name, seconds, command in stages:
            checked_inputs()
            output = run / name
            # Direct imported main, same process: exactly one session owner.
            # Never invoke this coordinator through another watchdog.
            code = watchdog_main(['--timeout', str(seconds), '--output', str(output), '--', *command])
            result['stages'].append(dict(name=name, exit=code))
            checked_inputs()
            if type(code) is not int or not 0 <= code < 256:
                raise ValueError('invalid stage return code')
            receipt = common.real_path(run, output / 'status.json')
            receipt_bytes = read_info(receipt)
            if not common.receipt_success(output, command, expected_code=code):
                raise ValueError('incomplete exact owned-process receipt')
            if read_info(receipt) != receipt_bytes:
                raise ValueError('owned-process receipt changed while inspected')
            if code != 0:
                result['exit'] = code
                return code
            text = ''.join(read_info(output / (stream + '.log'))[0].decode('utf-8')
                           for stream in ('stdout', 'stderr'))
            if re.search(r'\b(?:warning|error):', text, re.IGNORECASE):
                raise ValueError('compiler/toolchain diagnostics require review')
            if name == 'test':
                result['testsExecuted'] = validate_tests(text, manifest['expectedTests'])
        result['exit'] = 0
        return 0
    except (OSError, ValueError, TypeError, KeyError, AttributeError, UnicodeError) as error:
        result['failure'] = type(error).__name__ + ': ' + str(error)
        return 125
    finally:
        (run / 'status.json').write_text(json.dumps(result, indent=2) + '\n')


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv:
        raise SystemExit('No arguments/filters: run all ten methods directly, without a nested supervisor.')
    ensure_supported_host()
    root = Path(__file__).absolute().parents[2]
    if Path(__file__).absolute() != root / RUNNER:
        raise ValueError('private draft must be adopted at its declared public path before execution')
    common = load(root / COMMON, 'joined_native_live_common')
    parent = common.real_path(root, root / '.local/search-admission-joined-native')
    parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix='run.', dir=parent))
    print('Private joined-native evidence: ' + str(run), flush=True)
    try:
        freeze(root, run, common)
        frozen = load(run / ('Runner/' + RUNNER), 'joined_native_frozen_runner')
        frozen_common = load(run / ('Runner/' + COMMON), 'joined_native_frozen_common')
        watchdog = load(run / ('Runner/' + WATCHDOG), 'joined_native_frozen_watchdog')
        return frozen.execute(root, run, frozen_common, watchdog.main)
    except (OSError, ValueError, ImportError, TypeError, KeyError, AttributeError) as error:
        (run / 'status.json').write_text(json.dumps(
            dict(exit=125, failure=type(error).__name__ + ': ' + str(error))) + '\n')
        return 125


if __name__ == '__main__':
    raise SystemExit(main())
