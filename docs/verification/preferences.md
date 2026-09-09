# Preferences verification

Date: 2026-09-09. Native compilation and unit tests ran on Apple Silicon macOS.

## Implemented

- `EditorSettings` defines system/light/dark appearance, font family, 8–36 point font size, wrapping, and 2–8 space tab width. Defaults use a 13-point system monospaced font, system appearance, wrapping, and four-space tabs.
- `SettingsStore` performs bounded synchronous I/O for use away from the UI thread. Preferences live in a dedicated `Preferences/Settings.json` beneath the application state directory, honoring `THEONLYPAD_STATE_DIRECTORY`. New directories are private. Symlink files/directories are refused.
- Version-1 JSON contains `version` and `settings`. Its settings object requires `theme`, `fontSize`, `fontName`, `wrap`, and `tabWidth`. Version 0 contains `version`, `fontSize`, and `wordWrap`, migrating the latter fields and supplying defaults for newly introduced properties. Export always emits version 1.
- Imports reject unknown versions, unknown or missing fields, bad field types, invalid ranges, and files over 1 MiB. `importData` only decodes; callers save explicitly after validation. Malformed saved settings raise errors; defaults apply automatically only when no file exists. Failed validation leaves the previous file untouched.
- `PreferencesController` supplies searchable native controls, installed-font selection, automatic persistence, explicit JSON import/export, and confirmed reset. Disk I/O runs in detached tasks. Controls are disabled during writes. Changes reach `onApply` only after persistence succeeds. An unavailable imported font produces an explicit error. User-facing window strings use localization-ready string construction.

## Tested

`scripts/swift.sh test --filter SettingsTests --scratch-path .build/preferences` built the native preferences window and passed the initial six store tests. Coverage: absent defaults; customized save/reload; version-zero migration; unknown versions/fields; incorrect types and ranges; failed save/import preservation; export round trip; reset; corrupt persisted settings.

The first run observed the expected missing `SettingsStore`/`EditorSettings` compilation failure before implementation. Subsequent compilation temporarily waited for the independently implemented preferences and editor-application interfaces, then passed with the real implementations.

Fresh result after adding private-directory, symlink-file and size/missing-field checks: **8 tests passed, 0 failures**, 2026-09-09. `git diff --check` also passed.

## Outstanding

This subsystem report does not claim GUI execution. Root integration owns menu access, applying preferences to live/new editor windows, startup loading, and packaged GUI verification of search filtering, controls, file panels, reset, appearance and persisted restart behavior. Font availability is a native concern: core JSON validation preserves arbitrary valid font names, while the native import UI requires an installed font.

Settings do not contain documents or credentials. The store does not provide concurrent cross-process compare-and-swap or automatic merge of separate preferences writers. An unsupported schema is not silently downgraded.
