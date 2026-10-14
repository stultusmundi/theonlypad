# Native document-search panel component

Status: the session-backed panel and fixed public regression runner are implemented and locally verified. Editor binding, application command routing and supervised helper activation remain planned. The current Find route still uses its earlier implementation; this component is not a completed search feature family.

## Implemented

`Sources/TheOnlyPad/DocumentSearchPanelController.swift` owns one actual `DocumentSearchSession`, hidden construction, input controls, count/navigation rendering and inline replacement approval. It consumes displayed approval before effectful callbacks and fences AppKit updates against newer intents. Logical close disables controls, closes its real consumer, then invokes its own callback once. Closing a panel preserves its parent window ticket and sibling consumers. The panel retains no result text, match arrays, output or leases.

`Tests/DocumentSearchPanelIntegration` contains eight component tests, a read/action-only declaring extension and a fixed coordinator. The coordinator freezes current public sources, generates exactly one original-source + LF + access-tail derivative and verifies its separate provenance. It accepts no caller filters, source paths, access tails or prebuilt artifacts. Compiler caches are separately bounded; source trees remain immutable. Each stage directly owns the checked-in watchdog, so callers must not wrap it in another session-owning watchdog.

## Tested locally

On ARM64 macOS 26.6.2 / Swift 6.3.3, these commands pass:

```sh
python3 -B -m unittest discover -s Tests/DocumentSearchPanelIntegration -p test_public_panel_runner.py
scripts/test-document-search-panel.sh
xcrun swift-format lint --strict --recursive Sources Tests Package.swift
python3 scripts/check-public.py
```

The pure runner suite passes 18 tests. The fixed native command passes eight panel tests, the original 21 session tests and original 16 application-owner tests in separate processes against one frozen source graph: 45 passed, zero failures or skips. These counts are separate from the default package suite and are not added to it.

The eight tests cover initial attachment without extra Source inspection/capture; count-only completion and explicit wrapping navigation; all five input invalidations and late delivery; exact inline approval/reject/stale token behavior; thrown-start precedence and replacement reentry; sibling isolation and cancellation versus actual scripted completion; exact hidden close/delegate identity and callback-time retirement; and same-panel backend/Source reentry. Source replacement is an explicit scripted counter effect, not native document mutation or helper execution.

The final formatted public run retains 107 copied inputs plus one generated package manifest, five provenance files, 105 objects, nine modules, 166 artifact bindings and four test-bundle leaves. Authored modules use Swift 5 mode, macOS 14 targets and warnings as errors; the generated XCTest entry has no explicit language-mode flag. All three owned-process receipts and complete captures were verified, with fresh process identities and exact source/object/link/bundle bindings.

The current public app and helper also build with the added panel under the owned watchdog, using warnings as errors. Five actual modules compile 193 sources/objects. Planned test modules in that build description remain unbuilt; this build command does not execute tests or launch a helper. Reproduce compilation with `scripts/swift.sh build` using the established owned-watchdog wrapper where required.

## Retained failures and review

The first inert declaration failed compilation because `NSSearchField` requires `NSSearchFieldDelegate`; zero tests ran. A conformance-only correction then produced a genuine eight-case behavioral RED with 21 ordinary assertions and no unexpected errors. Productive Source review found an unguarded approval-clearing path; the repaired version adds exact intent checks after each AppKit write and caller aborts. The eight-case GREEN and matched 45-case regression runs passed after review.

The private runner's initial immutable tree included compiler-generated caches; it was corrected before execution by separating Toolchain scripts from mutable caches. Public promotion removes private packet/historical producer gates and records current Source/access derivation instead. Pure mapping/marker and derivation-record REDs remain retained. Formatting changed only the public test/access presentation; the final matched 45-case run uses those exact formatted bytes. Original declarations, failures, preformat runs and review records remain separate.

## Planned and blocked acceptance

A fixed lazy application search/quit bridge is being implemented against its genuine ten-case RED. Native editor binding and exact window/endpoint retirement have reviewed designs but are not activated. AppDelegate dispatch/validation, native quit publication ordering, real default-helper workflows, malformed/adversarial regex containment, memory/performance and current packaged desktop tests remain separate acceptance work. Visible desktop execution is blocked while the desktop is locked; this does not block component implementation.

No visible window interaction, physical keyboard, real responder-chain, native replacement, folder workflow, helper/process settlement, RSS, Intel, minimum-OS runtime, IME or VoiceOver acceptance follows from these panel tests. Distribution artifacts are unchanged and no release was published.

## Evidence retained locally

Raw synthetic evidence stays ignored under `.local/document-search-panel-integration/`. The final formatted run is `run.1E42998F-1830-4FA7-8D81-2F3F5CA60E46`; Root observation SHA256 is `b79126b707325bcdbd8062c11d2f0dcf70d1925a9e889390736f02151eb96bdf`, independent actual review `707c30535452865679d0e3a60bd2b3c7f4f78fdcc46c043904d7bec3da7aed62`. Panel Source is 9,716 bytes, SHA256 `b2dec5db382ea20dbb9fd980918e05175645bc14c0c7e31014db6bb74c20ea74`. Formatted tests are 30,959 bytes and access is 1,311 bytes; the exact derived panel is 11,028 bytes. These records establish only the scopes above.
