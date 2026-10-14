# Readonly folder preview native component

Development source contains a native readonly preview panel and a shared worker
lane. Its fixed component command passes 27 tests: eleven worker contracts and
sixteen hidden panel contracts. The folder-search entry and application command
routing are still private candidates; this component does not yet provide a
new user-visible workflow in the application.

The worker invokes the actual bounded Core preview off the main thread. It
admits one request per shared lane and retains that admission until work and
its exact settlement finish. Cancellation suppresses publication without
pretending that a filesystem operation has stopped. Closed recipients can
retire their original request but cannot publish results or reopen a window.

The panel preserves raw literal inputs and selected URLs. It supports one or
two saved UTF-8 files, empty replacement, case and whole-word options. It shows
complete byte and match counts, BOM/change facts and bounded original/proposed
excerpts. Four excerpts retain at most 64 KiB of UTF-8 rendering text; that is
not a measured process-memory limit. Replacement anchors refer to original
match positions, including deletion; they do not search the proposed output.
There is no Apply or file-writing action.

The original ten panel contracts passed before six added regression contracts
failed. Those failures reproduced older chooser cancellation overwriting a
newer intent, an older thrown error replacing newer work presentation, and
table selection disagreeing with the excerpts. The reviewed intent and
selection fixes pass all sixteen unchanged contracts. Actual Core-backed tests
also verify saved bytes and synthetic filesystem inventories after success and
refusal. Injected chooser timing is not actual picker or permission evidence.

The eleven worker and sixteen panel tests then passed together in one process.
Public formatting preserved imports, literals and test contracts, with only
formatting trivia and optional trailing array commas changed. The public fixed
runner also passes all 27 tests with zero failures or skips and warning-free
output. It deliberately does not request warnings as errors; the earlier
private component and full application verification do.

The fresh full application snapshot passes all 1,203 default SwiftPM tests and
builds the actual app and helper with warnings as errors. It freezes 591 inputs
and compiles 306 objects, including the two new native source files. The separate
27-test command is not part of that default count. Repository strict formatting
and public-source checks pass. This is original MIT code with no new dependency
or asset.

Run the closed component command directly; it owns its watchdog and accepts no
arguments or caller-selected artifacts:

```sh
scripts/test-folder-replacement-preview.sh
```

Never nest another process-group watchdog around this command. Raw synthetic
inputs, captures, source inventories and process receipts stay under ignored
`.local/folder-replacement-preview-integration/`. Historical declaration,
compiler and behavioral failures remain retained separately.

Pending work includes the folder-search entry, parent lifetime and tool command
integration; real folder/file pickers and packaged desktop workflows; physical
input and accessibility; broader selection, encoding and performance acceptance.
Apply, durable backups and interrupted multi-file write recovery remain
unimplemented. C-09 remains outstanding. These checks do not establish hard
cancellation, RSS bounds or complete feature acceptance.
