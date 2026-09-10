# Regex engine error propagation implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Never present a Foundation internal enumeration error as complete find or replacement results.

**Architecture:** Retain Foundation/ICU and all existing query semantics. Add a narrow internal enumeration adapter for deterministic callback-flag injection; production uses the unchanged Foundation enumerator. Inspect completion/error flags before accepting results and propagate typed failure through folder search and native status messages.

**Tech Stack:** Existing Swift 5 language mode, Foundation, AppKit; macOS 14 minimum. No new runtime dependency.

**Spec:** [regex execution review](../../verification/regex-execution-review.md), source-confirmed failure handling finding and proposed narrow fix. The supervised-helper architecture described there is separate outstanding work.

**Status:** In progress with a dedicated worker after independently approved new-window tasks. Root reviewed this scope against C-02/C-07/C-08. No final implementation or verification claim yet.

## Global constraints

- Original project code remains MIT; no copied engine implementation or new dependency.
- Core functionality remains offline with no telemetry, accounts or external service.
- No partial result may become a successful replacement or complete folder report.
- Existing regex dialect, limits, capture syntax, scope semantics and cooperative deadline behavior remain unchanged.
- Synthetic callback injection proves error propagation; it does not reproduce actual ICU exhaustion or establish hard cancellation.
- No adversarial regex runs directly in an unprotected test runner. Use an outer owned-process watchdog for suites containing the existing pathological fixture.
- Preserve unrelated work; no AppDelegate, window-owner or registry edits in this task.

## Task 1 — Propagate engine failures through existing search paths

**Files:** Modify `Sources/PadCore/SearchService.swift`, `Sources/PadCore/FolderSearch.swift`, `Sources/TheOnlyPad/SearchPanelController.swift`, `Sources/TheOnlyPad/FolderSearchController.swift`; create `Tests/PadCoreTests/SearchEngineFailureTests.swift`; extend `Tests/PadCoreTests/FolderSearchTests.swift`; update `docs/verification/search.md` and the requirements matrix with exact evidence.

**Interfaces:** Keep existing public initializers and search methods source-compatible. Add `SearchError.engineFailure`. Introduce an internal `SearchService` initializer with an enumeration closure receiving the real compiled expression, text, matching options, range and Foundation callback. Existing public initialization supplies the actual Foundation enumeration closure. An internal folder executor overload takes the same query/text, current per-file limits and cancellation closure; the public overload uses SearchService. Keep query compilation and validation in the real service, not the scripted enumerator.

- [ ] Add compiling seams that initially forward current production behavior unchanged. Add deterministic tests invoking public `matches` and `replacing` on the injected service. Construct a benign `NSTextCheckingResult` from a real expression such as `a` matched in `aa`; never fabricate invalid ranges. Emit nil+internalError, early valid match followed by completed+internalError, and result+internalError. Assert the exact typed error and no returned replacement. Assert the passed options include reportCompletion.

```swift
let query = SearchQuery(pattern: "a", mode: .regex)
XCTAssertThrowsError(try service.matches(query, in: "aa")) {
  XCTAssertEqual($0 as? SearchError, .engineFailure)
}
XCTAssertThrowsError(try service.replacing(query, in: "aa", with: "b")) {
  XCTAssertEqual($0 as? SearchError, .engineFailure)
}
```

- [ ] Run `scripts/swift.sh test --scratch-path .build/search-engine-errors --filter SearchEngineFailureTests`. Retain the genuine behavioral red separately from seam compilation errors. This new suite must contain only scripted flags and benign real-engine controls.
- [ ] Request reportProgress and reportCompletion together, preserving transparent/anchoring options. In every callback, first preserve an existing terminal failure and request stop. Check internalError before appending a result; store the first failure, request stop and throw it after enumeration. Cancellation/deadline checks continue to run; a later completion/error cannot overwrite an earlier cancellation or limit failure.

```swift
if failure != nil { stop.pointee = true; return }
do {
  if flags.contains(.internalError) { throw SearchError.engineFailure }
  try check(deadline)
  // Existing result and aggregate-capture limits apply before append.
} catch {
  failure = error
  stop.pointee = true
}
```

- [ ] Add benign progress/completed/hitEnd/requiredEnd controls, including zero-result success. Script a first match-limit failure then completion+internalError and require matchLimit. For cancellation, flip the test cancellation state only after enumeration begins, emit progress, then completion+internalError, and require cancelled. Include a real Foundation control asserting exact ranges/output. Rerun the same focused command unchanged.
- [ ] Add a temporary-folder test with two synthetic UTF-8 files: the first yields one hit; the second executor throws engineFailure. The public operation path must throw engineFailure and return no complete report; unreadable counters cannot absorb it. Account for empty-input pattern validation separately so the first-file behavior is unambiguous. Retain ordinary malformed/cancel/limit semantics and execute the affected FolderSearchTests under an owned outer watchdog.
- [ ] Add explicit engineFailure messages in document and folder panels: “The search engine could not finish. Narrow the pattern and try again.” Test the actual existing error-to-status path with injected errors or the established hidden harness; no visible app while GUI access is blocked. The failure path must not call replacement or publish partial results.
- [ ] Run affected benign semantic tests and actual app build. For any command including existing adversarial tests, launch the runner as an owned subprocess with an outer timeout, terminate/reap only that subprocess group on expiry, and report timeout as failure. Do not label the cooperative 20ms fixture a hard-deadline proof.
- [ ] Run scoped formatter, whitespace and public-pattern checks. Obtain independent spec/code review; correct material findings. Commit only owned files and publish sanitized evidence distinguishing scripted injection from actual Foundation controls. C-08 remains partial until hard execution containment and full acceptance are implemented.

## Root design review

Three approaches were considered: ignore flags and document the limit (fails truthful completion); replace the engine (unnecessary dialect migration for this defect); retain Foundation and propagate its documented flags (selected). A helper process is still needed for independent execution supervision, but is not required to correct this local error contract. This task cannot claim bounded worker count, RSS, hard timeout, open-document search or GUI acceptance.
