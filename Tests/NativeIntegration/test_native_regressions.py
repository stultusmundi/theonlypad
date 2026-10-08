"""Pure native-runner contracts; injected receipts, no native process launch."""
import importlib.util
import errno
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC=importlib.util.spec_from_file_location('native_regressions',Path(__file__).with_name('run_native_regressions.py'))
RUNNER=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(RUNNER)

class NativeRunnerTests(unittest.TestCase):
    def test_help_requires_its_named_positive_suite(self):
        text="Test Suite 'HelpReferenceTests' passed\nExecuted 5 tests, with 0 failures\n"
        try:
            result=RUNNER.parse_success('help',text)
        except (KeyError,ValueError):
            self.fail('A positive HelpReferenceTests result must be admitted by its own suite')
        self.assertEqual(result,{'tests':5,'failures':0})
        for text in ["Test Suite 'HelpReferenceTests' passed\nExecuted 0 tests, with 0 failures",
                     "Test Suite 'EditorDocumentTransferTests' passed\nExecuted 5 tests, with 0 failures",
                     "Test Suite 'HelpReferenceTests' passed\nExecuted 5 tests, with 1 failures",
                     "Executed 5 tests, with 0 failures"]:
            with self.subTest(text=text),self.assertRaises(ValueError):
                RUNNER.parse_success('help',text)

    def test_help_freezes_actual_controller_and_separate_test_without_presentation_transform(self):
        root,run=self.fixture()
        controller='// complete original Help controller\n'
        test='// real hidden Help assertions\n'
        (root/'Sources/TheOnlyPad/HelpController.swift').write_text(controller)
        (root/'Tests/NativeIntegration/HelpReferenceTests.swift').write_text(test)
        (root/'scripts/test-help-reference.sh').write_text('# fixed Help entry\n')
        try:
            args=RUNNER.parse_args(['help'])
        except SystemExit:
            self.fail('The Help entry must select an isolated Help regression run')
        manifest=RUNNER.freeze(root,run,args.suite)
        self.assertEqual((run/'Package/Sources/NativeRouting/HelpController.swift').read_text(),controller)
        self.assertEqual((run/'Package/Tests/NativeRoutingTests/HelpReferenceTests.swift').read_text(),test)
        self.assertFalse((run/'Package/Sources/NativeRouting/TheOnlyPadApplication.swift').exists())
        RUNNER.verify(run,manifest)
        (run/'Package/Sources/NativeRouting/HelpController.swift').write_text('changed after freeze')
        with self.assertRaises(ValueError): RUNNER.verify(run,manifest)

    def test_folder_navigation_requires_its_named_positive_suite(self):
        text="Test Suite 'FolderNavigationTests' passed\nExecuted 2 tests, with 0 failures\n"
        self.assertEqual(RUNNER.parse_success('folder-navigation',text),{'tests':2,'failures':0})
        for text in ["Test Suite 'FolderNavigationTests' passed\nExecuted 0 tests, with 0 failures",
                     "Test Suite 'SearchReplacementTests' passed\nExecuted 2 tests, with 0 failures"]:
            with self.assertRaises(ValueError): RUNNER.parse_success('folder-navigation',text)

    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.output=Path(self.temp.name)/'output';self.output.mkdir()
        self.command=['/usr/bin/env','THEONLYPAD_STATE_DIRECTORY=/synthetic/state','fixed-test']
    def receipt(self):
        text=b'complete output\n';(self.output/'stdout.log').write_bytes(text);(self.output/'stderr.log').write_bytes(b'')
        value=dict(command=self.command,pid=91,processGroup=91,exitObserved=True,registrationError=None,
            groupSignalAttempted=True,groupSignalError=None,groupCleanup='signaled',groupQuery=None,
            waitCompleted=True,returnCode=0,waitError=None,timedOut=False,interruptedSignal=None,
            truncated=False,captureComplete=True,failure=None,exit=0,
            captured={'stdout':dict(received=len(text),stored=len(text),discarded=0),
                      'stderr':dict(received=0,stored=0,discarded=0)})
        return value
    def store(self,value): (self.output/'status.json').write_text(json.dumps(value))
    def test_complete_success_requires_owned_capture_receipt(self):
        self.store(self.receipt());self.assertTrue(RUNNER.receipt_success(self.output,self.command))
    def test_missing_or_inconsistent_receipt_is_not_success(self):
        for field in self.receipt():
            with self.subTest(missing=field):
                value=self.receipt();del value[field];self.store(value)
                self.assertFalse(RUNNER.receipt_success(self.output,self.command))
        for field,value in [('waitCompleted',False),('captureComplete',False),('timedOut',True),
                            ('truncated',True),('failure','bad'),('interruptedSignal',15),
                            ('groupCleanup','unconfirmed'),('returnCode',1),('processGroup',92)]:
            with self.subTest(field=field):
                receipt=self.receipt();receipt[field]=value;self.store(receipt)
                self.assertFalse(RUNNER.receipt_success(self.output,self.command))
    def test_missing_file_or_captured_bytes_refuses(self):
        self.assertFalse(RUNNER.receipt_success(self.output,self.command))
        self.store(self.receipt());(self.output/'stdout.log').write_bytes(b'changed')
        self.assertFalse(RUNNER.receipt_success(self.output,self.command))
    def test_positive_xctest_count_and_named_suite_required(self):
        text="Test Suite 'EditorDocumentTransferTests' passed\nExecuted 12 tests, with 0 failures\n"
        self.assertEqual(RUNNER.parse_success('transfer',text),{'tests':12,'failures':0})
        for text in ["Executed 0 tests, with 0 failures", "Executed 12 tests, with 0 failures",
                     "Test Suite 'EditorDocumentTransferTests' passed\nExecuted 12 tests, with 1 failures"]:
            with self.subTest(text=text),self.assertRaises(ValueError): RUNNER.parse_success('transfer',text)
    def test_applied_settings_result_requires_its_own_positive_suite(self):
        text="Test Suite 'DocumentAppliedSettingsTests' passed\nExecuted 5 tests, with 0 failures\n"
        self.assertEqual(RUNNER.parse_success('settings',text),{'tests':5,'failures':0})
        for text in ["Test Suite 'DocumentAppliedSettingsTests' passed\nExecuted 0 tests, with 0 failures",
                     "Test Suite 'EditorDocumentTransferTests' passed\nExecuted 5 tests, with 0 failures"]:
            with self.subTest(text=text),self.assertRaises(ValueError): RUNNER.parse_success('settings',text)

    def test_search_replacement_requires_its_named_positive_suite(self):
        text="Test Suite 'SearchReplacementTests' passed\nExecuted 1 test, with 0 failures\n"
        self.assertEqual(RUNNER.parse_success('search-replacement',text),{'tests':1,'failures':0})
        for text in ["Test Suite 'SearchReplacementTests' passed\nExecuted 0 tests, with 0 failures",
                     "Test Suite 'EditorTransferProjectionTests' passed\nExecuted 1 test, with 0 failures"]:
            with self.subTest(text=text),self.assertRaises(ValueError):
                RUNNER.parse_success('search-replacement',text)

    def test_replay_completion_transform_preserves_owned_cleanup_and_is_exact(self):
        source="""prefix
  func replay(_ macro: EditorMacro, repeatCount: Int) {
    Task {
      defer {
        originalCancellationCleanup()
        Self.completeFileOperation(document, id: operationID, controller: self)
      }
      do {
        actualReplay()
      }
    }
  }
  func textViewDidChangeSelection(_ notification: Notification) {
suffix
"""
        marker='        Self.completeFileOperation(document, id: operationID, controller: self)\n      }\n      do {'
        expected=source.replace(marker,marker.replace('\n      }','\n        NativeEditTestCompletion.finish?()\n      }'))
        self.assertEqual(RUNNER.native_replay_completion(source),expected)
        for broken in [source.replace(marker,''),source.replace(marker,marker+'\n'+marker),
                       source+source,source.replace('  func textViewDidChangeSelection(', 'changed(')]:
            with self.assertRaises(ValueError): RUNNER.native_replay_completion(broken)

    def test_text_utility_transform_suppresses_only_the_exact_presentation(self):
        source="""prefix
  private func showTextUtilities() {
    let panel = actualPanel(actualReplacement)
    panel.showWindow(nil)
  }

  private func showSearch() {
    panel.showWindow(nil)
  }
suffix
"""
        expected=source.replace('    panel.showWindow(nil)',
          '    // Hidden harness: construct the actual utility panel without showing it.',1)
        self.assertEqual(RUNNER.native_text_utility_controller(source),expected)
        for broken in [source.replace('  private func showSearch()', 'changed()'),
                       source.replace('    let panel', '    panel.showWindow(nil)\n    let panel'),
                       source+source]:
            with self.assertRaises(ValueError): RUNNER.native_text_utility_controller(broken)

    def test_line_ending_completion_transform_is_exact_and_preserves_cleanup(self):
        source="""prefix
  private func convertLineEndings(
    Task {
      defer { Self.completeFileOperation(document, id: operationID, controller: self) }
      actualConversion()
    }
  }

  private func convertEncoding(
suffix
"""
        marker='      defer { Self.completeFileOperation(document, id: operationID, controller: self) }'
        expected=source.replace(marker,marker[:-2]+'; NativeEditTestCompletion.finish?() }')
        self.assertEqual(RUNNER.native_line_ending_completion(source),expected)
        for broken in [source.replace(marker,''),source.replace(marker,marker+'\n'+marker),
                       source+source,source.replace('  private func convertEncoding(', 'changed(')]:
            with self.assertRaises(ValueError): RUNNER.native_line_ending_completion(broken)

    def test_document_command_completion_transform_is_exact_and_preserves_cleanup(self):
        source="""prefix
  private func performDocumentCommand(
    Task { [weak self, weak document] in
      defer { Self.completeFileOperation(document, id: operationID, controller: self) }
      actualCommand()
    }
  }

  func navigateManaged(
suffix
"""
        marker='      defer { Self.completeFileOperation(document, id: operationID, controller: self) }'
        expected=source.replace(marker,marker[:-2]+'; NativeEditTestCompletion.finish?() }')
        self.assertEqual(RUNNER.native_edit_completion(source),expected)
        for broken in [source.replace(marker,''),source.replace(marker,marker+'\n'+marker),
                       source+source,source.replace('  func navigateManaged(', 'changed(')]:
            with self.assertRaises(ValueError): RUNNER.native_edit_completion(broken)

    def test_search_replacement_transform_changes_only_presentation_and_appends_access(self):
        source="""  private func showSearch() {
    let panel = actualSearchPanel(replace: actualReplacement)
    panel.showWindow(nil)
  }
  private func apply(_ transform: LineTransform) {
    untouched()
  }
"""
        expected=source.replace('    panel.showWindow(nil)',
            '    // Hidden harness: construct the actual panel without showing it.')+'\n// access'
        self.assertEqual(RUNNER.search_replacement_controller(source,'// access'),expected)
        for broken in [source.replace('panel.showWindow(nil)','changed()'),source+source]:
            with self.subTest(broken=broken),self.assertRaises(ValueError):
                RUNNER.search_replacement_controller(broken,'')
        access='// SEARCH-PANEL-ACCESS-BEGIN\nactual access\n// SEARCH-PANEL-ACCESS-END'
        self.assertEqual(RUNNER.search_replacement_access(access,'PANEL'),'actual access\n')
        for broken in ['',access+access]:
            with self.subTest(broken=broken),self.assertRaises(ValueError):
                RUNNER.search_replacement_access(broken,'PANEL')

    def test_native_summary_and_shared_smoke_are_distinct(self):
        self.assertEqual(RUNNER.parse_success('NativeCloseModelHarness','Native close model checks: 106, failures: 0'),{'checks':106,'failures':0})
        self.assertEqual(RUNNER.parse_success('DocumentFactoryHarness','Factory checks: 133, failures: 0'),{'checks':133,'failures':0})
        marker='PASS shared storage/undo, exact Unicode, revisions, selections, bounded detach/reattach, lifetime'
        self.assertEqual(RUNNER.parse_success('SharedPaneOwnershipHarness',marker),{'scenarios':1,'failures':0})
        for kind,text in [('NativeCloseModelHarness','Native close model checks: 0, failures: 0'),
                          ('DocumentFactoryHarness','Factory checks: 3, failures: 1'),
                          ('SharedPaneOwnershipHarness','')]:
            with self.subTest(kind=kind),self.assertRaises(ValueError): RUNNER.parse_success(kind,text)

    def fixture(self,suite='transfer',prebuilt=False,applied=False):
        root=Path(self.temp.name)/'repo';root.mkdir()
        files={name:'# fixed input\n' for name in RUNNER.FIXED}
        files.update({'Sources/PadCore/Core.swift':'import Foundation\n',
                      'Sources/SearchExecution/Child.swift':'import PadCore\n',
                      'Sources/TheOnlyPad/EditorDocument.swift':'class Model {\n  var dirty: Bool { false }\n}\n',
                      'Sources/TheOnlyPad/TheOnlyPadApplication.swift':'@main struct App {}\n',
                      'Package.swift':'// actual package\n',
                      'Tests/PadCoreTests/CoreTests.swift':'// core tests\n',
                      'Tests/SearchExecutionTests/ChildTests.swift':'// child tests\n'})
        for name in RUNNER.CLOSE_SOURCES:
            files.setdefault('Sources/TheOnlyPad/'+name+'.swift','// '+name+'\n')
        for name in (*RUNNER.CLOSE_HARNESSES,'EditorDocumentTransferTests','EditorTransferProjectionTests'):
            files['Tests/NativeIntegration/'+name+'.swift']='// original assertions '+name+'\n'
        if applied: files['Sources/TheOnlyPad/DocumentAppliedSettings.swift']='// future applied types\n'
        for name,data in files.items():
            path=root/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_text(data)
        run=Path(self.temp.name)/'run';run.mkdir()
        return root,run

    def test_search_replacement_manifest_declares_all_frozen_transforms(self):
        root,run=self.fixture()
        source="""  private func convertLineEndings(
      defer { Self.completeFileOperation(document, id: operationID, controller: self) }
  private func convertEncoding(
  private func performDocumentCommand(
      defer { Self.completeFileOperation(document, id: operationID, controller: self) }
  func navigateManaged(
  private func showTextUtilities() {
    panel.showWindow(nil)
  private func showSearch() {
    panel.showWindow(nil)
  private func apply(_ transform: LineTransform) {
  func replay(_ macro: EditorMacro, repeatCount: Int) {
        Self.completeFileOperation(document, id: operationID, controller: self)
      }
      do {
  func textViewDidChangeSelection(
"""
        files={'Sources/TheOnlyPad/EditorWindowController.swift':source,
          'Sources/TheOnlyPad/SearchPanelController.swift':'// actual search panel\n',
          'Sources/TheOnlyPad/TextUtilitiesController.swift':'// actual utility panel\n',
          'scripts/test-search-replacement.sh':'# actual suite entry\n',
          'Tests/NativeIntegration/SearchReplacementTests.swift':''.join(
            '// SEARCH-'+label+'-ACCESS-BEGIN\n// '+label+' access\n// SEARCH-'+label+'-ACCESS-END\n'
            for label in ('CONTROLLER','PANEL','UTILITY'))}
        for name,value in files.items(): (root/name).write_text(value)
        manifest=RUNNER.freeze(root,run,'search-replacement')
        self.assertEqual(manifest['transformation'],
          'Dirty getter counter; test access extracted into frozen controller, search panel and text utility panel; '
          'exact search and text utility showWindow calls suppressed; document command, line-ending conversion and '
          'macro replay defer completion observers appended with original cleanup retained; access regions omitted from XCTest source.')
        self.assertEqual((run/'Original/Sources/TheOnlyPad/EditorWindowController.swift').read_text(),source)
        self.assertNotEqual((run/'Package/Sources/NativeRouting/EditorWindowController.swift').read_text(),source)

    def test_transfer_snapshot_retains_exact_original_and_counter_transform(self):
        root,run=self.fixture()
        manifest=RUNNER.freeze(root,run,'transfer')
        original=(root/'Sources/TheOnlyPad/EditorDocument.swift').read_text()
        compiled=(run/'Package/Sources/NativeRouting/EditorDocument.swift').read_text()
        marker='  var dirty: Bool {'
        self.assertEqual(compiled,original.replace(marker,'  var transferHarnessDirtyReads = 0\n'+marker+'\n    transferHarnessDirtyReads += 1'))
        self.assertEqual((run/'Original/Sources/TheOnlyPad/EditorDocument.swift').read_text(),original)
        self.assertFalse((run/'Package/Sources/NativeRouting/TheOnlyPadApplication.swift').exists())
        self.assertEqual((run/'Package/Tests/NativeRoutingTests/EditorDocumentTransferTests.swift').read_bytes(),
                         (root/'Tests/NativeIntegration/EditorDocumentTransferTests.swift').read_bytes())
        RUNNER.verify(run,manifest)
        (run/'Package/Sources/NativeRouting/EditorDocument.swift').write_text('changed')
        with self.assertRaises(ValueError): RUNNER.verify(run,manifest)

    def test_projection_probe_preserves_focus_body_and_places_callback_after_origin(self):
        source = """  override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
    return originalAdmissionAndFocus(responder)
  }
  private func installResolvedPanes() {
    applyOrigin()
      try validateAuthority()
    }
    state.pending = nil
  }
  private func installPendingPresentationIfPossible() {}
"""
        result = RUNNER.projection_probe(source, '// access')
        self.assertIn('return originalAdmissionAndFocus(responder)', result)
        self.assertLess(result.index('applyOrigin()'), result.index('ProjectionFocusProbe.afterOrigin?(self)'))
        self.assertLess(result.index('ProjectionFocusProbe.afterOrigin?(self)'), result.index('try validateAuthority()'))
        self.assertTrue(result.endswith('// access'))
        for broken in [source.replace('override func makeFirstResponder', 'func changed'),
                       source.replace('      try validateAuthority()', '      changed()')]:
            with self.subTest(broken=broken), self.assertRaises(ValueError): RUNNER.projection_probe(broken, '')

    def test_projection_access_is_frozen_separately_from_retained_assertions(self):
        root,run=self.fixture()
        original='import XCTest\n// NATIVE-ACCESS-BEGIN\n// focus access sentinel\n// NATIVE-ACCESS-END\n// retained original and focus assertions\n'
        (root/'Tests/NativeIntegration/EditorTransferProjectionTests.swift').write_text(original)
        controller="""  override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
    return super.makeFirstResponder(responder)
  }
  private func installResolvedPanes() {
    for pane in panes {
      applyOrigin(pane)
      try validateAuthority()
    }
  }
  private func installPendingPresentationIfPossible() {}
"""
        (root/'Sources/TheOnlyPad/EditorWindowController.swift').write_text(controller)
        manifest=RUNNER.freeze(root,run,'projection')
        self.assertEqual((run/'Original/Tests/NativeIntegration/EditorTransferProjectionTests.swift').read_text(),original)
        self.assertEqual((run/'Original/Sources/TheOnlyPad/EditorWindowController.swift').read_text(),controller)
        self.assertEqual((run/'Package/Tests/NativeRoutingTests/EditorTransferProjectionTests.swift').read_text(),
                         'import XCTest\n\n// retained original and focus assertions\n')
        self.assertIn('// focus access sentinel', (run/'Package/Sources/NativeRouting/EditorWindowController.swift').read_text())
        self.assertIn('post-origin',manifest['transformation'])
        RUNNER.verify(run,manifest)

    def test_settings_access_transform_is_frozen_and_tests_remain_separate(self):
        root,run=self.fixture(applied=True)
        (root/'scripts/test-document-applied-settings.sh').write_text('# fixed settings wrapper\n')
        original='import XCTest\n// NATIVE-ACCESS-BEGIN\n// native access sentinel\n// NATIVE-ACCESS-END\n// retained test assertions\n'
        (root/'Tests/NativeIntegration/DocumentAppliedSettingsTests.swift').write_text(original)
        (root/'Sources/TheOnlyPad/EditorWindowController.swift').write_text('// original controller\n')
        (root/'Sources/TheOnlyPad/DocumentTextView.swift').write_text('class View {\n  let documentUndo: UndoManager\n}\n')
        manifest=RUNNER.freeze(root,run,'settings')
        self.assertEqual((run/'Original/Tests/NativeIntegration/DocumentAppliedSettingsTests.swift').read_text(),original)
        self.assertEqual((run/'Package/Tests/NativeRoutingTests/DocumentAppliedSettingsTests.swift').read_text(),
                         'import XCTest\n\n// retained test assertions\n')
        self.assertEqual((run/'Package/Sources/NativeRouting/EditorWindowController.swift').read_text(),
                         '// original controller\n\n// native access sentinel\n')
        self.assertTrue((run/'Package/Sources/NativeRouting/DocumentAppliedSettings.swift').is_file())
        RUNNER.verify(run,manifest)
        (run/'Package/Sources/NativeRouting/DocumentTextView.swift').write_text('unrecorded mutation')
        with self.assertRaises(ValueError): RUNNER.verify(run,manifest)

    def test_close_snapshot_includes_optional_applied_source_and_full_build_prerequisite(self):
        root,run=self.fixture(suite='close',applied=True)
        manifest=RUNNER.freeze(root,run,'close')
        self.assertTrue((run/'NativeSources/DocumentAppliedSettings.swift').is_file())
        self.assertEqual((run/'BuildPackage/Package.swift').read_bytes(),(root/'Package.swift').read_bytes())
        self.assertTrue((run/'BuildPackage/Sources/TheOnlyPad/TheOnlyPadApplication.swift').is_file())
        self.assertTrue((run/'BuildPackage/Tests/PadCoreTests/CoreTests.swift').is_file())
        self.assertEqual((run/'NativeSources/EditorDocument.swift').read_bytes(),(root/'Sources/TheOnlyPad/EditorDocument.swift').read_bytes())
        RUNNER.verify(run,manifest)

    def test_source_mutation_during_capture_and_symlink_are_refused(self):
        root,run=self.fixture();original=RUNNER.read_real
        reads=0
        def read(directory,path):
            nonlocal reads
            result=original(directory,path)
            if path.name=='EditorDocumentTransferTests.swift':
                reads+=1
                if reads==2: (root/'Sources/PadCore/Core.swift').write_text('changed after core copy')
            return result
        with patch.object(RUNNER,'read_real',read),self.assertRaises(ValueError): RUNNER.freeze(root,run,'transfer')
        target=root/'Sources/PadCore/Core.swift';target.unlink();target.symlink_to(root/'Package.swift')
        with self.assertRaises(ValueError): RUNNER.discover(root,'transfer',False)

    def test_core_artifacts_are_copied_and_checked_not_linked_from_live_directory(self):
        binary=Path(self.temp.name)/'debug';(binary/'PadCore.build').mkdir(parents=True);(binary/'Modules').mkdir()
        (binary/'PadCore.build/Core.swift.o').write_bytes(b'object');(binary/'Modules/PadCore.swiftmodule').write_bytes(b'module')
        run=Path(self.temp.name)/'run';run.mkdir();manifest=RUNNER.freeze_core(binary,run)
        (binary/'PadCore.build/Core.swift.o').write_bytes(b'later live build')
        self.assertEqual((run/'Core/PadCore.build/Core.swift.o').read_bytes(),b'object')
        RUNNER.verify(run,manifest)
        (run/'Core/PadCore.build/Core.swift.o').write_bytes(b'changed')
        with self.assertRaises(ValueError): RUNNER.verify(run,manifest)

    def watchdog(self,text,missing=False,mutate=None):
        self.calls=[]
        def call(argv):
            self.calls.append(argv);output=Path(argv[argv.index('--output')+1]);output.mkdir(parents=True)
            command=argv[argv.index('--')+1:]
            old_output,old_command=self.output,self.command;self.output,self.command=output,command
            value=self.receipt();self.output,self.command=old_output,old_command
            content=(text(command) if callable(text) else (text if 'test' in command else 'toolchain')).encode()
            if '-o' in command: Path(command[command.index('-o')+1]).write_bytes(b'compiled native fixture')
            (output/'stdout.log').write_bytes(content)
            value['captured']['stdout']={'received':len(content),'stored':len(content),'discarded':0}
            if not missing: (output/'status.json').write_text(json.dumps(value))
            if mutate: mutate()
            return 0
        return call

    def test_stage_missing_receipt_stops_before_next_child(self):
        root,run=self.fixture();RUNNER.freeze(root,run,'transfer')
        code=RUNNER.execute(run,RUNNER.parse_args(['transfer']),self.watchdog('',missing=True))
        self.assertEqual(code,125);self.assertEqual(len(self.calls),1)

    def test_zero_test_success_and_changed_frozen_source_are_failures(self):
        root,run=self.fixture();RUNNER.freeze(root,run,'transfer')
        code=RUNNER.execute(run,RUNNER.parse_args(['transfer']),self.watchdog("Test Suite 'EditorDocumentTransferTests' passed\nExecuted 0 tests, with 0 failures"))
        self.assertEqual(code,125);self.assertEqual(len(self.calls),2)

    def test_source_change_after_stage_is_detected_before_next_stage(self):
        root,run=self.fixture();RUNNER.freeze(root,run,'transfer')
        mutate=lambda:(run/'Original/Sources/PadCore/Core.swift').write_text('changed')
        code=RUNNER.execute(run,RUNNER.parse_args(['transfer']),self.watchdog('',mutate=mutate))
        self.assertEqual(code,125);self.assertEqual(len(self.calls),1)

    def test_success_preserves_fixed_state_exec_and_original_test_mode(self):
        root,run=self.fixture();RUNNER.freeze(root,run,'transfer')
        text="Test Suite 'EditorDocumentTransferTests' passed\nExecuted 12 tests, with 0 failures\n"
        code=RUNNER.execute(run,RUNNER.parse_args(['transfer']),self.watchdog(text))
        self.assertEqual(code,0);self.assertEqual(len(self.calls),2)
        command=self.calls[-1][self.calls[-1].index('--')+1:]
        self.assertEqual(command[0],'/usr/bin/env')
        self.assertEqual(command[1],'THEONLYPAD_STATE_DIRECTORY='+str(run/'State/test'))
        self.assertIn('test',command);self.assertNotIn('--filter',command)

    def test_prebuilt_argument_is_close_only(self):
        self.assertEqual(RUNNER.parse_args(['close','/synthetic/debug']).build_path,'/synthetic/debug')
        for arguments in [['transfer','/synthetic/debug'],['projection','extra'],['close','one','two']]:
            with self.subTest(arguments=arguments),self.assertRaises(SystemExit): RUNNER.parse_args(arguments)

    def test_close_prebuilt_compiles_only_frozen_inputs_and_runs_all_three_checks(self):
        root,run=self.fixture('close',prebuilt=True)
        RUNNER.freeze(root,run,'close',True)
        self.assertFalse((run/'BuildPackage').exists())
        binary=Path(self.temp.name)/'debug';(binary/'PadCore.build').mkdir(parents=True);(binary/'Modules').mkdir()
        (binary/'PadCore.build/Core.swift.o').write_bytes(b'object');(binary/'Modules/PadCore.swiftmodule').write_bytes(b'module')
        def output(command):
            return {'NativeCloseModelHarness':'Native close model checks: 106, failures: 0',
                    'DocumentFactoryHarness':'Factory checks: 133, failures: 0',
                    'SharedPaneOwnershipHarness':RUNNER.SHARED_MARKER}.get(Path(command[-1]).name,'toolchain')
        code=RUNNER.execute(run,RUNNER.parse_args(['close',str(binary)]),self.watchdog(output))
        self.assertEqual(code,0);self.assertEqual(len(self.calls),7)
        for invocation in self.calls:
            command=invocation[invocation.index('--')+1:]
            self.assertTrue(all(not word.startswith(str(binary)) for word in command))
            if '-o' in command:
                self.assertEqual([word for word in command if word.endswith('.o')],
                                 [str(run/'Core/PadCore.build/Core.swift.o')])
        result=json.loads((run/'status.json').read_text())
        self.assertEqual(set(result['results']),set(RUNNER.CLOSE_HARNESSES))

    def test_exited_leader_only_requires_exact_singleton_receipt(self):
        receipt=self.receipt();receipt.update(groupCleanup='exitedLeaderOnly',groupSignalError=1,
            groupQuery=dict(processGroup=91,errorNumber=None,bufferBytes=1024,returnedBytes=4,members=[91]))
        self.store(receipt);self.assertTrue(RUNNER.receipt_success(self.output,self.command))
        receipt['groupQuery']['members']=[91,92];self.store(receipt)
        self.assertFalse(RUNNER.receipt_success(self.output,self.command))

    def singleton(self):
        value=self.receipt()
        value.update(groupCleanup='exitedLeaderOnly',groupSignalError=errno.EPERM,
            groupQuery=dict(processGroup=91,errorNumber=None,bufferBytes=1024,returnedBytes=4,members=[91]))
        return value

    def test_all_complete_cleanup_branches_and_registration_race_are_accepted(self):
        for cleanup,error in [('signaled',None),('absent',errno.ESRCH),('exitedLeaderOnly',errno.EPERM)]:
            value=self.singleton();value.update(groupCleanup=cleanup,groupSignalError=error)
            if cleanup!='exitedLeaderOnly': value['groupQuery']=None
            self.store(value);self.assertTrue(RUNNER.receipt_success(self.output,self.command),cleanup)
        value=self.receipt();value.update(groupCleanup='absent',groupSignalError=errno.ESRCH,
            exitObserved=False,registrationError=errno.ESRCH)
        self.store(value);self.assertTrue(RUNNER.receipt_success(self.output,self.command))

    def test_every_singleton_query_field_is_required_and_strictly_typed(self):
        for field in self.singleton()['groupQuery']:
            with self.subTest(missing=field):
                value=self.singleton();del value['groupQuery'][field];self.store(value)
                self.assertFalse(RUNNER.receipt_success(self.output,self.command))
        for field,bad in [('processGroup',91.0),('bufferBytes',1024.0),('returnedBytes',4.0),
                          ('errorNumber',False),('members',[91.0]),('members',[91,92])]:
            with self.subTest(field=field,bad=bad):
                value=self.singleton();value['groupQuery'][field]=bad;self.store(value)
                self.assertFalse(RUNNER.receipt_success(self.output,self.command))

    def test_numeric_aliases_and_inconsistent_branch_shapes_refuse(self):
        for field,bad in [('exit',False),('returnCode',False),('processGroup',91.0),
                          ('exitObserved',1),('registrationError',float(errno.ESRCH)),
                          ('groupSignalError',True)]:
            with self.subTest(field=field,bad=bad):
                value=self.singleton();value[field]=bad;self.store(value)
                self.assertFalse(RUNNER.receipt_success(self.output,self.command))
        for cleanup,error in [('signaled',None),('absent',errno.ESRCH)]:
            with self.subTest(cleanup=cleanup):
                value=self.singleton();value.update(groupCleanup=cleanup,groupSignalError=error)
                self.store(value);self.assertFalse(RUNNER.receipt_success(self.output,self.command))
        for observed,registration in [(False,None),(False,True),(0,errno.ESRCH),(None,errno.ESRCH)]:
            with self.subTest(observed=observed,registration=registration):
                value=self.receipt();value.update(exitObserved=observed,registrationError=registration)
                self.store(value);self.assertFalse(RUNNER.receipt_success(self.output,self.command))
        for stream in ('stdout','stderr'):
            for field in ('received','stored','discarded'):
                with self.subTest(stream=stream,field=field):
                    value=self.receipt();value['captured'][stream][field]=float(value['captured'][stream][field]);self.store(value)
                    self.assertFalse(RUNNER.receipt_success(self.output,self.command))
                    value=self.receipt();del value['captured'][stream][field];self.store(value)
                    self.assertFalse(RUNNER.receipt_success(self.output,self.command))

    def test_boolean_aliases_for_capture_counts_are_refused(self):
        for field in ('received','stored','discarded'):
            with self.subTest(field=field):
                value=self.receipt();value['captured']['stderr'][field]=False;self.store(value)
                self.assertFalse(RUNNER.receipt_success(self.output,self.command))

    def test_extra_package_source_before_execution_launches_no_child(self):
        root,run=self.fixture();RUNNER.freeze(root,run,'transfer')
        (run/'Package/Sources/NativeRouting/Unrecorded.swift').write_text('// extra compiled source')
        code=RUNNER.execute(run,RUNNER.parse_args(['transfer']),self.watchdog(''))
        self.assertEqual(code,125);self.assertEqual(len(self.calls),0)

    def test_extra_test_after_metadata_prevents_test_stage(self):
        root,run=self.fixture();RUNNER.freeze(root,run,'transfer')
        extra=run/'Package/Tests/NativeRoutingTests/UnrecordedTests.swift'
        code=RUNNER.execute(run,RUNNER.parse_args(['transfer']),self.watchdog('',mutate=lambda:extra.write_text('// extra tests')))
        self.assertEqual(code,125);self.assertEqual(len(self.calls),1)

    def test_extra_native_source_before_execution_launches_no_child(self):
        root,run=self.fixture('close',prebuilt=True);RUNNER.freeze(root,run,'close',True)
        (run/'NativeSources/Unrecorded.swift').write_text('// extra source')
        code=RUNNER.execute(run,RUNNER.parse_args(['close','/synthetic/unneeded-build']),self.watchdog(''))
        self.assertEqual(code,125);self.assertEqual(len(self.calls),0)

    def test_extra_full_build_source_prevents_build_stage(self):
        root,run=self.fixture('close');RUNNER.freeze(root,run,'close')
        extra=run/'BuildPackage/Sources/PadCore/Unrecorded.swift'
        code=RUNNER.execute(run,RUNNER.parse_args(['close']),self.watchdog('',mutate=lambda:extra.write_text('// extra source')))
        self.assertEqual(code,125);self.assertEqual(len(self.calls),1)

    def test_extra_core_object_after_capture_prevents_native_compile(self):
        root,run=self.fixture('close',prebuilt=True);RUNNER.freeze(root,run,'close',True)
        binary=Path(self.temp.name)/'debug';(binary/'PadCore.build').mkdir(parents=True);(binary/'Modules').mkdir()
        (binary/'PadCore.build/Core.swift.o').write_bytes(b'object');(binary/'Modules/PadCore.swiftmodule').write_bytes(b'module')
        original=RUNNER.freeze_core
        def capture(binary,run):
            result=original(binary,run)
            (run/'Core/PadCore.build/Unrecorded.o').write_bytes(b'extra object')
            return result
        with patch.object(RUNNER,'freeze_core',capture):
            code=RUNNER.execute(run,RUNNER.parse_args(['close',str(binary)]),self.watchdog(''))
        self.assertEqual(code,125);self.assertEqual(len(self.calls),1)

    def test_unrecorded_module_or_alternate_package_manifest_is_refused(self):
        root,run=self.fixture();manifest=RUNNER.freeze(root,run,'transfer')
        (run/'Package/Package@swift-6.0.swift').write_text('// alternate discovered manifest')
        with self.assertRaises(ValueError): RUNNER.verify(run,manifest)
        binary=Path(self.temp.name)/'debug';(binary/'PadCore.build').mkdir(parents=True);(binary/'Modules').mkdir()
        (binary/'PadCore.build/Core.swift.o').write_bytes(b'object');(binary/'Modules/PadCore.swiftmodule').write_bytes(b'module')
        core=RUNNER.freeze_core(binary,run)
        (run/'Core/Modules/Unrecorded.swiftmodule').write_bytes(b'extra module')
        with self.assertRaises(ValueError): RUNNER.verify(run,core)

if __name__=='__main__': unittest.main()
