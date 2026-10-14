# Native search-source lifetime diagnostic

Verified locally on 2026-10-14, ARM64 macOS, using synthetic documents and
unshown native windows. These are private frozen-source diagnostics, not
production search-panel activation or desktop acceptance.

Two separately selected tests exercise the real managed document owner. The
first completes the document-close operation, observes the intentionally retained
closed-history record, closes the empty native window, observes history removal,
and joins the final paired session/recovery publication. Fresh stores are empty;
owned temporary state is removed before the helper-return lifetime assertions.
The controller, document, pane and window then release. The baseline passes one
test with zero failures.

The companion retains an actual search source across the same lifecycle. Its
original baseline test and preparation guards remain intact. All four native
objects still release while the source remains alive. Inspect and capture throw;
currentness, selection and replacement refuse stale access. This separately
selected test also passes one test with zero failures.

Each run freezes 186 inputs, compiles 184 objects and verifies five modules,
220 build artifacts and four test-bundle files. The four authored modules use
Swift 5 language mode with warnings treated as errors; the generated SwiftPM
test entry has no explicit language-mode argument. Independent reviews verify
the exact source, link and bundle bindings, natural completion and complete
owned-process capture. Raw evidence remains in ignored local directories.

Earlier unsupported-fixture lifetime tests and the separate genuine-window-close
diagnostic retain their four ordinary weak-reference assertion failures. These
new results do not establish their retaining cause or retroactively pass them.
The process owner and registry are diagnostic weak observations, not release
assertions. No combined 19-test result is claimed.

Supported native source selection/replacement/undo workflows, current public
source integration, supervised search-panel routing, visible close behavior,
physical input and memory acceptance remain outstanding. The diagnostics have
not changed production source or the packaged application.
