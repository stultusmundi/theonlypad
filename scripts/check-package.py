#!/usr/bin/env python3
"""Verify a local bundle/archive/SBOM without printing embedded paths or content."""
import hashlib
import json
import pathlib
import plistlib
import re
import sys
import zipfile

bundle, archive, sbom = map(pathlib.Path, sys.argv[1:])
info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
files = {p.relative_to(bundle).as_posix(): p.read_bytes()
         for p in bundle.rglob('*') if p.is_file()}
private_path = re.compile(rb'/(?:Users|home)/[A-Za-z0-9_.-]+/|/Volumes/')
for name, data in files.items():
    if private_path.search(data):
        raise SystemExit(f'Package contains a machine-path marker in {name}; inspect locally.')
with zipfile.ZipFile(archive) as compressed:
    names = compressed.namelist()
    if len(names) != len(set(names)) or any(
        name.startswith('/') or '..' in pathlib.PurePosixPath(name).parts for name in names
    ):
        raise SystemExit('Archive has duplicate or unsafe paths.')
    archived = {name for name in names if not name.endswith('/')}
    expected = {f'{bundle.name}/{name}' for name in files}
    if archived != expected:
        raise SystemExit('Archive inventory does not match the bundle.')
    if any(compressed.read(f'{bundle.name}/{name}') != data for name, data in files.items()):
        raise SystemExit('Archive bytes do not match the bundle.')
binary = files[f'Contents/MacOS/{info["CFBundleExecutable"]}']
digest = hashlib.sha256(binary).hexdigest()
component = json.loads(sbom.read_text())['metadata']['component']
if {'alg': 'SHA-256', 'content': digest} not in component['hashes']:
    raise SystemExit('SBOM executable hash does not match the bundle.')
print(f'Package verified: {len(files)} files; SHA-256 {digest}')
