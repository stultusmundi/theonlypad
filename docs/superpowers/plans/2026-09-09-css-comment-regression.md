# CSS comment regression

Requirement D-01. The existing shared slash-comment set incorrectly includes CSS in line-comment handling, coloring the remainder of an unquoted HTTPS URL as a comment. CSS comment syntax is block-only; see [CSS Syntax, consume comments](https://www.w3.org/TR/css-syntax-3/#consume-comments). The native comment command already has the correct language distinction.

Plan: add a failing synthetic CSS URL fixture requiring only the real block comment to be colored. Preserve multiline CSS block comments and both Swift comment forms with neighboring assertions. Separate line/block language sets without changing the token API, engine choice or lexical scope. Run `scripts/swift.sh test --filter LanguageTests`, strict formatting and the complete core suite when integration source is stable.

Implementation: split the slash line/block language sets. The new CSS URL regression failed before the fix (the URL suffix was colored as a comment), while neighboring block/Swift assertions passed. Targeted validation after the fix is recorded below. No claim of complete CSS grammar support follows from this fix.

Targeted red–green evidence: `scripts/swift.sh test --filter LanguageTests` first ran nine tests with one expected CSS URL failure, then all nine passed after the language-set fix (2026-09-09 15:48:57). Full core and packaged coloring checks remain pending integration.

Full core192 and full native integration suite subsequently passed. Updated package generated; no separate physical CSS coloring workflow claim.
