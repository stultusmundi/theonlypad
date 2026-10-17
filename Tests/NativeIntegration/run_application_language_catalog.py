"""Fixed retained application/catalog regression; eight serial direct owned stages."""
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

LOCATION = 'Tests/NativeIntegration/run_application_language_catalog.py'
PROOF_LOCATION = 'Tests/NativeIntegration/application_language_catalog_proof.py'
METHODS_LOCATION = 'Tests/NativeIntegration/application-language-catalog-methods.json'
PACKAGE_LOCATION = 'Tests/NativeIntegration/application-language-catalog-Package.swift'
COMBINED_LOCATION = 'Tests/NativeIntegration/ApplicationLanguageCatalogIntegrationTests.swift'
OLD_TEST_LOCATION = 'Tests/NativeIntegration/DocumentSearchAppRoutingTests.swift'
SOURCE_ROOTS = ('Sources/PadCore', 'Sources/SearchExecution', 'Sources/TheOnlyPad')
EXCLUDED_ENTRY = 'Sources/TheOnlyPad/TheOnlyPadApplication.swift'
RECEIPT_FIELDS = set('command pid processGroup exitObserved registrationError groupSignalAttempted '
    'groupSignalError groupCleanup groupQuery waitCompleted returnCode waitError timedOut '
    'interruptedSignal truncated captureComplete failure exit seconds captured'.split())
FIXED_SELECTIONS = {'old4': {'class': 'DocumentSearchAppRoutingTests', 'methods': ['testCapturedSearchPanelClaimsOnlyCloseAndSixNativeEditingSelectors', 'testCapturedSearchAvailabilityAndDispatchShareIdentityAndRefusalPolicy', 'testActualManagedConfigurationStaysSearchLazyAndAppGuardsPrecedeScope', 'testActualQuitPublishesNativeReceiptThenJoinsSearchAndExternalExactlyOnceAcrossVetoAndRetry']}, 'new10': {'class': 'ApplicationLanguageCatalogTests', 'methods': ['testApplicationCatalogStartupRemainsLazyAndStartsOneActualRead', 'testApplicationCatalogFailureRetainsLastConfirmedPublicationAndDocumentStartup', 'testApplicationCatalogErrorPresentationReentryCannotClobberSuccessorState', 'testQuitBeforeCatalogStartupNeverConstructsOrReadsCatalog', 'testBusyCatalogQuitVetoDoesNotInvalidateAndReleasedReadSettles', 'testActualUnresolvedWriteBlocksQuitWithoutAcknowledgingOrDiscarding', 'testNativeVetoRollsBackOnlyActualCatalogReservationAndKeepsSuccessfulCatalogWrite', 'testUnsettledSearchVetoReleasesCatalogWithoutReopeningTerminalSearch', 'testSuccessfulQuitReservesThenJoinsAndInvalidatesActualCatalogBeforeSingleReply', 'testFalseReplyReentryPreservesNewAttemptAndItsNewCatalogReservation']}, 'new9': {'class': 'LanguageManagerReadOnlyTests', 'methods': ['testManagerConstructionKeepsOneApplicationCatalogAuthority', 'testActualTableAndDetailsUseCompleteConfirmedCatalog', 'testHeldRefreshUsesExistingProducerAndTruthfulBusyState', 'testReloadFailurePreservesConfirmedRowsAndAppErrorObserver', 'testSamePublicationQuitNotificationsUpdatePresentation', 'testReentrantDeliveryCannotOverwriteSuccessorPublication', 'testNativeCloseReentryPreservesExactNewManager', 'testApplicationVetoKeepsManagerAndOriginalCatalogReservationRules', 'testCommittedQuitDetachesPresentationAfterActualOwnerJoin']}, 'editSave10': {'class': 'LanguageManagerEditSaveTests', 'methods': ['testNewAndEditKeepExactBoundedRawFieldsAndStableIDs', 'testValidationRejectsFieldAndCatalogCollisionsBeforeStoreAdmission', 'testDeleteAndRevertAreDraftOnlyUntilActualSave', 'testChildEditorNeverRetargetsSelectionOrForeignHistory', 'testActualSaveUsesOriginalOwnerAndCompleteFreshReader', 'testRefusedSaveKeepsRawBaseAndNoAdditionalProducer', 'testSaveCompletionPreservesNewerRawInput', 'testExternalPublicationMarksDirtyDraftStaleWithoutOverwrite', 'testDirtyAndInvalidActualCloseKeepsManagerAndChild', 'testDirtyQuitVetoPrecedesCatalogSearchAndNativePreparation']}, 'regression4': {'class': 'LanguageManagerEditSaveRegressionTests', 'methods': ['testRevertDeletedBaseRefusesSixtyFifthDefinitionWithoutChangingDraft', 'testDiscardSavedFormBaselineRefusesAggregateOverflowAndKeepsCurrentForm', 'testNativeFieldSubmissionReentryKeepsSameHandleSuccessorInControlsAndDone', 'testUninstalledCandidateCloseRetiresOnlyItsOwnSessionAndWindow']}}
TEST_MAPPINGS = {'Tests/NativeIntegration/ApplicationLanguageCatalogIntegrationTests.swift': 'Package/Tests/NativeRoutingTests/DocumentSearchAppRoutingTests.swift', 'Tests/NativeIntegration/ApplicationCatalogStoreControl.swift': 'Package/Tests/NativeRoutingTests/ApplicationCatalogStoreControl.swift', 'Tests/PadCoreTests/CatalogTestFixture.swift': 'Package/Tests/NativeRoutingTests/CatalogTestFixture.swift'}
TAIL_MAPPINGS = {'AppDelegate.swift': ['DocumentSearchAppRoutingAccess.swift', 'ApplicationCatalogAccess.swift', 'LanguageManagerApplicationAccess.swift'], 'EditorWindowController.swift': ['DocumentSearchEditorBindingAccess.swift'], 'NativeApplicationDocuments.swift': ['DocumentSearchAppNativeOwnerAccess.swift'], 'DocumentSearchPanelController.swift': ['DocumentSearchPanelAccess.swift'], 'NativeLanguageManagerSession.swift': ['LanguageManagerSessionAccess.swift'], 'NativeLanguageManagerController.swift': ['LanguageManagerControllerAccess.swift', 'LanguageManagerEditingAccess.swift'], 'NativeLanguageDefinitionEditorController.swift': ['LanguageDefinitionEditingAccess.swift']}
STAGE_BUDGETS = [{'name': 'toolchain', 'timeout': 30}, {'name': 'build', 'timeout': 180}, {'name': 'binpath', 'timeout': 30}, {'name': 'old4', 'timeout': 180}, {'name': 'new10', 'timeout': 180}, {'name': 'new9', 'timeout': 180}, {'name': 'editSave10', 'timeout': 180}, {'name': 'regression4', 'timeout': 180}]
SUPPORT_HASHES = {'scripts/run-owned-search-tests.py': 'd5bd867e4a65b4ee053209fe0a5822867b8d0878fd6d059f474c9b28a0f6286d', 'Tests/NativeIntegration/run_native_regressions.py': 'ff737184848e47d3d7f655196f6a16c25de62acb4671112209dc74c741dc50cf', 'Tests/NativeIntegration/application_language_catalog_proof.py': 'a51a380f2016265187d577416f840eaa83cacd0b6d083aba08f353b5d355cefb', 'Tests/NativeIntegration/ApplicationLanguageCatalogIntegrationTests.swift': '3216eda2cc5f3f93dcb172a328d2e186db1a8b3231204ad988b59a583fdf00e5', 'Tests/NativeIntegration/DocumentSearchAppRoutingTests.swift': '1e196900670029afdfd995f2b30bac50b2fa19e1f312c64809eddc366b3aa0b9', 'Tests/NativeIntegration/ApplicationCatalogStoreControl.swift': '7432da1fb7a622dbc2b4c168fbff8f5774a8d5728f0d9be458b7fa191007988a', 'Tests/PadCoreTests/CatalogTestFixture.swift': '411c68ccc900043125f1c970bf40a28993671e31ada8752cf80c60e45792795b', 'Tests/NativeIntegration/application-language-catalog-Package.swift': '1460f67527046bf1afa69e3083bfde7e342aa1a202a40e10533d67fc221597c8', 'Tests/NativeIntegration/test_application_language_catalog_runner.py': '7715bfbb3123cd3f4e9968c5577608297ab64cd847205c2a27eb29ca625b2501', 'Tests/NativeIntegration/DocumentSearchAppRoutingAccess.swift': '832fb07c9955621e209c5493234ecfbba65fc5871691cdb4301d4cb2bb40057a', 'Tests/NativeIntegration/ApplicationCatalogAccess.swift': '33c4bc49ac4236f40918bea1d0603c264b3e431858a38daa2338037227814c82', 'Tests/NativeIntegration/DocumentSearchEditorBindingAccess.swift': '602a3603c0f872ce2bb5814fd348138518b5276a33b469e2093625da05865537', 'Tests/NativeIntegration/DocumentSearchAppNativeOwnerAccess.swift': 'ec9ffa625b225067bb9573ca3c8087cc3828931885c20d736faabb87b722ee3b', 'Tests/NativeIntegration/DocumentSearchPanelAccess.swift': '063f08d19c8a6081344a3252a574ad7c921011349faf3c06989044810fe579df', 'Tests/NativeIntegration/LanguageManagerApplicationAccess.swift': 'f1700f0417ae0b17e7a407ec609d0a227354efef9a79425fb772bd6754be8c13', 'Tests/NativeIntegration/LanguageManagerSessionAccess.swift': 'fb121b41cbbbb3ddf7e4d3d540d614f1ded22502f76177c616bfad3d120702be', 'Tests/NativeIntegration/LanguageManagerControllerAccess.swift': 'b33b656e7b47bfd042e254c736951719ad6e333c836794c6aedda53849bd8a81', 'Tests/NativeIntegration/LanguageManagerEditingAccess.swift': '24b99f1809728c36d3f0cef4d97c0de260f09144e900ef22500ee4d6b50dfb05', 'Tests/NativeIntegration/LanguageDefinitionEditingAccess.swift': '1ebcc9536d00217a34f10de27846ee46297b6e0f6d60d3b3d5932fdb276b64b9'}


def require(value, message):
    if not value:
        raise ValueError(message)


def checked(root, path, directory=False):
    root, path = Path(root).absolute(), Path(path).absolute()
    require(root.is_absolute() and path.is_relative_to(root) and '..' not in path.parts,
            'path outside owned root')
    parts = path.relative_to(root).parts
    for index in range(len(parts) + 1):
        cursor = root.joinpath(*parts[:index])
        info = cursor.lstat()
        require(not stat.S_ISLNK(info.st_mode) and info.st_uid == os.getuid(), 'unowned or symlink path')
        if cursor != path or directory:
            require(stat.S_ISDIR(info.st_mode), 'owned directory required')
        else:
            require(stat.S_ISREG(info.st_mode), 'owned regular file required')
    return path


def read_input(root, path):
    """One actual descriptor read; bytes/hash and identity share that snapshot."""
    root, path = Path(root).absolute(), Path(path).absolute()
    checked(root, path)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        before = os.fstat(descriptor)
        require(stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid(), 'unowned descriptor')
        with os.fdopen(descriptor, 'rb', closefd=False) as stream:
            data = stream.read()
        after, named = os.fstat(descriptor), path.lstat()
        keys = ('st_dev', 'st_ino', 'st_uid', 'st_mode', 'st_size', 'st_mtime_ns', 'st_ctime_ns')
        require(all(getattr(before, key) == getattr(after, key) == getattr(named, key) for key in keys)
                and len(data) == after.st_size, 'input changed during snapshot')
        checked(root, path)
        fact = dict(path=path.relative_to(root).as_posix(), bytes=len(data),
                    sha256=hashlib.sha256(data).hexdigest(), device=after.st_dev,
                    inode=after.st_ino, uid=after.st_uid, mode=stat.S_IMODE(after.st_mode))
        return data, fact
    finally:
        os.close(descriptor)


def fact(root, path):
    return read_input(root, path)[1]


def directory_fact(root, path):
    path = checked(root, path, directory=True)
    value = path.lstat()
    return dict(path=path.relative_to(Path(root).absolute()).as_posix(), directory=True,
                device=value.st_dev, inode=value.st_ino, uid=value.st_uid,
                mode=stat.S_IMODE(value.st_mode))


def mkdir(root, path):
    root, path = Path(root).absolute(), Path(path).absolute()
    checked(root, root, directory=True)
    require(path.is_relative_to(root) and '..' not in path.parts, 'private directory escape')
    parts = path.relative_to(root).parts
    for index in range(1, len(parts) + 1):
        item = root.joinpath(*parts[:index])
        if not item.exists():
            item.mkdir(mode=0o700)
        checked(root, item, directory=True)
        require(stat.S_IMODE(item.lstat().st_mode) == 0o700, 'private directory must be0700')


def save(path, value):
    with Path(path).open('x') as stream:
        json.dump(value, stream, indent=2)
        stream.write('\n')
    Path(path).chmod(0o600)


def load_json(root, path):
    checked(root, path)
    require(Path(path).stat().st_size <= 8 * 1024 * 1024, 'metadata exceeds bound')
    data, _ = read_input(root, path)
    require(len(data) <= 8 * 1024 * 1024, 'metadata exceeds bound')
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, 'duplicate metadata key')
            result[key] = value
        return result
    return json.loads(data, object_pairs_hook=unique)


def tree(root, path):
    path = checked(root, path, directory=True)
    rows = []
    for item in [path, *sorted(path.rglob('*'))]:
        rows.append(directory_fact(root, item) if item.is_dir() else fact(root, item))
    return rows


def validate_cli(argv):
    require(argv == [], 'fixed application/catalog runner accepts no arguments')


def source_mapping(root):
    mapping = {}
    for prefix in SOURCE_ROOTS:
        source = checked(root, root / prefix, directory=True)
        paths = sorted(source.rglob('*.swift'))
        require(paths, 'missing current Source module')
        names = set()
        target = 'NativeRouting' if source.name == 'TheOnlyPad' else source.name
        for path in paths:
            checked(root, path)
            relative = path.relative_to(root).as_posix()
            if relative == EXCLUDED_ENTRY:
                continue
            require(path.name.casefold() not in names, 'ambiguous module object basename')
            names.add(path.name.casefold())
            mapping[relative] = 'Package/Sources/' + target + '/' + path.relative_to(source).as_posix()
    return mapping



def projected_old_test_prefix(old):
    """Exact two-import header projection of the unchanged qualified old Test."""
    require(isinstance(old, bytes) and len(old) == 51229
            and hashlib.sha256(old).hexdigest() == '1e196900670029afdfd995f2b30bac50b2fa19e1f312c64809eddc366b3aa0b9',
            'qualified old Test bytes changed')
    appkit = b'import AppKit\n'
    native = b'@testable import NativeRouting\n'
    require(old.count(appkit) == 1 and old.count(native) == 1
            and old.count(b'import Darwin\n') == 0
            and old.count(b'@testable import PadCore\n') == 0, 'old import anchors changed')
    return old.replace(appkit, appkit + b'import Darwin\n', 1).replace(
        native, native + b'@testable import PadCore\n', 1)


def support(root):
    captured = {}
    for relative, expected in SUPPORT_HASHES.items():
        data, row = read_input(root, root / relative)
        require(row['sha256'] == expected, 'qualified support changed: ' + relative)
        captured[relative] = data
    require(load_json(root, root / METHODS_LOCATION) == FIXED_SELECTIONS, 'fixed method roster changed')
    combined, old = captured[COMBINED_LOCATION], captured[OLD_TEST_LOCATION]
    prefix = projected_old_test_prefix(old)
    require(combined[:len(prefix)] == prefix, 'whole projected old Test prefix changed')
    require(hashlib.sha256(combined[:85690]).hexdigest() == 'be3c5a274524de6dd10c96246406a4b5197da31c560f2918089a84cf7a74219e',
            'whole original14 Test prefix changed')
    require(hashlib.sha256(combined[:110027]).hexdigest() == '3b288f7fe64b03ea0f710a427aad315e01794dc7dd6b7a0f1aca3366628e1d2e',
            'whole original23 Test prefix changed')
    # The whole-file hash binds every method/body; the frozen proof separately
    # applies its exact accepted declaration parser before any child.
    return captured[PACKAGE_LOCATION].decode('utf-8')


def build_plan(root, run):
    root, run = Path(root).absolute(), Path(run).absolute()
    checked(root, root, directory=True)  # Before any imports or writes.
    package = support(root)
    current = Path(__file__).absolute()
    require(read_input(root, root / LOCATION)[0] == read_input(current.parent, current)[0],
            'public coordinator differs from executing source')
    mapping = source_mapping(root)
    for target in TAIL_MAPPINGS:
        require('Sources/TheOnlyPad/' + target in mapping, 'missing access declaring Source')
    mapping.update(TEST_MAPPINGS)
    require(len({value.casefold() for value in mapping.values()}) == len(mapping), 'ambiguous package destination')
    swift = str(run / 'ToolSupport/scripts/swift.sh')
    common = ['--package-path', str(run / 'Package'), '--scratch-path', str(run / 'BuildProducts')]
    commands = {
        'toolchain': ['/usr/bin/xcrun', 'swift', '--version'],
        'build': [swift, 'build', *common, '--build-tests', '-Xswiftc', '-warnings-as-errors'],
        'binpath': [swift, 'build', *common, '--show-bin-path', '-Xswiftc', '-warnings-as-errors'],
    }
    bundle = run / 'BuildProducts' / (platform.machine() + '-apple-macosx/debug/NativeRoutingPackageTests.xctest')
    for name in ('old4', 'new10', 'new9', 'editSave10', 'regression4'):
        commands[name] = ['/usr/bin/xcrun', 'xctest', '-XCTest',
                          'NativeRoutingTests.' + FIXED_SELECTIONS[name]['class'], str(bundle)]
    commands = {name: ['/usr/bin/env', 'THEONLYPAD_STATE_DIRECTORY=' + str(run / 'State' / name),
                      'TMPDIR=' + str(run / 'Temporary' / name) + '/', *command]
                for name, command in commands.items()}
    return dict(productionOrigins=sorted(name for name in mapping if name.startswith('Sources/')),
                testMappings=dict(TEST_MAPPINGS), tailMappings={name: list(tails) for name, tails in TAIL_MAPPINGS.items()},
                stages=[dict(row) for row in STAGE_BUDGETS], captureAfter='binpath',
                commands=commands, swiftInputs=mapping, package=package,
                selections={name: {'class': row['class'], 'methods': list(row['methods'])} for name, row in FIXED_SELECTIONS.items()},
                tools={'scripts/swift.sh': 'ToolSupport/scripts/swift.sh',
                       'scripts/run-owned-search-tests.py': 'Runner/run-owned-search-tests.py',
                       'Tests/NativeIntegration/run_native_regressions.py': 'Runner/run_native_regressions.py',
                       PROOF_LOCATION: 'Runner/application_language_catalog_proof.py',
                       LOCATION: 'Runner/run_application_language_catalog.py'})


def freeze(root, run, plan):
    os.umask(0o077)
    root, run = Path(root).absolute(), Path(run).absolute()
    checked(root, root, directory=True)
    checked(run, run, directory=True)
    require(stat.S_IMODE(run.lstat().st_mode) == 0o700, 'run must be0700')
    require(build_plan(root, run) == plan, 'fixed plan changed before capture')
    destinations = dict(plan['swiftInputs'])
    destinations.update(plan['tools'])
    destinations.update({METHODS_LOCATION: 'Runner/application-language-catalog-methods.json',
                         PACKAGE_LOCATION: 'Runner/application-language-catalog-Package.swift',
                         'scripts/test-application-language-catalog.sh': 'Runner/test-application-language-catalog.sh'})
    relatives = sorted(set(destinations) | {OLD_TEST_LOCATION,
        'Tests/NativeIntegration/test_application_language_catalog_runner.py'} |
        {'Tests/NativeIntegration/' + tail for tails in TAIL_MAPPINGS.values() for tail in tails})
    captured, originals, copies, sources, generated, recipes, segments = {}, [], [], [], [], [], []
    # This is the sole authoritative Original read. Generated data below never
    # rereads a live source or pairs earlier bytes with a later unrelated fact.
    for relative in relatives:
        data, original = read_input(root, root / relative)
        target = run / 'Original' / relative
        mkdir(run, target.parent)
        with target.open('xb') as stream:
            stream.write(data)
        target.chmod(original['mode'])
        captured[relative] = data
        originals.append(original)
        copies.append(fact(run, target))
        sources.append(dict(source=relative, frozen=target.relative_to(run).as_posix(), sha256=original['sha256']))
    original_dirs = {root}
    for relative in relatives:
        original_dirs.update(path for path in (root / relative).parents if path.is_relative_to(root))
    original_directories = [directory_fact(root, path) for path in sorted(original_dirs)]
    by_origin = {row['path']: row for row in originals}
    for relative, expected in SUPPORT_HASHES.items():
        require(by_origin[relative]['sha256'] == expected, 'unqualified support snapshot')
    prefix = projected_old_test_prefix(captured[OLD_TEST_LOCATION])
    require(captured[COMBINED_LOCATION][:len(prefix)] == prefix,
            'captured whole projected old prefix changed')
    require(hashlib.sha256(captured[COMBINED_LOCATION][:85690]).hexdigest() == 'be3c5a274524de6dd10c96246406a4b5197da31c560f2918089a84cf7a74219e',
            'captured whole original14 Test prefix changed')
    require(hashlib.sha256(captured[COMBINED_LOCATION][:110027]).hexdigest() == '3b288f7fe64b03ea0f710a427aad315e01794dc7dd6b7a0f1aca3366628e1d2e',
            'captured whole original23 Test prefix changed')
    for relative, destination in destinations.items():
        parts = [relative]
        if relative.startswith('Sources/TheOnlyPad/'):
            parts += ['Tests/NativeIntegration/' + tail for tail in TAIL_MAPPINGS.get(Path(relative).name, [])]
        data = b'\n'.join(captured[part] for part in parts)
        target = run / destination
        mkdir(run, target.parent)
        with target.open('xb') as stream:
            stream.write(data)
        target.chmod(by_origin[relative]['mode'])
        if destination == 'ToolSupport/scripts/swift.sh':
            target.chmod(0o700)
        copied = fact(run, target)
        copies.append(copied)
        generated.append(dict(frozen=destination, sha256=copied['sha256'], origin=relative))
        lengths = [len(captured[part]) for part in parts]
        offsets = [sum(lengths[:index]) + index for index in range(len(parts))]
        recipes.append(dict(frozen=destination, inputs=parts, lengths=lengths, offsets=offsets,
                            inputSHA256=[by_origin[part]['sha256'] for part in parts],
                            join='ONE_LF', sha256=copied['sha256']))
        if len(parts) > 1:
            offset = lengths[0]
            for part, length in zip(parts[1:], lengths[1:]):
                segments.append(dict(target=Path(relative).name, source=part, start=offset, end=offset + 1 + length))
                offset += 1 + length
    target = run / 'Package/Package.swift'
    with target.open('xb') as stream:
        stream.write(captured[PACKAGE_LOCATION])
    target.chmod(by_origin[PACKAGE_LOCATION]['mode'])
    copied = fact(run, target)
    copies.append(copied)
    generated.append(dict(frozen='Package/Package.swift', sha256=copied['sha256'], origin=PACKAGE_LOCATION))
    recipes.append(dict(frozen='Package/Package.swift', inputs=[PACKAGE_LOCATION],
                        lengths=[len(captured[PACKAGE_LOCATION])], offsets=[0], join='ONE_LF',
                        inputSHA256=[by_origin[PACKAGE_LOCATION]['sha256']], sha256=copied['sha256']))
    directories = ['Original', 'Package', 'Runner', 'ToolSupport', 'ToolSupport/scripts',
                   'State', 'Temporary', 'Stages', 'Commands']
    for name in directories:
        mkdir(run, run / name)
    stage_dirs = [parent + '/' + row['name'] for row in STAGE_BUDGETS for parent in ('State', 'Temporary')]
    for name in stage_dirs:
        mkdir(run, run / name)
    segments = [row for target in TAIL_MAPPINGS for row in segments if row['target'] == target]
    identities = dict(original=originals, frozen=copies, originalDirectories=original_directories,
                      ownedDirectories=[directory_fact(run, run / name) for name in ['.', *directories, *stage_dirs]])
    manifest = dict(sources=sources, generated=generated,
                    inputTrees=['Original', 'Package', 'Runner', 'ToolSupport/scripts'],
                    plan=plan, identities=identities, derivations=recipes, tailSegments=segments)
    manifest['trees'] = {name: tree(run, run / name) for name in manifest['inputTrees']}
    save(run / 'input-identities.json', identities)
    save(run / 'sources.json', manifest)
    verify_inputs(root, run, manifest)
    native, proof = native_and_proof(run, manifest)
    native.verify(run, manifest)
    proof.application_methods(captured[COMBINED_LOCATION])
    return manifest


def verify_inputs(root, run, manifest):
    root, run = Path(root).absolute(), Path(run).absolute()
    checked(root, root, directory=True)
    checked(run, run, directory=True)
    require(build_plan(root, run) == manifest['plan'], 'current Source/support/plan changed')
    identities = manifest['identities']
    require(load_json(run, run / 'sources.json') == manifest, 'source manifest changed')
    require(load_json(run, run / 'input-identities.json') == identities, 'input identity authority changed')
    for row in identities['originalDirectories']:
        require(directory_fact(root, root / row['path']) == row, 'original directory identity changed')
    for row in identities['original']:
        require(fact(root, root / row['path']) == row, 'current original changed')
    for row in identities['frozen']:
        require(fact(run, run / row['path']) == row, 'captured input changed')
    for row in identities['ownedDirectories']:
        require(directory_fact(run, run / row['path']) == row, 'owned directory identity changed')
    originals = {row['source']: read_input(run, run / row['frozen'])[0] for row in manifest['sources']}
    require(len(originals) == len(manifest['sources']), 'duplicate original authority')
    for recipe in manifest['derivations']:
        data = [originals[name] for name in recipe['inputs']]
        lengths = [len(part) for part in data]
        require(recipe['join'] == 'ONE_LF' and recipe['lengths'] == lengths
                and recipe['offsets'] == [sum(lengths[:index]) + index for index in range(len(data))]
                and recipe['inputSHA256'] == [hashlib.sha256(part).hexdigest() for part in data],
                'derivation recipe changed')
        actual, row = read_input(run, run / recipe['frozen'])
        require(actual == b'\n'.join(data) and row['sha256'] == recipe['sha256'], 'generated bytes differ from Original')
    expected_segments = []
    for target, tails in TAIL_MAPPINGS.items():
        original = originals['Sources/TheOnlyPad/' + target]
        offset = len(original)
        for tail in tails:
            source = 'Tests/NativeIntegration/' + tail
            length = len(originals[source])
            expected_segments.append(dict(target=target, source=source, start=offset, end=offset + 1 + length))
            offset += 1 + length
    require(manifest['tailSegments'] == expected_segments, 'tail ranges/inverse changed')
    prefix = projected_old_test_prefix(originals[OLD_TEST_LOCATION])
    require(originals[COMBINED_LOCATION][:len(prefix)] == prefix, 'whole projected old prefix differs')
    require(hashlib.sha256(originals[COMBINED_LOCATION][:85690]).hexdigest() == 'be3c5a274524de6dd10c96246406a4b5197da31c560f2918089a84cf7a74219e',
            'whole frozen original14 Test prefix differs')
    require(hashlib.sha256(originals[COMBINED_LOCATION][:110027]).hexdigest() == '3b288f7fe64b03ea0f710a427aad315e01794dc7dd6b7a0f1aca3366628e1d2e',
            'whole frozen original23 Test prefix differs')
    for name, rows in manifest['trees'].items():
        require(tree(run, run / name) == rows, 'frozen exact membership changed')
    support_dir = checked(run, run / 'ToolSupport', directory=True)
    require({path.name for path in support_dir.iterdir()} <= {'scripts', '.cache'}, 'foreign ToolSupport entry')
    cache = support_dir / '.cache'
    if cache.exists() or cache.is_symlink():
        for path in [cache, *cache.rglob('*')]:
            checked(run, path, directory=path.is_dir())
    # Recheck actual current origins after derivation/tree verification as well.
    for row in identities['original']:
        require(fact(root, root / row['path']) == row, 'original changed during verification')


def import_module(path, name):
    path = Path(path).absolute()
    before = fact(path.parent, path)
    spec = importlib.util.spec_from_file_location(name, path)
    require(spec is not None and spec.loader is not None, 'dependency loader unavailable')
    module = importlib.util.module_from_spec(spec)
    previous = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        sys.modules[name] = module
        spec.loader.exec_module(module)
    finally:
        sys.dont_write_bytecode = previous
    require(fact(path.parent, path) == before, 'dependency changed during import')
    return module


def native_and_proof(run, manifest):
    run = Path(run)
    require(load_json(run, run / 'sources.json') == manifest, 'source authority changed before import')
    by_path = {row['path']: row for row in manifest['identities']['frozen']}
    for name in ('run_native_regressions.py', 'application_language_catalog_proof.py'):
        path = run / 'Runner' / name
        require(fact(run, path) == by_path[path.relative_to(run).as_posix()], 'dependency capture changed')
    require(fact(run, run / 'Runner/run_native_regressions.py')['sha256'] ==
            SUPPORT_HASHES['Tests/NativeIntegration/run_native_regressions.py'], 'unreviewed native dependency')
    require(fact(run, run / 'Runner/application_language_catalog_proof.py')['sha256'] ==
            SUPPORT_HASHES[PROOF_LOCATION], 'unreviewed proof dependency')
    native = import_module(run / 'Runner/run_native_regressions.py', 'run_native_regressions')
    proof = import_module(run / 'Runner/application_language_catalog_proof.py', 'application_catalog_frozen_proof')
    return native, proof


def capture(run, manifest):
    run = Path(run)
    native, proof = native_and_proof(run, manifest)
    lines = read_input(run, run / 'Stages/binpath/stdout.log')[0].decode('utf-8').strip().splitlines()
    require(len(lines) == 1, 'ambiguous binary path')
    binary = Path(lines[0])
    require(binary == run / 'BuildProducts' / (platform.machine() + '-apple-macosx/debug'), 'foreign binary directory')
    source_fact = fact(run, run / 'sources.json')
    record = proof.capture_native_build(run, binary, source_fact['sha256'])
    graph = proof.validate_native_compiler_graph(run, binary, manifest)
    directories = {run}
    for name in graph['paths']:
        directories.update(path for path in (run / name).parents if path.is_relative_to(run))
    identities = dict(sourceManifestFact=source_fact, buildManifestFact=fact(run, run / 'build-inputs.json'),
                      artifactDirectories=[directory_fact(run, path) for path in sorted(directories)], graph=graph)
    save(run / 'build-identities.json', identities)
    verify_capture(run, manifest, record)
    return record


def verify_capture(run, manifest, record):
    run = Path(run)
    native, proof = native_and_proof(run, manifest)
    identities = load_json(run, run / 'build-identities.json')
    require(fact(run, run / 'sources.json') == identities['sourceManifestFact'], 'source authority identity changed')
    require(fact(run, run / 'build-inputs.json') == identities['buildManifestFact'], 'build authority identity changed')
    proof.verify_native_build(run, record, identities['buildManifestFact']['sha256'])
    for row in identities['artifactDirectories']:
        require(directory_fact(run, run / row['path']) == row, 'artifact directory identity changed')
    # testBinary is <debug>/<bundle>/Contents/MacOS/<binary>: its debug ancestor
    # has four parents from the executable itself.
    binary = (run / record['testBinary']).parents[3]
    require(proof.validate_native_compiler_graph(run, binary, manifest) == identities['graph'], 'compiler graph changed')


def verify_evidence(run, evidence):
    run = Path(run)
    for row in evidence:
        path = run / row['path']
        current = directory_fact(run, path) if row.get('directory') else fact(run, path)
        require(current == row, 'adopted command/receipt/capture/result changed')


def stage(root, run, manifest, execute, verifier, row, evidence):
    verify_inputs(root, run, manifest)
    verify_evidence(run, evidence)
    name, command = row['name'], row['command']
    output = run / 'Stages' / name
    require(not output.exists() and not output.is_symlink(), 'stage output already exists')
    command_path = run / 'Commands' / (name + '.json')
    save(command_path, dict(name=name, command=command, timeout=row['timeout']))
    current_command = fact(run, command_path)
    evidence.append(current_command)  # Pin BEFORE this exact child boundary.
    code = execute(['--timeout', str(row['timeout']), '--output', str(output), '--', *command])
    require(fact(run, command_path) == current_command, 'current command changed during child')
    verify_inputs(root, run, manifest)
    checked(run, output, directory=True)
    require({path.name for path in output.iterdir()} == {'status.json', 'stdout.log', 'stderr.log'}, 'incomplete stage output membership')
    for leaf, limit in (('status.json', 8 * 1024 * 1024), ('stdout.log', 1_048_576), ('stderr.log', 1_048_576)):
        checked(run, output / leaf)
        require((output / leaf).stat().st_size <= limit, 'stage capture exceeds byte bound')
    rows = [read_input(run, output / leaf) for leaf in ('status.json', 'stdout.log', 'stderr.log')]
    require(len(rows[0][0]) <= 8 * 1024 * 1024 and all(len(value[0]) <= 1_048_576 for value in rows[1:]),
            'stage capture grew beyond byte bound')
    evidence.extend([directory_fact(run, output), *[value[1] for value in rows]])
    status = load_json(run, output / 'status.json')
    require(isinstance(status, dict) and set(status) == RECEIPT_FIELDS
            and type(status.get('seconds')) in (int, float) and math.isfinite(status['seconds'])
            and status['seconds'] >= 0, 'strict receipt schema/time invalid')
    require(isinstance(status['captured'], dict) and set(status['captured']) == {'stdout', 'stderr'}
            and all(isinstance(value, dict) and set(value) == {'stored', 'received', 'discarded'}
                    for value in status['captured'].values()), 'capture schema changed')
    require(verifier.receipt_success(output, command, code), 'owned watchdog receipt refused')
    verify_evidence(run, evidence)  # Includes CURRENT emitted receipt/captures.
    if code != 0:
        raise StageFailure(code, name)
    text = rows[1][0].decode('utf-8') + '\n' + rows[2][0].decode('utf-8')
    require(not re.search(r'(?im)^.*(?:warning:|error:)', text), 'stage diagnostic present')
    return code


class StageFailure(Exception):
    def __init__(self, code, name):
        self.code, self.name = code, name


def execute(root, run, child):
    """Normal public orchestration; only its synchronous child adapter is injected."""
    os.umask(0o077)
    root, run = Path(root).absolute(), Path(run).absolute()
    checked(root, root, directory=True)
    checked(run, run, directory=True)
    result = dict(state='INCOMPLETE', exit=125, stages=[], stageEvidence=[], selectionResults={})
    evidence = result['stageEvidence']
    manifest = artifact = None
    strict = proof = None

    def verify_all():
        require(manifest is not None, 'input capture incomplete')
        verify_inputs(root, run, manifest)
        verify_evidence(run, evidence)
        names = {path.name for path in run.iterdir()}
        allowed = {'Original', 'Package', 'Runner', 'ToolSupport', 'State', 'Temporary', 'Stages', 'Commands',
                   'BuildProducts', 'sources.json', 'input-identities.json', 'build-inputs.json',
                   'build-identities.json', 'old4-result.json', 'new10-result.json', 'new9-result.json',
                   'editSave10-result.json', 'regression4-result.json'}
        require(names <= allowed and len({name.casefold() for name in names}) == len(names), 'unexpected or aliased run namespace')
        reached = {value['name'] for value in result['stages']}
        require({path.name for path in (run / 'Commands').iterdir()} == {name + '.json' for name in reached}, 'command membership changed')
        require({path.name for path in (run / 'Stages').iterdir()} == reached, 'stage membership changed')
        for value in result['stages']:
            output = run / 'Stages' / value['name']
            require({path.name for path in output.iterdir()} == {'status.json', 'stdout.log', 'stderr.log'}, 'prior stage output changed')
        if artifact is not None:
            verify_capture(run, manifest, artifact)
        return True

    def runstage(name):
        verify_all()
        budget = next(value for value in STAGE_BUDGETS if value['name'] == name)
        row = dict(budget, command=manifest['plan']['commands'][name])
        retained = dict(name=name, command=row['command'], exit=None, receipt='Stages/' + name + '/status.json')
        result['stages'].append(retained)
        try:
            code = stage(root, run, manifest, child_adapter, strict, row, evidence)
        except StageFailure as error:
            retained['exit'] = error.code
            raise
        retained['exit'] = code
        if name in ('old4', 'new10', 'new9', 'editSave10', 'regression4'):
            text = read_input(run, run / 'Stages' / name / 'stdout.log')[0].decode('utf-8') + '\n' + read_input(run, run / 'Stages' / name / 'stderr.log')[0].decode('utf-8')
            parsed = proof.application_success(text, FIXED_SELECTIONS[name]['class'])
            save(run / (name + '-result.json'), parsed)
            evidence.append(fact(run, run / (name + '-result.json')))
            result['selectionResults'][name] = parsed
            result[name + 'Result'] = parsed
            require(not list((run / 'State' / name).iterdir()), 'selected stage retained unresolved State')
        verify_all()  # Final command, receipt, captures, parsed result and graph.

    errors = (OSError, ValueError, TypeError, KeyError, RuntimeError, AttributeError, ImportError)
    try:
        plan = build_plan(root, run)
        manifest = freeze(root, run, plan)
        evidence.extend([fact(run, run / 'sources.json'), fact(run, run / 'input-identities.json')])
        strict, proof = native_and_proof(run, manifest)
        if child is None:
            path = run / 'Runner/run-owned-search-tests.py'
            require(fact(run, path)['sha256'] == SUPPORT_HASHES['scripts/run-owned-search-tests.py'], 'watchdog changed')
            child_adapter = import_module(path, 'application_catalog_owned_watchdog').main
        else:
            child_adapter = child
        runstage('toolchain')
        runstage('build')
        runstage('binpath')
        artifact = capture(run, manifest)
        evidence.extend([fact(run, run / 'build-inputs.json'), fact(run, run / 'build-identities.json')])
        result['sourceManifestSHA256'] = fact(run, run / 'sources.json')['sha256']
        result['buildManifestSHA256'] = fact(run, run / 'build-inputs.json')['sha256']
        verify_all()
        runstage('old4')
        require(load_json(run, run / 'old4-result.json') == dict(tests=4, failures=0, className=FIXED_SELECTIONS['old4']['class']),
                'old4 exact success required before new10')
        runstage('new10')
        require(load_json(run, run / 'new10-result.json') == dict(tests=10, failures=0, className=FIXED_SELECTIONS['new10']['class']),
                'original14 exact success required before new9')
        runstage('new9')
        require(load_json(run, run / 'new9-result.json') == dict(tests=9, failures=0, className=FIXED_SELECTIONS['new9']['class']),
                'original23 exact success required before editSave10')
        runstage('editSave10')
        require(load_json(run, run / 'editSave10-result.json') == dict(tests=10, failures=0, className=FIXED_SELECTIONS['editSave10']['class']),
                'editSave10 exact success required before regression4')
        runstage('regression4')
        require(load_json(run, run / 'regression4-result.json') == dict(tests=4, failures=0, className=FIXED_SELECTIONS['regression4']['class']),
                'regression4 exact success required before final pass')
        result.update(state='COMPLETE_PASS', exit=0)
    except StageFailure as error:
        valid = type(error.code) is int and 0 < error.code < 256
        result.update(state='OLD4_FAILED_NEW10_UNENTERED' if error.name == 'old4' else 'NATURAL_STAGE_FAILURE',
                      exit=error.code if valid else 125)
    except errors as error:
        result.update(state='INCOMPLETE', exit=125, failureType=type(error).__name__, failure=str(error))
    finally:
        try:
            verify_all()
            result['postflightVerified'] = True
        except errors as error:
            result.update(state='INCOMPLETE', exit=125, postflightVerified=False,
                          postflightFailure=type(error).__name__ + ': ' + str(error))
        state = run / 'State'
        result['stateDirectoryEntries'] = sorted(path.relative_to(run).as_posix() for path in state.rglob('*')) if state.is_dir() else []
        save(run / 'result.json', result)
    print(json.dumps(result), flush=True)
    return result['exit']


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    validate_cli(argv)  # No import, mkdir or child can precede closed admission.
    current = Path(__file__).absolute()
    root = current.parents[2]
    require(current == root / LOCATION, 'fixed public coordinator path required')
    checked(root, root, directory=True)  # Actual caller UID admission before writes/imports.
    os.umask(0o077)
    local = root / '.local'
    if not local.exists():
        local.mkdir(mode=0o700)
    checked(root, local, directory=True)
    parent = local / 'application-language-catalog-integration'
    if not parent.exists():
        parent.mkdir(mode=0o700)
    checked(root, parent, directory=True)
    require(stat.S_IMODE(parent.lstat().st_mode) == 0o700, 'evidence parent must be0700')
    run = Path(tempfile.mkdtemp(prefix='run.', dir=parent))
    run.chmod(0o700)
    print('Private application/catalog evidence: ' + str(run), flush=True)
    return execute(root, run, None)


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print('Application/catalog runner refused: ' + str(error), file=sys.stderr)
        raise SystemExit(125)
