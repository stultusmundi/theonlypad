# TheOnlyPad architecture design

Status: reviewed against BUILD_PROMPT; engine selection provisional pending executable feasibility evidence. Human ceremony waived by the brief. Independent engine and requirements reviews are running.

## Approaches

1. Swift/AppKit with Apple's NSTextView: system-maintained editing, native input methods, undo and accessibility, no bundled editor dependency. Advanced code UI and bounded large-file rendering require adapters. Preferred initial integration candidate, not yet a validated performance choice.
2. Swift/AppKit with STTextView: TextKit 2 editor specialization and multi-selection APIs; introduces dependencies and compatibility obligations. Compare actual behavior before adoption.
3. Swift with WKWebView and Monaco: broad source editing features; additional native bridge, web accessibility/IME validation, distribution and memory costs. Retain as fallback if native engine evidence fails requirements.

## Boundaries

Swift Package targets: PadCore (Foundation-only data integrity, encoding, editing commands, search, settings, automation), TheOnlyPad (AppKit UI and editor adapter), and PadCoreTests. Minimum deployment target initially macOS 14, enabling a modern native baseline; ARM64 first, Intel build verification separately. No custom text layout engine.

Document data is decoded strictly and retains explicit encoding and BOM metadata. Line endings remain verbatim unless converted. Saving compares the last-read bytes with current disk bytes, writes a sibling temporary file, synchronizes it, and atomically renames only after checks; failures retain dirty state. Symlink targets must be resolved deliberately. Recovery stores versioned checksummed snapshots independently from original files, never in the repository. All disk-heavy operations must run away from the UI thread.

The editor adapter owns native text storage and grouped undo. Commands expose stable identifiers and typed payloads, shared by menus, palette, shortcuts and macros. Services consume immutable snapshots with generation IDs so stale results cannot overwrite new edits. Workspaces refer to document IDs, with shared storage across split views. Background search and language services require cancellation and resource limits. Extension installation and executable commands are explicit user actions; nothing executes on opening a project.

## Integrity acceptance

Strict byte round trips for UTF-8/BOM, UTF-16 LE/BE and supported legacy formats; malformed input errors; no implicit lossy save; external-change refusal; untouched original after injected interrupted or disk-full save; recover valid scratch snapshots and quarantine corrupt snapshots. Real temporary files and randomized Unicode round trips supplement example tests. UI save/close/recovery behavior must be verified in the packaged desktop app before requirement completion.

## Review

No stack option alone fulfills the brief. Feasibility evidence, real UI tests and performance measurements gate final architecture confirmation. Core work can proceed independently of the editor choice. The requirements matrix is the scope authority alongside BUILD_PROMPT; implementation does not make a requirement verified.
