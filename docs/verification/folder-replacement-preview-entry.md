# Read-only folder preview entry

Development-source checkpoint: 2026-10-14. This is partial C-06 acceptance,
not completion of multifile replacement or the application.

Find in Folder now contains **Read-only Replacement Preview…**. The parent
owns one preview, seeds only literal pattern/options, and invalidates the
preview before changing its root or closing. Search results and their navigation
generation remain independent. Replacement, chooser cancellation and factory
reentry cannot overwrite a newer child or close the same child returned by a
newer factory invocation.

The application recognizes the exact preview window/controller association.
Close targets that preview. Save, Save As, Save All and editor/automation/transfer
commands are refused in that scope. Undo, redo, cut, copy, paste and select-all
retain the native selectors. Dispatch and validation use the same policy after
the existing quit and registry checks. Source review verifies these call sites;
the hidden helper tests do not establish actual key-window or responder behavior.

## Verification

```sh
scripts/test-folder-replacement-preview.sh
scripts/test-folder-navigation.sh
scripts/swift.sh test
xcrun swift-format lint --strict --recursive Sources Tests Package.swift
python3 scripts/check-public.py
```

The fixed preview command completed **38 tests, zero failures or skips**:
11 worker, 16 panel, eight parent and three application-helper contracts.
It reads actual public Core, search and native sources, excluding only the app
entry from the test module. The run froze 189 build/runner inputs, compiled and
linked 187 objects, and verified five modules, 223 artifacts and four test-bundle
leaves. It was warning-free without requesting warnings as errors. Two explicit
frozen-only declaring-file access extensions preserve original production
bodies; their original copies and exact suffix reconstruction are recorded.
No caller-selected source, filter, skip-build or private producer is accepted.

The existing navigation regression completed ten tests with zero failures on
the matching formatted parent and its retained native source snapshot. Its synthetic close
notification now carries the actual owned window; every original navigation
assertion remains unchanged. That notification is not credited as SDK delivery.
The runner retains its documented dirty-read counter, access extensions and
suppressed folder presentation. Its command did not request warnings as errors.

A fresh frozen public app/helper build completed **1,203 default tests, zero
failures or skips**, with warnings treated as errors: 593 inputs, 306 objects,
nine modules and three link products. Shared dependencies intentionally overlap
between the link products. The native 38 are a separate suite and are not added
to the default count. Formatting and public-source pattern checks passed.

Independent source and actual-result reviews accompany the private evidence.
The direct owned-process watchdog recorded natural completion, complete
captures and the accepted singleton process-group receipt. No nested watchdog
is used.

## Retained failures and scope

The initial parent declaration tests failed before child-entry behavior existed.
The original tiny-search fixture used a noncanonical temporary URL; its corrected
expectation independently checks canonical URL, file identity and bytes.
A separate factory-reentry regression reproduced two failures on the first
productive parent; the repaired parent and original panel tests passed 24/0.

The application helper declaration baseline completed three failed tests with
58 ordinary errors and one explicit required-close-not-reached error. Repeated
close was unentered there. The productive candidate completed all three tests,
including repeated close, refusal and the injected six-selector argument checks.

The first fixed38 copier candidate lost its synthetic state environment through
the accepted watchdog sanitizer. Independent review rejected it before execution.
The corrected stage passes the exact owned State path through `/usr/bin/env`
in the child argument list. Watchdog sanitization is unchanged. Earlier fixed27,
failed declarations and all private review records are retained.

Shown entry/editing, real native chooser results, actual menu/keyboard/responder
behavior and preservation of an existing editor remain desktop gates. One
additive XCUITest workflow is reviewed but has not run against this checkpoint.
It covers entry, input editing, Save refusal and Command-W; it does not exercise
the chooser or result rows. Native input automation does not establish hardware
keyboard, physical IME, VoiceOver or standalone AX trust.

Apply, durable backups/journal recovery, broader encodings/globs, allocation/RSS,
performance, search-helper routing and full C-06/C-09 acceptance remain outstanding.
A neighboring rerun of the legacy managed-documents command stopped at compilation:
its six test files now require two approved access extensions that its copier
omits. No native cases ran in that attempt. The fixed coordinator migration
subsequently passed 73 unchanged native cases and 62 pure runner checks;
see [managed runner evidence](managed-documents-runner.md). Those results remain
separate from preview and desktop acceptance.

A clean local release candidate from source `5672527` now builds, uses ad-hoc
signatures and passes archive/SBOM validation. The main executable SHA-256 is
`77ba5daaf91bef7c32c276d49b4561e093ba8206f27477f1d23cd64efc89d1dd`;
the archive is 4,548,070 bytes with SHA-256
`63cefff9494769d64dd0a801848214a97a839dca78a9c6cad98e8e56f1793fbb`.
Launch it with `open dist/TheOnlyPad.app`. This candidate has not been exercised
on the desktop: macOS reported a locked screen before UI execution.
The 2026-10-12 package remains the last desktop-tested source checkpoint. No remote push, merge or release is authorized
by this verification.
