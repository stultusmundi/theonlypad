# Custom-language editing core — 2026-10-12

The core implements profile-aware line/block comments and selection-aware
indentation. Native command admission, Tab dispatch, undo grouping, language
management and session persistence remain separate work. These original
MIT-licensed components add no dependencies or assets.

Comment markers use exact UTF-16 spelling. Literal custom profiles and built-in
profiles share the new profile entry points. Block comments refuse unsafe
embedded delimiters; HTML comments retain their additional marker restrictions.
Existing built-in entry points remain available.

`LanguageIndentationEditing` supports tabs or one through eight spaces, rejects
invalid widths, and maps selections across indentation changes. A nonempty
selection ending at the next line's start excludes that line. Carets cannot
divide a Unicode scalar. Legacy line transformation and insertion behavior stay
covered by the original compatibility tests.

The new editing operations bound input/output to 2,000,000 UTF-16 units and
20,000 logical lines, including a final empty line. Cancellation checks separate
rendering phases and bound explicitly consumed advances, copies and comparison
work to 4,096 units. This is not a bound on every lookahead or opaque Foundation
instruction, and no allocation, RSS or latency measurement is claimed.

The authentic baseline completes 45 tests with 99 ordinary assertion failures
and no unexpected failures. Twenty new methods fail; 24 original compatibility
methods and one new legacy/fallback control already pass and receive no
failing-baseline credit. Earlier source-only drafts and compiler prerequisite
corrections were not executed and receive no behavioral baseline credit.

The reviewed implementation passes **54 focused tests with zero failures** in a
frozen Swift 5/macOS 14 package: the unchanged 45 baseline methods plus nine
original language methods. The build treats warnings as errors. Input hashes
and the complete owned-process receipt are verified; raw synthetic evidence
stays ignored. Independent review accepts the implementation and results.

After adoption and formatting, the actual application package passes **1,143
tests with zero failures**, and builds the app and helper without warnings.
All 474 copied manifest/source/test/resource input hashes remain unchanged.
The full test command compiles the application graph with warnings as errors;
the following build is incremental on the same scratch directory. Independent
review verifies the source, compiled/link products and complete receipts.

Run the focused selection with fresh output and scratch directories:

```sh
python3 -B scripts/run-owned-search-tests.py --timeout 180 --output .local/custom-language-editing-focused -- scripts/swift.sh test --scratch-path .build/custom-language-editing-focused --filter 'LanguageProfileEditingTests|LanguageIndentationTests|LanguageEditingTests|EditingTests|LineCommandsTests|LanguageTests'
python3 -B scripts/run-owned-search-tests.py --timeout 240 --output .local/custom-language-editing-full -- scripts/swift.sh test --scratch-path .build/custom-language-editing-full -Xswiftc -warnings-as-errors
python3 -B scripts/run-owned-search-tests.py --timeout 240 --output .local/custom-language-editing-build -- scripts/swift.sh build --scratch-path .build/custom-language-editing-full -Xswiftc -warnings-as-errors
```

The watchdog must be the sole process-group owner. This evidence does not
establish native Tab/undo behavior, a visible language manager, desktop or
physical-input acceptance. D-04 remains partial.
