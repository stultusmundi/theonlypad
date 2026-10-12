"""Frozen hidden native regressions with one accepted same-process watchdog owner."""
import argparse
import errno
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import sys
import tempfile

SUITES={'folder-navigation':('FolderNavigationTests','folder-navigation-tests'),
        'help':('HelpReferenceTests','help-reference-tests'),
        'search-replacement':('SearchReplacementTests','search-replacement-tests'),
        'settings':('DocumentAppliedSettingsTests','document-applied-settings-tests'),
        'transfer':('EditorDocumentTransferTests','native-document-transfer-tests'),
        'projection':('EditorTransferProjectionTests','editor-transfer-projection-tests'),
        'close':(None,'native-close-model'),
        'macro':('NativeMacroChronologyTests','native-macro-chronology-tests'),
        'managed-admission':('NativeManagedAdmissionStartupTests','managed-admission-tests')}
CLOSE_SOURCES=('EditorDocument','EditorDocumentCloseAdapter','EditorDocumentFactory',
    'NativeDocumentSeed','EditorDocumentWorkspaceAdapter','WorkspaceDocumentRegistryTypes',
    'EditorPane','DocumentTextView','DocumentPanePresentation','EditorPaneHost',
    'NativeSyntaxHighlighter','LineNumberRuler','DocumentFileStateController','FileMonitorClient')
CLOSE_HARNESSES=('NativeCloseModelHarness','DocumentFactoryHarness','SharedPaneOwnershipHarness')
FIXED=('scripts/swift.sh','scripts/run-owned-search-tests.py',
       'scripts/test-native-document-transfer.sh','scripts/test-editor-transfer-projection.sh',
       'scripts/test-native-close-model.sh','Tests/NativeIntegration/run_native_regressions.py',
       'Tests/NativeIntegration/test_native_regressions.py')
SHARED_MARKER='PASS shared storage/undo, exact Unicode, revisions, selections, bounded detach/reattach, lifetime'
PACKAGE='''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name:"NativeRouting", platforms:[.macOS(.v14)], targets:[.target(name:"PadCore"),.target(name:"SearchExecution",dependencies:["PadCore"]),.target(name:"NativeRouting",dependencies:["PadCore","SearchExecution"]),.testTarget(name:"NativeRoutingTests",dependencies:["NativeRouting","PadCore"])],swiftLanguageModes:[.v5])
'''


MACRO_TESTS=('MacroChronologyReplayTests','NativeMacroChronologyTests','NativeMacroStorageTask1ATests')
MACRO_ACCESS=('ApprovedViewCommitBroker.swift','DocumentCommitTextStorage.swift',
              'EditorDocument.swift','EditorWindowController.swift','NativeMacroCommitContext.swift')
MACRO_CLASSES={'NativeMacroApprovedViewCapacityTests':2,'NativeMacroApprovedViewPayloadTests':2,
               'NativeMacroApprovedViewReceiptTests':6,'NativeMacroChronologyTests':7,
               'NativeMacroControlledExplicitCapacityTests':1,'NativeMacroStrictExplicitCapacityTests':1}
MACRO_SELECTOR='|'.join(MACRO_CLASSES)
MACRO_ACCESS_FILE='Tests/NativeIntegration/NativeMacroChronologyAccess.swift'
ADMISSION_TESTS=('NativeManagedAdmissionStartupTests','EditorApplicationRoutingTests')
ADMISSION_ACCESS={'EditorWindowController.swift':'ManagedAdmissionControllerAccess.swift',
                  'EditorDocument.swift':'ManagedAdmissionHistoryAccess.swift'}
ADMISSION_METHODS={
    ('NativeManagedAdmissionStartupTests','testActualEmptyOwnerStartupRetainsViewAndHistoryRouting'),
    ('NativeManagedAdmissionStartupTests','testActualPlainFileOwnerStartupRetainsViewAndHistoryRouting'),
    ('NativeManagedAdmissionCallbackTests','testActualEndpointCallbackSuccessorSurvivesOuterAdmissionRefusal'),
    ('NativeManagedAdmissionCallbackTests','testActualPostPreservationCloseTicketRevokesRoutingOnOuterRefusal')}
ADMISSION_CLASSES={'NativeManagedAdmissionStartupTests':2,'NativeManagedAdmissionCallbackTests':2}
ADMISSION_SELECTOR='|'.join(ADMISSION_CLASSES)

def digest(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def read_real(root,path):
    root,path=Path(root),Path(path)
    cursor=root
    if root.is_symlink(): raise ValueError('symlink root refused')
    for part in path.relative_to(root).parts:
        cursor=cursor/part
        if cursor.is_symlink(): raise ValueError('symlink input refused')
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
    with os.fdopen(fd,'rb') as stream: return stream.read()

def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    module=importlib.util.module_from_spec(spec);sys.modules[name]=module;spec.loader.exec_module(module)
    return module

def parse_args(argv):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('suite',choices=SUITES)
    parser.add_argument('build_path',nargs='?')
    args=parser.parse_args(argv)
    if args.build_path and args.suite!='close': parser.error('only close accepts an existing debug build path')
    return args

def discover(root,suite,prebuilt):
    paths={root/name for name in FIXED}
    if suite=='folder-navigation': paths.add(root/'scripts/test-folder-navigation.sh')
    if suite=='help': paths.add(root/'scripts/test-help-reference.sh')
    if suite=='settings': paths.add(root/'scripts/test-document-applied-settings.sh')
    if suite=='macro':
        paths.add(root/'scripts/test-native-macro.sh')
        paths.add(root/MACRO_ACCESS_FILE)
    if suite=='managed-admission':
        paths.add(root/'scripts/test-managed-admission.sh')
        paths.update(root/'Tests/NativeIntegration'/name for name in ADMISSION_ACCESS.values())
    if suite=='search-replacement': paths.add(root/'scripts/test-search-replacement.sh')
    if suite!='close' or not prebuilt:
        paths.update((root/'Sources').rglob('*.swift'))
        if suite=='close':
            paths.add(root/'Package.swift')
            for name in ('PadCoreTests','SearchExecutionTests'):
                paths.update((root/'Tests'/name).glob('*.swift'))
    else:
        paths.update((root/'Sources/TheOnlyPad').glob('*.swift'))
        paths.update((root/'Sources/PadCore').glob('*.swift'))
        paths.update((root/'Sources/SearchExecution').glob('*.swift'))
    optional=root/'Sources/TheOnlyPad/DocumentAppliedSettings.swift'
    if optional.exists() or optional.is_symlink(): paths.add(optional)
    names=CLOSE_HARNESSES if suite=='close' else (MACRO_TESTS if suite=='macro' else (ADMISSION_TESTS if suite=='managed-admission' else (SUITES[suite][0],)))
    paths.update(root/'Tests/NativeIntegration'/(name+'.swift') for name in names)
    result=sorted(paths)
    if not any(p.parent==root/'Sources/PadCore' for p in result): raise ValueError('missing PadCore sources')
    for path in result: read_real(root,path)
    return result

def macro_access(text, filename):
    label=Path(filename).stem
    begin='// MACRO-'+label+'-ACCESS-BEGIN\n'
    end='// MACRO-'+label+'-ACCESS-END'
    if filename not in MACRO_ACCESS or text.count(begin)!=1 or text.count(end)!=1:
        raise ValueError('macro access markers changed')
    first=text.index(begin)+len(begin);last=text.index(end)
    if last<first: raise ValueError('macro access marker order changed')
    return text[first:last].encode()

def projection_probe(text,access):
    marker='  override func makeFirstResponder(_ responder: NSResponder?) -> Bool {\n'
    if text.count(marker)!=1: raise ValueError('focus probe marker changed')
    text=text.replace(marker,marker+'    if let controller = windowController as? EditorWindowController,\n      let result = ProjectionFocusProbe.beforeFocus?(controller, responder) { return result }\n')
    start=text.index('  private func installResolvedPanes(')
    end=text.index('  private func installPendingPresentationIfPossible',start)
    body=text[start:end];marker='      try validateAuthority()\n    }'
    index=body.rfind(marker)
    if index<0: raise ValueError('origin probe marker changed')
    body=body[:index]+'      ProjectionFocusProbe.afterOrigin?(self)\n'+body[index:]
    return text[:start]+body+text[end:]+'\n'+access

def search_replacement_access(test_source, name):
    begin='// SEARCH-'+name+'-ACCESS-BEGIN\n'
    end='// SEARCH-'+name+'-ACCESS-END'
    if test_source.count(begin)!=1 or test_source.count(end)!=1:
        raise ValueError('search access markers changed')
    return test_source.split(begin)[1].split(end)[0]

def native_edit_completion(text):
    start='  private func performDocumentCommand('
    end='  func navigateManaged('
    if text.count(start)!=1 or text.count(end)!=1:
        raise ValueError('native command completion boundaries changed')
    first=text.index(start);last=text.index(end,first)
    body=text[first:last]
    marker='      defer { Self.completeFileOperation(document, id: operationID, controller: self) }'
    if body.count(marker)!=1: raise ValueError('native command completion marker changed')
    body=body.replace(marker,marker[:-2]+'; NativeEditTestCompletion.finish?() }')
    return text[:first]+body+text[last:]

def native_line_ending_completion(text):
    start='  private func convertLineEndings('
    end='  private func convertEncoding('
    if text.count(start)!=1 or text.count(end)!=1:
        raise ValueError('native line ending completion boundaries changed')
    first=text.index(start);last=text.index(end,first)
    body=text[first:last]
    marker='      defer { Self.completeFileOperation(document, id: operationID, controller: self) }'
    if body.count(marker)!=1: raise ValueError('native line ending completion marker changed')
    body=body.replace(marker,marker[:-2]+'; NativeEditTestCompletion.finish?() }')
    return text[:first]+body+text[last:]

def native_replay_completion(text):
    start='  func replay(_ macro: EditorMacro, repeatCount: Int) {'
    end='  func textViewDidChangeSelection('
    if text.count(start)!=1 or text.count(end)!=1:
        raise ValueError('native replay completion boundaries changed')
    first=text.index(start);last=text.index(end,first)
    body=text[first:last]
    marker='        Self.completeFileOperation(document, id: operationID, controller: self)\n      }\n      do {'
    if body.count(marker)!=1: raise ValueError('native replay completion marker changed')
    body=body.replace(marker,marker.replace('\n      }','\n        NativeEditTestCompletion.finish?()\n      }'))
    return text[:first]+body+text[last:]

def native_text_utility_controller(text):
    start='  private func showTextUtilities() {'
    end='  private func showSearch() {'
    if text.count(start)!=1 or text.count(end)!=1:
        raise ValueError('native utility construction boundaries changed')
    first=text.index(start);last=text.index(end,first)
    body=text[first:last];marker='    panel.showWindow(nil)'
    if body.count(marker)!=1: raise ValueError('native utility presentation marker changed')
    body=body.replace(marker,'    // Hidden harness: construct the actual utility panel without showing it.')
    return text[:first]+body+text[last:]

def search_replacement_controller(text,access):
    start='  private func showSearch() {'
    end='  private func apply(_ transform: LineTransform) {'
    if text.count(start)!=1 or text.count(end)!=1:
        raise ValueError('search construction boundaries changed')
    first=text.index(start);last=text.index(end,first)
    body=text[first:last];marker='    panel.showWindow(nil)'
    if body.count(marker)!=1: raise ValueError('search presentation marker changed')
    body=body.replace(marker,'    // Hidden harness: construct the actual panel without showing it.')
    return text[:first]+body+text[last:]+'\n'+access

def freeze(root,run,suite,prebuilt=False):
    root,run=Path(root),Path(run)
    paths=discover(root,suite,prebuilt);items=[];generated=[]
    for path in paths:
        relative=path.relative_to(root).as_posix();target=run/'Original'/relative
        target.parent.mkdir(parents=True,exist_ok=True)
        target.write_bytes(read_real(root,path))
        if path.suffix=='.sh': target.chmod(0o700)
        items.append(dict(source=relative,frozen=target.relative_to(run).as_posix(),sha256=digest(target)))
    if discover(root,suite,prebuilt)!=paths: raise ValueError('source discovery changed during capture')
    for item in items:
        if hashlib.sha256(read_real(root,root/item['source'])).hexdigest()!=item['sha256']:
            raise ValueError('source bytes changed during capture')
    def generate(relative,data,origin=None):
        target=run/relative;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data)
        generated.append(dict(frozen=relative,sha256=digest(target),origin=origin))
    if suite!='close':
        for item in items:
            name=item['source'];path=Path(name)
            if name.startswith(('Sources/PadCore/', 'Sources/SearchExecution/')):
                generate('Package/'+name,(run/item['frozen']).read_bytes(),name)
            elif name.startswith('Sources/TheOnlyPad/') and path.name!='TheOnlyPadApplication.swift':
                data=(run/item['frozen']).read_bytes()
                if suite=='folder-navigation':
                    test_source=(run/'Original/Tests/NativeIntegration/FolderNavigationTests.swift').read_text()
                    label={'EditorWindowController.swift':'CONTROLLER',
                           'FolderSearchController.swift':'PANEL'}.get(path.name)
                    if label:
                        begin='// FOLDER-'+label+'-ACCESS-BEGIN\n'
                        end='// FOLDER-'+label+'-ACCESS-END'
                        if test_source.count(begin)!=1 or test_source.count(end)!=1:
                            raise ValueError('folder access markers changed')
                        text=data.decode()
                        if label=='CONTROLLER':
                            first=text.index('    case "edit.findFolder":')
                            last=text.index('    case "view.splitVertical":',first)
                            body=text[first:last]
                            marker='      panel.showWindow(nil)'
                            if body.count(marker)!=1: raise ValueError('folder presentation marker changed')
                            text=text[:first]+body.replace(marker,'      // Hidden test: keep the actual folder panel unshown.')+text[last:]
                        data=(text+'\n'+test_source.split(begin)[1].split(end)[0]).encode()
                if suite=='projection' and path.name=='EditorWindowController.swift':
                    access=(run/'Original/Tests/NativeIntegration/EditorTransferProjectionTests.swift').read_text().split('// NATIVE-ACCESS-BEGIN\n')[1].split('// NATIVE-ACCESS-END')[0]
                    data=projection_probe(data.decode(),access).encode()
                if suite=='search-replacement':
                    test_source=(run/'Original/Tests/NativeIntegration/SearchReplacementTests.swift').read_text()
                    if path.name=='EditorWindowController.swift':
                        text=search_replacement_controller(data.decode(),search_replacement_access(test_source,'CONTROLLER'))
                        for transform in (native_edit_completion,native_line_ending_completion,
                                          native_text_utility_controller,native_replay_completion):
                            text=transform(text)
                        data=text.encode()
                    if path.name=='TextUtilitiesController.swift':
                        data+=('\n'+search_replacement_access(test_source,'UTILITY')).encode()
                    if path.name=='SearchPanelController.swift':
                        data+=('\n'+search_replacement_access(test_source,'PANEL')).encode()
                if suite=='settings':
                    access=(run/'Original/Tests/NativeIntegration/DocumentAppliedSettingsTests.swift').read_text().split('// NATIVE-ACCESS-BEGIN\n')[1].split('// NATIVE-ACCESS-END')[0]
                    if path.name=='EditorWindowController.swift': data+=('\n'+access).encode()
                    if path.name=='DocumentTextView.swift':
                        marker='  let documentUndo: UndoManager'
                        if data.decode().count(marker)!=1: raise ValueError('font probe marker changed')
                        probe='  override var defaultParagraphStyle: NSParagraphStyle? {\n    get { super.defaultParagraphStyle }\n    set { AppliedSettingsProbe.paragraphWrites += 1; super.defaultParagraphStyle = newValue }\n  }\n  override var typingAttributes: [NSAttributedString.Key: Any] {\n    get { super.typingAttributes }\n    set { AppliedSettingsProbe.typingWrites += 1; super.typingAttributes = newValue }\n  }\n  override var isHorizontallyResizable: Bool {\n    get { super.isHorizontallyResizable }\n    set { AppliedSettingsProbe.beforeWrap?(self); super.isHorizontallyResizable = newValue }\n  }\n  override var font: NSFont? {\n    get { super.font }\n    set { AppliedSettingsProbe.fontWrites += 1; AppliedSettingsProbe.beforeFont?(self); super.font = newValue }\n  }\n'
                        data=data.decode().replace(marker,probe+marker).encode()
                if suite=='macro' and path.name in MACRO_ACCESS:
                    access=(run/'Original'/MACRO_ACCESS_FILE).read_bytes().decode()
                    data+=macro_access(access,path.name)
                if suite=='managed-admission' and path.name in ADMISSION_ACCESS:
                    # Exact declaring access: stored observations plus only the
                    # original public32 makeDiskConflict construction forwarder.
                    access=run/'Original/Tests/NativeIntegration'/ADMISSION_ACCESS[path.name]
                    data+=b'\n'+access.read_bytes()
                if path.name=='EditorDocument.swift' and suite not in ('macro','managed-admission'):
                    text=data.decode();marker='  var dirty: Bool {'
                    if text.count(marker)!=1: raise ValueError('dirty getter transform marker changed')
                    data=text.replace(marker,'  var transferHarnessDirtyReads = 0\n'+marker+'\n    transferHarnessDirtyReads += 1').encode()
                generate('Package/Sources/NativeRouting/'+path.name,data,name)
        name=SUITES[suite][0]+'.swift'
        test_data=(run/'Original/Tests/NativeIntegration'/name).read_bytes()
        if suite=='folder-navigation':
            text=test_data.decode()
            for label in ('CONTROLLER','PANEL'):
                start=text.index('// FOLDER-'+label+'-ACCESS-BEGIN')
                end=text.index('// FOLDER-'+label+'-ACCESS-END')+len('// FOLDER-'+label+'-ACCESS-END')
                text=text[:start]+text[end:]
            test_data=text.encode()
        if suite in ('settings','projection'):
            text=test_data.decode();start=text.index('// NATIVE-ACCESS-BEGIN');end=text.index('// NATIVE-ACCESS-END')+len('// NATIVE-ACCESS-END');test_data=(text[:start]+text[end:]).encode()
        if suite=='search-replacement':
            text=test_data.decode()
            for label in ('CONTROLLER','PANEL','UTILITY'):
                search_replacement_access(text,label)
                start=text.index('// SEARCH-'+label+'-ACCESS-BEGIN')
                end=text.index('// SEARCH-'+label+'-ACCESS-END')+len('// SEARCH-'+label+'-ACCESS-END')
                text=text[:start]+text[end:]
            test_data=text.encode()
        generate('Package/Tests/NativeRoutingTests/'+name,test_data,
                 'Tests/NativeIntegration/'+name)
        if suite=='macro':
            for extra in MACRO_TESTS:
                if extra!=SUITES[suite][0]:
                    origin='Tests/NativeIntegration/'+extra+'.swift'
                    generate('Package/Tests/NativeRoutingTests/'+extra+'.swift',
                             (run/'Original'/origin).read_bytes(),origin)
        if suite=='managed-admission':
            for extra in ADMISSION_TESTS:
                if extra!=SUITES[suite][0]:
                    origin='Tests/NativeIntegration/'+extra+'.swift'
                    generate('Package/Tests/NativeRoutingTests/'+extra+'.swift',
                             (run/'Original'/origin).read_bytes(),origin)
        generate('Package/Package.swift',PACKAGE.encode())
    else:
        # Custom storage has an authentic controller owner. Compile the captured
        # native dependency graph, excluding only the application's entry point.
        for item in items:
            name=item['source']
            if name.startswith('Sources/TheOnlyPad/') and name.endswith('.swift'):
                path=run/item['frozen']
                if path.name!='TheOnlyPadApplication.swift':
                    generate('NativeSources/'+path.name,path.read_bytes(),name)
        if not prebuilt:
            for item in items:
                name=item['source']
                if name=='Package.swift' or name.startswith(('Sources/','Tests/PadCoreTests/','Tests/SearchExecutionTests/')):
                    generate('BuildPackage/'+name,(run/item['frozen']).read_bytes(),name)
    trees=['Package'] if suite!='close' else ['NativeSources']+([] if prebuilt else ['BuildPackage'])
    manifest=dict(version=1,suite=suite,prebuilt=prebuilt,sources=items,generated=generated,inputTrees=trees,
        transformation=('Exact public production bodies plus two declaring access tails only: C raw observations and original public32 disk-conflict construction forwarder (NOT readonly); D stored weak history observations. Exact startup and routing clients; original routing32 compiled unselected, four named cases selected. No dirty getter, installer, warmup or private native language substitution.' if suite=='managed-admission' else 'Exact three macro fixture clients; five explicit access tails only; no dirty getter or product body hooks; six-class19 selection.' if suite=='macro' else 'Dirty getter counter; folder controller/panel private access appended; only folder command showWindow suppressed; access regions omitted from XCTest source.' if suite=='folder-navigation' else 'Dirty getter counter; test access extracted into frozen controller, search panel and text utility panel; exact search and text utility showWindow calls suppressed; document command, line-ending conversion and macro replay defer completion observers appended with original cleanup retained; access regions omitted from XCTest source.' if suite=='search-replacement' else 'Dirty getter counter; test access extracted into frozen controller; native font/paragraph/typing/wrap setters wrapped for tests; test-access region omitted from XCTest source.' if suite=='settings' else 'Dirty getter counter; test access extracted into frozen controller; focus entry and post-origin callback probes retain original bodies; test-access region omitted from XCTest source.' if suite=='projection' else 'One counter before original dirty getter; implementation retained unchanged.' if suite!='close' else None))
    if suite=='macro':
        access=(run/'Original'/MACRO_ACCESS_FILE).read_bytes().decode()
        manifest['macroAccess']=[dict(target=name,source=MACRO_ACCESS_FILE,
            bytes=len(macro_access(access,name)),
            sha256=hashlib.sha256(macro_access(access,name)).hexdigest()) for name in MACRO_ACCESS]
    if suite=='managed-admission':
        manifest['managedAdmissionAccess']=[dict(
            target=target,source='Tests/NativeIntegration/'+access,
            bytes=len((run/'Original/Tests/NativeIntegration'/access).read_bytes()),
            sha256=digest(run/'Original/Tests/NativeIntegration'/access),join='LF',
            originalSHA256=digest(run/'Original/Sources/TheOnlyPad'/target),
            generatedSHA256=digest(run/'Package/Sources/NativeRouting'/target))
            for target,access in ADMISSION_ACCESS.items()]
    (run/'sources.json').write_text(json.dumps(manifest,indent=2)+'\n')
    verify(run,manifest)
    return manifest

def verify(run,manifest):
    items=manifest['sources']+manifest['generated']
    for tree in manifest['inputTrees']:
        root=run/tree
        if root.is_symlink() or not root.is_dir(): raise ValueError('missing or symlink input tree')
        expected=set()
        for item in items:
            name=Path(item['frozen'])
            if not name.is_relative_to(tree): continue
            expected.add(('file',name.as_posix()))
            for parent in name.parents:
                if parent==Path(tree): break
                expected.add(('directory',parent.as_posix()))
        actual=set()
        for folder,directories,files in os.walk(root,followlinks=False):
            for kind,names in [('directory',directories),('file',files)]:
                for name in names:
                    path=Path(folder)/name
                    if path.is_symlink(): raise ValueError('symlink compiler input refused')
                    actual.add((kind,path.relative_to(run).as_posix()))
        if actual!=expected: raise ValueError('compiler input membership changed')
    for item in items:
        if hashlib.sha256(read_real(run,run/item['frozen'])).hexdigest()!=item['sha256']:
            raise ValueError('frozen bytes changed')

def manifest_inputs(run,manifest,prefix,suffix):
    """Compiler argv comes from the captured inventory, never a later directory glob."""
    return sorted(run/item['frozen'] for item in manifest['sources']+manifest['generated']
                  if item['frozen'].startswith(prefix) and item['frozen'].endswith(suffix))

def build_package_identity(binary, run, core_objects, search_objects):
    """Bind the compiler package operand to the captured module/object selection."""
    description = binary / 'description.json'
    if not description.is_file():
        raise ValueError('package consumers require compiler description')
    raw = read_real(binary, description)
    if len(raw) > 4 * 1024 * 1024:
        raise ValueError('compiler description exceeds bound')
    commands = json.loads(raw).get('swiftCommands')
    if not isinstance(commands, dict):
        raise ValueError('missing compiler command groups')
    package_names = []
    for module, objects in (('PadCore', core_objects), ('SearchExecution', search_objects)):
        groups = [value for value in commands.values()
                  if isinstance(value, dict) and value.get('moduleName') == module]
        if len(groups) != 1:
            raise ValueError('ambiguous compiler module group')
        group = groups[0]
        arguments = group.get('otherArguments')
        if not isinstance(arguments, list) or arguments.count('-package-name') != 1:
            raise ValueError('missing or duplicate compiler package operand')
        index = arguments.index('-package-name') + 1
        value = arguments[index] if index < len(arguments) else None
        if not isinstance(value, str) or re.fullmatch(r'[A-Za-z0-9_]{1,128}', value) is None:
            raise ValueError('invalid compiler package operand')
        package_names.append(value)
        if group.get('moduleOutputPath') != str(binary / 'Modules' / (module + '.swiftmodule')):
            raise ValueError('compiler module output differs from captured artifact')
        declared = group.get('objects')
        if not isinstance(declared, list) or any(not isinstance(x, str) for x in declared):
            raise ValueError('invalid compiler object roster')
        if len(set(declared)) != len(declared) or sorted(declared) != sorted(map(str, objects)):
            raise ValueError('compiler object roster differs from captured artifacts')
        sources = group.get('sources')
        if not isinstance(sources, list) or any(not isinstance(x, str) or not Path(x).is_absolute() for x in sources):
            raise ValueError('invalid compiler source roster')
        if len(set(sources)) != len(sources) or sorted(Path(x).name + '.o' for x in sources) != sorted(x.name for x in objects):
            raise ValueError('compiler source/object pairing differs')
        # Real coordinator captures actual source bytes separately. Pure artifact
        # fixtures lack that manifest and do not claim compiler provenance.
        original = run / 'Original/Sources' / module
        if original.is_dir():
            if sorted(x.name for x in original.glob('*.swift')) != sorted(Path(x).name for x in sources):
                raise ValueError('compiler source roster differs from frozen sources')
            for source in sources:
                source = Path(source)
                if read_real(source.parent, source) != read_real(original, original / source.name):
                    raise ValueError('compiler source bytes differ from frozen sources')
    if package_names[0] != package_names[1]:
        raise ValueError('compiler modules have different package identities')
    return package_names[0], raw

def freeze_core(binary,run):
    binary=Path(binary).resolve()
    core_objects=sorted((binary/'PadCore.build').glob('*.o'))
    search_objects=sorted((binary/'SearchExecution.build').glob('*.o'))
    core_modules=sorted((binary/'Modules').glob('PadCore.*'))
    search_modules=sorted((binary/'Modules').glob('SearchExecution.*'))
    objects=[*core_objects,*search_objects]
    modules=[*core_modules,*search_modules]
    paths=[*objects,*modules]
    if not core_objects or not (binary/'Modules/PadCore.swiftmodule').is_file():
        raise ValueError('verified debug build must contain PadCore objects and module')
    if search_objects or search_modules:
        if not search_objects or not (binary/'Modules/SearchExecution.swiftmodule').is_file():
            raise ValueError('SearchExecution artifacts require both objects and module')
    package_name, description_bytes = build_package_identity(binary, run, core_objects, search_objects) if search_objects else (None, None)
    if package_name is not None:
        paths.append(binary / 'description.json')
    items=[]
    for path in paths:
        relative=path.relative_to(binary);target=run/'Core'/relative
        target.parent.mkdir(parents=True,exist_ok=True)
        target.write_bytes(description_bytes if path == binary / 'description.json' else read_real(binary,path))
        items.append(dict(source=relative.as_posix(),frozen=target.relative_to(run).as_posix(),sha256=digest(target)))
    if (core_objects!=sorted((binary/'PadCore.build').glob('*.o'))
        or search_objects!=sorted((binary/'SearchExecution.build').glob('*.o'))
        or core_modules!=sorted((binary/'Modules').glob('PadCore.*'))
        or search_modules!=sorted((binary/'Modules').glob('SearchExecution.*'))):
        raise ValueError('build outputs changed during capture')
    for item in items:
        if hashlib.sha256(read_real(binary,binary/item['source'])).hexdigest()!=item['sha256']:
            raise ValueError('build output bytes changed during capture')
    manifest=dict(version=1,sourceDirectory=str(binary),sources=items,generated=[],inputTrees=['Core'],packageName=package_name)
    (run/'build-inputs.json').write_text(json.dumps(manifest,indent=2)+'\n')
    verify(run,manifest)
    return manifest

def receipt_success(output,command,expected_code=0):
    try:
        value=json.loads((output/'status.json').read_text())
        required={'command','pid','processGroup','exitObserved','registrationError','groupSignalAttempted',
            'groupSignalError','groupCleanup','groupQuery','waitCompleted','returnCode','waitError',
            'timedOut','interruptedSignal','truncated','captureComplete','failure','exit','captured'}
        if not isinstance(value,dict) or not required.issubset(value): return False
        if type(expected_code) is not int or not 0<=expected_code<256: return False
        if not isinstance(command,list) or not command or any(type(word) is not str or '\0' in word for word in command): return False
        if any(value[key] is not True for key in ('waitCompleted','captureComplete','groupSignalAttempted')): return False
        if any(value[key] is not False for key in ('timedOut','truncated')): return False
        if any(value[key] is not None for key in ('failure','interruptedSignal','waitError')): return False
        if any(type(value[key]) is not int or value[key]!=expected_code for key in ('exit','returnCode')): return False
        if value['command']!=command: return False
        pid=value['pid']
        if type(pid) is not int or pid<=0 or type(value['processGroup']) is not int or value['processGroup']!=pid: return False
        observed,registration=value['exitObserved'],value['registrationError']
        if type(observed) is not bool: return False
        if registration is not None and (type(registration) is not int or registration!=errno.ESRCH): return False
        if not observed and registration!=errno.ESRCH: return False
        cleanup,error=value['groupCleanup'],value['groupSignalError']
        if cleanup=='signaled':
            if error is not None or value['groupQuery'] is not None: return False
        elif cleanup=='absent':
            if type(error) is not int or error!=errno.ESRCH or value['groupQuery'] is not None: return False
        elif cleanup=='exitedLeaderOnly':
            query=value['groupQuery'];fields={'processGroup','errorNumber','bufferBytes','returnedBytes','members'}
            if type(error) is not int or error!=errno.EPERM or not observed: return False
            if not isinstance(query,dict) or not fields.issubset(query) or query['errorNumber'] is not None: return False
            if any(type(query[key]) is not int or query[key]!=expected for key,expected in
                   [('processGroup',pid),('bufferBytes',1024),('returnedBytes',4)]): return False
            if not isinstance(query['members'],list) or len(query['members'])!=1: return False
            if type(query['members'][0]) is not int or query['members'][0]!=pid: return False
        else: return False
        if not isinstance(value['captured'],dict): return False
        for name in ('stdout','stderr'):
            counts=value['captured'].get(name)
            if not isinstance(counts,dict) or not {'stored','received','discarded'}.issubset(counts): return False
            if any(type(counts[key]) is not int for key in ('stored','received','discarded')): return False
            stored=counts['stored']
            if (not 0<=stored<=1_048_576 or counts['received']!=stored
                or counts['discarded']!=0 or (output/(name+'.log')).stat().st_size!=stored): return False
        return True
    except (OSError,ValueError,TypeError,KeyError,AttributeError): return False

def parse_success(kind,text):
    if any(line.startswith('FAIL ') for line in text.splitlines()): raise ValueError('native assertion failed')
    if kind=='managed-admission':
        counts=[tuple(map(int,pair)) for pair in re.findall(r'Executed (\d+) tests?, with (\d+) failures',text)]
        if not counts or counts[-1]!=(4,0) or any(n<=0 or failures!=0 for n,failures in counts):
            raise ValueError('missing exact positive managed admission result')
        terminal=re.findall(r"^Test Case '([^']+)' (passed|failed|skipped)(?: \(.*\)\.)?$",text,re.M)
        if len(terminal)!=4 or any(result!='passed' for _,result in terminal):
            raise ValueError('managed admission incomplete or nonpassing cases')
        cases=[]
        for identity,_ in terminal:
            match=re.fullmatch(r'\-\[NativeRoutingTests\.(\w+) (test\w+)\]',identity)
            if match is None: raise ValueError('foreign managed admission case')
            cases.append(match.groups())
        if len(set(cases))!=4 or set(cases)!=ADMISSION_METHODS:
            raise ValueError('managed admission exact case selection changed')
        if {name:sum(case[0]==name for case in cases) for name in ADMISSION_CLASSES}!=ADMISSION_CLASSES:
            raise ValueError('managed admission class count changed')
        for name in ADMISSION_CLASSES:
            if len(re.findall(r"^Test Suite '"+re.escape(name)+r"' passed(?: at .*\.)?$",text,re.M))!=1:
                raise ValueError('managed admission class did not pass')
        return dict(tests=4,failures=0)
    if kind=='macro':
        counts=[tuple(map(int,pair)) for pair in re.findall(r'Executed (\d+) tests?, with (\d+) failures',text)]
        if not counts or counts[-1]!=(19,0) or any(n<=0 or failures!=0 for n,failures in counts):
            raise ValueError('missing exact positive macro result')
        cases=re.findall(r"Test Case '-\[NativeRoutingTests\.(\w+) (test\w+)\]' passed",text)
        if len(cases)!=19 or len(set(cases))!=19:
            raise ValueError('macro actual case count changed')
        if {name:sum(case[0]==name for case in cases) for name in MACRO_CLASSES}!=MACRO_CLASSES:
            raise ValueError('macro class selection changed')
        for name in MACRO_CLASSES:
            # Require one passed class header, including native XCTest's time suffix.
            if len(re.findall(r"^Test Suite '"+re.escape(name)+r"' passed(?: at .*\.)?$",text,re.M))!=1:
                raise ValueError('macro class did not pass')
        return dict(tests=19,failures=0)
    if kind in SUITES and kind!='close':
        counts=[tuple(map(int,pair)) for pair in re.findall(r'Executed (\d+) tests?, with (\d+) failures',text)]
        if not counts or any(n<=0 or failures!=0 for n,failures in counts): raise ValueError('missing positive XCTest result')
        if "Test Suite '"+SUITES[kind][0]+"' passed" not in text: raise ValueError('expected suite did not pass')
        return dict(tests=counts[-1][0],failures=0)
    if kind=='SharedPaneOwnershipHarness':
        if text.splitlines().count(SHARED_MARKER)!=1: raise ValueError('missing shared ownership scenario')
        return dict(scenarios=1,failures=0)
    prefix={'NativeCloseModelHarness':'Native close model','DocumentFactoryHarness':'Factory'}[kind]
    counts=re.findall(re.escape(prefix)+r' checks: (\d+), failures: (\d+)',text)
    if len(counts)!=1 or int(counts[0][0])<=0 or int(counts[0][1])!=0: raise ValueError('missing positive native checks')
    return dict(checks=int(counts[0][0]),failures=0)

class StageFailure(Exception):
    def __init__(self,code): self.code=code

def execute(run,args,watchdog_main):
    run=Path(run);manifest=json.loads((run/'sources.json').read_text());manifest_hash=digest(run/'sources.json')
    result=dict(exit=125,suite=args.suite,stages=[],results={},sourceManifestSHA256=manifest_hash,
        buildProvenance='caller must supply a verified matching debug build; frozen artifact hashes alone do not prove source equivalence' if args.build_path else 'built from frozen sources')
    core=None;core_hash=None
    def check():
        verify(run,manifest)
        if digest(run/'sources.json')!=manifest_hash: raise ValueError('source manifest changed')
        if core is not None:
            verify(run,core)
            if digest(run/'build-inputs.json')!=core_hash: raise ValueError('build manifest changed')
    def stage(name,command,timeout,kind=None):
        check();output=run/'Stages'/name;state=run/'State'/name;state.mkdir(parents=True)
        # env execs the fixed command in the same owned leader/session. Only synthetic
        # state is added after the accepted watchdog's environment sanitization.
        command=['/usr/bin/env','THEONLYPAD_STATE_DIRECTORY='+str(state),*map(str,command)]
        code=watchdog_main(['--timeout',str(timeout),'--output',str(output),'--',*command])
        result['stages'].append(dict(name=name,exit=code,receipt=str((output/'status.json').relative_to(run))))
        check()
        if type(code) is not int or not receipt_success(output,command,code): raise ValueError('incomplete stage receipt')
        if code!=0: raise StageFailure(code)
        text=(output/'stdout.log').read_text(errors='replace')+(output/'stderr.log').read_text(errors='replace')
        if kind: result['results'][kind]=parse_success(kind,text)
        return text
    try:
        stage('toolchain',['/usr/bin/xcrun','swift','--version'],30)
        swift=run/'Original/scripts/swift.sh'
        if args.suite!='close':
            command=[swift,'test','--package-path',run/'Package','--scratch-path',run/'Build']
            if args.suite=='macro': command+=['-Xswiftc','-warnings-as-errors','--filter',MACRO_SELECTOR]
            if args.suite=='managed-admission': command+=['-Xswiftc','-warnings-as-errors','--filter',ADMISSION_SELECTOR]
            stage('test',command,180,args.suite)
        else:
            if args.build_path:
                binary=Path(args.build_path).resolve()
            else:
                common=['--package-path',run/'BuildPackage','--scratch-path',run/'Build','-c','debug']
                stage('build',[swift,'build',*common],180)
                output=stage('bin-path',[swift,'build',*common,'--show-bin-path'],30)
                lines=output.strip().splitlines()
                if len(lines)!=1: raise ValueError('ambiguous built product path')
                binary=Path(lines[0])
                if not binary.is_absolute() or not binary.resolve().is_relative_to((run/'Build').resolve()):
                    raise ValueError('built product path outside owned scratch directory')
            core=freeze_core(binary,run);core_hash=digest(run/'build-inputs.json');result['buildManifestSHA256']=core_hash
            native_sources=manifest_inputs(run,manifest,'NativeSources/','.swift')
            core_objects=manifest_inputs(run,core,'Core/PadCore.build/','.o')
            search_objects=manifest_inputs(run,core,'Core/SearchExecution.build/','.o')
            if any(b'import SearchExecution' in path.read_bytes() for path in native_sources):
                if not search_objects or not (run/'Core/Modules/SearchExecution.swiftmodule').is_file():
                    raise ValueError('native SearchExecution consumer requires captured objects and module')
            for name in CLOSE_HARNESSES:
                package_arguments = ['-package-name', core['packageName']] if core['packageName'] is not None else []
                command=['/usr/bin/xcrun','swiftc','-swift-version','5',*package_arguments,'-target',platform.machine()+'-apple-macosx14.0',
                    '-module-cache-path',run/'cache','-parse-as-library','-I',run/'Core/Modules',
                    *native_sources,
                    run/'Original/Tests/NativeIntegration'/(name+'.swift'),
                    *core_objects,*search_objects,'-o',run/name]
                stage(name+'.compile',command,120)
                binary_hash=digest(run/name)
                result.setdefault('binaryHashes',{})[name]=binary_hash
                stage(name,[run/name],30,name)
                if digest(run/name)!=binary_hash: raise ValueError('native executable changed')
        check();result['exit']=0
    except StageFailure as error:
        result['exit']=error.code if 0<error.code<256 else 125
    except (OSError,ValueError,TypeError,KeyError,AttributeError) as error:
        result['failure']=type(error).__name__;result['exit']=125
    finally:
        (run/'status.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result),flush=True)
    return result['exit']

def main(argv=None):
    args=parse_args(sys.argv[1:] if argv is None else argv)
    root=Path(__file__).absolute().parents[2]
    parent=root/'.local'/SUITES[args.suite][1];parent.mkdir(parents=True,exist_ok=True)
    run=Path(tempfile.mkdtemp(prefix='run.',dir=parent));run.chmod(0o700)
    print('Private native regression evidence: '+str(run),flush=True)
    try:
        freeze(root,run,args.suite,bool(args.build_path))
        frozen=load('frozen_native_regressions',run/'Original/Tests/NativeIntegration/run_native_regressions.py')
        watchdog=load('frozen_native_watchdog',run/'Original/scripts/run-owned-search-tests.py')
        return frozen.execute(run,args,watchdog.main)
    except (OSError,ValueError,ImportError) as error:
        (run/'status.json').write_text(json.dumps(dict(exit=125,failure=type(error).__name__))+'\n')
        return 125

if __name__=='__main__': raise SystemExit(main())
