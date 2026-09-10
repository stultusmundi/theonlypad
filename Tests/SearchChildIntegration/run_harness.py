"""Freeze actual lifecycle sources; directly reuse the accepted owned watchdog."""
import argparse
import errno
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
import tempfile

PACKAGE = '''// swift-tools-version: 6.0
import PackageDescription
let package = Package(
  name: "SearchChildIntegration", platforms: [.macOS(.v14)],
  targets: [
    .target(name: "PadCore"),
    .target(name: "SearchExecution", dependencies: ["PadCore"]),
    .testTarget(name: "SearchExecutionTests", dependencies: ["SearchExecution", "PadCore"]),
  ], swiftLanguageModes: [.v5])
'''
FIXED = (
    'Tests/SearchExecutionTests/SearchChildLifecycleTests.swift',
    'Tests/SearchChildIntegration/SearchChildChannelTests.swift',
    'scripts/swift.sh', 'scripts/run-owned-search-tests.py',
    'scripts/test-search-child-lifecycle.sh',
    'Tests/SearchChildIntegration/run_harness.py',
)


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--build-only', action='store_true')
    mode.add_argument('--filter', default='SearchChildLifecycleTests')
    result = parser.parse_args(argv)
    if not result.filter.strip() or '\0' in result.filter:
        parser.error('--filter requires a nonempty NUL-free expression')
    return result


def digest(data):
    return hashlib.sha256(data).hexdigest()


def real_path(root, path):
    """Reject symlinks at every component within the declared repository root."""
    root = Path(root)
    path = Path(path)
    if root.is_symlink() or not root.is_dir():
        raise ValueError('repository root is not a real directory')
    relative = path.relative_to(root)
    cursor = root
    for part in relative.parts:
        cursor = cursor / part
        if cursor.is_symlink():
            raise ValueError('symlink source component refused')
    return path


def discover(root):
    sources = []
    for name in ('PadCore', 'SearchExecution'):
        directory = real_path(root, root / 'Sources' / name)
        if not directory.is_dir():
            raise ValueError('missing source directory')
        found = sorted(directory.glob('*.swift'))
        if not found:
            raise ValueError('empty production source target')
        sources.extend(found)
    sources.extend(root / name for name in FIXED)
    for path in sources:
        real_path(root, path)
        if not path.is_file():
            raise ValueError('missing source file')
    return sources


def read_source(path):
    # Do not follow a final-component symlink introduced after discovery.
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'rb') as source:
        return source.read()


def copy_source(source, target):
    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    target.write_bytes(read_source(source))
    if source.suffix == '.sh':
        target.chmod(0o700)


def freeze(root, run):
    root, run = Path(root), Path(run)
    paths = discover(root)
    items = []
    for source in paths:
        relative = source.relative_to(root).as_posix()
        prefix = 'Package' if relative.startswith(('Sources/', 'Tests/SearchExecutionTests/')) else 'Runner'
        target = run / prefix / relative
        if relative == 'Tests/SearchChildIntegration/SearchChildChannelTests.swift':
            target = run / 'Package/Tests/SearchExecutionTests/SearchChildChannelTests.swift'
        copy_source(source, target)
        items.append(dict(source=relative, frozen=target.relative_to(run).as_posix(),
                          sha256=digest(target.read_bytes())))
    # Re-discover and re-read AFTER the whole capture, not just per-file copying.
    if discover(root) != paths:
        raise ValueError('source discovery changed during snapshot')
    for item in items:
        if digest(read_source(real_path(root, root / item['source']))) != item['sha256']:
            raise ValueError('source bytes changed during snapshot')
    package = run / 'Package/Package.swift'
    package.write_text(PACKAGE)
    manifest = dict(version=1, sources=items,
                    generated=[dict(frozen='Package/Package.swift', sha256=digest(package.read_bytes()))])
    (run / 'sources.json').write_text(json.dumps(manifest, indent=2) + '\n')
    verify_frozen(run, manifest)
    return manifest


def verify_frozen(run, manifest):
    # SwiftPM discovers the complete package tree, including versioned manifests.
    # Validate membership as well as bytes before/after every owned stage.
    expected = set()
    for item in manifest['sources'] + manifest['generated']:
        name = Path(item['frozen'])
        if not name.is_relative_to('Package'):
            continue
        expected.add(('file', name.as_posix()))
        for parent in name.parents:
            if parent == Path('Package'):
                break
            expected.add(('directory', parent.as_posix()))
    package = real_path(run, run / 'Package')
    if not package.is_dir():
        raise ValueError('missing compiler input tree')
    actual = set()
    for folder, directories, files in os.walk(package, followlinks=False):
        for kind, names in [('directory', directories), ('file', files)]:
            for name in names:
                path = Path(folder) / name
                if path.is_symlink():
                    raise ValueError('symlink compiler input refused')
                actual.add((kind, path.relative_to(run).as_posix()))
    if actual != expected:
        raise ValueError('compiler input membership changed')
    for item in manifest['sources'] + manifest['generated']:
        path = real_path(run, run / item['frozen'])
        if digest(read_source(path)) != item['sha256']:
            raise ValueError('frozen bytes changed')


def receipt_success(output,command,expected_code=0):
    try:
        value=json.loads((output/'status.json').read_text())
        required={'command','pid','processGroup','exitObserved','registrationError','groupSignalAttempted',
            'groupSignalError','groupCleanup','groupQuery','waitCompleted','returnCode','waitError',
            'timedOut','interruptedSignal','truncated','captureComplete','failure','exit','captured'}
        if not isinstance(value,dict) or not required.issubset(value): return False
        if type(expected_code) is not int or not 0<=expected_code<256: return False
        if not isinstance(command,list) or not command or any(type(word) is not str or '\0' in word for word in command): return False
        if any(value[key] is not True for key in ('waitCompleted','captureComplete','groupSignalAttempted')): return False
        if any(value[key] is not False for key in ('timedOut','truncated')): return False
        if any(value[key] is not None for key in ('failure','interruptedSignal','waitError')): return False
        if any(type(value[key]) is not int or value[key]!=expected_code for key in ('exit','returnCode')): return False
        if value['command']!=command: return False
        pid=value['pid']
        if type(pid) is not int or pid<=0 or type(value['processGroup']) is not int or value['processGroup']!=pid: return False
        observed,registration=value['exitObserved'],value['registrationError']
        if type(observed) is not bool: return False
        if registration is not None and (type(registration) is not int or registration!=errno.ESRCH): return False
        if not observed and registration!=errno.ESRCH: return False
        cleanup,error=value['groupCleanup'],value['groupSignalError']
        if cleanup=='signaled':
            if error is not None or value['groupQuery'] is not None: return False
        elif cleanup=='absent':
            if type(error) is not int or error!=errno.ESRCH or value['groupQuery'] is not None: return False
        elif cleanup=='exitedLeaderOnly':
            query=value['groupQuery'];fields={'processGroup','errorNumber','bufferBytes','returnedBytes','members'}
            if type(error) is not int or error!=errno.EPERM or not observed: return False
            if not isinstance(query,dict) or not fields.issubset(query) or query['errorNumber'] is not None: return False
            if any(type(query[key]) is not int or query[key]!=expected for key,expected in
                   [('processGroup',pid),('bufferBytes',1024),('returnedBytes',4)]): return False
            if not isinstance(query['members'],list) or len(query['members'])!=1: return False
            if type(query['members'][0]) is not int or query['members'][0]!=pid: return False
        else: return False
        if not isinstance(value['captured'],dict): return False
        for name in ('stdout','stderr'):
            counts=value['captured'].get(name)
            if not isinstance(counts,dict) or not {'stored','received','discarded'}.issubset(counts): return False
            if any(type(counts[key]) is not int for key in ('stored','received','discarded')): return False
            stored=counts['stored']
            if (not 0<=stored<=1_048_576 or counts['received']!=stored
                or counts['discarded']!=0 or (output/(name+'.log')).stat().st_size!=stored): return False
        return True
    except (OSError,ValueError,TypeError,KeyError,AttributeError): return False

def execute(run, options, watchdog_main):
    run = Path(run)
    manifest = json.loads((run / 'sources.json').read_text())
    manifest_hash = digest((run / 'sources.json').read_bytes())
    common = ['--package-path', str(run / 'Package'), '--scratch-path', str(run / 'Build')]
    swift = str(run / 'Runner/scripts/swift.sh')
    stages = [('toolchain', 30, ['/usr/bin/xcrun', 'swift', '--version']),
              ('build', 180, [swift, 'build', *common, '--build-tests'])]
    if not options.build_only:
        stages.append(('test', 90, [swift, 'test', *common, '--skip-build', '--filter', options.filter]))
    result = dict(exit=125, stages=[], testsExecuted=None, testFailures=None,
                  buildOnly=options.build_only, sourceManifestSHA256=manifest_hash)
    try:
        for stage, timeout, command in stages:
            verify_frozen(run, manifest)
            if digest((run / 'sources.json').read_bytes()) != manifest_hash:
                raise ValueError('manifest changed')
            output = run / stage
            # Same-process call: watchdog directly owns the stage leader/session.
            # Its installed signal handlers settle ownership before returning.
            code = watchdog_main(['--timeout', str(timeout), '--output', str(output), '--', *command])
            result['stages'].append(dict(name=stage, exit=code))
            verify_frozen(run, manifest)
            if digest((run / 'sources.json').read_bytes()) != manifest_hash:
                raise ValueError('manifest changed')
            if code != 0:
                result['exit'] = code if type(code) is int and 0 < code < 256 else 125
                return result['exit']
            if not receipt_success(output, command):
                raise ValueError('stage receipt incomplete')
            if stage == 'test':
                text = (output / 'stdout.log').read_text(errors='replace') + (output / 'stderr.log').read_text(errors='replace')
                counts = re.findall(r'Executed (\d+) tests?, with (\d+) failures', text)
                if not counts:
                    raise ValueError('missing XCTest execution receipt')
                result['testsExecuted'], result['testFailures'] = map(int, counts[-1])
                if result['testsExecuted'] <= 0 or result['testFailures'] != 0:
                    raise ValueError('empty or failing XCTest execution')
        result['exit'] = 0
        return 0
    except (OSError, ValueError, TypeError, KeyError) as error:
        result['failure'] = type(error).__name__
        result['exit'] = 125
        return 125
    finally:
        (run / 'status.json').write_text(json.dumps(result, indent=2) + '\n')


def main(argv=None):
    options = parse_args(sys.argv[1:] if argv is None else argv)
    root = Path(__file__).absolute().parents[2]
    parent = real_path(root, root / '.local/search-child-integration')
    parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix='run.', dir=parent))
    print('Private search-child infrastructure evidence: ' + str(run), flush=True)
    try:
        freeze(root, run)
        path = run / 'Runner/scripts/run-owned-search-tests.py'
        spec = importlib.util.spec_from_file_location('frozen_search_watchdog', path)
        watchdog = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(watchdog)
        return execute(run, options, watchdog.main)
    except (OSError, ValueError, ImportError) as error:
        (run / 'status.json').write_text(json.dumps(dict(exit=125, failure=type(error).__name__)) + '\n')
        return 125


if __name__ == '__main__':
    raise SystemExit(main())
