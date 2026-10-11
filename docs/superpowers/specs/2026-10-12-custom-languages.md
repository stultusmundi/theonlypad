# Custom languages and editing policy

Status: reviewed design; implementation in progress. This addresses D-04 and
the language policy clauses of B-02/B-04. It does not establish feature acceptance.

Use original, declarative literal rules: names, extensions, identifier keywords,
line/block comment delimiters, quote delimiters and optional decimal highlighting.
Profiles cannot execute code or supply regular expressions. Existing built-in
language detection and editing behavior remain the default. The existing
extension framework remains a separate feature.

Custom profiles have stable UUIDs. Immutable catalog snapshots carry a generation;
resolved profiles carry definition revisions. Manual selection preserves a missing
UUID and visibly falls back to plain text. Automatic detection prefers a known
built-in extension, then a custom-owned unclaimed extension, then the detected
fallback. Manual custom selection can override the filename. Conflicting
extension ownership and duplicate IDs are rejected. Literal identity uses exact
UTF-16 units, including normalization-distinct comment and quote delimiters.

Limits: 64 definitions per catalog; 1 MiB catalog; 64 KiB definition; 80 Unicode
scalars per name; 16 lowercase ASCII extensions of at most 16 bytes; 1,024 keywords
of at most 64 UTF-16 units and 32,768 aggregate units; 32-unit comments; four quote
rules with 16-unit delimiters; one ASCII escape character; indentation width 1–8.
JSON parsing rejects duplicate keys, unknown fields, malformed Unicode and types,
and preserves numeric spelling. Parsing is bounded by depth 16 and value budgets
of 8,192 for an import and 100,000 for a catalog. Extracting shared JSON mechanics
must preserve the exact existing shortcut schema, limits and error behavior.

Store publication follows the existing directory-descriptor, checked replacement
and durability model. Language files additionally require single-link ownership.
Import validates before replacement; failed writes keep the prior catalog active.

The lexer handles at most two million UTF-16 units and 100,000 spans and checks
cancellation at bounded intervals, including inside long comments and strings.
It is lexical highlighting, not semantic intelligence. Larger documents retain
their existing large-file restrictions.

Native editing uses the resolved comment and indentation policy for Tab,
indent/outdent and comment commands, preserving native grouped undo. Enter
auto-indentation is outside this design and is not implied. Requested global
settings, effective language policy and successfully applied native settings are
distinct values. Transfers and new panes must retain the actual applied receipt.

Selection survives recovery, reopening, duplication and transfer. Introduce a new
session version only when custom selection requires it; preserve legacy readers
and their existing compatibility fixtures. Stale catalog/highlighting callbacks
cannot apply an old policy or authorize an edit.

The manager and picker must perform actual create/edit/delete/import/export and
selection operations. Register the manager command only with its working native
implementation. Missing profiles and refused imports require actionable messages.
Desktop tests and a newly packaged app remain mandatory acceptance gates.
