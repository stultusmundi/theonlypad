# TheOnlyPad

An independent, offline text and code editor for macOS, built with Swift and AppKit.

**Status: incomplete development build. The full application brief is not yet implemented or verified.** There is no published release. Do not rely on this build as the only copy of irreplaceable work.

The current native app supports multiple editor windows and reorderable/pinnable tabs; new/open/save/save-as-to-new-path/save-all/duplicate/revert; native undo; line transforms; a command palette; literal/escaped/ICU-regex find and replace; lexical language colors; JSON formatting; searchable appearance/editor settings; encoding and line-ending conversion; macro recording and library management; a filtered folder file list; and private scratch recovery. It also includes explicit external commands, declarative text-transform extensions, conversion/checksum tools, bounded folder search, Unicode line/column navigation, and a native Print panel. Files above 100 MB open in a read-only byte-window viewer, with bounded literal UTF-8 search, up to 1 GB. This is not full large-file editing.

Core tests and in-process AppKit harnesses cover portions of these features, including force-termination recovery. Actual desktop keyboard/dialog/IME/VoiceOver workflows and complete packaged editing workflows remain unverified. The current combined suite has 104 passing tests; this count does not establish full feature acceptance. See the [requirements matrix](docs/requirements-matrix.md), [verification records](docs/verification/), and [continuation checkpoint](docs/continuation.md).

## Build and run

Requires macOS 14 or newer and a Swift 6 toolchain/Xcode. Development has been tested with Swift 6.3.3 on Apple Silicon macOS 26.6.2. Intel and the minimum OS runtime have not been tested. No third-party Swift packages are currently used; SwiftPM has no external resolution lockfile to produce.

```sh
scripts/swift.sh build
scripts/swift.sh test
scripts/test-native-integration.sh
xcrun swift-format lint --strict --recursive Sources Tests Package.swift
python3 scripts/check-public.py
scripts/package.sh --ad-hoc-sign
open dist/TheOnlyPad.app
```

For file and position arguments, see the [CLI guide](docs/cli.md). The repository-local launcher requires Python 3. See [extension API](docs/extensions.md) for its limited declarative capability model.

Packaging produces `dist/TheOnlyPad.app`, an architecture-named ZIP, and a development SBOM. Ad-hoc signing does not confer a Developer ID or notarization. Nothing in these commands publishes remotely or accesses signing credentials. The command-line build wrapper keeps compiler caches local; a restricted agent environment may require permission to run the toolchain outside its filesystem sandbox.

## Current limits

- Panes, persisted workspaces/hierarchical folder tree, full advanced editing, folder replacement previews, and many language tools are outstanding. Physical tab dragging and complete encoding workflows still need desktop verification.
- Macro recording/replay and management are integrated. External commands, declarative extensions, printing and the repository-local CLI have partial automated coverage. Packaged CLI delivery, print-dialog workflows, localization and full accessibility remain unverified or outstanding.
- Save As refuses a different existing destination. Saving an opened file checks its original bytes; metadata/backup handling and races with uncooperative external writers still need work.
- Lexical colors are limited to documents of at most 2 million UTF-16 units. They are not complete grammars or semantic intelligence. JSON formatting preserves number/string/key lexemes and rejects excessive output.
- Regex uses ICU with cooperative cancellation, not process-isolated execution. Search and capture/output limits return explicit errors. Full dialect details are in [search verification](docs/verification/search.md).
- Recovery restores unsaved files as scratch documents; historical paths are not automatically overwritten. Window close asks about discarding changes, while app quit snapshots scratch/dirty documents.
- There is no updater, telemetry, account system, or cloud dependency.

## Project and licensing

Read [BUILD_PROMPT.md](docs/BUILD_PROMPT.md), [AGENTS.md](AGENTS.md), [CONTRIBUTING.md](CONTRIBUTING.md), and [SECURITY.md](SECURITY.md). The complete brief remains the scope; an initial working build is not completion.

Original code and geometric icon artwork are [MIT licensed](LICENSE). See [third-party notices](docs/third-party-notices.md). Apple frameworks are supplied by macOS. No Notepad++ code, branding or assets are copied; the [official manual](https://github.com/notepad-plus-plus/npp-usermanual) is a behavioral reference. TheOnlyPad is not affiliated with Notepad++ or Apple and does not support Windows plugin binaries.
