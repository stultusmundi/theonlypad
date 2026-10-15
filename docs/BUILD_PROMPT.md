# TheOnlyPad — autonomous application build prompt

Build a complete, polished, Notepad++-style text and source-code editor for macOS named **TheOnlyPad**. Repository: `stultusmundi/theonlypad`. Use original branding and keep identity centralized so it can be changed without architectural work.

This is an implementation request. Carry the project through research, architecture, planning, development, integration, testing, usability validation, packaging, and final review. Do not stop at a plan, scaffold, prototype, or MVP.

## Product intent

Create a fast, dependable desktop editor for developers and power users: instant scratch notes, reliable editing, strong search, many document formats, large files, and extensibility. Take functional inspiration from Notepad++ while following macOS conventions. Do not imply affiliation with Notepad++ or Apple or promise compatibility with Windows plugin binaries.

Core functionality must work offline without accounts, subscriptions, telemetry, or cloud services.

## Autonomy and authorization

I authorize routine product, UX, architecture, dependency, implementation, and testing decisions within this brief. Choose defensible defaults, record assumptions, and explain significant tradeoffs. Do not ask me to select frameworks, colors, folder structures, implementation order, or routine details.

Explicitly waive repeated human approval checkpoints in Superpowers brainstorming, design review, plan handoff, and routine execution. Replace them with documented review against this brief and independent agent review where available. Resolve feedback and proceed. This waiver concerns workflow ceremony, not platform permissions or security boundaries.

You may work in this project, create isolated branches/worktrees, install necessary development dependencies, run the application and local tests, create synthetic fixtures, and make local commits of your work. Preserve unrelated changes and do not modify other repositories.

The user explicitly authorized pushing project changes to GitHub on 2026-10-15. Routine non-force pushes of reviewed commits to development branches in `stultusmundi/theonlypad` are authorized; keep the remote branch current after verified checkpoints. Use the existing Git authentication mechanism without exposing credentials. Publish only reviewed public files, preserving unrelated changes; ignored diagnostics, caches and local packages stay local.

Remote merges, force pushes, release publishing, purchases, domain registration, system security changes, unrelated credential use and deletion of unrelated data still require separate authorization. Never interpret silence as permission.

Ask only when a missing decision materially prevents safe progress. Batch unavoidable questions and continue independent work while waiting. Milestones are internal checkpoints, not reasons to ask “shall I continue?” Work continuously through the entire scope.

If interrupted by tool, session, or context limits, persist an exact checkpoint and resume when execution is available. Do not claim background work continues after the session ends.

## Public open-source repository requirements

- Assume all tracked files, commits, issue comments, logs, and artifacts will be public.
- Original project code is MIT-licensed. Preserve LICENSE. Review licenses of dependencies, editor engines, grammars, fonts, icons, sample files, and generated assets before inclusion. Maintain third-party notices and redistribution obligations. A mature engine is welcome when its licensing fits the distribution; never assume that all bundled components inherit MIT.
- Do not copy Notepad++ source, logos, icons, or documentation into the project under an incompatible licensing assumption. Use the official manual as a behavioral reference and cite it. Use original implementation and assets or appropriately licensed alternatives.
- Keep secrets, personal data, real user documents, machine-specific paths, recovery buffers, signing material, and unreviewed diagnostics out of git and artifacts. Use synthetic fixtures, relative paths, and placeholders in examples. Review screenshots and logs before publishing them.
- Use a repository-local privacy-preserving commit identity where available. Do not change the user's global git identity.
- Keep README status honest: planned features are not shipped features. Do not fabricate badges, downloads, compatibility claims, benchmarks, signing status, or release notes.
- Maintain contributor guidance, private vulnerability-reporting instructions, issue/PR templates, and a clear version-support policy.
- Add useful CI when executable code exists: build/tests on macOS, appropriate lint/format checks, dependency review, and secret detection where available. Pin third-party actions to reviewed immutable revisions and give workflows minimum permissions. Never expose secrets to untrusted pull-request code or run it with privileged `pull_request_target` workflows.
- Provide reproducible dependency resolution and lockfiles, an inventory of dependencies/licenses, and a software bill of materials for release candidates. Review supply-chain and security findings with evidence; do not silence failing checks to achieve green status.
- Automated releases/signing must remain inert without explicit maintainer action and appropriate credentials. Local packaging is required even when notarization cannot be performed.
- Record current minimum OS/toolchain requirements, supported architectures, development setup, test commands, contribution process, and known limitations so an outside contributor can reproduce the build.
- Build updates, if added, must be authenticated and integrity-checked. Do not add a live update service or claim one exists without a verified publishing design.

## Superpowers lifecycle

Read the actual installed skills and adapt them to the explicit autonomy authorization above.

1. **using-superpowers:** establish available tools and project instructions.
2. **brainstorming:** classify as architectural; inspect the environment, compare 2–3 credible approaches, test risks, choose an approach, and write reviewed designs. Decompose subsystems where useful. Do not wait for routine design approvals.
3. **using-git-worktrees:** establish safe isolation when needed and preserve user changes.
4. **writing-plans:** create a master roadmap and executable subsystem plans with interfaces, dependencies, acceptance criteria, and actual verification commands. Map every requirement to planned work.
5. **subagent-driven-development / dispatching-parallel-agents:** parallel work is explicitly authorized. Delegate bounded independent tasks with ownership and interfaces. Review for both specification compliance and code quality. If agents are unavailable, execute sequentially with separate review passes.
6. **test-driven-development:** use red–green–refactor for testable behavior, particularly documents, commands, search, encodings, recovery, and macros. Avoid tests that merely reproduce implementation details.
7. **systematic-debugging:** reproduce failures, identify root causes, add regression coverage, and fix them. Do not patch symptoms repeatedly or weaken tests.
8. **requesting-code-review / receiving-code-review:** review subsystems and the integrated app; resolve material findings.
9. **verification-before-completion:** require fresh evidence before declaring completion.
10. **finishing-a-development-branch:** prepare a clean local handoff, verified artifacts, documentation, and local commits. Routine development-branch pushes follow the authorization above; remote merges, force pushes and releases require separate authorization.

Use Context7 for relevant dependency documentation and Serena for useful semantic navigation if available. Use installed dependency/security-review skills as appropriate. Do not apply unrelated repository-specific UI skills to TheOnlyPad.

## Architecture and technology

Prefer a native Swift application using AppKit/SwiftUI and a mature editor component where justified. Before selecting the stack, test multiple cursors/rectangular selections, large files/long lines, incremental syntax highlighting, Unicode/IME composition, undo transactions, recovery, accessibility, and UI automation. Choose another architecture if evidence shows it better meets the requirements; document performance, maintenance, licensing, distribution, and testing tradeoffs.

Do not build a text engine from scratch unless existing engines demonstrably cannot meet the requirements. Prioritize Apple Silicon and support Intel where the selected toolchain permits. Define and justify the minimum macOS version early.

Separate document storage, editor engine, commands, search, language services, persistence, extensions, and UI behind testable interfaces. Use one command registry for menus, shortcuts, the command palette, and macros.

## Feature requirements

### A. Documents and file lifecycle

- New/open/recent files, open folder, drag-and-drop, and Finder Open With.
- Save, Save As, Save All, duplicate document, revert, and reload.
- Multiple windows; reorderable/pinnable tabs with dirty indicators.
- Close others/to the right, reopen closed tab, and efficient tab switching.
- Untitled scratch buffers preserved across restarts.
- Optional autosave, periodic recovery snapshots, session restoration.
- External modification detection and safe reload/conflict handling.
- Read-only files, permissions, missing files, symlinks, and renamed files.
- Atomic saves where supported, backups, recoverable failures, disk-full and interrupted-write handling.
- No silent loss or overwriting of unsaved edits.

### B. Editing

- Reliable grouped undo/redo; multiple cursors/selections; rectangular/column selections; insert/overwrite modes.
- Indent/outdent, tabs/spaces conversion, language-aware defaults.
- Duplicate/delete/move/join/split/sort lines; deduplicate lines; trim whitespace; case conversion.
- Line/block comments, bracket matching, configurable paired insertion.
- Line numbers, current-line highlight, indentation guides, whitespace markers, soft wrap, zoom, fonts, column ruler.
- Bookmarks, navigation, and operations on bookmarked lines.
- Go to line/column, matching delimiter, navigation history.
- Accurate line/selection/character/byte statistics.
- Correct emoji, combining characters, bidirectional text, and IME behavior.

### C. Search and replace

- Incremental find, next/previous, match case, whole word, wrap.
- Literal, escaped-text, and regex modes; capture groups/backreferences.
- Search selection/document/open documents/folders.
- Include/exclude globs, recursion, ignore files, hidden-file controls.
- History, counts, highlighting, clickable results.
- Replace one/all and preview multi-file changes.
- Cancellable background searches with progress.
- Defined handling of malformed regex, zero-length and multiline matches, catastrophic regex execution, binary/unreadable files.
- Tested recovery or backups for multi-file replacements.
- Document regex dialect and differences from Notepad++.

### D. Languages and developer tools

- Syntax highlighting for common programming, markup, configuration, and shell languages, with an explicit support list and representative test fixtures.
- Extension/content detection, manual language choice, plain-text mode.
- Folding, completion, snippets, function/symbol outline.
- User-defined highlighting/languages; per-language indentation/comments.
- JSON validation/formatting; XML/HTML formatting where supported; safe external formatter integration.
- Markdown preview with safe embedded-HTML and external-resource handling.
- Side-by-side file comparison and synchronized navigation.
- Escaping/unescaping, URL/Base64 conversion, checksums.
- Distinguish syntax highlighting from semantic intelligence and document capabilities per language.

### E. Encodings and line endings

- UTF-8 with/without BOM, UTF-16 LE/BE, documented legacy encodings.
- Distinct reopen-with-encoding versus convert-encoding actions.
- Lossy-conversion warnings and invalid-byte handling.
- LF/CRLF/CR detection/conversion and mixed endings.
- Preserve encoding/endings unless explicitly changed.
- Binary detection and safe treatment without silent corruption.
- Byte-preserving round-trip fixtures where preservation is expected.

### F. Views and workspaces

- Horizontal/vertical splits; synchronized views of one shared document model.
- Move documents between panes/windows.
- Folder tree, filtering, quick-open, workspace persistence.
- Minimap/document map with a large-file fallback.
- Search-results, outline, output panels; distraction-free/full-screen modes.
- Light/dark/system themes, configurable syntax colors.
- Status bar for language, encoding, line ending, caret, selection.

### G. Automation and extensibility

- Record/save/rename/delete/replay/repeat macros, named macros, shortcut bindings.
- Deterministic command-based recording, cancellation, undo boundaries.
- Configurable external commands with document/path/selection variables, safe argument handling, output capture, cancellation, exit reporting.
- Never execute commands automatically merely because a file/project was opened.
- Versioned/documented extension API; local install/enable/disable/uninstall; capability disclosure, compatibility checks, error containment.
- Working sample extension proving end-to-end integration.
- Explain actual trust/isolation boundaries; do not claim unimplemented sandboxing.
- Windows Notepad++ plugin binaries are outside compatibility scope.

### H. macOS integration and polish

- Native menus, standard Command-key shortcuts, configurable mappings, collision detection, command palette.
- Finder/Open With/Dock integration, native dialogs, full-screen, multiple displays.
- Correct window-close versus app-quit behavior; Services/share integration where appropriate.
- CLI launcher accepting files and line/column positions.
- Printing/PDF export.
- VoiceOver labels, keyboard navigation, focus visibility, contrast, reduced motion.
- Retina rendering, comfortable compact layouts.
- Searchable preferences, import/export/reset, versioned migrations.
- Help, shortcut reference, actionable error/recovery messages.
- Localization-ready strings and complete English UI.

### I. Performance and reliability

- Keep I/O, search, parsing, and expensive analysis off the UI thread; provide cancellation and backpressure.
- Explicit large-file mode with visible capability changes.
- Test synthetic 1 MB, 10 MB, 100 MB, and 1 GB files plus pathological long lines.
- Normal editing/search expectations through 100 MB; safe responsive viewing and bounded-memory search at 1 GB, with honest editing restrictions.
- Provisional targets on a recorded reference machine: cold launch to editable buffer within 2 seconds; ordinary editing p95 input latency under 50 ms; 100 MB file usable within 5 seconds.
- Measure repeated runs, memory, and responsiveness. Investigate misses; do not quietly lower targets or claim universal results.

## Reference parity and scope control

Consult the current [official Notepad++ manual](https://github.com/notepad-plus-plus/npp-usermanual). Build a parity matrix covering all feature families above and additional core reference features found during research.

Classify each item as implemented equivalent, macOS adaptation, Windows-specific/not applicable with justification, or outstanding. Third-party plugins form an unbounded ecosystem: implement the extension framework and the specified tools, not every third-party plugin.

Every applicable requirement needs a stable ID, implementation location, acceptance criteria, tests/evidence, and status. Outstanding features remain outstanding; never relabel them “future work” to declare completion. An initial milestone is not the final scope.

## Testing and validation

Build verification infrastructure early. For each feature: define observable acceptance criteria, implement meaningful automated coverage, exercise failure modes, validate neighboring integrations, test user-facing behavior in the actual app, review code, and record evidence before completion.

Required coverage:

- Unit tests for editing commands, offsets, encodings, regex, macros, persistence, settings migrations.
- Property-based tests for reversible edits, undo/redo, encoding round trips.
- Real temporary-file integration tests.
- Fault injection for interrupted saves, permissions, external changes, corrupt recovery data, disk full.
- UI tests for primary workflows, menus, shortcuts, dialogs, tabs, panes, focus, preferences, session reopening.
- Force-termination recovery tests demonstrating restored content.
- Unicode/IME, accessibility, themes, display scaling.
- Performance benchmarks with retained machine details/results.
- Dependency, extension, command execution, preview, file-access, and distribution security review.

Use XCUITest/accessibility automation for native UI or an appropriate real desktop harness for the chosen architecture. A browser preview does not validate desktop behavior; screenshots do not prove functionality. If required GUI tools/permissions are unavailable, complete independent work, record the unverified requirements, and request only missing access. Do not substitute mocks for unperformed end-to-end checks.

Test the packaged app, including clean launch, open/edit/save/quit/reopen, not just a development build. Sanitize all public evidence and preserve original verification results locally when needed.

## Implementation order

1. Architecture spikes, requirements matrix, runnable shell, test harness.
2. Document lifecycle, basic editing, safe saves, undo, recovery.
3. Advanced editing, encodings, search/replace.
4. Language tools, panes, workspaces, themes.
5. Macros, external commands, extensions, macOS integration.
6. Accessibility, performance, fault testing, security review.
7. Packaging, clean-environment smoke tests, complete parity/public-repository review.

Adjust ordering for dependencies while preserving scope. Every milestone must leave a working app. Continue after internal checkpoints.

## Persistent project records

Maintain AGENTS.md with conventions and proven build/test/run commands; `docs/superpowers/specs/` with reviewed designs; `docs/superpowers/plans/` with executable plans/progress; `docs/requirements-matrix.md`; `docs/decisions.md`; sanitized `docs/verification/`; and `docs/continuation.md` with current state, exact next action, commands, and blockers.

Progress updates should say what works, supporting evidence, what remains, and the next action. Continue working after updates.

## Definition of done

Declare completion only when every applicable requirement is implemented and verified; there are no placeholder controls, fake results, stubs, or silent no-ops; fresh automated checks pass; the real integrated app was exercised; material review findings are resolved; data integrity/recovery are demonstrated; performance and limits are documented; a reproducible local `.app` and archive/DMG exist; and installation, usage, architecture, tests, extensions, and third-party licensing are documented.

Prepare signing/notarization support without fabricating credentials or claiming an unsigned build is notarized. Missing signing identity must not prevent a verified local build. Identify external release steps separately.

At handoff provide artifact locations/launch instructions, implemented features, actual tests/benchmarks, limitations/blocked requirements, licensing/dependency notices, and outstanding signing/release steps. Do not represent incomplete work as a completed product.

Begin with environment inspection and architectural brainstorming, then execute the full lifecycle without waiting for routine approvals.
