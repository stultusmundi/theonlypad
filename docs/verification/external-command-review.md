# Independent command and extension integration review

Date: 2026-09-09. Scope: read-only review of `ExternalCommand.swift`, `ExternalCommandController.swift`, `ExtensionCatalog.swift`, `ExtensionManagerController.swift` and their AppDelegate routing. This is a focused implementation review, not a sandbox or penetration-test certification.

## External command finding: addressed

Priority P1: the original quit helper snapshotted active commands and awaited them, while an idle command panel could still launch another process. Reproduction: launch a TERM-resistant bounded fixture in panel A; begin quit cancellation; during the asynchronous wait, press Run in idle panel B. The second command escaped the original snapshot.

The owner added a shutdown state checked by Run and made cancellation drain active work until empty. A native AppKit probe against the changed controller attempted a second launch during the first command's termination grace period. Observed results: `Started second command during quit: false` and `Second command still running after first quit wait: false`. Fixtures used temporary local files and were cleaned up. This probe was temporary, not a retained regression test; the review does not claim that an automated regression suite covers this race.

No further material defect was found in the reviewed single-pass placeholder expansion, explicit executable/argument handling, combined bounded output capture or cancellation escalation. Capture fairly drains both nonblocking pipes. Output limits are explicit, and inherited descendant pipes have a bounded drain window after the direct child exits.

Documented limits remain: external commands have the user's local permissions; choosing a shell explicitly permits shell interpretation; descendants may outlive cancellation of the direct child. Process startup and uninterruptible kernel behavior do not gain a strict wall-clock guarantee from the polling deadline. These are not claims of process-tree containment.

## Extension finding: addressed in source

Priority P2: stale enabled commands after a catalog reload. At review time, `ExtensionManagerController.performMutation` called `onChanged` only for a mutation, not a plain reload. AppDelegate dispatched a cached enabled command directly without rereading catalog authorization.

Reproduction derived from the reviewed control flow: enable an extension; disable it through a second `ExtensionCatalog` instance; click Reload in the manager. The manager shows Disabled, but the root's cached menu/palette command still dispatches its transform. A load error similarly clears the manager without invalidating the root cache. This reproduction is based on source inspection and was not executed as a native integration harness.

Recommended correction: notify/invalidate root routing after every reload and load failure, and revalidate the exact enabled command at dispatch. The manager's own Run path already rereads enabled state before invoking its callback. The current manager notifies after successful reload and after failure. The root now rereads enabled commands, requires exact command equality, and checks quit state, target window visibility and document identity before executing. Source verification closes the reported stale-routing path; a native reproduction/regression harness was not run for this finding.

The catalog is declarative and restricts commands to built-in text transforms; it does not load executable extension code. Old palette command IDs are safely ignored after the root cache has actually been invalidated. Generation checks suppress older asynchronous catalog-refresh completions. Closing a previous singleton panel before replacement prevents orphaned visible panel targets; physical window interaction was not exercised by this review.

## Text utilities follow-up review

Reviewed `TextUtilities.swift`, `TextUtilitiesController.swift`, `TextUtilitiesTests.swift` and `EditorWindowController.showTextUtilities` after folder-search completion. No material defect found in this focused source review.

The Base64 dialect requires standard alphabet, canonical padding and no whitespace; re-encoding validates canonical input. URL conversion is component percent encoding, preserving literal plus on decode rather than treating it as a form-space. JSON conversion emits/accepts a complete quoted string. Strict UTF8 decoding preserves BOM/control characters and rejects malformed bytes. Input/output have a 2,000,000 UTF8-byte cap; expanding encoders preflight or bound appends. Existing tests inspect exact byte roundtrips, malformed input and expansion caps; this reviewer inspected these tests but did not separately rerun them.

Preview generations reject old completion results; close invalidates callbacks. Hash output cannot replace text. Root replacement requires the same current document and exact UTF16 snapshot, rejects saving/quit state, and uses the native shouldChangeText/didChangeText path with a named undo group. Closing the editor also closes its utility panel. This review does not establish physical GUI usability or independently verify native undo behavior. Cancellation is checked before and after the bounded conversion, not within every conversion loop; stale output remains suppressed.
