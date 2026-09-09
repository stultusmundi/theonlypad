# Native model recovery ownership

Implemented: native ownership generation, a separate workspace-handle conformance, first-only actor-authority installation and immutable authorized recovery capture with checked revision issuance. The managed epoch counter is separate from the existing legacy counter. Repair installation, live registry ownership and controller writer migration are not implemented by this slice.

`scripts/test-document-recovery-ownership.sh .build/recovery-close-candidate/arm64-apple-macosx/debug` passed the 26-assertion model harness and unchanged SharedPaneOwnershipHarness in `.local/document-recovery-ownership/run.f1HCid9K`. Both compiled and exited 0 against the freshly built core; source and linked object hashes are retained. The earlier compiled red `run.Vj2g6jBw` failed valid first adoption while invalid-input controls and shared-pane ownership still passed. Root and independent review found no material issue in this bounded adapter.

Cases cover wrong owner/document and zero revision refusal, duplicate adoption without counter rewind, scratch/clean/dirty disposition, normalization-sensitive text, encoding/BOM changes, real uncertain-publication evidence, immutable prior captures across edits/ownership changes, actual shared-pane undo/redo and UInt64 exhaustion without wrapping. No windows were shown and no desktop input or performance claim is made.

Authority provenance is the trusted actor caller's responsibility. The process owner must enforce native admission, pending-edit and resource checks before capture. Passing model tests does not establish those unimplemented integration guarantees.
