# Command modifier admission

Status: reviewed design and private candidate in progress; no production admission change is integrated. Requirement H-01 remains partial.

## Problem and evidence

The packaged shortcut workflow saves Option-Command-N, restores defaults, then observes the current default Command-N menu item firing on Option-Command-N. The user-equivalent getter is empty. Direct hidden NSMenu tests reject that combination, so they do not reproduce active application routing.

A private principal-class spike wraps the actual `NSApplication.sendEvent` call without altering or swallowing events. The packaged trace confirms the failing action occurs within that scope and its event is identical to `NSApp.currentEvent`. The original desktop assertion still fails. This provides a concrete admission boundary; a persistent last-event cache or `currentEvent` alone would not.

## Selected behavior

For a registry-owned menu action, reject mismatched Command/Option/Control/Shift modifiers only when every condition is established:

- The action runs inside a live key-down dispatch scope, with matching current-event object identity and Command present.
- The sender is the current published item for that command, with a configured shortcut.
- The item's configured key and modifier mask still match the publication snapshot.
- There is no user-key-equivalent override exposed by AppKit.

Otherwise retain the existing dispatch path. Do not compare raw characters or normalized keys: AppKit's keyboard localization remains authoritative. Repeat events receive the same modifier check; do not reuse the recorder's repeat-refusal path and accidentally permit a repeated mismatch. Caps Lock and Function are outside the four configurable modifiers.

Native Quit remains outside the registry handler. Menu clicks, accessibility actions, command-palette calls and direct commands do not gain a persistent keyboard token. Nested non-key events temporarily clear the context, then restore the outer scope. Scope cleanup is synchronous and bounded; no monitor, timer, reposting or asynchronous context retention is introduced.

A synchronous unrelated selector invocation during a key-down is not distinguishable from a key-equivalent selector through a public AppKit cause flag. The current application has no such route; preserve this limitation and review future routing additions.

## Work and verification

1. Private principal-class wiring and event identity spike: completed. Unshown subclass construction and the generated `.app` both use `PadCommandApplication`; actual failing desktop dispatch has a live matching event. This is route evidence, not a fix.
2. Private generic admission candidate: implement current-item snapshots and the scoped modifier gate. Native unit cases must cover exact/custom/default bindings, extra/missing modifiers, repeat mismatches, arrows/punctuation without key reinterpretation, stale/config-changed items, user overrides, missing/mismatched event identity, mouse/no-Command events, and nested scope restoration. Retain red/green evidence.
3. Run the unchanged desktop customization/persistence/reset workflow. Add actual menu-click and accessibility controls, including Option-held menu selection, and verify native Quit. A passing native helper does not substitute for these workflows.
4. Independently review specification and quality, including principal-class packaging, source-target membership and command snapshot lifetime. Integrate only reviewed production code without private tracing; run fresh native/core checks and uninstrumented packaged regressions.
5. Update H-01 evidence and continuation with actual results. No other shortcut, accessibility or keyboard-layout acceptance is inferred from this slice.

Proposed production locations are `CommandDispatchApplication.swift`, `NativeCommandKeyAdmission.swift`, `AppDelegate.swift`, the app entry and package principal-class metadata. New commands/tests are not documented as proven until executed. Existing public test infrastructure remains available; all diagnostic assets and synthetic raw evidence stay under ignored `.local/` directories.
