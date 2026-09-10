# New-window chooser verification

Source: `55a7b1bb9ee50b6ea5f94b64cae5657a25e9dd5b`. Task3 is implemented, locally tested and independently approved for specification and code quality with no findings. Committed-source integration and local packaging also pass; see [integrated evidence](new-window-integrated.md). This records hidden native behavior, not desktop acceptance.

The real File → Move Document to Window command offers typed existing-window and New Window destinations. Availability is an owner-supplied display hint; acceptance repeats authoritative checks. A single-window workspace can move its selected editable document without creating a second document. Disabled New Window choices refuse even programmatic confirmation, and existing destinations remain usable at the aggregate window limit. Cancellation consumes the chooser without creating an endpoint.

Only the owner's settled actual destination can be presented. Owner identity, newer chooser, quit entry including veto, exact endpoint, assignment and selected-document checks fence late completion. Restored and retained failures use the document-error flow; a retained endpoint loss is repaired through the real Retry Session Recovery Save command without resurrecting a consumed presentation request.

## Evidence

- `scripts/test-document-move-destination.sh`: 15 tests, zero failures, 1.653 seconds.
- `scripts/test-native-application-document-transfer.sh`: 12 tests, zero failures, 2.074 seconds.
- `scripts/swift.sh build --scratch-path .build/new-window-chooser`: actual application build passed, 8.54 seconds.
- Scoped strict Swift formatting, runner syntax, public-source and whitespace checks passed.

The chooser tests exercise real controls and actual owner dispatch. They verify one model/storage/undo authority, no factory calls, ordinary Unicode edits after capture and undo/redo, once-only presentation, capacity changes, stale ownership, new chooser/quit/owner fences, cancellation, real preparation failure, real hidden destination loss, and actual recovery retry. The runner records frozen source hashes and explicit test-only observation/access transformations. No transfer results or native transfer ports are replaced in these chooser tests.

The first behavioral red had four tests and one failure: the real single-window chooser lacked New Window. A later retained-failure fixture incorrectly changed pane state after settlement; its eight failed assertions were retained, diagnosed, and replaced with actual hidden endpoint closure. These fixture failures are not classified as product defects. Final source manifests match the committed production sources.

Private evidence: `.local/task3-source-freeze.json`, `.local/task3-evidence.json`, `.local/document-move-destination-tests/run.nYaZz7v4`, and `.local/native-application-document-transfer-tests/run.Tzz4clkC`. Raw logs and synthetic state remain ignored.

## Limits

The console is locked. Visible chooser layout, physical focus/keyboard/menu behavior, VoiceOver, Retina, packaged launch and normal desktop quit/relaunch remain unverified. Independent document groups, streaming transfer and the remaining full F-02 clauses are outstanding. No new dependency, publication, Developer ID signing or notarization is involved.
