# Search service verification

Date: 2026-09-09. Implementation: `Sources/PadCore/SearchService.swift`. Tests: `Tests/PadCoreTests/SearchTests.swift`. Platform observed from runner: arm64e Apple macOS target, Swift Testing library 1902. This is unit/service verification, not actual desktop search validation or a performance benchmark for the application.

Command:

```sh
scripts/swift.sh test --filter SearchTests --scratch-path .build/search
```

Observed red: eight tests, 13 failed assertions against the initial API skeleton. Observed green at 12:10:54 local runner time: eight tests, zero failures, 0.022 seconds. Fresh build completed without compiler warnings. Initial sandbox attempt failed on compiler/cache filesystem access; the authorized retry outside sandbox executed successfully.

Coverage: literal metacharacters; case-insensitive Unicode whole words; escaped newline/tab and malformed escape; scoped matching and invalid negative/overflow/surrogate ranges; zero-length multiline matches; malformed regex; capture substitutions and literal dollar/backslash replacements; explicit input/match/output overflow errors; cancellation; zero budget; catastrophic-backtracking interruption. A first implementation failed the surrogate-range test; explicit UTF-16 scalar endpoint validation fixed it.

Safety contract and limits:

- Service is synchronous. Its caller must run it on a worker, never the UI thread. No search UI is wired by this change.
- Default caps: 10,000,000 UTF-16 input units, 100,000 matches, 20,000,000 output units, one-second cooperative deadline. Pattern and replacement-template length are limited to 4,096 UTF-16 units. Exceeding limits throws; results are never silently truncated.
- Input scope must be in bounds and may not split a surrogate pair. It may split a combining sequence: regex/scalar-level search is intentional; the eventual editor selection layer must decide how to expose such matches.
- ICU `.reportProgress` callbacks check monotonic time and cancellation. `(a+)+$` against 200 `a` characters plus `!` was interrupted at about 20 ms with a 20 ms budget. This establishes the callback works for this adversarial case on this host, not a hard worst-case guarantee.
- Compilation and individual Foundation substring/template allocations do not offer cancellation callbacks. Deadline checks surround those operations, but cannot preempt them. Template parsing is bounded by the 4,096-unit template cap; each capture range is checked against remaining output capacity before substring allocation. Hard CPU/memory containment is outstanding; never claim process isolation.
- Regex zero-length advancement is delegated to ICU enumeration and covered by multiline-anchor tests. Whole-word mode wraps the pattern with Unicode word boundaries and transparent selection bounds. It is word-oriented and is not useful for arbitrary punctuation-only queries.
- Dialect is platform Foundation/ICU, not Notepad++ Boost regex compatibility. Regex replacement uses `$1`, `$2`, etc.; no Boost replacement compatibility is promised. Escaped-text supports `\n`, `\r`, `\t`, `\0` and `\\`; replacement text in escaped/literal mode stays literal.

Outstanding: native GUI invocation and cancellation UI; full C-family workflows; large/streaming/folder searches; safe multifile replacement; comprehensive dialect-difference fixtures; separate-process regex containment. No broad requirements row is marked complete by these tests.

## Replacement allocation review follow-up

Independent review identified that Foundation replacementString could allocate repeated large captures before enforcing the output cap. Replaced that call with bounded template parsing and incremental output construction; capture lengths and unchanged source spans are checked before substring allocation. Numeric `$0` means the whole match; `$1` and later numbers reference groups, consuming only digits that form an existing group. Unmatched optional groups expand empty. Backslash quotes the next scalar, including dollar/backslash. Named references, nonexistent initial group references, bare dollars and dangling escapes throw `invalidReplacement`. This is an explicitly documented ICU-style subset, not unrestricted ICU replacement syntax.

Added regression: a six-unit `$0$1$1` template produces exactly three output units under a three-unit budget; a fourth capture fails. Escaped dollars/backslashes and malformed templates are covered. Red run: nine tests, three failures against previous implementation. A concurrent language/UI implementation temporarily prevented repository compilation, so an isolated temporary Swift package containing exact copies of SearchService.swift and SearchTests.swift was used for this red/green cycle; no other agent files were changed.

Follow-up green: isolated package nine tests passed at 12:17:08 (0.023 s). Once concurrent integration compiled, the original repository command above also passed all nine SearchTests at 12:17:41 (0.023 s), with no compiler warnings. The three-unit regression verifies output accounting; the preallocation safety guarantee additionally rests on review of the checked-length-before-substring implementation, not a claim that unit timing measures peak memory.
