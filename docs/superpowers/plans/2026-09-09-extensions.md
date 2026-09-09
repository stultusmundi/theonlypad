# Declarative extensions plan

Planned: a strictly bounded version-1 local extension manifest/catalog, a native manager, and an original sample. Extensions declare existing text transformations; they cannot execute scripts, access files/network, or load native libraries.

1. Write real-file tests for disabled installation, capability/version rejection, symlinks, corruption preservation, enable/disable/uninstall and command execution; observe missing implementation failure.
2. Implement strict manifest/catalog validation, private state, process-serialized atomic mutations and bounded reads. IDs/names never become filesystem paths.
3. Implement native capability disclosure, installation, enable/disable/uninstall and explicit command callbacks. Root owns editor/menu integration.
4. Include a sample and document trust boundaries. Run `scripts/swift.sh test --filter ExtensionCatalogTests --scratch-path .build/extensions`; compile the native manager. Record actual verification separately from GUI claims.

## Implemented

The catalog, strict manifest validation, disabled installation, enable/disable/uninstall, native capability disclosure and command callback are implemented. The manager installs the exact inspected immutable manifest and revalidates command availability before dispatch. `onChanged` notifies the root command registry after every successful or failed reload/mutation. The original example and schema/trust documentation are in `Examples/CleanupExtension` and `docs/extensions.md`.

## Tested

On 2026-09-09, `scripts/swift.sh test --filter ExtensionCatalogTests --scratch-path .build/extensions` built the integrated native application and passed **9 tests, 0 failures**. The first test run had observed the expected missing-type failure. Coverage includes the actual bundled sample, disabled defaults, enable/disable/uninstall, command execution, duplicate-install protection, versions/capabilities/executable-field rejection, sizes/command limits, private permissions, symlinks, invalid IDs, corrupt/unknown-field preservation, and installation of the exact manifest reviewed before a source-file change.

`Tests/NativeIntegration/ExtensionHarness.swift` was compiled against the tested PadCore objects and real `ExtensionManagerController`, then executed with synthetic text and a fresh temporary `THEONLYPAD_STATE_DIRECTORY`. It passed install → enable → actual native Run button callback → disabled Run control → uninstall, exit 0. This tests real AppKit controls and the manager callback, rather than a mock. `git diff --check` passed.

## Outstanding verification

Root integration owns registry/menu/palette dispatch, target-document behavior, native undo and packaged interaction with the install file picker and disclosure sheet. The isolated manager harness does not prove those additional workflows or an external extension code sandbox. The implementation intentionally supports only declarative built-in text transformations; arbitrary executable extension code is outside this API.
