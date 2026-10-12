# Custom-language core checkpoint — 2026-10-12

The core now contains validated literal language definitions, stable custom UUIDs,
built-in editing overrides, strict bounded definition JSON, and a catalog resolver.
Automatic selection preserves built-in extension precedence; manual custom
selection uses the UUID. A missing custom UUID retains its reference and resolves
to safe plain text with a warning. Comment and quote equality compares exact
UTF-16 spelling, including canonically equivalent but distinct delimiters.

This is original MIT-licensed code with no new dependencies or assets. The shared
JSON parser preserves the existing shortcut decoder's limits and error behavior.
At this first checkpoint the catalog represents drafts. The subsequent
[store and lexer checkpoint](custom-languages-components.md) implements installed
definition revisions and supersedes the store/lexer outstanding states below.

The original isolated component baseline completed 21 tests with 109 ordinary
assertion failures. A subsequent implementation run completed 76 tests with one
unexpected error: an equality fixture used identical line and block openers,
contrary to the specified ambiguity rejection. The reviewed fixture correction
checks line and block identity separately in valid definitions, preserving the
independent equal-opener rejection. The corrected frozen run passes 76 tests with
zero failures and warnings. Independent source review covers the implementation
and fixture correction.

After adoption and formatting, the actual application package builds and passes
77 selected tests with zero failures and warnings. Its source inventory remains
unchanged across that run. Formatting lint, public-source checks and diff checks
also pass. The selected tests include the 21 new component cases and existing
language, editing and shortcut compatibility checks; this is not a full-suite run.

Reproduce the focused selection:

```sh
scripts/swift.sh test --filter 'LanguageProfileTests|BoundedProfileJSONTests|LanguageTests|LanguageEditingTests|Shortcut'
```

The recorded runs use the checked-in owned-process watchdog with finite deadlines
and synthetic state. Raw receipts remain ignored. The separate manager-command
baseline still fails and is not adopted as a shipped command. Durable catalog
persistence, the custom lexer, native editing policies, language management UI,
session and transfer integration, and desktop acceptance remain outstanding.
Passing these components does not establish D-04 completion.
