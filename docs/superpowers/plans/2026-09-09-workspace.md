# Workspace file discovery and sidebar implementation plan

> **For agentic workers:** Execute this assigned subsystem inline using TDD and fresh verification. BUILD_PROMPT.md authorizes documented routine design decisions without repeated approval ceremonies.

**Goal:** Discover bounded workspace files and present an honest native searchable relative-path list.

**Architecture:** Foundation enumerates a validated local directory on a worker, skips symlinks/hidden/generated directories, enforces a 50,000 visited-path ceiling, and revalidates canonical containment before opening. AppKit presents a flat list with filtering, double-click/Return open, real discovered-path counts and cancellation. The owning editor receives validated URLs and owns document lifecycle.

**Tech stack:** Foundation and AppKit, no dependency or executable workspace configuration.

**Spec:** [BUILD_PROMPT.md](../../BUILD_PROMPT.md), partial A-01/F-03/C-04/I-01. A flat file list is not a folder tree; persistence and restoration remain outstanding. No EditorWindowController/AppDelegate changes or remote actions.

## Ownership and interfaces

- `Sources/PadCore/WorkspaceIndex.swift`: public WorkspaceEntry(url: URL, relativePath: String); `WorkspaceIndex.scan(root:limit:isCancelled:onProgress:) throws -> [WorkspaceEntry]`; `filtered(_:query:) -> [WorkspaceEntry]`; `validatedFile(_:within:) throws -> URL`.
- Default and hard traversal ceiling: 50,000 visited entries, including directories; caller may choose a smaller limit. Cancellation checked per entry. Progress reports actual visited entries, not an invented percentage. Limit/error/cancellation throws without claiming a partial list is complete.
- Canonical root must be a local directory. Hidden entries, leaf/directory symlinks, `.git`, `.build`, `node_modules` and nonregular files are excluded. Returned file URLs must resolve inside the canonical root. Revalidate an entry before callback to reject symlink substitution/escape after indexing. Path checks cannot eliminate every filesystem race after returning a URL.
- `Sources/TheOnlyPad/WorkspaceSidebar.swift`: `@MainActor final class WorkspaceSidebar: NSView`, `init(onOpen: @escaping (URL) -> Void)`, `openFolder(_:)`, private(set) `rootURL: URL?`, optional `onRootChanged: ((URL) -> Void)?`. Contains Open Folder and Cancel controls, filter field, relative-path NSTableView and status. Workers use request generations to suppress stale results.
- `Tests/PadCoreTests/WorkspaceIndexTests.swift`: real temporary directories for ignore rules, relative paths, nested files, binary files, case-insensitive filtering, symlink escape, cancellation, limit and root validation.
- This plan retains actual verification evidence and native harness instructions.

## Design review

Whole-tree eager recursion without bounds risks filesystem loops or UI stalls; recursive folder UI additionally needs expansion/loading design. A bounded flat index satisfies quick-open without claiming tree parity. Do not run project config, scripts, formatters or extensions merely from opening a folder. No writes to workspace files or settings persistence are part of this change. Owner still supplies secure document reads after the URL callback.

## Steps

- [x] Write file-discovery tests; observe failures against a minimal API shell.
- [x] Implement root validation, bounded enumeration, excludes, canonical containment, cancellation/progress and filtering; rerun tests.
- [x] Write temporary native control harness; observe failure against a sidebar shell, then implement worker-driven list and open callbacks.
- [x] Run actual repository `scripts/swift.sh test --filter WorkspaceIndexTests --scratch-path .build/workspace` and build; record native programmatic harness results separately from actual GUI automation.

## Verification recorded 2026-09-09

Implemented and tested the bounded core and native flat sidebar. Initial isolated red run produced seven failed assertions across four tests; the green implementation passed all four. The integrated repository command below passed four tests with zero failures at 13:04 local time, and compiled the application successfully in 2.50 seconds:

```sh
scripts/swift.sh test --filter WorkspaceIndexTests --scratch-path .build/workspace
```

The retained native harness is `Tests/NativeIntegration/WorkspaceHarness.swift`. It exercises actual AppKit list/filter controls, Return and double-action callbacks, root callback, cancellation and rejection of a file replaced by a symlink. It uses temporary synthetic files and removes them afterward. Compile/run command used:

```sh
swiftc -module-cache-path .cache/swift -parse-as-library -I .build/workspace/arm64-apple-macosx/debug/Modules Sources/TheOnlyPad/WorkspaceSidebar.swift Tests/NativeIntegration/WorkspaceHarness.swift .build/workspace/arm64-apple-macosx/debug/PadCore.build/*.o -o .build/large-benchmark/workspace-harness
.build/large-benchmark/workspace-harness
```

Observed output: `PASS: native workspace list, filtering, Return/double action, root callback, cancellation and open revalidation`.

Root integration review found the sidebar callback routes through the editor's quit guard. The Open Folder command reveals the sidebar and the view command toggles it. These are code-review observations, not physical GUI automation. The native harness sends control actions programmatically; it does not establish mouse/keyboard accessibility usability. Folder-tree expansion and persisted workspace restoration remain outstanding. Filtering is bounded by the index size but does not implement per-keystroke worker cancellation; stale filter completions are ignored. Canonical validation cannot eliminate filesystem changes after the callback returns a URL. No workspace config is executed.
