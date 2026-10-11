# Windows plugin incompatibility feedback

2026-10-11, ARM64 macOS 26.6.2, Swift 6.3.3 in Swift 5 language mode; SDK 26.5 and macOS 14 deployment target. This is not a macOS 14 runtime or Intel test.

`ExtensionCatalog.inspect` now rejects an MZ-prefixed input with a specific error explaining that Windows Notepad++ plugin binaries cannot be installed and that declarative JSON manifests are accepted. Classification follows the existing secure bounded read. This two-byte prefix selects a diagnostic; it does not validate PE files or recognize every executable format. Other non-JSON input remains rejected by the parser. Valid JSON is accepted independently of filename.

The extension manager explains the same compatibility limit in its JSON chooser and empty-selection details. The JSON filter, capability disclosure, initially-disabled installation and catalog mutation rules remain unchanged. Help and the extension guide already disclaim Windows binary compatibility.

## Verified

Four new real temporary-file tests supplement the original nine catalog tests. Before implementation, six binary inspect/install attempts produced twelve ordinary missing-message assertions; all other methods and catalog-preservation assertions passed. The unchanged thirteen methods then passed against the independently reviewed implementation.

Coverage includes synthetic `.dll`, uppercase `.DLL`, renamed `.json`, valid JSON renamed `.dll`, truncated signatures, corrupt JSON, symlink refusal and manifest-size priority. Each attempted binary installation preserves existing catalog bytes, entries and enabled commands. No binary is loaded or executed.

After integration and formatting, the actual public manifest built the application and passed all 1,045 tests with zero failures, unexpected errors, skips or compiler warnings. Strict formatting checks for the three changed Swift files and public-source checks passed. Builds/tests ran under the checked-in owned-process watchdog with complete output and cleanup receipts.

The existing unmodified `ExtensionHarness` also passed against the formatted production controller and the matching fifty Core objects: install an enabled synthetic sample, run its real transformation callback, disable it and verify no additional invocation, then uninstall it. The harness uses a prohibited activation policy and shows no window.

A guarded reproduction of the public test suite, using a fresh output directory, is:

```sh
python3 scripts/run-owned-search-tests.py --timeout 180 \
  --output .local/extension-verification/new-run -- \
  scripts/swift.sh test --scratch-path .build/extension-verification
```

Do not nest another session-owning watchdog. Retained raw synthetic evidence is ignored under `.local/extension-windows-plugin-feedback-*` and `.local/extension-windows-integrated-20261011/`.

## Remaining acceptance

Visible chooser text, binary-error presentation, packaged runtime and broader accessibility/desktop acceptance remain outstanding. Catalog tests and hidden controller execution do not establish those results. No new package, publication, notarization, remote push or merge is claimed. Private macro/search candidates are separate from this integrated change.
