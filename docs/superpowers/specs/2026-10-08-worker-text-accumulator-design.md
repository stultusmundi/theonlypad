# Production worker text accumulator design

Status: independently reviewed design; implementation and runtime verification pending.

## Authority and scope

BUILD_PROMPT authorizes routine architecture, local implementation, tests and scoped commits, replacing repeated human approvals with documented review. This architectural slice supplies the missing concrete `SearchWorkerTextAccumulator`. It does not activate editor search, add a helper executable, change limits, or establish allocation/RSS or desktop acceptance. Original MIT code; Foundation and Swift standard library only. macOS14 minimum, Swift6 toolchain in Swift5 language mode.

## Alternatives and decision

Select one bounded UTF8 Data builder with strict validation and exact UTF16 accounting. Its explicit stored content ceiling is three bytes per declared UTF16 unit. A String builder would avoid a final conversion but offers less explicit byte accounting; a chunked builder defers copying at the cost of additional ownership and flattening complexity. Neither alternative has established peak-memory superiority here. This baseline can be replaced behind the existing protocol after measurements. Data capacity, temporary decoded chunks, final String and Foundation engine storage remain outside the content ceiling; there is no RSS claim.

## Public package boundary

Create `Sources/PadSearchWorkerRuntime/SearchWorkerUTF8Accumulator.swift`:

```swift
package enum SearchWorkerTextAccumulatorError: Error, Equatable {
  case invalidDeclaredLength, invalidChunk, inputExceeded, lengthMismatch, invalidState
}
package final class SearchWorkerUTF8Accumulator: SearchWorkerTextAccumulator {
  package init(declaredUTF16: Int) throws
  package func appendUTF8(_ bytes: Data) throws
  package func finish() throws -> String
}
```

The constructor accepts0...100_000_000 units, matching existing wire metadata. Reject negative, above-ceiling and Int.max values before any content allocation. Do not eagerly reserve the declared size. Single synchronous lane, single request, no Sendable promise or concurrent access.

## Input and state contract

SearchWireUTF16Decoder emits valid, scalar-aligned nonempty UTF8 chunks of at most65_536 bytes; it carries UTF16 surrogate halves before emission. The accumulator independently checks each chunk with strict standard-library UTF8 validation, preserving literal U+FEFF, NUL, combining sequences and all line endings. Do not use replacement decoding or normalization. Split UTF8 scalars submitted directly are invalid: this is an accumulator for the decoder's complete-scalar output, not another incremental decoder. Empty append is a harmless no-op while receiving.

Before storing a chunk, reject above65_536 bytes, malformed UTF8, a UTF16 count exceeding the remaining declared length, or a byte count exceeding the remaining three-times-declared content ceiling. Use subtraction checks with already bounded counters. Every append failure poisons the instance and discards its Data owner. A failed object cannot return a prefix or accept later data.

`finish()` succeeds exactly once, only when receivedUTF16 equals declaredUTF16. Decode the accumulated bytes strictly and check the final UTF16 count. Before returning, discard the accumulator's Data owner and enter finished state. This releases logical ownership; the resulting String may share backing storage, so do not claim physical deallocation or secure erasure. Early finish poisons with lengthMismatch. Append after success and repeated finish fail with invalidState. Previously returned Strings remain valid.

## Integration and acceptance

Existing injected factory seam receives declared length: `{ try SearchWorkerUTF8Accumulator(declaredUTF16: $0) }`. Keep runtime production flow and fixed Foundation engine unchanged in this slice. Tests must exercise real reader, collector, accumulator and runtime, not an echo substitute. Use synthetic channels only at the external read/write boundary.

Acceptance: exact ASCII, three-byte BMP, supplementary scalars, decomposed accents, initial/interior U+FEFF, NUL and mixed line endings; empty documents; exact cap per chunk; negative/overflow metadata; malformed/overlong/surrogate/truncated UTF8; count overrun, early finish, duplicate finish and poisoned reuse. Real UTF16 wire surrogate split across frames must reconstruct exact text. Malformed/truncated/coalesced trailing wire data must not execute partial text. Sequential requests release accumulator owners before terminal and admit the next request only after terminal. Actual Foundation find and capture replacement over Unicode must yield literal expected ranges/text; malformed regex remains a semantic error and permits a subsequent healthy request.

## Verification and remaining gates

Root alone runs compiler/runtime under the checked-in direct owned-process watchdog. Unit and neighboring runtime suites use SwiftPM filters; broad suite uses the same watchdog because existing regex cases are adversarial. Native desktop authentication remains independently pending. Record compiler RED separately from behavioral RED; do not manufacture a baseline by relabeling a test-only surrogate as production. Independent source review and fresh package-target build precede the local feature checkpoint.

Checked dedicated lifetime startup, helper product/entrypoint, fixed nested packaging and parent/editor routing each require their own reviewed implementation and real-process acceptance. Private allocation/source-fit campaign completion is not a prerequisite for this explicitly scoped production binding; its limited results do not imply memory acceptance.
