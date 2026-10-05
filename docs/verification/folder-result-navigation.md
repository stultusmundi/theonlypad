# Folder-result navigation — 2026-10-05

Implemented and independently reviewed: folder-result navigation carries the exact opened document/pane and its authority snapshot across recent-file and legacy completion callbacks. Cancel, root change, closed panels and replaced panels revoke navigation. Native activation repeats admission and identity/text checks after display/focus; surrogate-split ranges refuse. AppKit retains its native composed-character selection behavior. Encoding opens pass their intended document explicitly into reload; ordinary reload captures its target before callbacks.

Two actual hidden-controller regressions established the defects before their fixes. Changing focus to a same-text document inside the recent-file callback caused three assertions to fail across two tests: the wrong document received the result selection. Independent review then found reload captured current after its admission callback; the three-test regression produced two assertions because the unrelated document's text and original bytes changed. Both frozen failures remain preserved.

Verification:

- `scripts/test-folder-navigation.sh`: 10 tests pass. Actual AppKit controllers, native selection and synthetic file I/O cover redirected focus, result revocation, ownership/operation/edit-restore invalidation, supplementary/combining Unicode, surrogate refusal, new/existing opens, legacy/typed callback order, missing-file failure and byte-viewer refusal. The 100,000,001-byte viewer fixture is a sparse synthetic file, not a large-file performance measurement.
- `python3 -B -m unittest discover -s Tests/NativeIntegration -p test_native_regressions.py`: 38 pure runner checks pass.
- `scripts/test-managed-documents.sh`: 71 tests pass, including typed completion held until real managed intake projects. This uses the existing bounded managed runner, not the newer strict watchdog receipt format.
- `scripts/test-search-replacement.sh`: 32 neighboring native edit/search checks pass.
- `scripts/swift.sh build --scratch-path .build/folder-navigation-final`: actual application builds without warnings, under the accepted direct watchdog. Both existing search/folder error-panel harnesses pass against that verified core build; their exact script/source copies run in a fresh ignored directory to preserve older evidence.
- Strict formatting, public-source checks and diff whitespace checks pass.

Root verified all300 original/generated bindings, strict watchdog receipts, every expected test name and the exact navigation test binary. Final navigation inventory SHA256: `f2907f022120b5f6c8b67a5fedee01d649dbe1fad7e681448323bd958ac68d24`; private evidence: `.local/folder-navigation-tests/run.2eehu7m0/`. Neighboring verification and independent design/source reviews are under `.local/folder-search-navigation-20261005/`.

The first test-only compile failure omitted a private-current accessor. Later expanded tests incorrectly assumed text edits leave the caret unchanged and combining-mark selection stays scalar-sized. Those failures remain preserved; final tests compare post-callback selection and include a separate native NSTextView composed-selection control. No production check was relaxed for these expectations.

The native runner freezes sources and appends declared private test access, suppresses only the folder command's showWindow call, and retains the existing dirty-read counter. It directly owns its watchdog; do not wrap it in another process-group watchdog. Tests show no windows and post no input. A shown chooser/sheet, physical input, arbitrary callback coverage and packaged desktop acceptance remain unverified. This repair does not route folder searches through a supervised helper or establish memory/performance policy. The complete product remains unfinished.
