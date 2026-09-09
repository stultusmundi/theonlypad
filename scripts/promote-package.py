#!/usr/bin/env python3
"""Validate staged development artifacts and promote them with failure rollback.

Promotion is not atomic across three paths. Caught errors trigger rollback;
process termination or rollback failure leaves a private backup in dist for
manual recovery. No original artifacts are stored in the shell's staging dir.
"""
import fcntl
import hashlib
import json
import os
import pathlib
import plistlib
import shutil
import sys
import tempfile
import zipfile


def validate(stage, names):
    app, archive, sbom = [stage / name for name in names]
    info_path = app / 'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    binary_relative = pathlib.Path('Contents/MacOS') / info['CFBundleExecutable']
    binary = (app / binary_relative).read_bytes()
    inventory = json.loads(sbom.read_text())
    component = inventory['metadata']['component']
    if not any(item['alg'] == 'SHA-256' and item['content'] == hashlib.sha256(binary).hexdigest()
               for item in component['hashes']):
        raise ValueError('SBOM does not match staged executable')
    with zipfile.ZipFile(archive) as zipped:
        if zipped.testzip() is not None:
            raise ValueError('Archive CRC validation failed')
        for relative in (pathlib.Path('Contents/Info.plist'), binary_relative):
            if zipped.read(str(pathlib.Path(app.name) / relative)) != (app / relative).read_bytes():
                raise ValueError('Archive does not match staged bundle')


def promote(stage, dist, names):
    stage, dist = pathlib.Path(stage), pathlib.Path(dist)
    if len(set(names)) != len(names) or any(pathlib.Path(n).name != n or n in ('', '.', '..') for n in names):
        raise ValueError('Artifact names must be unique path components')
    for name in names:
        if not (stage / name).exists() or (stage / name).is_symlink():
            raise FileNotFoundError('Missing or linked staged artifact: ' + name)
        if (dist / name).is_symlink():
            raise ValueError('Refusing linked destination: ' + name)
    # Serialize cooperating promotions; builds may finish in either order.
    with (dist / '.package-promotion.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        backup = pathlib.Path(tempfile.mkdtemp(prefix='.package-backup.', dir=dist))
        saved, installed = [], []
        try:
            for name in names:
                if (dist / name).exists():
                    os.rename(dist / name, backup / name)
                    saved.append(name)
            for name in names:
                os.rename(stage / name, dist / name)
                installed.append(name)
        except BaseException as error:
            failures = []
            for name in reversed(installed):
                try:
                    os.rename(dist / name, stage / name)
                except BaseException as failure:
                    failures.append(failure)
            for name in reversed(saved):
                try:
                    # Never overwrite a promoted directory if its removal failed.
                    if (dist / name).exists():
                        raise OSError('Destination still occupied: ' + name)
                    os.rename(backup / name, dist / name)
                except BaseException as failure:
                    failures.append(failure)
            if failures:
                raise RuntimeError('Promotion rollback failed; backup retained at ' + str(backup)) from error
            shutil.rmtree(backup)
            raise
        else:
            shutil.rmtree(backup)


if __name__ == '__main__':
    if len(sys.argv) != 6:
        sys.exit('Usage: promote-package.py STAGE DIST APP_NAME ZIP_NAME SBOM_NAME')
    stage, dist = map(pathlib.Path, sys.argv[1:3])
    names = sys.argv[3:]
    validate(stage, names)
    promote(stage, dist, names)
