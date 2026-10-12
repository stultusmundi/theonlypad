# Custom-language store and lexer checkpoint — 2026-10-12

The core now implements durable custom-language catalogs, definition revisions and
a bounded literal lexer. These are original MIT-licensed components with no new
dependencies or assets. Native language management, editing policies, document
selection persistence and highlighter integration remain separate work.

The catalog stores at most 64 definitions in bounded strict JSON. It preserves
exact UTF-16 marker spelling and integer generation/revision values. Stable reads
require an owned directory and a regular, single-link, non-symlink catalog file.
Saving revalidates the loaded receipt and uses the existing atomic publication
service. Unchanged definitions retain their revisions; changed definitions advance
them. Stale receipts refuse replacement. The receipt returned after publication
proves a fresh matching read, not ownership of the written inode. Publication
uncertainty and unconfirmed readback have distinct typed outcomes; callers must
handle them. Same-user races after the final identity check remain an existing
limitation rather than a general compare-and-swap guarantee.

The lexer handles literal comments, quotes, keywords and optional ASCII integers.
It preserves scalar-aligned UTF-16 ranges and exact case/marker spelling. It
refuses input above 2,000,000 UTF-16 units and results above 100,000 tokens;
cancellation is polled within 4,096 consumed units and on phase boundaries.
Failure returns no partial token list. These bounds are logical limits, not
allocation, RSS or typing-latency measurements.

The corrected store baseline completed 24 cases with 109 ordinary assertion
failures. Four additive integer-preservation controls bring that baseline to
28 cases and 115 ordinary failures. The corresponding implementation and existing
language/shortcut compatibility selection pass 104 tests. Two additional real
post-publication fault tests pass separately: a readback callback failure and a
competing atomic leaf replacement. Removing only typed readback wrapping causes
those two methods to reach four ordinary assertion failures; the real publication
and fault prerequisites still pass. Earlier compiler prerequisite failures remain
retained and receive no behavioral baseline credit.

The lexer baseline completes 26 cases with 90 ordinary assertion failures;
three already passing baseline cases receive no failing-test credit. Its matched
implementation and original language fixtures pass 35 tests. Boundary, Unicode,
token-range and actual cancellation-observer assertions are covered.

After adoption and formatting, the actual public package passes **1,122 tests
with zero failures**, and the app/helper build passes without warnings. All 435
manifest/source/test input hashes remain unchanged through both commands.
Independent review accepts the source and assertion-preserving formatting.
The runs use synthetic data and the checked-in finite owned-process watchdog.
Raw inventories and receipts remain ignored.

Reproduce with fresh output and scratch directories:

```sh
python3 -B scripts/run-owned-search-tests.py --timeout 240 --output .local/custom-language-components-test -- scripts/swift.sh test --scratch-path .build/custom-language-components
python3 -B scripts/run-owned-search-tests.py --timeout 240 --output .local/custom-language-components-build -- scripts/swift.sh build --scratch-path .build/custom-language-components
```

Never nest the watchdog inside another process-group watchdog. No new
supervised-search routing, packaged runtime, native language UI, desktop,
physical-input, accessibility, memory or performance acceptance is established.
The manager-command baseline remains outstanding. D-04 remains partial.
