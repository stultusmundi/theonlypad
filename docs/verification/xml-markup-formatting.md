# XML markup formatter — Core checkpoint, 16 October 2026

The working application source includes `LanguageService.formatXML`. It formats whitespace inside start/empty tags: attributes move onto indented lines and the closing delimiter receives indentation. It preserves element content, interelement whitespace, quotes and attribute values, character references, comments, CDATA, processing instructions, declaration spelling, BOM and existing line endings. This is not tree pretty-printing. The native command, editor transaction/undo integration, HTML formatting and external formatter integration remain outstanding under D-05.

The original ten XML methods and nine existing language methods produced18 passes and one failing method with four ordinary namespace assertions. A source-identical finite diagnostic isolated unbound prefixes, reserved namespace declarations and duplicate expanded attributes. Seven independently reviewed namespace methods then produced three passes and four failing methods with24 ordinary assertions on that same baseline. No unexpected errors occurred. Earlier private Test drafts with static review findings were retained and never credited as executed tests.

The corrected scanner validates namespace declarations before uses; checks XML1.0 QName/NCName rules, reserved bindings, scope restoration and duplicate expanded attributes; and compares names and normalized namespace values by bytes rather than Swift canonical String equality. Foundation XMLParser remains an offline syntax validator with external resolution disabled. DTDs and custom entities are refused before parsing. URI grammar is not independently validated beyond the retained parser. The formatter has matching2,000,000-byte input/output and65,536-byte markup budgets, depth128,100,000 tokens,256 attributes per tag and256-byte names. Budget refusals do not truncate documents. Formatting is idempotent within these constraints.

Root observed26/0 in the minimal actual-source package (ten XML, seven namespace, nine original language methods), then26/0 again after the reviewed formatting derivative. The derivative includes a redundant guard-parenthesis removal as well as whitespace; it is not described as literally whitespace-only. Exact inputs and natural exit0 with complete direct-watchdog captures were checked. These focused counts overlap the default suite and must not be added to it.

After adopting exactly four reviewed files, the actual application compiled and linked and the default suite passed1,228 unique methods with0 failures or unexpected errors and warnings treated as errors. All575 saved source/Test/support input facts remained exact. The checked-in owned-process watchdog completed naturally in35.428 seconds with complete captures and its strict20-field receipt. The incremental scratch directory may reuse unchanged helper artifacts; this is not a fresh helper compilation or helper launch claim. Strict recursive Swift formatting, public-source pattern checking and Git whitespace checking also passed.

Reproduction:

```sh
scripts/swift.sh test --scratch-path .build/catalog-application-public-20261016 -Xswiftc -warnings-as-errors --filter 'XMLNamespaceFormattingTests|XMLFormattingTests|LanguageTests'
python3 -B scripts/run-owned-search-tests.py --timeout 300 --output .local/xml-core-verification -- scripts/swift.sh test --scratch-path .build/catalog-application-public-20261016 -Xswiftc -warnings-as-errors
xcrun swift-format lint --strict --recursive Sources Tests Package.swift
python3 -B scripts/check-public.py
```

Use a fresh ignored watchdog output directory. Root owns serial compiler/native execution. Raw synthetic evidence stays ignored under `.local/`; no private documents or machine-specific paths are published. Namespace-phase cancellation attribution remains unverified; immediate cancellation tests do not establish that horizon. Scanner polling is cooperative; Foundation parsing has no hard cancellation deadline. Logical caps are not measured allocation/RSS, throughput, responsiveness or large-file acceptance. No native menu, desktop, physical keyboard, IME, VoiceOver or current package acceptance follows. The local distributable still predates this source checkpoint. Original implementation uses existing system frameworks and introduces no third-party dependency or asset.
