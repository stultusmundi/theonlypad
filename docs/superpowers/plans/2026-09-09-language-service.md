# Language identification and lexical highlighting

Spec: ../specs/2026-09-09-architecture-design.md. Foundation-only service; native color application follows as separate integration. No semantic-intelligence claim.

- [ ] Failing tests for filename/shebang detection, comment/string/keyword/number token ranges, JSON formatting errors and roundtrip.
- [ ] Implement `LanguageService.swift`: explicit support list and scalar-safe NSRange spans, bounded input and lexical scanning via regex with priority comments/strings, no remote grammar or assets. JSON formatting via JSONSerialization and sorted keys.
- [ ] Verify `scripts/swift.sh test --filter LanguageTests`. Inspect overlap rules; no highlights for plain text; refuse overly large analysis to preserve UI responsiveness.
- [ ] Native adapter applies colors to visible/small documents on worker results guarded by revision identity; larger files retain plain editing until incremental parser implemented.

Outstanding: incremental parser, folding/completion/snippets/outlines, user grammars, language-specific syntax beyond the documented lexical subset.
