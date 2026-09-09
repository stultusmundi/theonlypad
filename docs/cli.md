# Command-line launcher

Use the repository-local launcher after building the current app:

```sh
scripts/package.sh
scripts/theonlypad --line 42 --column 5 'notes.txt'
scripts/theonlypad first.txt second.txt
scripts/theonlypad -- '--filename-starting-with-a-dash.txt'
```

The script requires Python 3 and macOS `/usr/bin/open`. It selects the sole `.app` in this repository's `dist` directory. If that directory contains multiple apps, or the app is installed elsewhere, choose its path explicitly:

```sh
THEONLYPAD_APP='/path/to/TheOnlyPad.app' scripts/theonlypad --line 2 document.txt
```

Nothing is installed globally. Relative filenames resolve against the invoking shell's current directory. Quote filenames using normal shell quoting. The launcher does not interpret document text or filenames as shell code.

`--line N` and `--column N` are positive, 1-based decimal integers and apply to **every file in the invocation**, regardless of option order. Defaults are line 1, column 1. Duplicate options, unknown flags, zero/negative/overflow positions, and options without a file are rejected. `--` ends option parsing. An invocation with no arguments opens or activates the app. Limits: 128 files, 256 arguments, 1 MB of input arguments, and 128 KB of encoded LaunchServices arguments. Use separate invocations for different per-file positions or larger batches.

Columns count Unicode extended grapheme clusters in logical text order. Emoji sequences and combining accents count as one column. Columns beyond the requested line clamp to its end; nonexistent lines produce an error. CRLF is one ending; LF and CR are also recognized. A trailing ending creates a final empty line.

## Running-instance delivery and trust

The launcher reads the registered scheme from the selected app's Info.plist and passes URLs through `open -a`. It uses neither `--args` nor `-n`: requests can reach an already running app, without creating another instance that shares recovery state. Rebuild older app bundles that lack the protocol registration.

The protocol shape is:

```text
theonlypad://open?file=<percent-encoded-file-URL>&line=42&column=5
```

The scheme is centralized in `AppIdentity.urlScheme`. Requests allow only local file URLs (empty host or localhost), reject unknown/duplicate fields, remote hosts, user information, ports and fragments, and contain no command-execution or network-fetch actions. Protocol links are **unauthenticated**: websites and local programs can construct them. The app opens these local files without an additional protocol confirmation; it cannot securely distinguish CLI requests from other links. Links can therefore cause a local file to appear in the editor, but cannot transmit its contents or run commands.

## Implementation and verification status

Implemented parser APIs: `LaunchRequest.parse(arguments:workingDirectory:)`, `LaunchRequest.parse(url:)`, `request.protocolURL()`, and `TextNavigation.utf16Offset(in:line:column:)`. Parsing and navigation perform no file I/O or command execution.

Tests first failed on absent types. All four `LaunchRequestTests` passed in the root package (also checked previously in an exact-source isolated package), covering paths/options, invalid positions/budgets, protocol round trips/rejections, emoji/combining/bidi columns, mixed endings, clamping and missing lines. The launcher passed shell syntax/help checks and an intercepted-subprocess test of URL construction, literal special-character filenames, and invalid-position rejection. That test intentionally did not invoke LaunchServices.

The tracked `Tests/NativeIntegration/LaunchHarness.swift` passed against the real AppDelegate and EditorWindowController. It checks asynchronous protocol routing, a Unicode filename containing spaces and URI punctuation, actual NSTextView grapheme positions, mixed endings, column clamping, existing tabs, and independent positions in a multi-file batch. This is in-process native integration. A later packaged smoke verified URL registration, successful LaunchServices request acceptance for new and running instances, and one application process. Packaged text/caret state was not observed; complete end-to-end position verification still requires desktop access.

```sh
scripts/swift.sh test --filter LaunchRequestTests
sh -n scripts/theonlypad
scripts/theonlypad --help
```
