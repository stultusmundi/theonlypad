"""One pure compiler-graph contract with independent mutations; no executables run.

The first private validator is explicitly inert. Valid graph calls complete, then
mutation assertions must fail because ValueError is not raised. No modeabsence
short-circuit, fabricated compiler receipt, or native acceptance is involved.
"""
import importlib.util
import json
from pathlib import Path
import platform
import tempfile
import unittest
import hashlib

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('real_helper_graph_baseline', HERE / 'run_native_regressions.py')
RUNNER = importlib.util.module_from_spec(spec)
spec.loader.exec_module(RUNNER)
MODULES = ('PadCore', 'SearchExecution', 'PadSearchWorkerRuntime', 'PadSearchWorker',
           'NativeRouting', 'NativeRoutingTests', 'NativeRoutingPackageTests')
HELPER_MODULES = MODULES[:4]
TEST_MODULES = ('PadCore', 'SearchExecution', 'NativeRouting', 'NativeRoutingTests', 'NativeRoutingPackageTests')

def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data if isinstance(data, bytes) else data.encode())

def save(path, value): write(path, json.dumps(value, indent=2) + '\n')
def pin(path, root):
    data = path.read_bytes()
    return dict(frozen=path.relative_to(root).as_posix(), sha256=hashlib.sha256(data).hexdigest(), origin=None)

class RealHelperCompilerGraphTests(unittest.TestCase):
    def fixture(self, root):
        binary = root / 'Build/arm64-apple-macosx/debug'
        binary.mkdir(parents=True)
        generated, groups = [], {}
        for module in MODULES:
            if module == 'NativeRoutingPackageTests':
                sources = [binary / (module + '.derived/runner.swift')]
            elif module == 'NativeRoutingTests':
                sources = [root / 'Package/Tests' / module / 'RealTests.swift']
            else:
                sources = [root / 'Package/Sources' / module / 'One.swift']
                if module == 'PadCore': sources.append(root / 'Package/Sources/PadCore/Two.swift')
            objects = []
            mapping = {'': {'swift-dependencies': str(binary / (module + '.build/primary.swiftdeps'))}}
            for source in sources:
                write(source, '// synthetic ' + module + '/' + source.name + '\n')
                if module != 'NativeRoutingPackageTests': generated.append(pin(source, root))
                obj = binary / (module + '.build') / (source.name + '.o')
                write(obj, b'synthetic object, never executed')
                objects.append(str(obj))
                mapping[str(source)] = {'object': str(obj)}
            args = ['-target', platform.machine() + '-apple-macosx14.0', '-warnings-as-errors', '-package-name', 'package']
            if module != 'NativeRoutingPackageTests': args += ['-swift-version', '5']
            module_path = binary / 'Modules' / (module + '.swiftmodule')
            for ext in ('.swiftmodule', '.swiftdoc', '.swiftsourceinfo', '.abi.json'):
                write(binary / 'Modules' / (module + ext), b'synthetic companion')
            filelist = binary / (module + '.build/sources')
            write(filelist, ''.join(str(p) + '\n' for p in sources))
            outputmap = binary / (module + '.build/output-file-map.json')
            save(outputmap, mapping)
            groups[module] = dict(moduleName=module, sources=list(map(str, sources)), objects=objects,
                                  fileList=str(filelist), outputFileMapPath=str(outputmap),
                                  moduleOutputPath=str(module_path), otherArguments=args)
        for product, modules in [('PadSearchWorker', HELPER_MODULES), ('NativeRoutingPackageTests', TEST_MODULES)]:
            write(binary / (product + '.product/Objects.LinkFileList'),
                  ''.join(path + '\n' for module in modules for path in groups[module]['objects']))
        write(binary / 'PadSearchWorker', b'synthetic helper; NEVER EXECUTE')
        bundle = binary / 'NativeRoutingPackageTests.xctest'
        for path in ('Contents/MacOS/NativeRoutingPackageTests',
                     'Contents/MacOS/NativeRoutingPackageTests.dSYM/Contents/Info.plist',
                     'Contents/MacOS/NativeRoutingPackageTests.dSYM/Contents/Resources/DWARF/NativeRoutingPackageTests',
                     'Contents/MacOS/NativeRoutingPackageTests.dSYM/Contents/Resources/Relocations/aarch64/NativeRoutingPackageTests.yml'):
            write(bundle / path, b'synthetic bundle leaf')
        description = dict(swiftCommands=groups, builtTestProducts=[dict(
            binaryPath=str(bundle / 'Contents/MacOS/NativeRoutingPackageTests'),
            packagePath=str(root / 'Package'), productName='NativeRoutingPackageTests')])
        save(binary / 'description.json', description)
        write(root / 'Package/Package.swift', '// synthetic manifest: schema tests only\n')
        generated.append(pin(root / 'Package/Package.swift', root))
        manifest = dict(sources=[], generated=generated, inputTrees=['Package'])
        save(root / 'sources.json', manifest)
        return binary, manifest, description

    def test_valid_baseline_then_independent_compiler_graph_mutations_are_refused(self):
        validator = getattr(RUNNER, 'validate_real_helper_compiler_graph', None)
        self.assertTrue(callable(validator), 'Inert validator declaration required before meaningful mutation RED')
        mutations = ('foreign-source', 'duplicate-source', 'missing-module', 'duplicate-module',
                     'foreign-module', 'wrong-target', 'missing-werror', 'wrong-authored-language',
                     'filelist-missing-source', 'map-swapped-pair', 'map-foreign-source',
                     'object-missing', 'untracked-object', 'module-output-path',
                     'helper-link-missing', 'helper-link-duplicate', 'test-link-worker-leak',
                     'link-shared-object-missing', 'generated-entry-outside', 'test-product-path')
        for mutation in mutations:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp).resolve()
                binary, manifest, description = self.fixture(root)
                validator(root, binary, manifest)  # Otherwise-valid baseline always first.
                groups = description['swiftCommands']
                core = groups['PadCore']
                if mutation == 'foreign-source':
                    path = root / 'outside.swift'
                    write(path, '// unbound foreign source\n')
                    core['sources'][0] = str(path)
                elif mutation == 'duplicate-source': core['sources'].append(core['sources'][0])
                elif mutation == 'missing-module': del groups['SearchExecution']
                elif mutation == 'duplicate-module': groups['secondCore'] = dict(core)
                elif mutation == 'foreign-module':
                    groups['ForeignModule'] = dict(core, moduleName='ForeignModule')
                elif mutation == 'wrong-target': core['otherArguments'][1] = platform.machine() + '-apple-macosx13.0'
                elif mutation == 'missing-werror': core['otherArguments'].remove('-warnings-as-errors')
                elif mutation == 'wrong-authored-language': core['otherArguments'][-1] = '6'
                elif mutation == 'filelist-missing-source': write(Path(core['fileList']), core['sources'][0] + '\n')
                elif mutation.startswith('map-'):
                    path = Path(core['outputFileMapPath'])
                    mapping = json.loads(path.read_text())
                    if mutation == 'map-swapped-pair':
                        a, b = core['sources']
                        mapping[a]['object'], mapping[b]['object'] = mapping[b]['object'], mapping[a]['object']
                    else: mapping[str(root / 'foreign.swift')] = {'object': core['objects'][0]}
                    save(path, mapping)
                elif mutation == 'object-missing': Path(core['objects'][0]).unlink()
                elif mutation == 'untracked-object': write(binary / 'PadCore.build/Untracked.swift.o', b'extra')
                elif mutation == 'module-output-path': core['moduleOutputPath'] = str(binary / 'Modules/SearchExecution.swiftmodule')
                elif mutation.startswith('helper-link'):
                    path = binary / 'PadSearchWorker.product/Objects.LinkFileList'
                    lines = path.read_text().splitlines()
                    write(path, '\n'.join(lines[1:] if mutation.endswith('missing') else lines + [lines[0]]) + '\n')
                elif mutation == 'test-link-worker-leak':
                    path = binary / 'NativeRoutingPackageTests.product/Objects.LinkFileList'
                    write(path, path.read_text() + groups['PadSearchWorker']['objects'][0] + '\n')
                elif mutation == 'link-shared-object-missing':
                    path = binary / 'NativeRoutingPackageTests.product/Objects.LinkFileList'
                    write(path, path.read_text().replace(core['objects'][0] + '\n', ''))
                elif mutation == 'generated-entry-outside':
                    path = root / 'unowned-runner.swift'
                    write(path, '// wrong generated entry\n')
                    groups['NativeRoutingPackageTests']['sources'] = [str(path)]
                elif mutation == 'test-product-path':
                    description['builtTestProducts'][0]['binaryPath'] = str(binary / 'PadSearchWorker')
                save(binary / 'description.json', description)
                with self.assertRaises(ValueError, msg='must refuse ' + mutation):
                    validator(root, binary, manifest)

if __name__ == '__main__': unittest.main()
