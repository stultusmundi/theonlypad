"""Validate final local artifacts; no immutable-filesystem or signing claim."""
import contextlib
import hashlib
import json
import os
import pathlib
import plistlib
import re
import stat
import zipfile
import zlib

HELPER = 'Contents/Helpers/PadSearchWorker'
PRIVATE_PATH = re.compile(rb'/(?:Users|home)/[A-Za-z0-9_.-]+/|/Volumes/')


def _require(condition, message):
    if not condition:
        raise ValueError(message)


@contextlib.contextmanager
def _regular_file(path):
    # NONBLOCK avoids hanging on a special file substituted after tree inspection.
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        _require(stat.S_ISREG(os.fstat(fd).st_mode), 'Package artifact is not a regular file.')
        with os.fdopen(fd, 'rb', closefd=False) as stream:
            yield stream
    finally:
        os.close(fd)


def _read_regular(path):
    with _regular_file(path) as stream:
        return stream.read()


def _bundle_tree(bundle):
    _require(stat.S_ISDIR(bundle.lstat().st_mode), 'Package bundle must be a real directory.')
    files, directories = {}, {''}
    pending = [bundle]
    while pending:
        path = pending.pop()
        mode = path.lstat().st_mode
        relative = path.relative_to(bundle).as_posix()
        if stat.S_ISDIR(mode):
            if path != bundle:
                directories.add(relative)
            pending.extend(path.iterdir())
        elif stat.S_ISREG(mode):
            files[relative] = (path, mode)
        else:
            raise ValueError('Package tree contains a linked or special member.')
    return files, directories


def _require_helper(files, directories):
    _require(HELPER in files and 'Contents/Helpers' in directories,
             'Package is missing its fixed helper.')
    members = {name for name in set(files) | directories if name.startswith('Contents/Helpers/')}
    _require(members == {HELPER}, 'Package Helpers inventory is not the fixed single product.')
    _require(files[HELPER][1] & 0o111, 'Package helper is not executable.')
    _require(files[HELPER][0].lstat().st_size > 0, 'Package helper is empty.')


def _bundle_info(data):
    try:
        info = plistlib.loads(data)
    except (ValueError, OverflowError, plistlib.InvalidFileException):
        raise ValueError('Package metadata is invalid.') from None
    fields = ['CFBundleExecutable', 'CFBundleName', 'DevelopmentVersion', 'LSMinimumSystemVersion']
    _require(isinstance(info, dict) and all(isinstance(info.get(key), str) and info[key] for key in fields),
             'Package metadata is incomplete.')
    name = info['CFBundleExecutable']
    _require(name not in ('.', '..') and not any(char in name for char in '/\\\0'),
             'Package executable name is not one path component.')
    return info


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        _require(key not in result, 'SBOM has duplicate JSON fields.')
        result[key] = value
    return result


def _sbom(data):
    try:
        value = json.loads(data.decode('utf-8'), object_pairs_hook=_unique_object)
    except (UnicodeError, json.JSONDecodeError):
        raise ValueError('SBOM JSON is invalid.') from None
    _require(isinstance(value, dict) and value.get('bomFormat') == 'CycloneDX'
             and value.get('specVersion') == '1.6' and type(value.get('version')) is int
             and value['version'] == 1, 'SBOM format is invalid.')
    return value


def _property(component, name):
    properties = component.get('properties')
    _require(isinstance(properties, list) and all(isinstance(item, dict) for item in properties),
             'SBOM properties are invalid.')
    matches = [item.get('value') for item in properties if item.get('name') == name]
    _require(len(matches) == 1, 'SBOM required property is missing or duplicated.')
    return matches[0]


def _component(component, name, version, reference, digest):
    _require(isinstance(component, dict), 'SBOM component is invalid.')
    _require(component.get('type') == 'application' and component.get('name') == name
             and component.get('version') == version and component.get('bom-ref') == reference,
             'SBOM component identity does not match the package.')
    _require(component.get('licenses') == [{'license': {'id': 'MIT'}}],
             'SBOM component license is not MIT.')
    _require(component.get('hashes') == [{'alg': 'SHA-256', 'content': digest}],
             'SBOM executable hash does not match the bundle.')


def _validate_sbom(inventory, info, digests):
    metadata = inventory.get('metadata')
    _require(isinstance(metadata, dict), 'SBOM metadata is missing.')
    root = metadata.get('component')
    _component(root, info['CFBundleName'], info['DevelopmentVersion'], 'application', digests['application'])
    _require(_property(root, 'external-package-count') == '0', 'SBOM external package count is not zero.')
    _require(_property(root, 'minimum-macos') == info['LSMinimumSystemVersion'],
             'SBOM minimum macOS does not match the package.')
    components = inventory.get('components')
    _require(isinstance(components, list) and len(components) == 1,
             'SBOM requires exactly one fixed helper component.')
    helper = components[0]
    _component(helper, 'PadSearchWorker', info['DevelopmentVersion'],
               'helper:PadSearchWorker', digests['helper:PadSearchWorker'])
    _require(helper.get('properties') == [{'name': 'bundle-relative-path', 'value': HELPER}],
             'SBOM helper path is not the fixed bundle path.')
    dependencies = inventory.get('dependencies')
    _require(isinstance(dependencies, list) and len(dependencies) == 2,
             'SBOM dependency graph is incomplete.')
    graph = {}
    for item in dependencies:
        _require(isinstance(item, dict) and set(item) == {'ref', 'dependsOn'}
                 and isinstance(item['ref'], str) and item['ref'] not in graph,
                 'SBOM dependency graph contains invalid or duplicate references.')
        graph[item['ref']] = item['dependsOn']
    _require(graph == {'application': ['helper:PadSearchWorker'], 'helper:PadSearchWorker': []},
             'SBOM dependency graph is not the fixed application/helper relation.')


def _validate_archive(bundle, archive, files, directories):
    expected = {bundle.name + '/' + name for name in files}
    expected_directories = {bundle.name + '/' + name + '/' if name else bundle.name + '/'
                            for name in directories}
    seen, archived = set(), set()
    try:
        with _regular_file(archive) as stream, zipfile.ZipFile(stream) as zipped:
            for entry in zipped.infolist():
                name = entry.filename
                parts = name[:-1].split('/') if name.endswith('/') else name.split('/')
                _require(name and name == entry.orig_filename and '\0' not in name and '\\' not in name
                         and all(part not in ('', '.', '..') for part in parts) and name not in seen,
                         'Archive has duplicate or unsafe paths.')
                seen.add(name)
                mode = entry.external_attr >> 16
                if name.endswith('/'):
                    _require(stat.S_ISDIR(mode) and name in expected_directories,
                             'Archive directory type or name is invalid.')
                    payload = zipped.read(entry)  # Checks the CRC, including directory entries.
                    _require(not payload,
                             'Archive directory type, name or content is invalid.')
                else:
                    _require(stat.S_ISREG(mode), 'Archive contains a linked, special or untyped file.')
                    _require(name in expected, 'Archive inventory does not match the bundle.')
                    relative = name[len(bundle.name) + 1:]
                    if relative == HELPER:
                        _require(mode & 0o111, 'Archive helper is not executable.')
                    payload = zipped.read(entry)
                    _require(payload == files[relative], 'Archive bytes do not match the bundle.')
                    archived.add(name)
    except (zipfile.BadZipFile, RuntimeError, NotImplementedError, EOFError, zlib.error):
        raise ValueError('Archive is invalid or failed CRC validation.') from None
    _require(archived == expected, 'Archive inventory does not match the bundle.')


def validate_package(bundle, archive, sbom):
    """Return (file count, executable SHA256s); refuse invalid final artifacts.

    Inspect every tree member before reading contents and protect final opens.
    Cooperating local staging is required; this is not an immutable tree snapshot.
    """
    bundle, archive, sbom = map(pathlib.Path, (bundle, archive, sbom))
    paths, directories = _bundle_tree(bundle)
    _require_helper(paths, directories)
    files = {name: _read_regular(path) for name, (path, _) in paths.items()}
    _require(all(not PRIVATE_PATH.search(data) for data in files.values()),
             'Package contains a machine-path marker; inspect locally.')
    _require('Contents/Info.plist' in files, 'Package metadata is missing.')
    info = _bundle_info(files['Contents/Info.plist'])
    main = 'Contents/MacOS/' + info['CFBundleExecutable']
    _require(main in files and paths[main][1] & 0o111 and files[main],
             'Package main executable is missing, empty or nonexecutable.')
    digests = {'application': hashlib.sha256(files[main]).hexdigest(),
               'helper:PadSearchWorker': hashlib.sha256(files[HELPER]).hexdigest()}
    _validate_archive(bundle, archive, files, directories)
    _validate_sbom(_sbom(_read_regular(sbom)), info, digests)
    return len(files), digests
