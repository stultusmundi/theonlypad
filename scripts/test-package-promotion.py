#!/usr/bin/env python3
"""Synthetic filesystem regression tests; no compiler or app launch."""
import hashlib
import json
import plistlib
import zipfile
import importlib.util
import pathlib
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('promotion', pathlib.Path(__file__).with_name('promote-package.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PromotionTests(unittest.TestCase):
    def test_staged_artifact_validation_rejects_mismatched_inventory_and_archive(self):
        with tempfile.TemporaryDirectory() as temp:
            stage = pathlib.Path(temp)
            names = ['Example.app', 'Example.zip', 'Example.sbom.json']
            app = stage / names[0]
            binary = app / 'Contents/MacOS/Example'
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b'synthetic executable')
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'Example'}))
            inventory = {'metadata': {'component': {'hashes': [{'alg': 'SHA-256', 'content': hashlib.sha256(binary.read_bytes()).hexdigest()}]}}}
            (stage / names[2]).write_text(json.dumps(inventory))
            with zipfile.ZipFile(stage / names[1], 'w') as archive:
                for file in (binary, app / 'Contents/Info.plist'):
                    archive.write(file, str(file.relative_to(stage)))
            module.validate(stage, names)
            inventory['metadata']['component']['hashes'][0]['content'] = '0' * 64
            (stage / names[2]).write_text(json.dumps(inventory))
            with self.assertRaisesRegex(ValueError, 'SBOM'):
                module.validate(stage, names)
            binary.write_bytes(b'changed executable')
            inventory['metadata']['component']['hashes'][0]['content'] = hashlib.sha256(binary.read_bytes()).hexdigest()
            (stage / names[2]).write_text(json.dumps(inventory))
            with self.assertRaisesRegex(ValueError, 'Archive'):
                module.validate(stage, names)

    def fixture(self, root):
        dist = root / 'dist'
        stage = dist / 'stage'
        stage.mkdir(parents=True)
        names = ['Example.app', 'Example.zip', 'Example.sbom.json']
        for name in names:
            (dist / name).write_text('old ' + name)
            (stage / name).write_text('new ' + name)
        return dist, stage, names

    def test_success_replaces_all_outputs(self):
        with tempfile.TemporaryDirectory() as temp:
            dist, stage, names = self.fixture(pathlib.Path(temp))
            module.promote(stage, dist, names)
            for name in names:
                self.assertEqual((dist / name).read_text(), 'new ' + name)
            self.assertEqual(list(dist.glob('.package-backup.*')), [])

    def test_each_rename_failure_restores_previous_outputs(self):
        for failure in range(1, 7):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temp:
                dist, stage, names = self.fixture(pathlib.Path(temp))
                original = module.os.rename
                count = 0
                def rename(source, target):
                    nonlocal count
                    count += 1
                    if count == failure:
                        raise OSError('synthetic promotion failure')
                    original(source, target)
                with patch.object(module.os, 'rename', side_effect=rename):
                    with self.assertRaises(OSError):
                        module.promote(stage, dist, names)
                for name in names:
                    self.assertEqual((dist / name).read_text(), 'old ' + name)

    def test_rollback_failure_retains_recoverable_backup(self):
        with tempfile.TemporaryDirectory() as temp:
            dist, stage, names = self.fixture(pathlib.Path(temp))
            original = module.os.rename
            count = 0
            def rename(source, target):
                nonlocal count
                count += 1
                if count >= 5:
                    raise OSError('synthetic persistent filesystem failure')
                original(source, target)
            with patch.object(module.os, 'rename', side_effect=rename):
                with self.assertRaisesRegex(RuntimeError, 'backup retained'):
                    module.promote(stage, dist, names)
            backups = list(dist.glob('.package-backup.*'))
            self.assertEqual(len(backups), 1)
            for name in names:
                self.assertEqual((backups[0] / name).read_text(), 'old ' + name)

    def test_missing_staged_output_does_not_touch_existing_outputs(self):
        with tempfile.TemporaryDirectory() as temp:
            dist, stage, names = self.fixture(pathlib.Path(temp))
            (stage / names[-1]).unlink()
            with self.assertRaises(FileNotFoundError):
                module.promote(stage, dist, names)
            for name in names:
                self.assertEqual((dist / name).read_text(), 'old ' + name)

    def test_first_package_failure_removes_partial_outputs(self):
        with tempfile.TemporaryDirectory() as temp:
            dist, stage, names = self.fixture(pathlib.Path(temp))
            for name in names:
                (dist / name).unlink()
            original = module.os.rename
            def rename(source, target):
                if pathlib.Path(source) == stage / names[-1]:
                    raise OSError('synthetic promotion failure')
                original(source, target)
            with patch.object(module.os, 'rename', side_effect=rename):
                with self.assertRaises(OSError):
                    module.promote(stage, dist, names)
            self.assertFalse(any((dist / name).exists() for name in names))


if __name__ == '__main__':
    unittest.main()
