# Preferences implementation plan

Planned: a versioned settings store and searchable native preferences window, with explicit import/export/reset actions. Theme, font family, font size, wrapping and tab width are stored in a dedicated Preferences subdirectory, separate from recovery snapshots.

1. Write store tests for defaults, persistence, schema migration, malformed fields, unknown versions/keys, and export/reset. Observe missing implementation failure.
2. Implement strict version-1 JSON envelopes. Version 0 accepts `fontSize` and `wordWrap`, migrating other settings to defaults. Reject unknown fields rather than silently discarding them. Verify real temporary files.
3. Implement AppKit controls, search filtering, import/export panels, reset and asynchronous persistence. Valid font-size range is 8–36 points; tab width is 2–8. UI steppers constrain the ranges; imported out-of-range data is rejected explicitly.
4. Run `scripts/swift.sh test --filter SettingsTests --scratch-path .build/preferences` and build native integration. Record implemented/tested/unverified separately in `docs/verification/preferences.md`.

Root owns application menu integration and applying settings to editors. Native interactions require GUI evidence independently of unit tests.
