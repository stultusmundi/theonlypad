"""Fixed construction/compiler contracts; direct owned watchdog, no search helper.

No command-line selection, transformed production source, or alternate supervisor.
An exit of zero covers the fixed stages below. The separately reviewed eager-entry
mutation remains a companion gate; this coordinator does not manufacture it.
"""
from pathlib import Path
import ast
import hashlib
import importlib.util
import json
import os
import re
import stat
import sys
import tempfile

HERE = 'Tests/SearchAdmissionServiceIntegration'
NEGATIVES = ('ForbiddenLegacy', 'ForbiddenController', 'ForbiddenDriver',
             'ForbiddenDriverInitializer', 'ForbiddenControllerInitializer')
CONSTRUCTION = (
    'testAbsentBundleConstructsAndJoinedClosePreservesResidentCharge',
    'testInvalidBundleURLsPropagateResolverInvalidURL',
    'testMissingFixedHelperDeliversActualLaunchFailedENOENTWithoutFallback',
    'testActualParentConstructionDoesNotEnterInjectedLauncherBeforeBegin',
)
TASK1_TESTS = (
    'testConsumersShareControllerAndForwardQueueCancellation',
    'testLeaseBorrowPreservesContextAndReleaseInvalidates',
    'testActiveCancelAndUnregisterUseExactConsumerAndHandle',
    'testRawParentRefusalAndFreshSettlementAreForwarded',
    'testUnsupportedAndLegacyControllerRefusalsAreForwarded',
    'testMatchingCancelledFacadeCallersShareActualOwner',
)
TASK1 = (
    'Tests/SearchExecutionTests/SearchAdmissionServiceTests.swift',
    'Tests/SearchExecutionTests/SearchAdmissionServiceTestHarness.swift',
    'Tests/SearchExecutionTests/SearchAdmissionTestHarness.swift',
    'Tests/SearchExecutionTests/SearchAdmissionJoinedTestHarness.swift',
    'Tests/SearchExecutionTests/SearchParentWireDriverTestHarness.swift',
)
FIXED = (*TASK1, HERE + '/SearchAdmissionServiceConstructionTests.swift',
         *(HERE + '/Fixtures/' + name + '.swift' for name in ('AllowedClient', *NEGATIVES)),
         HERE + '/run_harness.py', HERE + '/test_runner.py',
         'scripts/test-search-admission-service.sh', 'scripts/swift.sh',
         'Tests/SearchChildIntegration/run_harness.py',
         'scripts/run-owned-search-tests.py', 'Package.swift')
PACKAGES = ('Package', *('Compiler/' + name for name in NEGATIVES))
EXEMPT = ('Build', 'Runner/.cache')
PACKAGE = '''// swift-tools-version: 6.0
import PackageDescription
let package = Package(
  name: "SearchAdmissionServiceIntegration", platforms: [.macOS(.v14)],
  targets: [
    .target(name: "PadCore"),
    .target(name: "SearchExecution", dependencies: ["PadCore"]),
    .target(name: "AllowedClient", dependencies: ["PadCore", "SearchExecution"]),
%s    .testTarget(name: "SearchExecutionTests", dependencies: ["PadCore", "SearchExecution"]),
  ], swiftLanguageModes: [.v5])
'''


def digest(data):
    return hashlib.sha256(data).hexdigest()


def load(path, name):
    """Execute the declared Python bytes directly, without consulting a pyc."""
    data, _ = read_file(Path(path))
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    exec(compile(data, str(path), 'exec'), module.__dict__)
    return module


def real_path(root, path):
    root, path = Path(root), Path(path)
    if not root.is_absolute() or root.is_symlink() or not root.is_dir():
        raise ValueError('root must be an absolute real directory')
    # Check ancestors too: a symlinked worktree/evidence parent is not admitted.
    for ancestor in (root, *root.parents):
        if ancestor.is_symlink():
            raise ValueError('symlink root ancestor refused')
    relative = path.relative_to(root)
    if '..' in relative.parts:
        raise ValueError('noncanonical relative input')
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
        real_path(root, path)
        read_file(path)
    return paths


def destinations(relative):
    if relative.startswith('Sources/'):
        return [('compiledProduction', package + '/' + relative) for package in PACKAGES]
    if relative in TASK1 or relative == HERE + '/SearchAdmissionServiceConstructionTests.swift':
        return [('compiledTests', package + '/Tests/SearchExecutionTests/' + Path(relative).name)
                for package in PACKAGES]
    if relative == HERE + '/Fixtures/AllowedClient.swift':
        return [('ordinaryCompilerClient', package + '/Sources/AllowedClient/AllowedClient.swift')
                for package in PACKAGES]
    if relative.startswith(HERE + '/Fixtures/'):
        name = Path(relative).stem
        if name not in NEGATIVES:
            raise ValueError('unknown compiler fixture')
        return [('ordinaryCompilerClient', 'Compiler/' + name + '/Sources/ForbiddenClient/' + name + '.swift')]
    return [('publicManifestProvenance' if relative == 'Package.swift' else 'runnerOnly',
             'Runner/' + relative)]


def generated():
    return {package + '/Package.swift': (PACKAGE % (
        '' if package == 'Package' else
        '    .target(name: "ForbiddenClient", dependencies: ["PadCore", "SearchExecution"]),\n'
    )).encode() for package in PACKAGES}


def named_methods(data, expected):
    text = data.decode('utf-8')
    names = re.findall(r'\bfunc\s+(test\w+)\s*\(', text)
    if (sorted(names) != sorted(expected) or len(names) != len(set(names))
            or re.search(r'\bXCTSkip\b|^\s*#if\b', text, re.M)):
        raise ValueError('missing, conditional, skipped or duplicate method source')


def pure_names(data):
    tree = ast.parse(data)
    names = []
    for item in tree.body:
        if isinstance(item, ast.ClassDef):
            for method in item.body:
                if isinstance(method, (ast.FunctionDef, ast.AsyncFunctionDef)) and method.name.startswith('test_'):
                    if method.decorator_list:
                        raise ValueError('decorated pure test refused')
                    names.append('test_runner.' + item.name + '.' + method.name)
    if not names or len(names) != len(set(names)):
        raise ValueError('missing or duplicate pure methods')
    return sorted(names)


def validate_fixture(relative, data):
    if not relative.startswith(HERE + '/Fixtures/'):
        return
    text = data.decode('utf-8')
    if '@testable' in text or re.search(r'^\s*#if\b', text, re.M):
        raise ValueError('compiler client must use ordinary import')
    if 'import SearchExecution\n' not in text:
        raise ValueError('compiler client missing ordinary module import')
    name = Path(relative).stem
    if name in NEGATIVES:
        expressions = {
            'ForbiddenLegacy': '_ = await service.shutdown()',
            'ForbiddenController': '_ = service.controller',
            'ForbiddenDriver': '_ = service.driver',
            'ForbiddenDriverInitializer': '_ = try SearchAdmissionService<String>(driver: driver)',
            'ForbiddenControllerInitializer': '_ = try SearchAdmissionService<String>(controller: controller)',
        }
        lines = text.splitlines()
        if len(lines) != 5 or lines[3].strip() != expressions[name]:
            raise ValueError('forbidden expression must be exact fixture line 4')


def freeze(root, run):
    root, run = Path(root), Path(run)
    real_path(root, root)
    real_path(run, run)
    items = []
    for source in discover(root):
        relative = source.relative_to(root).as_posix()
        data, mode = read_file(source)
        validate_fixture(relative, data)
        if relative == TASK1[0]:
            named_methods(data, TASK1_TESTS)
        if relative == HERE + '/SearchAdmissionServiceConstructionTests.swift':
            named_methods(data, CONSTRUCTION)
        copies = []
        for role, name in destinations(relative):
            target = run / name
            target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            target.write_bytes(data)
            target.chmod(mode)
            copies.append(dict(frozen=name, role=role, mode=mode))
        items.append(dict(source=relative, origin=str(source), sha256=digest(data), mode=mode,
                          bytes=len(data), copies=copies))
    generated_items = []
    for name, data in generated().items():
        path = run / name
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        path.write_bytes(data)
        path.chmod(0o600)
        generated_items.append(dict(frozen=name, sha256=digest(data), mode=0o600, bytes=len(data)))
    data, _ = read_file(root / HERE / 'test_runner.py')
    manifest = dict(version=1, root=str(root), sources=items, generated=generated_items,
                    expectedTests=['SearchAdmissionServiceConstructionTests.' + name for name in CONSTRUCTION],
                    expectedPure=pure_names(data), exempt=list(EXEMPT))
    path = run / 'sources.json'
    path.write_text(json.dumps(manifest, indent=2) + '\n')
    path.chmod(0o400)
    verify(run, manifest)
    return manifest


def membership(run):
    result = set()
    for top in ('Package', 'Compiler', 'Runner'):
        directory = real_path(run, run / top)
        if not directory.is_dir():
            raise ValueError('missing frozen input tree')
        for folder, directories, files in os.walk(directory, followlinks=False):
            for name in (*directories, *files):
                path = real_path(run, Path(folder) / name)
                relative = path.relative_to(run).as_posix()
                if relative in EXEMPT:
                    if not path.is_dir():
                        raise ValueError('cache exemption is not a directory')
                    directories.remove(name)
                    # Generated caches may contain normal toolchain symlinks;
                    # no adopted origin/copy is allowed within this exemption.
                    continue
                if not path.is_file() and not path.is_dir():
                    raise ValueError('nonregular frozen member')
                result.add(('directory' if path.is_dir() else 'file', relative))
    return result


def verify(run, manifest):
    root = Path(manifest['root'])
    real_path(run, run)
    for name in ('Build', *('Build/' + scratch for scratch in ('Main', *NEGATIVES))):
        path = real_path(run, run / name)
        if path.exists() and not path.is_dir():
            raise ValueError('declared build root is not a real directory')
    paths = discover(root)
    if ([p.relative_to(root).as_posix() for p in paths] != [i['source'] for i in manifest['sources']]
            or manifest['version'] != 1 or manifest['exempt'] != list(EXEMPT)
            or manifest['expectedTests'] != ['SearchAdmissionServiceConstructionTests.' + n for n in CONSTRUCTION]):
        raise ValueError('origin membership or source manifest schema changed')
    expected = set()
    for item in manifest['sources']:
        relative = item['source']
        if item['origin'] != str(root / relative):
            raise ValueError('origin path changed')
        data, mode = read_file(real_path(root, root / relative))
        if (digest(data), mode, len(data)) != (item['sha256'], item['mode'], item['bytes']):
            raise ValueError('origin bytes or mode changed')
        expected_copies = [dict(frozen=name, role=role, mode=mode) for role, name in destinations(relative)]
        if item['copies'] != expected_copies:
            raise ValueError('compiler/runner copy provenance changed')
        for copy in item['copies']:
            name = copy['frozen']
            if any(name == e or name.startswith(e + '/') for e in EXEMPT):
                raise ValueError('adopted copy under build/cache exemption')
            actual, copied_mode = read_file(real_path(run, run / name))
            if actual != data or copied_mode != mode:
                raise ValueError('frozen bytes or mode changed')
            expected.add(('file', name))
    required_generated = generated()
    if sorted(i['frozen'] for i in manifest['generated']) != sorted(required_generated):
        raise ValueError('generated manifest inventory changed')
    for item in manifest['generated']:
        name = item['frozen']
        data, mode = read_file(real_path(run, run / name))
        wanted = required_generated[name]
        if (data != wanted or digest(data) != item['sha256'] or mode != 0o600
                or item['mode'] != mode or item['bytes'] != len(data)):
            raise ValueError('generated manifest bytes or mode changed')
        expected.add(('file', name))
    for _, name in list(expected):
        for parent in Path(name).parents:
            if parent.as_posix() == '.':
                break
            expected.add(('directory', parent.as_posix()))
    # Top roots are inspected but os.walk membership reports their children.
    expected.difference_update(('directory', name) for name in ('Package', 'Compiler', 'Runner'))
    if membership(run) != expected:
        raise ValueError('complete frozen membership changed')
    pure, _ = read_file(root / HERE / 'test_runner.py')
    if manifest['expectedPure'] != pure_names(pure):
        raise ValueError('pure test inventory changed')


def reject_diagnostics(text):
    if re.search(r'\b(?:warning|error|fatal error):|\b(?:skipped|XCTSkip)\b', text, re.I):
        raise ValueError('warning/error/skip requires review')


def validate_tests(text, expected):
    def normalize(value):
        match = re.fullmatch(r'-\[SearchExecutionTests\.(\w+) (test\w+)\]', value)
        return match[1] + '.' + match[2] if match else value
    reject_diagnostics(text)
    starts = [normalize(n) for n in re.findall(r"Test Case '([^']+)' started\.", text)]
    passes = [normalize(n) for n in re.findall(r"Test Case '([^']+)' passed \(", text)]
    counts = re.findall(r'Executed (\d+) tests?, with (\d+) failures(?: \((\d+) unexpected\))?', text)
    if (not expected or len(expected) != len(set(expected))
            or sorted(starts) != sorted(expected) or sorted(passes) != sorted(expected)
            or not counts or int(counts[-1][0]) != len(expected)
            or any(int(failures) or int(unexpected or 0) for _, failures, unexpected in counts)
            or re.search(r"Test Case '[^']+' (?:failed|skipped)", text)):
        raise ValueError('incomplete unique named XCTest execution')
    return len(expected)


def validate_pure(text, expected):
    lines = re.findall(r'^(test_\w+) \((test_runner\.\w+(?:\.test_\w+)?)\) \.\.\. ok$', text, re.M)
    names = [owner if owner.endswith('.' + method) else owner + '.' + method
             for method, owner in lines]
    summaries = re.findall(r'^Ran (\d+) tests? in ', text, re.M)
    if (not expected or sorted(names) != sorted(expected) or len(summaries) != 1
            or int(summaries[0]) != len(expected) or not re.search(r'^OK$', text, re.M)
            or re.search(r'\b(?:ERROR|FAIL|skipped|warning|error):?|\bunexpected success\b', text)):
        raise ValueError('incomplete pure controls')
    return len(expected)


def validate_negative(text, fixture):
    """Narrow diagnostic classifier; authentic wording is recorded, never invented.

    Require all located errors to be the intended line/member. A bare SwiftPM
    emit-module failure summary is permitted only alongside those located errors.
    Repeated identical diagnostics from compile/emit-module are accepted. An
    initializer's exact incorrect-label diagnostic may additionally have only
    its observed related conversion (matching driver/controller type to URL),
    at that same fixture line4. That secondary diagnostic is never sufficient
    alone or with an inaccessible initializer. Other distinct/conversion/syntax/
    module errors fail closed. Excerpts must repeat a permitted located message.
    """
    path = str(Path(fixture))
    name = Path(path).stem
    if name not in NEGATIVES:
        raise ValueError('unknown fixed negative stage')
    headers = re.findall(r'^(.+?):(\d+):(\d+): (error|warning): (.+)$', text, re.M)
    if not headers or re.search(r'\bwarning:', text):
        raise ValueError('missing intended diagnostic or warning')
    member = {'ForbiddenLegacy': 'shutdown', 'ForbiddenController': 'controller',
              'ForbiddenDriver': 'driver'}.get(name)
    primary_label = related_conversion = None
    if not member:
        label = 'driver' if name == 'ForbiddenDriverInitializer' else 'controller'
        source_type = ('any SearchParentWireJoining' if name == 'ForbiddenDriverInitializer'
                       else 'SearchAdmissionController<String>')
        primary_label = "incorrect argument label in call (have '" + label + ":', expected 'applicationBundle:')"
        related_conversion = ("cannot convert value of type '" + source_type
                              + "' to expected argument type 'URL'")
    messages = []
    for origin, line, column, level, message in headers:
        if origin != path or line != '4' or int(column) <= 0 or level != 'error':
            raise ValueError('wrong diagnostic file/line/category')
        if member:
            intended = (("'SearchAdmissionService<String>'" in message
                         and re.search(r"has no member '" + member + "'", message) is not None)
                        or ("'" + member + "'" in message
                            and re.search(r"inaccessible due to '(?:private|internal)' protection level", message)))
        else:
            intended = (message == primary_label or message == related_conversion
                        or ("'init(" + label + ":)'" in message
                            and re.search(r"inaccessible due to '(?:private|internal)' protection level", message)))
        if not intended:
            raise ValueError('unrelated compiler error')
        messages.append(message)
    unique = set(messages)
    if related_conversion is not None and related_conversion in unique:
        if unique != {primary_label, related_conversion}:
            raise ValueError('related conversion requires its exact label primary only')
    elif len(unique) != 1:
        raise ValueError('multiple distinct compiler errors require review')
    for line in text.splitlines():
        if re.search(r'\b(?:error|fatal error):', line):
            if re.fullmatch(r'.+:\d+:\d+: error: .+', line):
                continue
            if re.fullmatch(r'error: emit-module command failed with exit code 1 \(use -v to see invocation\)', line):
                continue
            # Swift's numbered source excerpt repeats the error message.
            if any(re.fullmatch(r'\s*\|\s*`- error: ' + re.escape(message), line) for message in unique):
                continue
            raise ValueError('unlocated/unrelated compiler error')
    return dict(fixture=path, line=4, messages=sorted(set(messages)), emittedErrors=len(headers))


def stage_logs(output, common, command, code):
    if type(code) is not int or not common.receipt_success(output, command, expected_code=code):
        raise ValueError('incomplete genuine expected-exit receipt')
    stdout, _ = read_file(real_path(output, output / 'stdout.log'))
    stderr, _ = read_file(real_path(output, output / 'stderr.log'))
    return stdout.decode('utf-8'), stderr.decode('utf-8')


def bundle_inventory(run, bundle):
    real_path(run, bundle)
    if not bundle.is_dir():
        raise ValueError('missing XCTest artifact bundle')
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
    directory.relative_to(run / 'Build/Main')
    real_path(run, directory)
    name = 'SearchAdmissionServiceIntegrationPackageTests'
    bundle = directory / (name + '.xctest')
    executable = bundle / 'Contents/MacOS' / name
    data, mode = read_file(real_path(run, executable))
    if not data or not mode & 0o111:
        raise ValueError('missing executable XCTest artifact')
    return dict(bundle=str(bundle), executable=str(executable), executableSHA256=digest(data),
                executableMode=mode, sourceManifestSHA256=manifest_hash,
                buildReceiptSHA256=build_receipt_hash, members=bundle_inventory(run, bundle))


def verify_artifact(run, artifact, manifest_hash, build_receipt_hash):
    if (artifact['sourceManifestSHA256'] != manifest_hash
            or artifact['buildReceiptSHA256'] != build_receipt_hash):
        raise ValueError('artifact source/build receipt binding changed')
    bundle = Path(artifact['bundle'])
    bundle.relative_to(run / 'Build/Main')
    executable = Path(artifact['executable'])
    if executable != bundle / 'Contents/MacOS/SearchAdmissionServiceIntegrationPackageTests':
        raise ValueError('artifact executable origin changed')
    data, mode = read_file(real_path(run, executable))
    if (digest(data) != artifact['executableSHA256'] or mode != artifact['executableMode']
            or bundle_inventory(run, bundle) != artifact['members']):
        raise ValueError('actual XCTest artifact changed')


def stages(run):
    wrapper = str(run / 'Runner/scripts/swift.sh')
    def swift(action, package, scratch, *args):
        return [wrapper, action, '--package-path', str(run / package), '--scratch-path',
                str(run / 'Build' / scratch), *args]
    return [
        ('pure', 60, [sys.executable, '-B', '-m', 'unittest', 'discover', '-v', '-s',
                      str(run / ('Runner/' + HERE)), '-p', 'test_runner.py'], 0),
        ('toolchain', 30, ['/usr/bin/xcrun', 'swift', '--version'], 0),
        ('allowed', 180, swift('build', 'Package', 'Main', '--target', 'AllowedClient'), 0),
        *[(name, 180, swift('build', 'Compiler/' + name, name, '--target', 'ForbiddenClient'), 1)
          for name in NEGATIVES],
        ('build-tests', 180, swift('build', 'Package', 'Main', '--build-tests'), 0),
        ('bin-path', 30, swift('build', 'Package', 'Main', '--show-bin-path'), 0),
        ('construction', 180, swift('test', 'Package', 'Main', '--filter',
                                   'SearchAdmissionServiceConstructionTests'), 0),
    ]


def execute(run, common, watchdog_main):
    result = dict(exit=125, stages=[], constructionTests=None, searchHelperExecutionStageIncluded=False,
                  eagerMutation='Separate source-reviewed companion control not executed by this runner')
    artifact = None
    accepted_outputs = {}
    try:
        manifest_bytes, manifest_mode = read_file(run / 'sources.json')
        if manifest_mode != 0o400:
            raise ValueError('unsealed source manifest')
        manifest = json.loads(manifest_bytes)
        manifest_hash = digest(manifest_bytes)
        result['sourceManifestSHA256'] = manifest_hash
        build_receipt_hash = None
        def checked():
            if read_file(run / 'sources.json') != (manifest_bytes, manifest_mode):
                raise ValueError('sealed source manifest changed')
            verify(run, manifest)
            for path, pinned in accepted_outputs.items():
                if read_file(real_path(run, path)) != pinned:
                    raise ValueError('accepted stage receipt/capture/metadata changed')
            if artifact is not None:
                verify_artifact(run, artifact, manifest_hash, build_receipt_hash)
        for name, seconds, command, expected_code in stages(run):
            checked()
            output = run / 'Stages' / name
            output.parent.mkdir(mode=0o700, exist_ok=True)
            # Sole same-process supervisor. Never wrap this coordinator in another.
            code = watchdog_main(['--timeout', str(seconds), '--output', str(output), '--', *command])
            result['stages'].append(dict(name=name, command=command, exit=code, expectedExit=expected_code))
            checked()
            if type(code) is not int or code != expected_code:
                raise ValueError('stage did not produce its genuine expected exit: ' + name)
            stdout, stderr = stage_logs(output, common, command, expected_code)
            for leaf in ('status.json', 'stdout.log', 'stderr.log'):
                path = output / leaf
                accepted_outputs[path] = read_file(real_path(run, path))
            text = stdout + '\n' + stderr
            if name == 'pure':
                result['pureTests'] = validate_pure(text, manifest['expectedPure'])
            elif name in NEGATIVES:
                fixture = run / 'Compiler' / name / 'Sources/ForbiddenClient' / (name + '.swift')
                binding = validate_negative(text, fixture)
                binding.update(sourceManifestSHA256=manifest_hash,
                               receiptSHA256=digest(read_file(output / 'status.json')[0]),
                               stdoutSHA256=digest(read_file(output / 'stdout.log')[0]),
                               stderrSHA256=digest(read_file(output / 'stderr.log')[0]))
                (output / 'diagnostic-binding.json').write_text(json.dumps(binding, indent=2) + '\n')
                accepted_outputs[output / 'diagnostic-binding.json'] = read_file(output / 'diagnostic-binding.json')
                result['stages'][-1]['diagnostics'] = binding
            else:
                reject_diagnostics(text)
                if name == 'build-tests':
                    build_receipt_hash = digest(read_file(output / 'status.json')[0])
                elif name == 'bin-path':
                    artifact = bind_artifact(run, stdout, manifest_hash, build_receipt_hash)
                    (run / 'artifact.json').write_text(json.dumps(artifact, indent=2) + '\n')
                    accepted_outputs[run / 'artifact.json'] = read_file(run / 'artifact.json')
                elif name == 'construction':
                    result['constructionTests'] = validate_tests(text, manifest['expectedTests'])
            checked()
        result['exit'] = 0
        return 0
    except (OSError, ValueError, TypeError, KeyError, UnicodeError, ImportError) as error:
        result['failure'] = type(error).__name__ + ': ' + str(error)
        return 125
    finally:
        (run / 'status.json').write_text(json.dumps(result, indent=2) + '\n')


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv:
        raise SystemExit('No arguments accepted: complete fixed Task2 stages only.')
    root = Path(__file__).absolute().parents[2]
    parent = real_path(root, root / '.local/search-admission-service-integration')
    parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix='run.', dir=parent))
    print('Private admission-service evidence: ' + str(run), flush=True)
    try:
        freeze(root, run)
        runner = load(run / ('Runner/' + HERE + '/run_harness.py'), 'frozen_admission_service_runner')
        common = load(run / 'Runner/Tests/SearchChildIntegration/run_harness.py', 'frozen_admission_common')
        watchdog = load(run / 'Runner/scripts/run-owned-search-tests.py', 'frozen_admission_watchdog')
        return runner.execute(run, common, watchdog.main)
    except (OSError, ValueError, TypeError, KeyError, ImportError, UnicodeError) as error:
        (run / 'status.json').write_text(json.dumps(dict(exit=125, failure=type(error).__name__)) + '\n')
        return 125


if __name__ == '__main__':
    raise SystemExit(main())
