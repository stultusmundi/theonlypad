# Native close and admission adapters

The process registry and close owner retain model and recovery authority. Native controllers provide exact identity validation, close confirmation, control admission, legacy queue drain, scalar resource checks and a one-use empty-window close permit. Endpoint identity is separate from new user admission, allowing the owning publisher to validate frozen windows.

User edit, selection, undo, file, pane and asynchronous completion sinks consult registry admission. Owner projection has narrowly scoped selection/layout/focus authority, not permission to edit. Direct native selection and actual UndoManager calls are guarded at the model/view level. An NSWindow preflight rejects an already-denied editor before AppKit resigns the current responder. Admission predicates must remain pure; arbitrary allowed-then-revoked callbacks are not transactionally rolled back by AppKit.

Clean close may retain history; dirty close requires explicit discard confirmation. Unconfirmed publication remains refused by the registry, retaining evidence and directing the user to verify/retry Save or Save As. Applying admission does not clear undo, content, baseline or presentation. Removed history models avoid presentation mutations. Monitoring detachment is handed to a required process callback that must retain receipts/failures before returning or throwing.

The process must still compose these adapters with actual close/repair receipts, endpoint lifetime, async history preparation, monitor reattachment, startup and quit. AppDelegate activation is disabled until those integrations are verified. No dirty-history compatibility or complete desktop freeze is claimed by this slice.
