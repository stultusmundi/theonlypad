"""Fixed retained Locate regression: one frozen build, two exact direct suites."""
from pathlib import Path
import hashlib
import importlib.util
import json
import math
import os
import platform
import re
import stat
import sys
import tempfile

HERE = Path(__file__).absolute().parent
LOCATION = 'Tests/NativeIntegration/run_disk_conflict_presentation.py'
TEST = 'LocateDiskConflictPresentationTests.swift'
GENERATED = 'NativeRoutingPackageTests'
CLASS_OLD = 'NativeRoutingTests.ManagedLocateTokenCharacterizationTests'
CLASS_NEW = 'NativeRoutingTests.LocateDiskConflictPresentationTests'
WATCH_SHA = 'd5bd867e4a65b4ee053209fe0a5822867b8d0878fd6d059f474c9b28a0f6286d'
NATIVE_SHA = 'f4435e99ad7a547a90d01ce38c094d0813fac797a443a0e33654cce6b5ea9cef'
CATALOG_SHA = 'f0972dc53ce438a4f7c6b93d5a069084b23fa38d0ddcb0c828ad3f03adf769b7'
TEST_SHA = 'f514f9a2897b3bed59974d7e0682719ba7e040f0fb87493fce26760c5993f128'
PACKAGE_SHA = '1460f67527046bf1afa69e3083bfde7e342aa1a202a40e10533d67fc221597c8'
FIXED_METHODS = {
    'old2': ['testManagedUnchangedTokenLocateCancelPreservesDocument',
             'testManagedRetainedTokenRefusesBeforeAndAfterDeliveryFreshPanelCancels'],
    'new2': ['testUntouchedInstalledPanelStalesOnAcceptedT2DespiteDifferentSelectedTabAndReopensFresh',
             'testCloseNotificationReentryCannotOverwriteExactInstalledSuccessor'],
}
TAILS = {
    'DocumentFileStateController.swift': ['NativeMonitorBridgeAccess.swift'],
    'EditorWindowController.swift': ['NativeMonitorControllerAccess.swift',
                                    'DocumentSearchEditorBindingAccess.swift',
                                    'LocatePresentationOwnerAccess.swift'],
    'NativeApplicationDocuments.swift': ['DocumentSearchAppNativeOwnerAccess.swift',
                                       'LocatePresentationCheckpointAccess.swift'],
    'DocumentDiskConflictController.swift': ['LocatePresentationPanelAccess.swift'],
}
TAIL_HASHES = {
    'NativeMonitorBridgeAccess.swift': '5f62bac646984afd8f39849c8cd963fd0093198f653979e8d9b14e852480cbc4',
    'NativeMonitorControllerAccess.swift': '80b4c212694c85eca3505dc81020bdd383412f389f4543916c5623de67828682',
    'DocumentSearchEditorBindingAccess.swift': '602a3603c0f872ce2bb5814fd348138518b5276a33b469e2093625da05865537',
    'LocatePresentationOwnerAccess.swift': 'e2fe9b856e2528f6b538c494c26824350b8657e35a4aecc72b9a628a8c83ada7',
    'DocumentSearchAppNativeOwnerAccess.swift': 'ec9ffa625b225067bb9573ca3c8087cc3828931885c20d736faabb87b722ee3b',
    'LocatePresentationCheckpointAccess.swift': 'd3a2c6786cbf71bc779dbf5d65168e93150b1bd4892407d6bfc4a83d113105ea',
    'LocatePresentationPanelAccess.swift': 'cab109f7cc4a23797383dfded15d290e1a0e36e830e9e1a4684662fae89a66e5',
}
SOURCE_ROOTS = ('Sources/PadCore', 'Sources/SearchExecution', 'Sources/TheOnlyPad')
RECEIPT_FIELDS = set('command pid processGroup exitObserved registrationError groupSignalAttempted '
    'groupSignalError groupCleanup groupQuery waitCompleted returnCode waitError timedOut '
    'interruptedSignal truncated captureComplete failure exit seconds captured'.split())
# The read-only catalog module is usable solely for its bound checkout/run pair.
# A relocated pure caller never inherits authority from an earlier repository.
_CATALOG = None
_CATALOG_ROOTS = ()


def require(value, message):
    if not value:
        raise ValueError(message)


def checked(root, path, directory=False):
    root, path = Path(root).absolute(), Path(path).absolute()
    require(path.is_relative_to(root) and '..' not in path.parts, 'path outside owned root')
    parts = path.relative_to(root).parts
    for cursor in [root, *[root.joinpath(*parts[:i]) for i in range(1, len(parts) + 1)]]:
        info = cursor.lstat()
        require(not stat.S_ISLNK(info.st_mode), 'symlink refused')
        require(info.st_uid == os.geteuid(), 'foreign owner refused')
        if cursor != path:
            require(stat.S_ISDIR(info.st_mode), 'non-directory ancestor')
    mode = path.lstat().st_mode
    require(stat.S_ISDIR(mode) if directory else stat.S_ISREG(mode), 'wrong path type')
    return path


def catalog(root):
    return _CATALOG if Path(root).absolute() in _CATALOG_ROOTS else None


def fact(root, path):
    path = checked(root, path)
    helper = catalog(root)
    if helper is not None:
        row, data = helper.fact(root, path)
        require(row['st_uid'] == os.geteuid(), 'foreign descriptor owner')
        checked(root, path)
        return row, data
    # Bootstrap only: ownership must be checked before importing the catalog.
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and before.st_uid == os.geteuid(), 'unowned descriptor')
        with os.fdopen(fd, 'rb', closefd=False) as stream:
            data = stream.read()
        after, named = os.fstat(fd), path.lstat()
        keys = ('st_dev', 'st_ino', 'st_uid', 'st_mode', 'st_size', 'st_mtime_ns', 'st_ctime_ns')
        require(all(getattr(before, key) == getattr(after, key) == getattr(named, key) for key in keys)
                and len(data) == after.st_size, 'input changed during read')
        checked(root, path)
        return dict(path=path.relative_to(root).as_posix(), sha256=hashlib.sha256(data).hexdigest(),
                    **{key: getattr(after, key) for key in keys}), data
    finally:
        os.close(fd)


def load(root, path):
    def unique(pairs):
        value = {}
        for key, item in pairs:
            require(key not in value, 'duplicate JSON key')
            value[key] = item
        return value
    return json.loads(fact(root, path)[1], object_pairs_hook=unique)


def save(path, value):
    # Exclusive writes retain the first authority; no later posthoc replacement.
    with Path(path).open('x') as stream:
        json.dump(value, stream, indent=2)
        stream.write('\n')


def mkdir(root, path):
    root, path = Path(root).absolute(), Path(path).absolute()
    require(path.is_relative_to(root) and '..' not in path.parts, 'directory outside owned root')
    checked(root, root, True)
    helper = catalog(root)
    if helper is not None:
        helper.mkdir(root, path)
    else:
        for index in range(1, len(path.relative_to(root).parts) + 1):
            part = root.joinpath(*path.relative_to(root).parts[:index])
            if not part.exists():
                part.mkdir(mode=0o700)
            checked(root, part, True)
            require(stat.S_IMODE(part.lstat().st_mode) == 0o700, 'owned directory must be0700')
    checked(root, path, True)


def directory_fact(root, path):
    path = checked(root, path, True)
    helper = catalog(root)
    if helper is not None:
        return helper.directory_fact(root, path)
    info = path.lstat()
    return dict(path=path.relative_to(root).as_posix(), directory=True, device=info.st_dev,
                inode=info.st_ino, uid=info.st_uid, mode=stat.S_IMODE(info.st_mode))


def tree(root, path):
    path = checked(root, path, True)
    # Inspect every leaf before catalog.tree performs any reads.
    entries = [path, *sorted(path.rglob('*'))]
    for entry in entries:
        checked(root, entry, entry.is_dir())
    helper = catalog(root)
    if helper is not None:
        return helper.tree(root, path)
    return [directory_fact(root, entry) if entry.is_dir() else fact(root, entry)[0] for entry in entries]


def fixed_selections():
    return {
        'old2': {'class': CLASS_OLD, 'methods': list(FIXED_METHODS['old2'])},
        'new2': {'class': CLASS_NEW, 'methods': list(FIXED_METHODS['new2'])},
    }


def support(root):
    root = Path(root)
    for relative, digest in [('Tests/NativeIntegration/run_native_regressions.py', NATIVE_SHA),
                             ('Tests/NativeIntegration/run_native_language_catalog.py', CATALOG_SHA),
                             ('scripts/run-owned-search-tests.py', WATCH_SHA)]:
        require(fact(root, root / relative)[0]['sha256'] == digest, 'accepted helper bytes changed: ' + relative)
    selections = load(root, root / 'Tests/NativeIntegration/disk-conflict-presentation-methods.json')
    require(selections == fixed_selections(), 'fixed class/method roster changed')
    test_bytes = fact(root, root / 'Tests/NativeIntegration' / TEST)[1]
    require(hashlib.sha256(test_bytes).hexdigest() == TEST_SHA, 'fixed reviewed Test bytes changed')
    validate_declarations(test_bytes, selections)
    package = fact(root, root / 'Tests/NativeIntegration/disk-conflict-presentation-Package.swift')[1]
    require(hashlib.sha256(package).hexdigest() == PACKAGE_SHA, 'fixed reviewed package bytes changed')
    return selections, package.decode('utf-8')


def validate_cli(argv):
    require(argv == [], 'fixed runner accepts no arguments')


def source_mapping(root):
    mapping = {}
    for source_module, target_module in [('PadCore', 'PadCore'), ('SearchExecution', 'SearchExecution'),
                                          ('TheOnlyPad', 'NativeRouting')]:
        source = checked(root, root / 'Sources' / source_module, True)
        files = sorted(source.rglob('*.swift'))
        require(files, 'missing Source root')
        basenames = set()
        for path in files:
            checked(root, path)
            if path == root / 'Sources/TheOnlyPad/TheOnlyPadApplication.swift':
                continue
            require(path.name.casefold() not in basenames, 'ambiguous compiler object basename')
            basenames.add(path.name.casefold())
            destination = 'Package/Sources/' + target_module + '/' + path.relative_to(source).as_posix()
            mapping[path.relative_to(root).as_posix()] = destination
    return mapping


def build_plan(root, run):
    root, run = Path(root).absolute(), Path(run).absolute()
    checked(root, root, True)
    selections, package = support(root)
    mapping = source_mapping(root)
    mapping['Tests/NativeIntegration/' + TEST] = 'Package/Tests/NativeRoutingTests/' + TEST
    require(len({value.casefold() for value in mapping.values()}) == len(mapping), 'ambiguous frozen Source path')
    access = {name: ['Tests/NativeIntegration/' + tail for tail in tails] for name, tails in TAILS.items()}
    for name, paths in access.items():
        require('Sources/TheOnlyPad/' + name in mapping, 'access declaration Source absent')
        for path in paths:
            require(fact(root, root / path)[0]['sha256'] == TAIL_HASHES[Path(path).name], 'fixed access tail bytes changed')
    swift = str(run / 'ToolSupport/scripts/swift.sh')
    common = ['--package-path', str(run / 'Package'), '--scratch-path', str(run / 'BuildProducts')]
    rows = [('toolchain', 30, ['/usr/bin/xcrun', 'swift', '--version']),
            ('build', 180, [swift, 'build', *common, '--build-tests', '-Xswiftc', '-warnings-as-errors']),
            ('binpath', 30, [swift, 'build', *common, '--show-bin-path', '-Xswiftc', '-warnings-as-errors'])]
    bundle = run / 'BuildProducts' / (platform.machine() + '-apple-macosx/debug') / (GENERATED + '.xctest')
    for key in ('old2', 'new2'):
        rows.append((key, 180, ['/usr/bin/xcrun', 'xctest', '-XCTest', selections[key]['class'], str(bundle)]))
    stages = [dict(name=name, timeout=timeout, command=['/usr/bin/env',
        'THEONLYPAD_STATE_DIRECTORY=' + str(run / 'State' / name),
        'TMPDIR=' + str(run / 'Temporary' / name) + '/', *command]) for name, timeout, command in rows]
    return dict(selections=selections, swiftInputs=mapping, accessTails=access, package=package,
        stages=stages, captureAfter='binpath', tools={
            'scripts/swift.sh': 'ToolSupport/scripts/swift.sh',
            'scripts/run-owned-search-tests.py': 'Runner/run-owned-search-tests.py',
            'Tests/NativeIntegration/run_native_regressions.py': 'Runner/run_native_regressions.py',
            'Tests/NativeIntegration/run_native_language_catalog.py': 'Runner/run_native_language_catalog.py',
            'Tests/NativeIntegration/disk_conflict_presentation_proof.py': 'Runner/disk_conflict_presentation_proof.py',
            LOCATION: 'Runner/run_disk_conflict_presentation.py'})


def validate_declarations(data, rosters):
    require(rosters == fixed_selections(), 'fixed two-class roster required')
    raw = data.decode('utf-8') if isinstance(data, bytes) else data
    classes = re.findall(r'^\s*(?:@MainActor\s+)?final\s+class\s+(\w+)\s*:\s*XCTestCase\s*\{', raw, re.M)
    declarations = re.findall(r'^\s*func\s+(test\w+)\s*\(', raw, re.M)
    require(classes == ['ManagedLocateTokenCharacterizationTests', 'LocateDiskConflictPresentationTests'],
            'exact two XCTest classes required')
    expected = FIXED_METHODS['old2'] + FIXED_METHODS['new2']
    require(declarations == expected, 'exact four method declarations required')
    # The reviewed whole-file digest is separately mandatory for original and copy.
    return True


def freeze(root, run, plan):
    global _CATALOG, _CATALOG_ROOTS
    root, run = Path(root).absolute(), Path(run).absolute()
    require(Path(__file__).absolute() == root / LOCATION, 'fixed public entry required')
    checked(root, root, True)
    checked(run, run, True)
    require(build_plan(root, run) == plan, 'plan changed before freeze')
    destinations = dict(plan['swiftInputs'])
    destinations.update(plan['tools'])
    destinations.update({
        'Tests/NativeIntegration/disk-conflict-presentation-methods.json': 'Runner/disk-conflict-presentation-methods.json',
        'Tests/NativeIntegration/disk-conflict-presentation-Package.swift': 'Runner/disk-conflict-presentation-Package.swift',
        'scripts/test-disk-conflict-presentation.sh': 'Runner/test-disk-conflict-presentation.sh'})
    relatives = sorted(set(destinations) | {tail for tails in plan['accessTails'].values() for tail in tails})
    originals, copies, sources, generated, recipes = [], [], [], [], []
    captured = {}
    # Each input is read ONCE into the authoritative Original capture. All derived
    # bytes below come exclusively from this capture, never a second live read.
    for relative in relatives:
        original, raw = fact(root, root / relative)
        original_path = run / 'Original' / relative
        mkdir(run, original_path.parent)
        with original_path.open('xb') as stream:
            stream.write(raw)
        original_path.chmod(stat.S_IMODE(original['st_mode']))
        captured[relative] = raw
        originals.append(original)
        copies.append(fact(run, original_path)[0])
        sources.append(dict(source=relative, frozen=original_path.relative_to(run).as_posix(), sha256=original['sha256']))
    original_directories = {root}
    for relative in relatives:
        original_directories.update((root / relative).parents)
    original_directories = sorted(path for path in original_directories if path.is_relative_to(root))
    original_directory_facts = [directory_fact(root, path) for path in original_directories]
    by_origin = {row['path']: row for row in originals}
    for relative, digest in [('scripts/run-owned-search-tests.py', WATCH_SHA),
        ('Tests/NativeIntegration/run_native_regressions.py', NATIVE_SHA),
        ('Tests/NativeIntegration/run_native_language_catalog.py', CATALOG_SHA)]:
        require(by_origin[relative]['sha256'] == digest, 'unreviewed dependency capture')
    # Import only the now-authoritative, owned catalog snapshot. Its primitive
    # functions take explicit roots; no support/build/main path is called.
    helper_path = run / 'Original/Tests/NativeIntegration/run_native_language_catalog.py'
    before = fact(run, helper_path)[0]
    _CATALOG = import_module(helper_path, 'locate_catalog_' + run.name.replace('.', '_'))
    _CATALOG_ROOTS = (root, run)
    require(fact(run, helper_path)[0] == before, 'catalog changed during import')
    for relative, destination in destinations.items():
        parts = [relative]
        for name, tails in plan['accessTails'].items():
            if relative == 'Sources/TheOnlyPad/' + name:
                parts += tails
        data = b'\n'.join(captured[part] for part in parts)
        target = run / destination
        mkdir(run, target.parent)
        with target.open('xb') as stream:
            stream.write(data)
        target.chmod(stat.S_IMODE(by_origin[relative]['st_mode']))
        row = fact(run, target)[0]
        copies.append(row)
        generated.append(dict(frozen=destination, sha256=row['sha256'], origin=relative))
        lengths = [len(captured[part]) for part in parts]
        offsets = [sum(lengths[:index]) + index for index in range(len(parts))]
        recipes.append(dict(frozen=destination, inputs=parts, join='ONE_LF', lengths=lengths,
            offsets=offsets, inputSHA256=[by_origin[part]['sha256'] for part in parts], sha256=row['sha256']))
    package_origin = 'Tests/NativeIntegration/disk-conflict-presentation-Package.swift'
    package = run / 'Package/Package.swift'
    with package.open('xb') as stream:
        stream.write(captured[package_origin])
    package.chmod(stat.S_IMODE(by_origin[package_origin]['st_mode']))
    copied = fact(run, package)[0]
    copies.append(copied)
    generated.append(dict(frozen='Package/Package.swift', sha256=copied['sha256'], origin=package_origin))
    recipes.append(dict(frozen='Package/Package.swift', inputs=[package_origin], join='ONE_LF',
        lengths=[len(captured[package_origin])], offsets=[0],
        inputSHA256=[by_origin[package_origin]['sha256']], sha256=copied['sha256']))
    directories = ['Original', 'Package', 'Runner', 'ToolSupport', 'ToolSupport/scripts',
                   'State', 'Temporary', 'Stages', 'Commands']
    for name in directories:
        mkdir(run, run / name)
    stage_directories = [parent + '/' + row['name'] for row in plan['stages'] for parent in ('State', 'Temporary')]
    for name in stage_directories:
        mkdir(run, run / name)
    input_trees = ['Original', 'Package', 'Runner', 'ToolSupport/scripts']
    owned = [directory_fact(run, run / name) for name in ['.', *directories, *stage_directories]]
    manifest = dict(sources=sources, generated=generated, inputTrees=input_trees,
        originals=originals, originalDirectories=original_directory_facts, copies=copies,
        ownedDirectories=owned, plan=plan, derivations=recipes,
        trees={name: tree(run, run / name) for name in input_trees})
    save(run / 'inputs.json', manifest)
    verify_inputs(root, run, manifest)
    return manifest


def verify_inputs(root, run, manifest):
    root, run = Path(root), Path(run)
    require(build_plan(root, run) == manifest['plan'], 'public Source/support/plan changed')
    for row in manifest['originalDirectories']:
        require(directory_fact(root, root / row['path']) == row, 'original directory identity changed')
    for row in manifest['originals']:
        require(fact(root, root / row['path'])[0] == row, 'original identity/content changed')
    for row in manifest['copies']:
        require(fact(run, run / row['path'])[0] == row, 'frozen identity/content changed')
    frozen = {row['source']: fact(run, run / row['frozen'])[1] for row in manifest['sources']}
    require(len(frozen) == len(manifest['sources']), 'duplicate Original capture')
    for row in manifest['derivations']:
        parts = [frozen[name] for name in row['inputs']]
        lengths = [len(part) for part in parts]
        require(row['join'] == 'ONE_LF' and lengths == row['lengths']
                and row['offsets'] == [sum(lengths[:index]) + index for index in range(len(parts))]
                and row['inputSHA256'] == [hashlib.sha256(part).hexdigest() for part in parts], 'derivation recipe changed')
        expected = b'\n'.join(parts)
        actual = fact(run, run / row['frozen'])[1]
        require(actual == expected and hashlib.sha256(actual).hexdigest() == row['sha256'], 'derived bytes differ from Original')
    validate_declarations(frozen['Tests/NativeIntegration/' + TEST], manifest['plan']['selections'])
    validate_declarations(fact(run, run / 'Package/Tests/NativeRoutingTests' / TEST)[1], manifest['plan']['selections'])
    require(hashlib.sha256(frozen['Tests/NativeIntegration/' + TEST]).hexdigest() == TEST_SHA, 'whole Test changed')
    require(frozen['Tests/NativeIntegration/disk-conflict-presentation-Package.swift'].decode('utf-8') == manifest['plan']['package'], 'captured package differs from plan')
    for name, rows in manifest['trees'].items():
        require(tree(run, run / name) == rows, 'frozen tree membership changed')
    require(load(run, run / 'inputs.json') == manifest, 'input manifest changed')
    for row in manifest['ownedDirectories']:
        require(directory_fact(run, run / row['path']) == row, 'owned directory identity changed')
    support_dir = checked(run, run / 'ToolSupport', True)
    require({path.name for path in support_dir.iterdir()} <= {'scripts', '.cache'}, 'unexpected ToolSupport member')
    cache = support_dir / '.cache'
    if cache.exists() or cache.is_symlink():
        for path in [cache, *cache.rglob('*')]:
            checked(run, path, path.is_dir())
    # Final live reread prevents the derivation verifier itself from extending a
    # stale Original claim through a concurrent public-source replacement.
    for row in manifest['originals']:
        require(fact(root, root / row['path'])[0] == row, 'original changed during verification')


def parse_result(raw, exit_code, selection):
    require(selection in ('old2', 'new2'), 'unknown fixed selection')
    row = fixed_selections()[selection]
    cls, methods = row['class'], row['methods']
    text = raw.decode('utf-8') if isinstance(raw, bytes) else raw
    expected = {'-[' + cls + ' ' + method + ']' for method in methods}
    starts = list(re.finditer(r"^Test Case '([^']+)' started(?: at [^\n]+)?\.$", text, re.M))
    terminals = list(re.finditer(r"^Test Case '([^']+)' (passed|failed|skipped) \([^\n]*\)\.$", text, re.M))
    require(len(starts) == 2 and {match[1] for match in starts} == expected, 'missing/foreign/repeated case starts')
    require(len(terminals) == 2 and {match[1] for match in terminals} == expected
            and all(match[2] != 'skipped' for match in terminals), 'incomplete/foreign/skipped terminal cases')
    require(len(re.findall(r'^Test Case .*$', text, re.M)) == 4, 'unparsed case records')
    events = sorted([(match.start(), match[1], 'start') for match in starts]
                    + [(match.start(), match[1], 'finish') for match in terminals])
    require(all(events[index][2] == 'start' and events[index + 1][2] == 'finish'
                and events[index][1] == events[index + 1][1] for index in (0, 2)), 'interleaved/reversed case records')
    start_positions = {match[1]: match.start() for match in starts}
    for match in terminals:
        require(start_positions[match[1]] < match.start(), 'case finished before start')
    plain = cls.rsplit('.', 1)[1]
    suite_starts = list(re.finditer(r"^Test Suite '([^']+)' started(?: at [^\n]+)?\.$", text, re.M))
    suite_ends = list(re.finditer(r"^Test Suite '([^']+)' (passed|failed) at [^\n]+\.$", text, re.M))
    names = [match[1] for match in suite_starts]
    # Darwin XCTest also reports the package bundle as a third nested suite.
    # The synthetic pure contract has just Selected tests and the plain class.
    require(names in (['Selected tests', plain], ['Selected tests', GENERATED + '.xctest', plain]), 'unexpected suite hierarchy')
    require([match[1] for match in suite_ends] == list(reversed(names)), 'incomplete/repeated/foreign suite terminals')
    require(len(re.findall(r'^Test Suite .*$', text, re.M)) == len(suite_starts) + len(suite_ends), 'unparsed suite record')
    for index, name in enumerate(names):
        end = suite_ends[len(names) - index - 1]
        require(suite_starts[index].end() <= starts[0].start() and end.start() >= terminals[-1].end(), 'case outside suite lifetime')
    summaries = list(re.finditer(r'^\s*Executed (\d+) tests?, with (\d+) failures? \((\d+) unexpected\)(?:[^\n]*)$', text, re.M))
    require(len(summaries) == len(suite_ends), 'missing/repeated XCTest summary')
    parsed = [tuple(map(int, match.groups())) for match in summaries]
    failures, unexpected = parsed[0][1:]
    require(all(value == (2, failures, unexpected) for value in parsed), 'inconsistent XCTest summaries')
    for index, (end, summary) in enumerate(zip(suite_ends, summaries)):
        require(end.end() <= summary.start() and (index + 1 == len(suite_ends) or summary.end() <= suite_ends[index + 1].start()), 'summary outside terminal suite')
    failed = sum(match[2] == 'failed' for match in terminals)
    require(failures >= failed and bool(failures) == bool(failed) and unexpected == 0, 'nonordinary XCTest failures')
    require(all(match[2] == ('failed' if failures else 'passed') for match in suite_ends), 'suite/numeric result differs')
    require(type(exit_code) is int and exit_code == (1 if failures else 0), 'natural process exit differs')
    require(not failures or 'XCTAssert' in text or ': failed - ' in text, 'ordinary assertion evidence missing')
    return dict(executed=2, failures=failures, unexpected=unexpected, exit=exit_code,
        selection=selection, methods=methods, observed=[(match[1], match[2]) for match in terminals])


def import_module(path, name):
    path = Path(path).absolute()
    checked(path.parent, path)
    before = fact(path.parent, path)[0]
    spec = importlib.util.spec_from_file_location(name, path)
    require(spec is not None and spec.loader is not None, 'module loader unavailable')
    module = importlib.util.module_from_spec(spec)
    prior = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        sys.modules[name] = module
        spec.loader.exec_module(module)
    finally:
        sys.dont_write_bytecode = prior
    require(fact(path.parent, path)[0] == before, 'dependency changed during import')
    return module


def native_and_proof(run, manifest):
    run = Path(run)
    # Pure capture uses public-shaped HERE; real main uses the frozen Runner.
    # Both sources must match the actual manifest's authority before import.
    require(load(run, run / 'inputs.json') == manifest, 'input authority changed before dependency import')
    for name in ('run_native_regressions.py', 'disk_conflict_presentation_proof.py'):
        frozen = run / 'Runner' / name
        row = next(row for row in manifest['copies'] if row['path'] == frozen.relative_to(run).as_posix())
        require(fact(run, frozen)[0] == row, 'dependency authority changed')
    native_path = run / 'Runner/run_native_regressions.py'
    require(fact(run, native_path)[0]['sha256'] == NATIVE_SHA, 'unreviewed native dependency')
    native = import_module(native_path, 'accepted_native')
    proof = import_module(run / 'Runner/disk_conflict_presentation_proof.py', 'locate_compiler_proof')
    return native, proof


def capture(run, manifest):
    run = Path(run)
    native, proof = native_and_proof(run, manifest)
    binary_text = fact(run, run / 'Stages/binpath/stdout.log')[1].decode('utf-8').strip().splitlines()
    require(len(binary_text) == 1, 'ambiguous binary path')
    binary = Path(binary_text[0])
    require(binary == run / 'BuildProducts' / (platform.machine() + '-apple-macosx/debug'), 'foreign binary root')
    source_fact = fact(run, run / 'inputs.json')[0]
    graph = proof.validate_native_compiler_graph(run, binary, manifest)
    directories = {run}
    for name in graph['paths']:
        directories.update(path for path in (run / name).parents if path.is_relative_to(run))
    directory_facts = [directory_fact(run, path) for path in sorted(directories)]
    rows = [native.real_helper_artifact(run, run / name) for name in graph['paths']]
    facts = [fact(run, run / name)[0] for name in graph['paths']]
    require(proof.validate_native_compiler_graph(run, binary, manifest) == graph, 'compiler graph changed during capture')
    require(all(native.real_helper_artifact(run, run / row['path']) == row for row in rows), 'compiler artifact changed during capture')
    binary_row = next(row for row in rows if row['path'] == graph['testBinary'])
    require(binary_row['mode'] & 0o111, 'Test binary is not executable')
    record = dict(binaryRoot=binary.relative_to(run).as_posix(), binary=graph['testBinary'],
        sourceManifestSHA256=source_fact['sha256'], sourceManifestFact=source_fact,
        compiler=graph['modules'], artifacts=rows, artifactFacts=facts, artifactDirectories=directory_facts,
        membership=graph['membership'], links=graph['links'], packageName=graph['packageName'],
        objectCount=graph['objectCount'], graph=graph)
    save(run / 'artifacts.json', record)
    verify_capture(run, manifest, record)
    return record


def verify_capture(run, manifest, record):
    run = Path(run)
    native, proof = native_and_proof(run, manifest)
    require(load(run, run / 'artifacts.json') == record, 'captured artifact record changed')
    require(fact(run, run / 'inputs.json')[0] == record['sourceManifestFact'], 'source authority identity changed')
    require(record['sourceManifestSHA256'] == record['sourceManifestFact']['sha256'], 'source hash projection changed')
    for row in record['artifactDirectories']:
        require(directory_fact(run, run / row['path']) == row, 'compiler artifact directory identity changed')
    for row in record['artifactFacts']:
        require(fact(run, run / row['path'])[0] == row, 'compiler artifact identity/content changed')
    for row in record['artifacts']:
        require(native.real_helper_artifact(run, run / row['path']) == row, 'native artifact fact changed')
    actual = proof.validate_native_compiler_graph(run, run / record['binaryRoot'], manifest)
    require(actual == record['graph'] and actual['modules'] == record['compiler']
            and actual['paths'] == sorted(row['path'] for row in record['artifacts'])
            and actual['membership'] == record['membership'] and actual['links'] == record['links'], 'native compiler graph changed')


def verify_evidence(run, evidence):
    for row in evidence:
        actual = directory_fact(run, run / row['path']) if row.get('directory') else fact(run, run / row['path'])[0]
        require(actual == row, 'adopted command/receipt/capture/result changed')


def stage(root, run, manifest, execute, verifier, row, evidence):
    verify_inputs(root, run, manifest)
    verify_evidence(run, evidence)
    name = row['name']
    output = run / 'Stages' / name
    require(not output.exists() and not output.is_symlink(), 'stage output already exists')
    command = run / 'Commands' / (name + '.json')
    save(command, dict(name=name, timeout=row['timeout'], command=row['command']))
    command_fact = fact(run, command)[0]
    evidence.append(command_fact)  # Crucially before invoking the current child.
    code = execute(['--timeout', str(row['timeout']), '--output', str(output), '--', *row['command']])
    require(fact(run, command)[0] == command_fact, 'current command changed during child')
    verify_inputs(root, run, manifest)
    checked(run, output, True)
    require({path.name for path in output.iterdir()} == {'status.json', 'stdout.log', 'stderr.log'}, 'stage output membership differs')
    output_fact = directory_fact(run, output)
    rows = [fact(run, output / name) for name in ('status.json', 'stdout.log', 'stderr.log')]
    evidence += [output_fact, *[value[0] for value in rows]]
    status = load(run, output / 'status.json')
    require(isinstance(status, dict) and set(status) == RECEIPT_FIELDS
            and type(status.get('seconds')) in (int, float) and math.isfinite(status['seconds'])
            and status['seconds'] >= 0, 'strict receipt schema/time invalid')
    require(set(status['captured']) == {'stdout', 'stderr'}
            and all(isinstance(value, dict) and set(value) == {'stored', 'received', 'discarded'}
                    for value in status['captured'].values()), 'capture schema differs')
    require(verifier.receipt_success(output, row['command'], code), 'watchdog receipt refused')
    # Recheck current receipt/streams after the verifier's independent reads.
    verify_evidence(run, evidence)
    text = rows[1][1].decode('utf-8') + '\n' + rows[2][1].decode('utf-8')
    parsed = None
    if name in ('old2', 'new2'):
        parsed = parse_result(text, code, name)
        save(run / (name + '-result.json'), parsed)
        evidence.append(fact(run, run / (name + '-result.json'))[0])
    else:
        if code != 0:
            raise StageFailure(code)
        require(not re.search(r'(?im)^.*(?:warning:|error:)', text), 'compiler diagnostic present')
    return text, code, parsed


class StageFailure(Exception):
    def __init__(self, code):
        self.code = code


def execute(root, run, manifest):
    strict, _ = native_and_proof(run, manifest)
    watch_path = run / 'Runner/run-owned-search-tests.py'
    require(fact(run, watch_path)[0]['sha256'] == WATCH_SHA, 'watchdog bytes changed')
    watchdog = import_module(watch_path, 'owned_watchdog')
    result = dict(state='INCOMPLETE', exit=125, stages=[], selectionResults={})
    evidence = [fact(run, run / 'inputs.json')[0]]
    result['adoptedEvidence'] = evidence
    artifact = None
    artifact_fact = None

    def verify_all():
        verify_inputs(root, run, manifest)
        verify_evidence(run, evidence)
        names = {path.name for path in run.iterdir()}
        allowed = {'Original', 'Package', 'Runner', 'ToolSupport', 'State', 'Temporary',
                   'Stages', 'Commands', 'BuildProducts', 'inputs.json', 'artifacts.json',
                   'old2-result.json', 'new2-result.json'}
        require(names <= allowed and len({name.casefold() for name in names}) == len(names), 'unexpected or aliased run namespace')
        reached = {row['name'] for row in result['stages']}
        require({path.name for path in (run / 'Commands').iterdir()} == {name + '.json' for name in reached}, 'command membership changed')
        require({path.name for path in (run / 'Stages').iterdir()} == reached, 'stage membership changed')
        for row in result['stages']:
            output = run / 'Stages' / row['name']
            require({path.name for path in output.iterdir()} == {'status.json', 'stdout.log', 'stderr.log'}, 'prior output membership changed')
        if artifact is not None:
            require(fact(run, run / 'artifacts.json')[0] == artifact_fact, 'artifact authority identity changed')
            verify_capture(run, manifest, artifact)
        return True

    def runstage(name):
        verify_all()
        row = next(value for value in manifest['plan']['stages'] if value['name'] == name)
        retained = dict(name=name, command=row['command'], code=None, receipt='Stages/' + name + '/status.json')
        result['stages'].append(retained)
        try:
            text, code, parsed = stage(root, run, manifest, watchdog.main, strict, row, evidence)
        except StageFailure as error:
            retained['code'] = error.code
            raise
        retained['code'] = code
        if parsed is not None:
            result['selectionResults'][name] = parsed
            if parsed['failures'] == 0:
                require(not list((run / 'State' / name).iterdir()), 'selected stage left State entries')
        verify_all()  # Includes FINAL current receipt, streams, command and result.
        return text, code, parsed

    try:
        runstage('toolchain')
        runstage('build')
        runstage('binpath')
        artifact = capture(run, manifest)
        artifact_fact = fact(run, run / 'artifacts.json')[0]
        result['artifactManifestFact'] = artifact_fact
        verify_all()
        _, code, parsed = runstage('old2')
        if parsed['failures']:
            result['state'], result['exit'] = 'OLD2_FAILED_NEW2_UNENTERED', 1
        else:
            # Re-read the already-adopted old selection before the new child.
            require(load(run, run / 'old2-result.json')['failures'] == 0, 'old2 must pass before new2')
            _, code, parsed = runstage('new2')
            result['state'] = 'COMPLETE_ORDINARY_FAILURE' if parsed['failures'] else 'COMPLETE_PASS'
            result['exit'] = 1 if parsed['failures'] else 0
    except StageFailure as error:
        result.update(state='NATURAL_STAGE_FAILURE', exit=error.code,
                      failureType='StageFailure', failure='natural setup stage exited ' + str(error.code))
    except (OSError, ValueError, TypeError, KeyError, RuntimeError, AttributeError, ImportError) as error:
        result.update(state='INCOMPLETE', exit=125, failureType=type(error).__name__, failure=str(error))
    finally:
        try:
            verify_all()
            result['postflightVerified'] = True
        except (OSError, ValueError, TypeError, KeyError, RuntimeError, AttributeError, ImportError) as error:
            result.update(state='INCOMPLETE', exit=125, postflightVerified=False, postflightFailure=type(error).__name__ + ': ' + str(error))
        result['stateDirectoryEntries'] = sorted(path.relative_to(run).as_posix() for path in (run / 'State').rglob('*'))
        save(run / 'result.json', result)
        save(run / 'status.json', result)
    return result['exit']


def main(argv):
    global HERE
    validate_cli(argv)
    root = HERE.parents[1]
    require(HERE == root / 'Tests/NativeIntegration', 'runner must live at fixed public path')
    checked(root, root, True)
    local = root / '.local'
    if not local.exists():
        local.mkdir(mode=0o700)
    checked(root, local, True)
    parent = local / 'disk-conflict-presentation-integration'
    if not parent.exists():
        parent.mkdir(mode=0o700)
    checked(root, parent, True)
    require(stat.S_IMODE(parent.lstat().st_mode) == 0o700, 'evidence parent must be0700')
    run = Path(tempfile.mkdtemp(prefix='run.', dir=parent))
    run.chmod(0o700)
    try:
        plan = build_plan(root, run)
        manifest = freeze(root, run, plan)
        prior_here = HERE
        HERE = run / 'Runner'
        try:
            return execute(root, run, manifest)
        finally:
            HERE = prior_here
    except (OSError, ValueError, TypeError, KeyError, RuntimeError, AttributeError, ImportError) as error:
        result = dict(state='INCOMPLETE', exit=125, failureType=type(error).__name__, failure=str(error))
        # execute owns terminal records after it enters its guarded lifecycle.
        if not (run / 'result.json').exists():
            save(run / 'result.json', result)
        if not (run / 'status.json').exists():
            save(run / 'status.json', result)
        return 125


if __name__ == '__main__':
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (OSError, ValueError) as error:
        print('Locate presentation runner refused: ' + str(error), file=sys.stderr)
        raise SystemExit(125)
