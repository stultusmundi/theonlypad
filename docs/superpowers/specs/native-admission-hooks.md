# Native selection and undo admission hooks

Status: model/view hooks implemented with hidden native tests. Registry/controller wiring and full application close admission are separate integration work. Legacy callers with nil predicates continue to allow selection and undo.

DocumentTextView.canChangeSelection is independent of canFocus and canMutate. All three overridden selection setters check admission before typing-run callbacks and again afterward; refusal does not call AppKit's selection setter. This preserves selection and avoids a callback revocation race. Reentrant predicate evaluation fails closed.

`withSelectionInstallation(authorizedBy:_:) throws` is a narrow synchronous owner scope. It establishes its scope before evaluating authorization, refuses nested installation, reevaluates its predicate for every selection setter, and restores state with defer. It never removes the user predicate. The controller must supply a pure exact-endpoint/process-operation authorization check; this hook alone is not ownership proof. A scope does not authorize text edits, undo, focus or arbitrary view reconstruction.

EditorDocument.canUndoRedo feeds its actual GuardedDocumentUndoManager, which overrides undo, redo and undoNestedGroup. Denial does not clear actions, change grouping, alter text/bookmarks or rotate semantic generations. Admission uses a weak model capture, rejects a released model and avoids recursive predicate entry. The native view still returns the same model manager; there is no proxy menu-only check. The subclass is MainActor-isolated and compiles without unsafe isolation assumptions.

EditorDocument.captureCloseState refuses while its real manager isUndoing or isRedoing. This blocks a close request reentered by an undo callback even after the undo entry gate has admitted the group. Existing pending storage/bookmark, operation, composition and repair guards remain intact.

Controller integration must install exact registry predicates before user admission, refresh isEditable/isSelectable without changing semantic data, and use owner selection installation only under the existing projection transaction. These hooks do not freeze scrolling or raw direct NSTextStorage mutations. Complete controller mutation/close admission and pane-event integration remain required.
