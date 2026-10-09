"""Exactly two hidden native facade cases; one direct owned watchdog per stage.

Adopt at the declared repository paths before execution. This isolated macOS26
host does not change the public macOS14 floor or run a search helper/editor.
"""
from pathlib import Path
import ast
import hashlib
import importlib.util
import json
import os
import platform
import re
import stat
import sys
import tempfile

HERE = 'Tests/SearchAdmissionServiceNativeIntegration'
NATIVE = HERE + '/NativeAdmissionServiceTests.swift'
RUNNER = HERE + '/run_harness.py'
PURE = HERE + '/test_runner.py'
SHELL = 'scripts/test-search-admission-service-native.sh'
COMMON = 'Tests/SearchChildIntegration/run_harness.py'
WATCHDOG = 'scripts/run-owned-search-tests.py'
HARNESSES = (
    'Tests/SearchExecutionTests/SearchAdmissionServiceTestHarness.swift',
    'Tests/SearchExecutionTests/SearchAdmissionTestHarness.swift',
    'Tests/SearchExecutionTests/SearchAdmissionJoinedTestHarness.swift',
    'Tests/SearchExecutionTests/SearchParentWireDriverTestHarness.swift',
)
METHODS = ('testCaptureRefusalThroughFacadePreservesAdmission',
           'testJoinedFacadeInsideBorrowPreservesResidualCreditUntilRealReturn')
EXPECTED = tuple('NativeAdmissionServiceTests.' + name for name in METHODS)
FIXED = (NATIVE, *HARNESSES, RUNNER, PURE, SHELL, COMMON, WATCHDOG,
         'scripts/swift.sh', 'Package.swift')
EXEMPT = ('Build', 'Runner/.cache')
PACKAGE = '''// swift-tools-version: 6.2
import PackageDescription
let package = Package(
  name: "SearchAdmissionServiceNativeIntegration", platforms: [.macOS(.v26)],
  targets: [
    .target(name: "PadCore"),
    .target(name: "SearchExecution", dependencies: ["PadCore"]),
    .testTarget(name: "SearchExecutionTests", dependencies: ["PadCore", "SearchExecution"]),
  ], swiftLanguageModes: [.v5])
'''
ENTRYPOINT = '''#!/bin/sh
# Exact hidden native facade2. Invoke directly, without another watchdog.
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec python3 -B "$repo_root/Tests/SearchAdmissionServiceNativeIntegration/run_harness.py" "$@"
'''


def digest(data):
    return hashlib.sha256(data).hexdigest()


def real_path(root, path):
    root, path = Path(root), Path(path)
    if not root.is_absolute() or root.is_symlink() or not root.is_dir():
        raise ValueError('root must be an absolute real directory')
    for ancestor in (root, *root.parents):
        if ancestor.is_symlink():
            raise ValueError('symlink root ancestor refused')
    relative = path.relative_to(root)
    if '..' in relative.parts:
        raise ValueError('noncanonical input path')
    cursor = root
    for part in relative.parts:
        cursor = cursor / part
        if cursor.is_symlink():
            raise ValueError('symlink input component refused')
    return path


def read_file(path):
    if not Path(path).is_file() or Path(path).is_symlink():
        raise ValueError('input must be a regular nonsymlink file')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'rb') as source:
        before = os.fstat(source.fileno())
        if not stat.S_ISREG(before.st_mode):
            raise ValueError('input is not a regular file')
        data = source.read()
        after = os.fstat(source.fileno())
    if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_mode) != (
            after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_mode):
        raise ValueError('input changed during read')
    return data, stat.S_IMODE(after.st_mode)


def load(path, name):
    data, _ = read_file(Path(path))
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    # Execute pinned source bytes; never consult timestamp-valid bytecode.
    exec(compile(data, str(path), 'exec'), module.__dict__)
    return module


def ensure_supported_host(system=None, version=None):
    system = platform.system() if system is None else system
    version = platform.mac_ver()[0] if version is None else version
    if (type(system) is not str or type(version) is not str or system != 'Darwin'
            or not re.fullmatch(r'\d+(?:\.\d+){0,2}', version)
            or int(version.split('.')[0]) < 26):
        raise ValueError('macOS26 native test host required; no skips; public app floor remains macOS14')
    return dict(system=system, version=version)


def swift_code(text):
    """Mask nested comments and ordinary strings before examining declarations."""
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
                    end = cursor + len(delimiter)
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


def balanced_end(code, start):
    cursor, depth = start, 1
    while cursor < len(code) and depth:
        depth += (code[cursor] == '{') - (code[cursor] == '}')
        cursor += 1
    if depth:
        raise ValueError('unterminated Swift declaration body')
    return cursor


def native_tests(data):
    code = swift_code(data.decode('utf-8'))
    if re.search(r'#\s*(?:if|elseif|else|endif)\b|\bXCTSkip\w*\b', code):
        raise ValueError('conditional or skipped native source refused')
    classes = list(re.finditer(r'\bfinal\s+class\s+(\w+)\s*:\s*XCTestCase\s*\{', code))
    if len(classes) != 1 or classes[0][1] != 'NativeAdmissionServiceTests':
        raise ValueError('exact native XCTest class required')
    start = classes[0].end()
    end = balanced_end(code, start)
    all_methods = re.findall(r'\bfunc\s+(test\w+)\s*\(', code)
    signatures = list(re.finditer(r'\bfunc\s+(test\w+)\s*\(\s*\)\s+async\s+throws\s*\{',
                                  code[start:end - 1]))
    if (sorted(all_methods) != sorted(METHODS) or len(all_methods) != 2
            or sorted(match[1] for match in signatures) != sorted(METHODS)):
        raise ValueError('missing, extra, misplaced, duplicate or wrong-signature native method')
    for signature in signatures:
        body_start = start + signature.end()
        body_end = balanced_end(code, body_start)
        body = code[body_start:body_end - 1]
        if body_end > end or not re.search(r'\bXCTAssert\w*\s*\(', body):
            raise ValueError('empty or assertion-free native method refused')
    return list(EXPECTED)


def validate_public_manifest(data):
    code = swift_code(data.decode('utf-8'))
    if (re.findall(r'\.macOS\s*\(\s*\.v(\d+)\s*\)', code) != ['14']
            or not re.search(r'\bswiftLanguageModes\s*:\s*\[\s*\.v5\s*\]', code)):
        raise ValueError('public macOS14/Swift5 manifest contract changed')


def pure_names(data):
    tree = ast.parse(data)
    names = []
    for item in tree.body:
        if isinstance(item, ast.ClassDef):
            for method in item.body:
                if isinstance(method, (ast.FunctionDef, ast.AsyncFunctionDef)) and method.name.startswith('test_'):
                    if method.decorator_list:
                        raise ValueError('decorated pure control refused')
                    names.append('test_runner.' + item.name + '.' + method.name)
    if not names or len(names) != len(set(names)):
        raise ValueError('missing or duplicate pure control source')
    return sorted(names)


def discover(root):
    paths = []
    for target in ('PadCore', 'SearchExecution'):
        directory = real_path(root, root / 'Sources' / target)
        if not directory.is_dir():
            raise ValueError('missing production target')
        found = []
        for folder, directories, files in os.walk(directory, followlinks=False):
            for name in (*directories, *files):
                path = real_path(root, Path(folder) / name)
                if path.is_file() and path.suffix == '.swift':
                    found.append(path)
                elif not path.is_dir():
                    raise ValueError('unexpected production source member')
        if not found:
            raise ValueError('empty production target')
        paths.extend(sorted(found))
    paths.extend(root / name for name in FIXED)
    if len(paths) != len(set(paths)):
        raise ValueError('duplicate source origin')
    for path in paths:
        read_file(real_path(root, path))
    return paths


def destination(relative):
    if relative.startswith('Sources/'):
        return 'compiledProduction', 'Package/' + relative
    if relative in HARNESSES or relative == NATIVE:
        return 'compiledTests', 'Package/Tests/SearchExecutionTests/' + Path(relative).name
    return ('publicManifestProvenance' if relative == 'Package.swift' else 'runnerOnly',
            'Runner/' + relative)


def freeze(root, run):
    real_path(root, root)
    real_path(run, run)
    items = []
    for source in discover(root):
        relative = source.relative_to(root).as_posix()
        data, mode = read_file(source)
        if relative == NATIVE:
            native_tests(data)
        elif relative == 'Package.swift':
            validate_public_manifest(data)
        role, name = destination(relative)
        target = run / name
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        target.write_bytes(data)
        target.chmod(mode)
        items.append(dict(source=relative, origin=str(source), frozen=name, role=role,
                          sha256=digest(data), bytes=len(data), mode=mode))
    package = run / 'Package/Package.swift'
    package.write_bytes(PACKAGE.encode())
    package.chmod(0o400)
    pure, _ = read_file(root / PURE)
    manifest = dict(version=1, root=str(root), sources=items,
                    generated=[dict(frozen='Package/Package.swift', sha256=digest(PACKAGE.encode()),
                                    mode=0o400, bytes=len(PACKAGE.encode()))],
                    expectedTests=list(EXPECTED), expectedPure=pure_names(pure),
                    nativeHostMinimum=26, publicDeploymentFloor=14, exempt=list(EXEMPT))
    metadata = run / 'sources.json'
    metadata.write_text(json.dumps(manifest, indent=2) + '\n')
    metadata.chmod(0o400)
    verify(run, manifest)
    return manifest


def membership(run):
    result = set()
    for top in ('Package', 'Runner'):
        directory = real_path(run, run / top)
        if not directory.is_dir():
            raise ValueError('missing frozen input tree')
        for folder, directories, files in os.walk(directory, followlinks=False):
            for name in (*directories, *files):
                path = real_path(run, Path(folder) / name)
                relative = path.relative_to(run).as_posix()
                if relative == 'Runner/.cache':
                    if not path.is_dir():
                        raise ValueError('cache exemption is not a real directory')
                    directories.remove(name)
                    continue
                if not path.is_file() and not path.is_dir():
                    raise ValueError('nonregular frozen member')
                result.add(('directory' if path.is_dir() else 'file', relative))
    return result


def verify(run, manifest):
    if (not isinstance(manifest, dict) or set(manifest) != {
            'version', 'root', 'sources', 'generated', 'expectedTests', 'expectedPure',
            'nativeHostMinimum', 'publicDeploymentFloor', 'exempt'}
            or type(manifest['version']) is not int or manifest['version'] != 1
            or type(manifest['nativeHostMinimum']) is not int or manifest['nativeHostMinimum'] != 26
            or type(manifest['publicDeploymentFloor']) is not int or manifest['publicDeploymentFloor'] != 14
            or manifest['expectedTests'] != list(EXPECTED) or manifest['exempt'] != list(EXEMPT)):
        raise ValueError('native source manifest schema/policy changed')
    root = Path(manifest['root'])
    real_path(run, run)
    for name in EXEMPT:
        path = real_path(run, run / name)
        if path.exists() and not path.is_dir():
            raise ValueError('declared generated root is not a real directory')
    paths = discover(root)
    if [p.relative_to(root).as_posix() for p in paths] != [i['source'] for i in manifest['sources']]:
        raise ValueError('origin membership changed')
    expected = set()
    for item in manifest['sources']:
        relative = item['source']
        role, name = destination(relative)
        if (set(item) != {'source', 'origin', 'frozen', 'role', 'sha256', 'bytes', 'mode'}
                or item['origin'] != str(root / relative) or item['role'] != role or item['frozen'] != name
                or type(item['sha256']) is not str or not re.fullmatch(r'[0-9a-f]{64}', item['sha256'])
                or type(item['mode']) is not int or not 0 <= item['mode'] <= 0o777
                or type(item['bytes']) is not int or item['bytes'] < 0
                or any(name == e or name.startswith(e + '/') for e in EXEMPT)):
            raise ValueError('compiler/runner origin/hash/mode relationship changed')
        original, mode = read_file(real_path(root, root / relative))
        data, copied_mode = read_file(real_path(run, run / name))
        if (digest(original) != item['sha256'] or len(original) != item['bytes']
                or mode != item['mode'] or data != original or copied_mode != mode):
            raise ValueError('frozen or origin bytes/mode changed')
        if relative == NATIVE:
            native_tests(data)
        elif relative == 'Package.swift':
            validate_public_manifest(data)
        expected.add(('file', name))
    wanted = [dict(frozen='Package/Package.swift', sha256=digest(PACKAGE.encode()),
                   mode=0o400, bytes=len(PACKAGE.encode()))]
    if manifest['generated'] != wanted or read_file(run / 'Package/Package.swift') != (PACKAGE.encode(), 0o400):
        raise ValueError('generated native manifest relationship changed')
    expected.add(('file', 'Package/Package.swift'))
    for _, name in list(expected):
        for parent in Path(name).parents:
            if parent.as_posix() == '.':
                break
            expected.add(('directory', parent.as_posix()))
    expected.difference_update(('directory', name) for name in ('Package', 'Runner'))
    if membership(run) != expected:
        raise ValueError('complete frozen input membership changed')
    if manifest['expectedPure'] != pure_names(read_file(root / PURE)[0]):
        raise ValueError('pure control inventory changed')
    if read_file(run / ('Runner/' + SHELL)) != (ENTRYPOINT.encode(), 0o755):
        raise ValueError('exact adopted shell/executable mode changed')


def reject_diagnostics(text):
    if re.search(r'\b(?:warning|error|fatal error):|\b(?:skipped|XCTSkip\w*)\b', text, re.I):
        raise ValueError('warning/error/skip requires review')


def validate_tests(text, expected):
    if tuple(expected) != EXPECTED:
        raise ValueError('exact native2 allowlist changed')
    reject_diagnostics(text)
    def normalize(value):
        match = re.fullmatch(r'-\[SearchExecutionTests\.(\w+) (test\w+)\]', value)
        return match[1] + '.' + match[2] if match else value.removeprefix('SearchExecutionTests.')
    starts = [normalize(n) for n in re.findall(r"Test Case '([^']+)' started\.", text)]
    passes = [normalize(n) for n in re.findall(r"Test Case '([^']+)' passed \(", text)]
    counts = re.findall(r'Executed (\d+) tests?, with (\d+) failures(?: \((\d+) unexpected\))?', text)
    if (sorted(starts) != sorted(EXPECTED) or sorted(passes) != sorted(EXPECTED)
            or len(starts) != 2 or len(passes) != 2 or not counts or int(counts[-1][0]) != 2
            or any(not 0 < int(count) <= 2 or int(failed) or int(unexpected or 0)
                   for count, failed, unexpected in counts)
            or re.search(r"Test Case '[^']+' (?:failed|skipped)", text)
            or re.search(r'native modal loop required emergency release|deadline release is never'
                         r'|actual native fixture event missing|registered immediate task has no retained handle', text)):
        raise ValueError('incomplete unique native2 execution or failed native cleanup')
    return 2


def validate_pure(text, expected):
    lines = re.findall(r'^(test_\w+) \((test_runner\.\w+(?:\.test_\w+)?)\) \.\.\. ok$', text, re.M)
    names = [owner if owner.endswith('.' + method) else owner + '.' + method for method, owner in lines]
    summaries = re.findall(r'^Ran (\d+) tests? in ', text, re.M)
    if (not expected or sorted(names) != sorted(expected) or len(summaries) != 1
            or int(summaries[0]) != len(expected) or not re.search(r'^OK$', text, re.M)
            or re.search(r'\b(?:ERROR|FAIL|skipped|warning|error):?|\bunexpected success\b', text)):
        raise ValueError('incomplete pure controls')
    return len(expected)


def stage_logs(output, common, command):
    if not common.receipt_success(output, command, expected_code=0):
        raise ValueError('incomplete genuine expected-zero receipt')
    stdout, _ = read_file(real_path(output, output / 'stdout.log'))
    stderr, _ = read_file(real_path(output, output / 'stderr.log'))
    return stdout.decode('utf-8'), stderr.decode('utf-8')


def bundle_inventory(run, bundle):
    real_path(run, bundle)
    if not bundle.is_dir():
        raise ValueError('missing actual XCTest bundle')
    entries = []
    for folder, directories, files in os.walk(bundle, followlinks=False):
        for name in sorted((*directories, *files)):
            path = real_path(run, Path(folder) / name)
            if path.is_dir():
                entries.append(dict(path=path.relative_to(bundle).as_posix(), directory=True,
                                    mode=stat.S_IMODE(path.stat().st_mode)))
            else:
                data, mode = read_file(path)
                entries.append(dict(path=path.relative_to(bundle).as_posix(), sha256=digest(data),
                                    bytes=len(data), mode=mode))
    return sorted(entries, key=lambda i: i['path'])


def bind_artifact(run, binpath, manifest_hash, build_receipt_hash):
    lines = binpath.splitlines()
    if len(lines) != 1 or not lines[0] or '\0' in lines[0]:
        raise ValueError('invalid compiler bin-path output')
    directory = Path(lines[0])
    if not directory.is_absolute() or '..' in directory.parts:
        raise ValueError('noncanonical compiler bin-path')
    directory.relative_to(run / 'Build')
    real_path(run, directory)
    name = 'SearchAdmissionServiceNativeIntegrationPackageTests'
    bundle = directory / (name + '.xctest')
    executable = bundle / 'Contents/MacOS' / name
    data, mode = read_file(real_path(run, executable))
    if not data or not mode & 0o111:
        raise ValueError('missing executable native XCTest artifact')
    return dict(bundle=str(bundle), executable=str(executable), executableSHA256=digest(data),
                executableMode=mode, sourceManifestSHA256=manifest_hash,
                buildReceiptSHA256=build_receipt_hash, members=bundle_inventory(run, bundle))


def verify_artifact(run, artifact, manifest_hash, build_receipt_hash):
    if (artifact['sourceManifestSHA256'] != manifest_hash
            or artifact['buildReceiptSHA256'] != build_receipt_hash):
        raise ValueError('artifact source/build receipt binding changed')
    bundle = Path(artifact['bundle'])
    bundle.relative_to(run / 'Build')
    executable = Path(artifact['executable'])
    if executable != bundle / 'Contents/MacOS/SearchAdmissionServiceNativeIntegrationPackageTests':
        raise ValueError('artifact executable origin changed')
    data, mode = read_file(real_path(run, executable))
    if (digest(data) != artifact['executableSHA256'] or mode != artifact['executableMode']
            or bundle_inventory(run, bundle) != artifact['members']):
        raise ValueError('actual native XCTest artifact changed')


def stages(run):
    wrapper = str(run / 'Runner/scripts/swift.sh')
    def swift(action, *args):
        return [wrapper, action, '--package-path', str(run / 'Package'),
                '--scratch-path', str(run / 'Build'), *args]
    return (
        ('pure', 60, [sys.executable, '-B', '-m', 'unittest', 'discover', '-v', '-s',
                      str(run / ('Runner/' + HERE)), '-p', 'test_runner.py']),
        ('toolchain', 30, ['/usr/bin/xcrun', 'swift', '--version']),
        ('build-tests', 240, swift('build', '--build-tests')),
        ('bin-path', 30, swift('build', '--show-bin-path')),
        ('native2', 240, swift('test', '--filter', 'NativeAdmissionServiceTests')),
    )


def execute(run, common, watchdog_main):
    result = dict(exit=125, stages=[], nativeTests=None,
                  searchHelperExecutionStageIncluded=False, shownWindowStageIncluded=False)
    artifact = None
    accepted_outputs = {}
    try:
        host = ensure_supported_host()
        result['host'] = host
        manifest_bytes, manifest_mode = read_file(run / 'sources.json')
        if manifest_mode != 0o400:
            raise ValueError('unsealed native source manifest')
        manifest = json.loads(manifest_bytes)
        manifest_hash = digest(manifest_bytes)
        result['sourceManifestSHA256'] = manifest_hash
        build_receipt_hash = None
        def checked():
            if ensure_supported_host() != host:
                raise ValueError('native host binding changed')
            if read_file(run / 'sources.json') != (manifest_bytes, manifest_mode):
                raise ValueError('sealed native source manifest changed')
            verify(run, manifest)
            for path, pin in accepted_outputs.items():
                if read_file(real_path(run, path)) != pin:
                    raise ValueError('accepted stage receipt/capture/metadata changed')
            if artifact is not None:
                verify_artifact(run, artifact, manifest_hash, build_receipt_hash)
        for name, seconds, command in stages(run):
            checked()
            output = run / 'Stages' / name
            output.parent.mkdir(mode=0o700, exist_ok=True)
            # Sole same-process session owner. Never nest an outer watchdog.
            code = watchdog_main(['--timeout', str(seconds), '--output', str(output), '--', *command])
            result['stages'].append(dict(name=name, command=command, exit=code, expectedExit=0))
            checked()
            if type(code) is not int or code != 0:
                raise ValueError('stage failed its genuine expected exit: ' + name)
            stdout, stderr = stage_logs(output, common, command)
            for leaf in ('status.json', 'stdout.log', 'stderr.log'):
                path = output / leaf
                accepted_outputs[path] = read_file(real_path(run, path))
            text = stdout + '\n' + stderr
            reject_diagnostics(text)
            if name == 'pure':
                result['pureTests'] = validate_pure(text, manifest['expectedPure'])
            elif name == 'build-tests':
                build_receipt_hash = digest(read_file(output / 'status.json')[0])
            elif name == 'bin-path':
                artifact = bind_artifact(run, stdout, manifest_hash, build_receipt_hash)
                path = run / 'artifact.json'
                path.write_text(json.dumps(artifact, indent=2) + '\n')
                accepted_outputs[path] = read_file(path)
            elif name == 'native2':
                result['nativeTests'] = validate_tests(text, manifest['expectedTests'])
            checked()
        result['exit'] = 0
        return 0
    except (OSError, ValueError, TypeError, KeyError, AttributeError, UnicodeError, ImportError) as error:
        result['failure'] = type(error).__name__ + ': ' + str(error)
        return 125
    finally:
        (run / 'status.json').write_text(json.dumps(result, indent=2) + '\n')


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv:
        raise SystemExit('No arguments accepted: exact native2 stages only, without another watchdog.')
    root = Path(__file__).absolute().parents[2]
    if Path(__file__).absolute() != root / RUNNER:
        raise ValueError('private draft must be adopted at declared paths before execution')
    ensure_supported_host()
    parent = real_path(root, root / '.local/search-admission-service-native')
    parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix='run.', dir=parent))
    print('Private native facade evidence: ' + str(run), flush=True)
    try:
        freeze(root, run)
        runner = load(run / ('Runner/' + RUNNER), 'frozen_native_service_runner')
        common = load(run / ('Runner/' + COMMON), 'frozen_native_service_common')
        watchdog = load(run / ('Runner/' + WATCHDOG), 'frozen_native_service_watchdog')
        return runner.execute(run, common, watchdog.main)
    except (OSError, ValueError, TypeError, KeyError, AttributeError, ImportError, UnicodeError) as error:
        (run / 'status.json').write_text(json.dumps(dict(exit=125, failure=type(error).__name__)) + '\n')
        return 125


if __name__ == '__main__':
    raise SystemExit(main())
