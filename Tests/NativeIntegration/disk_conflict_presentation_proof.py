"""Narrow accepted V4 five-module validator; only BuildProducts namespace differs."""
from pathlib import Path
import platform
import re
import shlex
from accepted_native import read_real, verify, real_helper_owned_path, real_helper_json

NATIVE_MODULES = ('PadCore', 'SearchExecution', 'NativeRouting', 'NativeRoutingTests', 'NativeRoutingPackageTests')

def validate_native_compiler_graph(run,binary,manifest):
    """Actual five-module compiler maps and sole native Test link union."""
    run,binary=Path(run),Path(binary)
    real_helper_owned_path(run,binary,directory=True)
    if not binary.is_relative_to(run/'BuildProducts'): raise ValueError('compiler products outside owned Build')
    verify(run,manifest)
    description=real_helper_json(run,binary/'description.json')
    commands=description.get('swiftCommands')
    if not isinstance(commands,dict) or len(commands)!=len(NATIVE_MODULES):
        raise ValueError('unexpected compiler module census')
    groups={}
    for command in commands.values():
        if not isinstance(command,dict): raise ValueError('invalid compiler group')
        module=command.get('moduleName')
        if module not in NATIVE_MODULES or module in groups: raise ValueError('foreign or duplicate module')
        groups[module]=command
    if set(groups)!=set(NATIVE_MODULES): raise ValueError('missing compiler module')
    paths={binary/'description.json'};module_rows=[];memberships=[];objects={};package_names=[]
    for module in NATIVE_MODULES:
        command=groups[module]
        if module=='NativeRoutingPackageTests':
            expected=[binary/'NativeRoutingPackageTests.derived/runner.swift']
        else:
            prefix='Package/'+('Tests/' if module=='NativeRoutingTests' else 'Sources/')+module+'/'
            expected=sorted(run/row['frozen'] for row in manifest['generated']
                if row['frozen'].startswith(prefix) and row['frozen'].endswith('.swift'))
        if not expected or len(set(expected))!=len(expected): raise ValueError('missing or repeated frozen module Source')
        declared=command.get('sources')
        if not isinstance(declared,list) or any(type(x) is not str for x in declared): raise ValueError('invalid compiler Sources')
        if len(set(declared))!=len(declared) or sorted(declared)!=sorted(map(str,expected)):
            raise ValueError('compiler Sources differ from frozen membership')
        for source in expected: real_helper_owned_path(run,source)
        object_paths=[binary/(module+'.build')/(source.name+'.o') for source in expected]
        if len(set(object_paths))!=len(object_paths): raise ValueError('ambiguous Source basenames')
        declared_objects=command.get('objects')
        if not isinstance(declared_objects,list) or any(type(x) is not str for x in declared_objects):
            raise ValueError('invalid compiler objects')
        if len(set(declared_objects))!=len(declared_objects) or sorted(declared_objects)!=sorted(map(str,object_paths)):
            raise ValueError('compiler object pairing differs')
        actual_objects=sorted((binary/(module+'.build')).rglob('*.o'))
        if actual_objects!=sorted(object_paths): raise ValueError('unknown or missing module object')
        for path in object_paths: real_helper_owned_path(run,path)
        filelist=binary/(module+'.build/sources');outputmap=binary/(module+'.build/output-file-map.json')
        module_output=binary/'Modules'/(module+'.swiftmodule')
        if (command.get('fileList')!=str(filelist) or command.get('outputFileMapPath')!=str(outputmap)
            or command.get('moduleOutputPath')!=str(module_output)):
            raise ValueError('compiler output path changed')
        real_helper_owned_path(run,filelist)
        listed=shlex.split(read_real(run,filelist).decode())
        if len(listed)!=len(set(listed)) or sorted(listed)!=sorted(declared): raise ValueError('compiler filelist differs')
        mapping=real_helper_json(run,outputmap)
        if not isinstance(mapping,dict) or set(mapping)!={*declared,''}: raise ValueError('compiler outputmap Source census differs')
        for source,obj in zip(expected,object_paths):
            value=mapping[str(source)]
            if not isinstance(value,dict) or value.get('object')!=str(obj): raise ValueError('compiler Source/object map differs')
        arguments=command.get('otherArguments')
        if not isinstance(arguments,list) or any(type(x) is not str for x in arguments): raise ValueError('invalid compiler flags')
        def operand(flag):
            if arguments.count(flag)!=1 or arguments.index(flag)+1>=len(arguments): raise ValueError('missing/duplicate compiler operand')
            return arguments[arguments.index(flag)+1]
        if operand('-target')!=platform.machine()+'-apple-macosx14.0' or arguments.count('-warnings-as-errors')!=1:
            raise ValueError('compiler target or Werror changed')
        if module!='NativeRoutingPackageTests' or '-swift-version' in arguments:
            if operand('-swift-version')!='5': raise ValueError('authored compiler language changed')
        package_name=operand('-package-name')
        if not re.fullmatch(r'[A-Za-z0-9_]{1,128}',package_name): raise ValueError('invalid compiler package identity')
        package_names.append(package_name)
        companions=[binary/'Modules'/(module+suffix) for suffix in ('.swiftmodule','.swiftdoc','.swiftsourceinfo','.abi.json')]
        if sorted((binary/'Modules').glob(module+'.*'))!=sorted(companions): raise ValueError('module companion membership differs')
        for path in companions: real_helper_owned_path(run,path)
        paths.update([*object_paths,filelist,outputmap,*companions])
        if module=='NativeRoutingPackageTests':
            derived=binary/'NativeRoutingPackageTests.derived'
            if sorted(derived.rglob('*.swift'))!=expected: raise ValueError('generated entry Source membership differs')
            paths.update(expected)
            memberships.append(dict(root=derived.relative_to(run).as_posix(),pattern='*.swift',
                paths=[x.relative_to(run).as_posix() for x in expected]))
        objects[module]=object_paths
        memberships.append(dict(root=(binary/(module+'.build')).relative_to(run).as_posix(),pattern='*.o',
            paths=sorted(x.relative_to(run).as_posix() for x in object_paths)))
        module_rows.append(dict(module=module,sources=list(map(str,expected)),objects=list(map(str,object_paths)),
            generatedEntry=module=='NativeRoutingPackageTests',swiftVersionExplicit='-swift-version' in arguments))
    if len(set(package_names))!=1: raise ValueError('compiler package identity disagreement')
    all_objects=sorted(x for values in objects.values() for x in values)
    if sorted(binary.rglob('*.o'))!=all_objects: raise ValueError('foreign compiled object outside fixed modules')
    memberships.append(dict(root=binary.relative_to(run).as_posix(),pattern='*.o',
        paths=[x.relative_to(run).as_posix() for x in all_objects]))
    expected_modules={binary/'Modules'/(module+suffix) for module in NATIVE_MODULES
        for suffix in ('.swiftmodule','.swiftdoc','.swiftsourceinfo','.abi.json')}
    if set((binary/'Modules').iterdir())!=expected_modules: raise ValueError('foreign module companion')
    memberships.append(dict(root=(binary/'Modules').relative_to(run).as_posix(),pattern='*',
        paths=sorted(x.relative_to(run).as_posix() for x in expected_modules)))
    links=[]
    for product,modules in (('NativeRoutingPackageTests',NATIVE_MODULES),):
        path=binary/(product+'.product/Objects.LinkFileList');real_helper_owned_path(run,path)
        members=shlex.split(read_real(run,path).decode())
        expected=[str(obj) for module in modules for obj in objects[module]]
        if len(set(members))!=len(members) or sorted(members)!=sorted(expected): raise ValueError('product link union differs')
        paths.add(path);links.append(dict(product=product,objects=members))
    bundle=binary/'NativeRoutingPackageTests.xctest'
    test_binary=bundle/'Contents/MacOS/NativeRoutingPackageTests'
    products=description.get('builtTestProducts')
    if (not isinstance(products,list) or len(products)!=1 or not isinstance(products[0],dict)
        or products[0].get('binaryPath')!=str(test_binary) or products[0].get('packagePath')!=str(run/'Package')
        or products[0].get('productName')!='NativeRoutingPackageTests'):
        raise ValueError('built Test product differs')
    real_helper_owned_path(run,bundle,directory=True);real_helper_owned_path(run,test_binary)
    leaves=sorted(x for x in bundle.rglob('*') if not x.is_dir())
    if len(leaves)!=4: raise ValueError('unexpected Test bundle leaf count')
    symbol=bundle/'Contents/MacOS/NativeRoutingPackageTests.dSYM/Contents'
    required={test_binary,symbol/'Info.plist',symbol/'Resources/DWARF/NativeRoutingPackageTests'}
    remainder=set(leaves)-required
    if not required.issubset(leaves) or len(remainder)!=1: raise ValueError('Test bundle layout differs')
    relocation=next(iter(remainder))
    if re.fullmatch(r'Resources/Relocations/(?:aarch64|x86_64)/NativeRoutingPackageTests.yml',relocation.relative_to(symbol).as_posix()) is None:
        raise ValueError('Test bundle relocation differs')
    for path in leaves: real_helper_owned_path(run,path)
    paths.update(leaves)
    memberships.append(dict(root=bundle.relative_to(run).as_posix(),pattern='files',
        paths=sorted(x.relative_to(run).as_posix() for x in leaves)))
    return dict(paths=sorted(x.relative_to(run).as_posix() for x in paths),modules=module_rows,links=links,
        membership=memberships,testBinary=test_binary.relative_to(run).as_posix(),packageName=package_names[0],
        generatedEntry='NativeRoutingPackageTests.derived/runner.swift',
        objectCount=len(all_objects))
