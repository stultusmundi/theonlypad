"""Narrow five-module derivative of accepted native compiler proof; no helper product."""
import hashlib
import json
from pathlib import Path
import platform
import re
import shlex
from run_native_regressions import digest, read_real, verify, real_helper_owned_path, real_helper_artifact, real_helper_json

NATIVE_MODULES=('PadCore','SearchExecution','NativeRouting','NativeRoutingTests','NativeRoutingPackageTests')
APPLICATION_METHODS={
 'DocumentSearchAppRoutingTests': (
    'testCapturedSearchPanelClaimsOnlyCloseAndSixNativeEditingSelectors',
    'testCapturedSearchAvailabilityAndDispatchShareIdentityAndRefusalPolicy',
    'testActualManagedConfigurationStaysSearchLazyAndAppGuardsPrecedeScope',
    'testActualQuitPublishesNativeReceiptThenJoinsSearchAndExternalExactlyOnceAcrossVetoAndRetry',
),
 'ApplicationLanguageCatalogTests': (
    'testApplicationCatalogStartupRemainsLazyAndStartsOneActualRead',
    'testApplicationCatalogFailureRetainsLastConfirmedPublicationAndDocumentStartup',
    'testApplicationCatalogErrorPresentationReentryCannotClobberSuccessorState',
    'testQuitBeforeCatalogStartupNeverConstructsOrReadsCatalog',
    'testBusyCatalogQuitVetoDoesNotInvalidateAndReleasedReadSettles',
    'testActualUnresolvedWriteBlocksQuitWithoutAcknowledgingOrDiscarding',
    'testNativeVetoRollsBackOnlyActualCatalogReservationAndKeepsSuccessfulCatalogWrite',
    'testUnsettledSearchVetoReleasesCatalogWithoutReopeningTerminalSearch',
    'testSuccessfulQuitReservesThenJoinsAndInvalidatesActualCatalogBeforeSingleReply',
    'testFalseReplyReentryPreservesNewAttemptAndItsNewCatalogReservation',
),
 'LanguageManagerReadOnlyTests': (
    'testManagerConstructionKeepsOneApplicationCatalogAuthority',
    'testActualTableAndDetailsUseCompleteConfirmedCatalog',
    'testHeldRefreshUsesExistingProducerAndTruthfulBusyState',
    'testReloadFailurePreservesConfirmedRowsAndAppErrorObserver',
    'testSamePublicationQuitNotificationsUpdatePresentation',
    'testReentrantDeliveryCannotOverwriteSuccessorPublication',
    'testNativeCloseReentryPreservesExactNewManager',
    'testApplicationVetoKeepsManagerAndOriginalCatalogReservationRules',
    'testCommittedQuitDetachesPresentationAfterActualOwnerJoin',
),
}
APPLICATION_CLASSES=tuple(APPLICATION_METHODS)

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


def capture_native_build(run,binary_directory,source_manifest_hash):
    run,binary=Path(run),Path(binary_directory)
    if digest(run/'sources.json')!=source_manifest_hash: raise ValueError('source authority changed before capture')
    manifest=real_helper_json(run,run/'sources.json')
    proof=validate_native_compiler_graph(run,binary,manifest)
    artifacts=[real_helper_artifact(run,run/path) for path in proof['paths']]
    if validate_native_compiler_graph(run,binary,manifest)!=proof: raise ValueError('compiler graph changed during capture')
    record=dict(sourceManifestSHA256=source_manifest_hash,testBinary=proof['testBinary'],artifacts=artifacts,
        membership=proof['membership'],compiler=proof['modules'],links=proof['links'],
        packageName=proof['packageName'],objectCount=proof['objectCount'],
        generatedEntryQualification='generated runner has separately recorded explicit-language flag; authored modules Swift5')
    binary_row=next(x for x in artifacts if x['path']==record['testBinary'])
    if not binary_row['mode']&0o111: raise ValueError('built Test binary is not executable')
    path=run/'build-inputs.json'
    with path.open('x') as stream: stream.write(json.dumps(record,indent=2)+'\n')
    path.chmod(0o600)
    verify_native_build(run,record,digest(path))
    return record


def verify_native_build(run,record,expected_record_hash):
    run=Path(run)
    path=run/'build-inputs.json'
    if digest(real_helper_owned_path(run,path))!=expected_record_hash or real_helper_json(run,path)!=record:
        raise ValueError('original build authority changed')
    if digest(real_helper_owned_path(run,run/'sources.json'))!=record['sourceManifestSHA256']:
        raise ValueError('frozen source authority changed')
    rows=record['artifacts']
    if not isinstance(rows,list) or not rows or len({row['path'] for row in rows})!=len(rows):
        raise ValueError('ambiguous artifact authority')
    if sum(row['path']==record['testBinary'] for row in rows)!=1: raise ValueError('missing exact Test binary authority')
    for row in rows:
        path=run/row['path']
        if not path.is_relative_to(run/'BuildProducts') or real_helper_artifact(run,path)!=row:
            raise ValueError('build artifact changed')
    for item in record.get('membership',[]):
        root=real_helper_owned_path(run,run/item['root'],directory=True)
        if item['pattern']=='files': actual=sorted(x for x in root.rglob('*') if not x.is_dir())
        elif item['pattern'] in ('*.o','*.swift'): actual=sorted(root.rglob(item['pattern']))
        elif item['pattern']=='*': actual=sorted(root.iterdir())
        else: raise ValueError('invalid artifact membership shape')
        if [x.relative_to(run).as_posix() for x in actual]!=item['paths']:
            raise ValueError('artifact membership changed')
        for path in actual: real_helper_owned_path(run,path)


def application_methods(data):
    """Exact fixed three-class/twenty-three-method fixture census; not a general Swift parser."""
    owner=None;classes=[];methods=[]
    for match in re.finditer(r'\bclass\s+(\w+)\s*:\s*XCTestCase\b|\bfunc\s+(test\w+)\s*\(',data.decode()):
        if match.group(1):
            owner=match.group(1);classes.append(owner)
        elif owner: methods.append((owner,match.group(2)))
        else: raise ValueError('application catalog method lacks fixed XCTest class')
    expected=tuple((owner,method) for owner,names in APPLICATION_METHODS.items() for method in names)
    if tuple(classes)!=APPLICATION_CLASSES or tuple(methods)!=expected:
        raise ValueError('fixed application catalog declaration census changed')
    return methods


def application_success(text, selection):
    if selection not in APPLICATION_METHODS: raise ValueError('unknown fixed application catalog selection')
    methods=APPLICATION_METHODS[selection]
    if re.search(r'(?m)^.*(?:error:|caught error:)|\b[1-9][0-9]* unexpected\b',text):
        raise ValueError('application catalog error record')
    counts=[tuple(map(int,pair)) for pair in re.findall(r'Executed (\d+) tests?, with (\d+) failures',text)]
    expected=len(methods)
    if not counts or counts[-1]!=(expected,0) or any(n<=0 or failure for n,failure in counts):
        raise ValueError('missing complete application catalog selection result')
    terminal=re.findall(r"^Test Case '([^']+)' (passed|failed|skipped)(?: \(.*\)\.)?$",text,re.M)
    if len(terminal)!=expected or any(result!='passed' for _,result in terminal):
        raise ValueError('incomplete application catalog selection cases')
    cases=[]
    for identity,_ in terminal:
        match=re.fullmatch(r'\-\[NativeRoutingTests\.(\w+) (test\w+)\]',identity)
        if match is None: raise ValueError('foreign application catalog selection case')
        cases.append(match.groups())
    expected_cases={(selection,method) for method in methods}
    if len(set(cases))!=expected or set(cases)!=expected_cases:
        raise ValueError('application catalog exact class selection changed')
    if len(re.findall(r"^Test Suite '"+re.escape(selection)+r"' passed(?: at .*\.)?$",text,re.M))!=1:
        raise ValueError('application catalog class did not pass exactly once')
    return dict(tests=expected,failures=0,className=selection)
