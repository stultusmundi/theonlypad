# Native document factory verification

An immutable preparation seed and a MainActor factory initialize unregistered EditorDocument models for scratch, open, restored session, backup, disk copy, duplicate, reopened clean history and legacy recovery sources. Decoding and position validation belong on preparation workers; the factory performs model setup without window attachment, file monitoring or recovery submission. Existing controller creation routes remain unchanged pending intake integration.

Root independently ran `scripts/test-document-factory.sh .build/adoption-close-integrated/arm64-apple-macosx/debug`. The factory harness passed 115 checks and the unchanged shared-pane ownership harness passed; both compilation and runtime exited zero. Retained snapshot: `.local/document-factory/run.S9SZhoVI`; summary: `.local/document-factory-root.log`. Platform: ARM64 macOS 26.6.2/Swift 6.3.3, Swift 5 mode. These hidden AppKit model tests do not show or activate windows.

Coverage includes exact Unicode/EOL text, saved baselines, encoding/BOM, source paths, manual language, bookmarks, pane presentation, clean-history validation, no copied recovery authority, scalar limits and URL-less recovered content even with an informational original path. Initial behavioral red failed nine factory paths. A later focused invalid-history-bookmark test failed before its fix; its final 115-check rerun passed. Earlier fixture compilation failure is retained separately. Independent root source review was clear.

Seed limits are per payload, not aggregate process admission. The process retains responsibility for its 100-million-UTF16/400-MB startup estimate and 100-MB input limit. No factory latency benchmark, native intake/close routing, desktop workflow or packaged app acceptance is claimed.

## Prepared restoration and display-name detection

The expanded hidden harness passed 122 checks plus the unchanged shared-pane ownership control. Root reran `scripts/test-document-factory.sh .build/native-ownership-integrated/arm64-apple-macosx/debug`; compilation and runtime exited zero in `.local/document-factory/run.muomEb3i`. Seven behavioral failures preceded the fix. Encoded restoration decodes once and retains the same saved baseline and presentation. Backup, disk-copy and recovery seeds detect language from their final display name, with filename precedence over shebang detection and manual overrides preserved. Independent review found no material issue. This does not validate native controller routing or desktop interaction.
