# Single-enumeration search result implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task by task.

**Goal:** Produce find ranges and replacement text from one accepted Foundation enumeration, preserving current query/error semantics and full-document coordinates.

**Architecture:** Add a view-free PadCore operation/result API around the existing private search and replacement builder. Existing public methods remain wrappers. This is the semantic prerequisite for supervised execution; native routing and IPC remain separate stages.

**Tech Stack:** Existing Foundation, Swift 5 language mode, macOS 14; no dependency.

**Spec:** `docs/superpowers/specs/2026-09-10-supervised-search.md`, semantic primitive stage, and `docs/verification/regex-execution-review.md`. This plan does not implement process containment.

**Status:** Planned; execute only after the active engineFailure task is independently approved. Root retains ownership of this plan until dispatch.

## Global Constraints

- Preserve the existing public matches/replacing signatures and Foundation/ICU dialect.
- Preserve first terminal failure, reportCompletion and engineFailure from the preceding approved task.
- Keep full original UTF-16 coordinates and transparent/no-anchoring selection bounds.
- No native panel, registry, helper, process, file-write or package changes in this task.
- Every test using adversarial regex runs beneath an owned-process watchdog. New semantic fixtures here are benign.
- Synthetic callback injection demonstrates invocation/error behavior, not real ICU exhaustion or hard termination.

## Task 1 — One semantic operation and compatible wrappers

**Files:** Modify `Sources/PadCore/SearchService.swift`; create `Tests/PadCoreTests/SearchExecutionTests.swift`; extend the preceding `SearchEngineFailureTests.swift` only for operation-specific failure propagation.

**Interfaces:** Add these public PadCore values and method. The eventual protocol wraps the output with its own request identity; it does not add native ownership to this API.

```swift
public enum SearchExecutionOperation: Sendable, Equatable {
  case find
  case replace(template: String)
}
public struct SearchExecutionOutput: Sendable, Equatable {
  public let matches: [NSRange]
  public let replacement: String?
  public init(matches: [NSRange], replacement: String?) {
    self.matches = matches
    self.replacement = replacement
  }
}
// On SearchService:
public func execute(
  _ query: SearchQuery, in text: String, scope: NSRange? = nil,
  operation: SearchExecutionOperation
) throws -> SearchExecutionOutput
```

`find` returns ranges and nil replacement. `replace` returns ranges and full resulting text, even with zero matches. Captures stay internal; no public capture payload or additional capture enumeration is needed. Existing `matches` returns the find output ranges. Existing `replacing` calls replace with nil scope and returns its guaranteed replacement. Both preserve their current defaults and errors.

- [ ] Add an invocation-counting benign enumerator through the preceding internal test seam. It delegates to the actual compiled Foundation regex, increments once per enumeration, and uses a generous finite test budget. Record the current native-style composition of matches then replacing as two enumerations; this is baseline evidence, not a new product test to retain unnecessarily.
- [ ] Add tests for the new public execute API. Distinguish an API compilation red from a genuine assertion failure. The principal acceptance is exact ranges/output and one invocation:

```swift
let query = SearchQuery(pattern: "(a)", mode: .regex)
let result = try service.execute(
  query, in: "a a", operation: .replace(template: "$1!"))
XCTAssertEqual(result.matches, [NSRange(location: 0, length: 1), NSRange(location: 2, length: 1)])
XCTAssertEqual(result.replacement, "a! a!")
XCTAssertEqual(enumerations, 1)
```

- [ ] Run `scripts/swift.sh test --scratch-path .build/search-single-enumeration --filter SearchExecutionTests`; retain setup and behavioral results separately.
- [ ] Move the existing replacement assembly into a private builder receiving the single compiled expression, accepted checking results, original text, template and the same monotonic deadline. Validate template after search, as currently done. Do not call matches/replacing recursively from execute. The implementation flow is:

```swift
let deadline = ProcessInfo.processInfo.systemUptime + timeLimit
let (regex, results) = try search(query, text: text, scope: scope, deadline: deadline)
let replacement: String?
switch operation {
case .find: replacement = nil
case .replace(let template):
  replacement = try buildReplacement(regex: regex, results: results, text: text,
                                     template: template, deadline: deadline)
}
return SearchExecutionOutput(matches: results.map(\.range), replacement: replacement)
```

Keep existing preallocation/output limits and cancellation checks inside the builder. A failed enumeration/template/output check returns no output object. Prefix copying starts at original offset0 and suffix ends at original text length, so scoped replacement preserves text outside the scope.

- [ ] Add explicit scoped replacement acceptance: replacing `a` within range(2,1) of `a a a` yields range(2,1) and `a b a`. A whole-word query over the middle letters of a word yields no artificial boundary. Include zero-length EOF replacement, lookahead captures, unmatched optional captures, `$0`, multi-digit numeric capture parsing and escaped template literals. Expected outputs are literal fixture values, not a second execution of the same implementation.
- [ ] Add benign fixtures for literal metacharacters, escaped newline/NUL, Unicode case/whole-word behavior, emoji plus combining marks and invalid surrogate-splitting scopes. Require exact UTF-16 ranges. Test no matches returns unchanged full text for replace and nil replacement for find.
- [ ] Assert prior error precedence and limits: invalid query before invalid template; engineFailure before result construction; cancellation/limit followed by internalError preserves the first error; oversized output refuses; invalid scope does not enumerate. Preserve existing wrapper behavior with direct expected results, and count exactly one enumeration per wrapper call.
- [ ] Rerun the focused suite, preceding engine-error suite and actual app build. If running all SearchTests or the core suite, use the verified outer watchdog. Run scoped strict formatting/public/whitespace checks; retain exact source hashes and command outcomes.
- [ ] Obtain independent spec and quality review, resolve material findings and make a scoped local commit. Record this API as implemented only after tests/review; C-07/C-08 remain partial until supervisor/native/folder integration and remaining acceptance complete.

## Root consistency review

This is one independently reviewable semantic task. The operation and output names above are the only new public names; the later transport must consume them, not redefine divergent query semantics. It depends on the preceding internal enumeration seam and typed engine error; no file ownership overlaps active implementation until that task ends. Scoped replacement is additive; the existing replacing wrapper still operates on the whole text. Engine capture semantics stay internal, and both ranges and output derive from the exact same accepted enumeration.

Name review: `SearchExecutionOperation` avoids the native panels’ existing nested `SearchOperation` closure aliases. No production or test declaration currently uses the new name.
