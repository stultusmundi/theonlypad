"""Explicit hidden AppKit borrow tests; no shown window, input, or helper.

The coordinator directly owns its accepted watchdog. Never nest another watchdog.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
import tempfile

NATIVE = 'Tests/SearchAdmissionNativeIntegration/NativeBorrowBoundaryTests.swift'
REQUIRED = (
    'testReplacementAdmissionResolvesInsideNativeBorrowForBothBudgets',
    'testNestedNativeUnregisterDefersDestructionThroughBothBorrows',
    'testRepeatedShutdownCompletesInsideNativeBorrowAndCountsItsRetainedLease',
)
FIXED = (
    NATIVE,
    'Tests/SearchExecutionTests/SearchAdmissionTestHarness.swift',
    'Tests/SearchAdmissionNativeIntegration/run_harness.py',
    'Tests/SearchAdmissionNativeIntegration/test_runner.py',
    'Tests/SearchChildIntegration/run_harness.py',
    'scripts/swift.sh', 'scripts/run-owned-search-tests.py',
    'scripts/test-search-admission-native-borrow.sh', 'Package.swift',
)
PACKAGE = '''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "SearchAdmissionNativeIntegration", platforms: [.macOS(.v14)], targets: [
  .target(name: "PadCore"),
  .target(name: "SearchExecution", dependencies: ["PadCore"]),
  .testTarget(name: "SearchExecutionTests", dependencies: ["PadCore", "SearchExecution"])
], swiftLanguageModes: [.v5])
'''

def validate_tests(text, expected):
    def normalized(value):
        match = re.fullmatch(r'-\[SearchExecutionTests\.(\w+) (test\w+)\]', value)
        return match[1] + '.' + match[2] if match else value
    started = re.findall(r"Test Case '([^']+)' started\.", text)
    passed = re.findall(r"Test Case '([^']+)' passed \(", text)
    started, passed = [normalized(v) for v in started], [normalized(v) for v in passed]
    counts = re.findall(r'Executed (\d+) tests?, with (\d+) failures', text)
    if (not expected or len(set(expected)) != len(expected)
            or sorted(started) != sorted(expected) or sorted(passed) != sorted(expected)
            or not counts or tuple(map(int, counts[-1])) != (len(expected), 0)
            or any(int(failed) for _, failed in counts)):
        raise ValueError('incomplete named XCTest execution')
    return len(expected)

def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    # Execute the declared bytes, never timestamp-valid unbound Python bytecode.
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'rb') as source:
        data = source.read()
    exec(compile(data, str(path), 'exec'), module.__dict__)
    return module


def native_tests(text):
    if '#if' in text or 'XCTSkip' in text:
        raise ValueError('conditional or skipped native test refused')
    names = re.findall(r'\bfunc (test\w+)\s*\(', text)
    if not names or len(names) != len(set(names)):
        raise ValueError('missing or duplicate named tests')
    if set(names) != set(REQUIRED) or not re.search(r'\bclass\s+NativeBorrowBoundaryTests\b', text):
        raise ValueError('required native borrow class/cases missing or changed')
    return ['NativeBorrowBoundaryTests.' + name for name in names]


def discover(root, common):
    paths = []
    for target in ('PadCore', 'SearchExecution'):
        folder = common.real_path(root, root / 'Sources' / target)
        found = sorted(folder.rglob('*.swift'))
        if not found:
            raise ValueError('missing production target')
        paths.extend(found)
    paths.extend(root / name for name in FIXED)
    for path in paths:
        common.real_path(root, path)
        if not path.is_file():
            raise ValueError('missing source input')
    return paths


def freeze(root, run, common):
    paths = discover(root, common)
    items, expected = [], []
    for source in paths:
        relative = source.relative_to(root).as_posix()
        original = common.read_source(source)
        prefix = 'Package' if relative.startswith(('Sources/', 'Tests/SearchExecutionTests/')) else 'Runner'
        target = run / prefix / relative
        if relative == NATIVE:
            target = run / 'Package/Tests/SearchExecutionTests' / source.name
            expected = native_tests(original.decode('utf-8'))
        target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        target.write_bytes(original)
        if source.suffix == '.sh':
            target.chmod(0o700)
        items.append(dict(source=relative, frozen=target.relative_to(run).as_posix(),
                          sha256=common.digest(original), originSHA256=common.digest(original)))
    if discover(root, common) != paths:
        raise ValueError('source membership changed during capture')
    for item in items:
        if common.digest(common.read_source(common.real_path(root, root / item['source']))) != item['originSHA256']:
            raise ValueError('origin changed during capture')
    package = run / 'Package/Package.swift'
    package.write_text(PACKAGE)
    manifest = dict(version=1, sources=items, expectedTests=expected,
                    generated=[dict(frozen='Package/Package.swift', sha256=common.digest(package.read_bytes()))])
    (run / 'sources.json').write_text(json.dumps(manifest, indent=2) + '\n')
    verify(run, manifest, common)
    return manifest


def verify(run, manifest, common):
    common.verify_frozen(run, manifest)
    for item in manifest['sources']:
        if item['sha256'] != item['originSHA256']:
            raise ValueError('native runner forbids source transformations')
    native = common.read_source(run / 'Package/Tests/SearchExecutionTests/NativeBorrowBoundaryTests.swift')
    if manifest['expectedTests'] != native_tests(native.decode('utf-8')):
        raise ValueError('named test manifest changed')


def execute(run, scratch, common, watchdog_main):
    result = dict(exit=125, stages=[], testsExecuted=None)
    try:
        manifest_bytes = (run / 'sources.json').read_bytes()
        manifest = json.loads(manifest_bytes)
        result['sourceManifestSHA256'] = common.digest(manifest_bytes)
        swift = str(run / 'Runner/scripts/swift.sh')
        stages = [
            ('toolchain', 30, ['/usr/bin/xcrun', 'swift', '--version']),
            ('test', 180, [swift, 'test', '--package-path', str(run / 'Package'),
                           '--scratch-path', str(scratch), '--filter',
                           'NativeBorrowBoundaryTests']),
        ]
        def checked_inputs():
            if (run / 'sources.json').read_bytes() != manifest_bytes:
                raise ValueError('source manifest changed')
            verify(run, manifest, common)
        for name, seconds, command in stages:
            checked_inputs()
            output = run / name
            # Direct same-process supervisor. Never wrap this coordinator in another watchdog.
            code = watchdog_main(['--timeout', str(seconds), '--output', str(output), '--', *command])
            result['stages'].append(dict(name=name, exit=code))
            checked_inputs()
            if code != 0:
                result['exit'] = code if type(code) is int and 0 < code < 256 else 125
                return result['exit']
            if not common.receipt_success(output, command):
                raise ValueError('incomplete process receipt')
            if name == 'test':
                stdout = (output / 'stdout.log').read_text(errors='strict')
                stderr = (output / 'stderr.log').read_text(errors='strict')
                result['testsExecuted'] = validate_tests(stdout, manifest['expectedTests'])
                if 'warning:' in stderr or 'error:' in stderr:
                    raise ValueError('compiler diagnostics require review')
        result['exit'] = 0
        return 0
    except (OSError, ValueError, TypeError, KeyError, UnicodeError) as error:
        result['failure'] = type(error).__name__ + ': ' + str(error)
        return 125
    finally:
        (run / 'status.json').write_text(json.dumps(result, indent=2) + '\n')


def main(argv=None):
    if argv is None:
        argv = sys.argv[1:]
    if argv:
        raise SystemExit('This runner takes no arguments; it executes the complete hidden native borrow class.')
    root = Path(__file__).absolute().parents[2]
    common = load(root / 'Tests/SearchChildIntegration/run_harness.py', 'native_borrow_common')
    parent = common.real_path(root, root / '.local/search-admission-native-integration')
    parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix='run.', dir=parent))
    print('Private native-borrow evidence: ' + str(run), flush=True)
    try:
        freeze(root, run, common)
        runner = load(run / 'Runner/Tests/SearchAdmissionNativeIntegration/run_harness.py', 'frozen_native_borrow_runner')
        frozen_common = load(run / 'Runner/Tests/SearchChildIntegration/run_harness.py', 'frozen_native_borrow_common')
        watchdog = load(run / 'Runner/scripts/run-owned-search-tests.py', 'frozen_native_borrow_watchdog')
        scratch = common.real_path(root, root / '.build/search-admission-native-integration')
        return runner.execute(run, scratch, frozen_common, watchdog.main)
    except (OSError, ValueError, ImportError) as error:
        (run / 'status.json').write_text(json.dumps(dict(exit=125, failure=type(error).__name__)) + '\n')
        return 125


if __name__ == '__main__':
    raise SystemExit(main())
