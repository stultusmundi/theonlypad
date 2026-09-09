# Native document initialization factory

The factory is an implemented prerequisite, not an active controller migration. Existing controller routes, recovery routing and application ownership remain unchanged. Native intake must be reviewed and integrated before calling this factory from application creation paths.

`NativeDocumentSeed` is an immutable Sendable preparation value with a private initializer. Its eight constructors cover scratch, opened file, restored session/recovery, backup, disk copy, duplicate, clean-history reopen and standalone recovery. A restored file is an additional tested variation. No seed retains a model, endpoint, source operation, monitor, undo manager or recovery authority.

Preparation validates per-document limits of 100 million UTF-16 units and 100 million original source bytes. Tests may supply stricter limits; ceilings cannot increase. Read-only seed counts report this one payload, not aggregate admission. The process remains responsible for reserving the existing 100 million recovery UTF-16 / 400 MB aggregate resource budget before accepting or duplicating payloads. Input allocation has already occurred when a constructor receives a String/Data; constructor checks are not a substitute for bounded reads or process reservation.

Decode, language detection, exact byte/text coherence and bookmark/presentation resolution are preparation work intended for existing workers. The factory does not repeat those scans. Restored and reopened file values prove exact decoded UTF-16 and BOM pairing with original bytes. Canonically equivalent but different UTF-16 is not accepted as the same saved baseline. Recovery originalPath remains informational: restored recovery and standalone recovery always have nil URL/originalBytes. Saved baseline defaults and backup/copy/duplicate language semantics match current controller initialization.

`EditorDocumentFactory.make` runs on MainActor and creates one unregistered model with its proven internal storage observer, primary pane and highlighter ownership. It copies prepared semantic values, acknowledges a baseline only for real file values, and retains restored pane presentation lazily, mapping the saved focused slot to the sole live pane. It does not show a window, attach endpoint callbacks, install a monitor, append to a controller, submit recovery, or register ownership. TextKit setup cost is not claimed bounded independently of document size, and no performance measurement is implied.

History reopening accepts a coherent clean value only: text/encoding/BOM equal saved state, exact original bytes where present, and bookmarks valid for that text. It creates a fresh model/undo/storage without copying pending publication or writer authority. Process history claim/consume remains later work.

Disk-copy integration must synchronously validate and consume the source-operation context at accepted handoff, reserve the process payload budget, and retain the immutable seed in the intake owner. Later intake uses separately captured destination incarnation/selection intent, not the finished source operation. Source closure cannot silently abandon an accepted seed. Only completed activation/projection may report a copy as created. This handoff is a design contract, not implemented by the factory.

## Verification and limits

The compile-only factory seam failed nine positive cases covering all eight paths plus restored-file variation. An earlier fixture compile error is separately retained, not counted as behavioral red. Initial implementation passed 114 checks plus the unchanged shared-pane ownership harness. A focused invalid-history-bookmark regression then failed at runtime; the seed now rejects dropped invalid bookmarks rather than storing them unchanged. Final verification is recorded in the execution plan.

Tests use synthetic values and hidden AppKit model construction only. They verify exact text/baselines/encoding/BOM, URL pairing, informational recovery names, independent ownership, lazy pane state, limits and invalid pairings. No physical input, visible UI, application registration or recovery publication is claimed.
