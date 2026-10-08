#!/usr/bin/env python3
"""Synthetic package behavior at the real checker and promotion boundaries."""
import copy
import hashlib
import importlib.util
import json
import os
import pathlib
import plistlib
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile

sys.dont_write_bytecode = True
SCRIPTS = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('package_test_promotion', SCRIPTS / 'promote-package.py')
promotion = importlib.util.module_from_spec(spec)
spec.loader.exec_module(promotion)
HELPER = 'Contents/Helpers/PadSearchWorker'


class SyntheticPackage:
    def __init__(self, root):
        self.root = root
        root.mkdir(parents=True, exist_ok=True)
        self.names = ['Example.app', 'Example.zip', 'Example.sbom.json']
        self.app, self.archive, self.sbom = [root / name for name in self.names]
        self.main = self.app / 'Contents/MacOS/Example'
        self.helper = self.app / HELPER
        self.main.parent.mkdir(parents=True)
        self.helper.parent.mkdir(parents=True)
        self.main.write_bytes(b'synthetic main executable')
        self.helper.write_bytes(b'synthetic fixed helper executable')
        self.main.chmod(0o755)
        self.helper.chmod(0o755)
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleExecutable': 'Example', 'CFBundleName': 'Example',
            'DevelopmentVersion': '0.1.0-dev', 'LSMinimumSystemVersion': '14.0',
        }))
        component = {
            'type': 'application', 'name': 'Example', 'version': '0.1.0-dev',
            'bom-ref': 'application', 'licenses': [{'license': {'id': 'MIT'}}],
            'hashes': [{'alg': 'SHA-256', 'content': self.digest(self.main)}],
            'properties': [{'name': 'external-package-count', 'value': '0'},
                           {'name': 'minimum-macos', 'value': '14.0'}],
        }
        self.inventory = {
            'bomFormat': 'CycloneDX', 'specVersion': '1.6', 'version': 1,
            'metadata': {'component': component},
            'components': [{
                'type': 'application', 'name': 'PadSearchWorker', 'version': '0.1.0-dev',
                'bom-ref': 'helper:PadSearchWorker', 'licenses': [{'license': {'id': 'MIT'}}],
                'hashes': [{'alg': 'SHA-256', 'content': self.digest(self.helper)}],
                'properties': [{'name': 'bundle-relative-path', 'value': HELPER}],
            }],
            'dependencies': [
                {'ref': 'application', 'dependsOn': ['helper:PadSearchWorker']},
                {'ref': 'helper:PadSearchWorker', 'dependsOn': []},
            ],
        }
        self.save_inventory()
        self.rebuild_archive()

    @staticmethod
    def digest(path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def save_inventory(self):
        self.sbom.write_text(json.dumps(self.inventory) + '\n')

    def refresh_helper_hash(self):
        self.inventory['components'][0]['hashes'][0]['content'] = self.digest(self.helper)
        self.save_inventory()

    def rebuild_archive(self):
        # Explicit Unix types distinguish payload validity from archive metadata validity.
        with zipfile.ZipFile(self.archive, 'w', compression=zipfile.ZIP_STORED) as zipped:
            for path in [self.app, *sorted(self.app.rglob('*'))]:
                directory = path.is_dir()
                name = path.relative_to(self.root).as_posix() + ('/' if directory else '')
                info = zipfile.ZipInfo(name)
                info.create_system = 3
                mode = stat.S_IFDIR | 0o755 if directory else stat.S_IFREG | (path.stat().st_mode & 0o777)
                info.external_attr = (mode << 16) | (0x10 if directory else 0)
                zipped.writestr(info, b'' if directory else path.read_bytes())

    def archive_records(self):
        with zipfile.ZipFile(self.archive) as zipped:
            return [(copy.copy(info), zipped.read(info)) for info in zipped.infolist()]

    def write_records(self, records):
        with zipfile.ZipFile(self.archive, 'w', compression=zipfile.ZIP_STORED) as zipped:
            for info, data in records:
                zipped.writestr(info, data)


class PackageValidationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.package = SyntheticPackage(self.root / 'stage')

    def check(self, package):
        return subprocess.run(
            [sys.executable, str(SCRIPTS / 'check-package.py'), str(package.app),
             str(package.archive), str(package.sbom)], capture_output=True, text=True,
            timeout=5, env=dict(os.environ, PYTHONDONTWRITEBYTECODE='1'))

    def assert_refused(self, package, reason):
        # Subtests keep the independent promotion assertion when the checker lacks a guard.
        with self.subTest(consumer='check-package', reason=reason):
            result = self.check(package)
            self.assertNotEqual(result.returncode, 0, reason)
        with self.subTest(consumer='promotion.validate', reason=reason):
            with self.assertRaises((ValueError, OSError, zipfile.BadZipFile), msg=reason):
                promotion.validate(package.root, package.names)

    def test_regular_executable_helper_and_exact_archive_sbom_are_valid(self):
        result = self.check(self.package)
        self.assertEqual(result.returncode, 0, result.stderr)
        promotion.validate(self.package.root, self.package.names)

    def test_absent_helper_cannot_be_hidden_by_matching_archive_inventory(self):
        self.package.helper.unlink()
        self.package.rebuild_archive()
        self.assert_refused(self.package, 'fixed helper is required independently of ZIP inventory')

    def test_empty_helper_with_updated_hash_and_archive_is_not_an_executable_product(self):
        self.package.helper.write_bytes(b'')
        self.package.refresh_helper_hash()
        self.package.rebuild_archive()
        self.assert_refused(self.package, 'empty helper cannot become valid through matching hashes')

    def test_linked_helper_cannot_borrow_identical_external_bytes(self):
        target = self.root / 'external-helper'
        target.write_bytes(self.package.helper.read_bytes())
        target.chmod(0o755)
        self.package.helper.unlink()
        self.package.helper.symlink_to(target)
        self.assert_refused(self.package, 'final helper symlink must be rejected before reading')

    def test_linked_helpers_ancestor_cannot_pass_final_regular_file_check(self):
        directory = self.package.helper.parent
        target = self.root / 'external-helpers'
        directory.rename(target)
        directory.symlink_to(target, target_is_directory=True)
        self.assert_refused(self.package, 'linked Helpers ancestor is outside trusted bundle tree')

    def test_helper_directory_is_not_a_regular_executable(self):
        self.package.helper.unlink()
        self.package.helper.mkdir()
        self.assert_refused(self.package, 'directory cannot replace helper product')

    def test_fifo_helper_is_refused_without_reading_or_blocking(self):
        self.package.helper.unlink()
        os.mkfifo(self.package.helper)
        self.assert_refused(self.package, 'FIFO helper must be rejected using file type')

    def test_nonexecutable_helper_with_matching_archive_is_refused(self):
        self.package.helper.chmod(0o644)
        self.package.rebuild_archive()
        self.assert_refused(self.package, 'regular helper requires executable mode')

    def test_unexpected_helpers_member_is_not_sanctioned_by_complete_archive(self):
        (self.package.helper.parent / 'OtherWorker').write_bytes(b'unexpected helper')
        self.package.rebuild_archive()
        self.assert_refused(self.package, 'Helpers contains exactly one fixed product')

    def test_special_file_elsewhere_in_bundle_is_not_silently_omitted(self):
        os.mkfifo(self.package.app / 'Contents/synthetic-fifo')
        self.assert_refused(self.package, 'all bundle members must be regular files or directories')

    def test_missing_helper_component_cannot_pass_main_hash_validation(self):
        self.package.inventory['components'] = []
        self.package.save_inventory()
        self.assert_refused(self.package, 'main executable hash does not authenticate the helper')

    def test_duplicate_or_extra_component_is_refused(self):
        for name in ['duplicate', 'extra']:
            with self.subTest(shape=name):
                package = SyntheticPackage(self.root / name)
                extra = copy.deepcopy(package.inventory['components'][0])
                if name == 'extra':
                    extra['name'] = 'UnapprovedWorker'
                    extra['bom-ref'] = 'helper:UnapprovedWorker'
                package.inventory['components'].append(extra)
                package.save_inventory()
                self.assert_refused(package, 'sole helper component cannot be duplicated or expanded')

    def test_helper_metadata_matches_fixed_product_and_parent_version(self):
        for field, value in [('name', 'OtherWorker'), ('version', '9.9'),
                             ('type', 'library'), ('bom-ref', 'helper:OtherWorker')]:
            with self.subTest(field=field):
                package = SyntheticPackage(self.root / field)
                package.inventory['components'][0][field] = value
                package.save_inventory()
                self.assert_refused(package, 'fixed helper identity/version/type/reference mismatch')

    def test_helper_license_is_mit(self):
        self.package.inventory['components'][0]['licenses'] = [{'license': {'id': 'Proprietary'}}]
        self.package.save_inventory()
        self.assert_refused(self.package, 'helper license must describe the adopted MIT component')

    def test_helper_bundle_path_is_exact_and_required(self):
        for name, properties in [
                ('wrong', [{'name': 'bundle-relative-path', 'value': 'Contents/MacOS/PadSearchWorker'}]),
                ('missing', []),
                ('duplicate', [{'name': 'bundle-relative-path', 'value': HELPER}] * 2)]:
            with self.subTest(shape=name):
                package = SyntheticPackage(self.root / name)
                package.inventory['components'][0]['properties'] = properties
                package.save_inventory()
                self.assert_refused(package, 'helper path property is one exact fixed binding')

    def test_helper_digest_is_required_and_matches_final_bytes(self):
        for name, hashes in [('wrong', [{'alg': 'SHA-256', 'content': '0' * 64}]),
                             ('missing', [])]:
            with self.subTest(shape=name):
                package = SyntheticPackage(self.root / name)
                package.inventory['components'][0]['hashes'] = hashes
                package.save_inventory()
                self.assert_refused(package, 'actual final helper bytes require their own SHA-256')

    def test_external_dependency_count_cannot_expand_or_disappear(self):
        for name in ['nonzero', 'missing']:
            with self.subTest(shape=name):
                package = SyntheticPackage(self.root / name)
                properties = package.inventory['metadata']['component']['properties']
                if name == 'nonzero':
                    properties[0]['value'] = '1'
                else:
                    properties = [item for item in properties if item['name'] != 'external-package-count']
                package.inventory['metadata']['component']['properties'] = properties
                package.save_inventory()
                self.assert_refused(package, 'external dependency inventory remains exactly zero')

    def test_dependency_graph_cannot_drop_redirect_or_cycle_helper_binding(self):
        graphs = [[], [{'ref': 'application', 'dependsOn': []}],
                  [{'ref': 'application', 'dependsOn': ['other']},
                   {'ref': 'helper:PadSearchWorker', 'dependsOn': []}],
                  [{'ref': 'application', 'dependsOn': ['helper:PadSearchWorker']},
                   {'ref': 'helper:PadSearchWorker', 'dependsOn': ['application']}]]
        for index, graph in enumerate(graphs):
            with self.subTest(graph=index):
                package = SyntheticPackage(self.root / f'graph-{index}')
                package.inventory['dependencies'] = graph
                package.save_inventory()
                self.assert_refused(package, 'exact application-to-helper dependency graph is required')

    def test_main_identity_and_version_match_actual_plist(self):
        for field, value in [('name', 'DifferentApp'), ('version', '9.9'), ('bom-ref', 'other-root')]:
            with self.subTest(field=field):
                package = SyntheticPackage(self.root / field)
                package.inventory['metadata']['component'][field] = value
                package.save_inventory()
                self.assert_refused(package, 'root SBOM identity must match the actual app')

    def test_changed_helper_and_updated_sbom_cannot_pass_stale_archive(self):
        self.package.helper.write_bytes(b'changed helper bytes')
        self.package.refresh_helper_hash()
        self.assert_refused(self.package, 'helper hash agreement cannot repair stale archive bytes')

    def test_archive_cannot_omit_or_replace_helper_payload(self):
        for name in ['omitted', 'replaced']:
            with self.subTest(shape=name):
                package = SyntheticPackage(self.root / name)
                records = package.archive_records()
                if name == 'omitted':
                    records = [(info, data) for info, data in records if info.filename != 'Example.app/' + HELPER]
                else:
                    records = [(info, b'replacement payload' if info.filename == 'Example.app/' + HELPER else data)
                               for info, data in records]
                package.write_records(records)
                self.assert_refused(package, 'archived helper must be the final bundled helper')

    def test_helper_archive_mode_and_type_only_changes_fail_with_identical_payloads(self):
        for name, mode in [('nonexec', stat.S_IFREG | 0o644), ('symlink', stat.S_IFLNK | 0o755),
                           ('fifo', stat.S_IFIFO | 0o755), ('directory', stat.S_IFDIR | 0o755),
                           ('untyped', 0o755)]:
            with self.subTest(shape=name):
                package = SyntheticPackage(self.root / name)
                self.assert_metadata_only_refused(package, 'Example.app/' + HELPER, mode)

    def test_all_archive_member_types_and_directory_names_are_validated(self):
        for name, member, mode in [
                ('linked-info', 'Example.app/Contents/Info.plist', stat.S_IFLNK | 0o644),
                ('special-main', 'Example.app/Contents/MacOS/Example', stat.S_IFIFO | 0o755),
                ('directory-as-file', 'Example.app/Contents/', stat.S_IFREG | 0o755),
                ('file-as-directory', 'Example.app/Contents/Info.plist', stat.S_IFDIR | 0o755)]:
            with self.subTest(shape=name):
                package = SyntheticPackage(self.root / name)
                self.assert_metadata_only_refused(package, member, mode)

    def assert_metadata_only_refused(self, package, member, mode):
        records = package.archive_records()
        original_payloads = [(info.filename, data) for info, data in records]
        original_sbom = package.sbom.read_bytes()
        original_helper = package.helper.read_bytes()
        found = 0
        for info, _ in records:
            if info.filename == member:
                info.external_attr = mode << 16
                found += 1
        self.assertEqual(found, 1, 'metadata mutation targets exactly one actual ZIP member')
        package.write_records(records)
        self.assertEqual([(info.filename, data) for info, data in package.archive_records()], original_payloads)
        self.assertEqual(package.sbom.read_bytes(), original_sbom)
        self.assertEqual(package.helper.read_bytes(), original_helper)
        self.assert_refused(package, 'payload/hash equality cannot authenticate invalid ZIP file type/mode')

    def test_machine_path_marker_in_helper_is_refused_even_with_matching_hashes(self):
        self.package.helper.write_bytes(b'/' + b'Volumes/' + b'synthetic-marker/helper')
        self.package.refresh_helper_hash()
        self.package.rebuild_archive()
        self.assert_refused(self.package, 'helper content participates in the existing machine-path scan')

    def test_main_hash_guard_remains_active(self):
        self.package.inventory['metadata']['component']['hashes'][0]['content'] = '0' * 64
        self.package.save_inventory()
        self.assert_refused(self.package, 'original main SHA-256 guard remains required')

    def test_unexpected_archive_member_is_not_ignored_by_promotion(self):
        records = self.package.archive_records()
        info = zipfile.ZipInfo('Example.app/Contents/unexpected')
        info.create_system = 3
        info.external_attr = (stat.S_IFREG | 0o644) << 16
        self.package.write_records(records + [(info, b'unexpected payload')])
        self.assert_refused(self.package, 'whole archive inventory must match the complete bundle')

    def test_unsafe_and_duplicate_zip_names_are_refused(self):
        for name in ['/absolute', 'Example.app/../escape', 'Example.app/Contents/Info.plist']:
            with self.subTest(member=name):
                package = SyntheticPackage(self.root / ('unsafe-' + str(len(list(self.root.iterdir())))))
                records = package.archive_records()
                info = zipfile.ZipInfo(name)
                info.create_system = 3
                info.external_attr = (stat.S_IFREG | 0o644) << 16
                package.write_records(records + [(info, b'extra payload')])
                self.assert_refused(package, 'unsafe or duplicate ZIP names cannot be promoted')

    def test_corrupt_helper_crc_is_refused(self):
        with zipfile.ZipFile(self.package.archive) as zipped:
            info = zipped.getinfo('Example.app/' + HELPER)
        archive = bytearray(self.package.archive.read_bytes())
        filename_length, extra_length = struct.unpack_from('<HH', archive, info.header_offset + 26)
        offset = info.header_offset + 30 + filename_length + extra_length
        archive[offset] ^= 1
        self.package.archive.write_bytes(archive)
        self.assert_refused(self.package, 'CRC failure cannot validate a helper payload')

    def test_helper_change_after_initial_check_is_refused_before_promotion(self):
        result = self.check(self.package)
        self.assertEqual(result.returncode, 0, result.stderr)
        dist = self.root / 'dist'
        dist.mkdir()
        for name in self.package.names:
            (dist / name).write_bytes(('old ' + name).encode())
        self.package.helper.write_bytes(b'helper changed after initial successful validation')
        result = subprocess.run(
            [sys.executable, str(SCRIPTS / 'promote-package.py'), str(self.package.root), str(dist),
             *self.package.names], capture_output=True, text=True, timeout=5,
            env=dict(os.environ, PYTHONDONTWRITEBYTECODE='1'))
        with self.subTest(boundary='refusal'):
            self.assertNotEqual(result.returncode, 0, 'promotion revalidates changed helper independently')
        for name in self.package.names:
            with self.subTest(preserved=name):
                self.assertTrue((dist / name).is_file(), 'original output remains its original file')
                self.assertEqual((dist / name).read_bytes(), ('old ' + name).encode())
        self.assertEqual(list(dist.glob('.package-backup.*')), [])


if __name__ == '__main__':
    unittest.main()
