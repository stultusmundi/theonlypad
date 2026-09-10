# New-window transfer handoff — 2026-09-10

Source commit: `1c96b99e424caae18a9f9d1999fe7bf02c515e7f`. Implementation and hidden/native verification are complete for this internal handoff task; independent specification/code review is pending. The product chooser is still outstanding. This is not complete F-02 or desktop acceptance.

## Implemented

The prepared destination hands the existing model to the ordinary transfer coordinator. The wrapper retains the real inner transfer ID and an additional publisher pause across failures, endpoint reconstruction and waiter cancellation. Generic new operations remain gated while exact inner cleanup and later edits can proceed. No destination scratch buffer, decoding, document factory/adoption or disk copy is used for the move.

Trusted terminal receipts record the inner outcome and registry revision before public callbacks. Unused-window cleanup validates exact identity, assignment, emptiness and history; changed or unrelated replacements are retained rather than deleted. Retry continues the same inner transfer. A failed successor constructor remains retryable without inventing another transaction. The provisional destination and its recorded successors stay unannounced; ordinary source-window replacement preserves its existing behavior.

## Verified

| Check | Result |
| --- | --- |
| New-window preparation and handoff | 44 tests, zero failures; 8.143 seconds |
| Existing-window transfer, including rich two-pane neighbor case | 12 tests, zero failures |
| Process transfer and terminal receipts | 17 tests, zero failures |
| Native document owner | 9 tests, zero failures |
| Native transfer projection | 9 tests, zero failures |
| Actual application build | Passed; 8.53 seconds |
| Monitor bridge/service/application assertions | 142 + 29 + 26 checks passed |
| Hidden native monitor lifecycle | Passed |

Tests cover same model/storage/undo/panes, UTF-16LE/BOM bytes, pins/bookmarks/source neighbor, recovery identity, file monitoring, real paired publication before/after held capture, two exact pause leases, cancellation, callback reentry, populated/replaced cleanup refusal, endpoint loss and same-ID retry. The five source-recording compatibility snapshots match final production hashes. Scoped strict formatting, shell syntax, whitespace and public-source checks pass. No broad core rerun is claimed for this task.

Commands are recorded in the private implementation report and established runners: `scripts/test-native-new-window-transfer.sh`, `scripts/test-native-application-document-transfer.sh`, `scripts/test-application-document-transfer-process.sh`, `scripts/test-native-application-documents.sh`, `scripts/test-editor-transfer-projection.sh`, and `scripts/swift.sh build --scratch-path .build/new-window-handoff`. The bridge/lifecycle runners used that verified debug build.

Private source/evidence manifests: `.local/task2-source-freeze.json`, `.local/task2-evidence.json`. Final runs: new-window `run.K7UGF0oh`, existing-window `run.hJpFTwAy`, process `run.hLVeRcuX`, owner `run.J9a8TtMy`, projection `run.o3pmZ5vd`. Raw diagnostics and synthetic files remain ignored.

## Pane geometry regression

Both transfer paths exposed an existing strict-validation mismatch for a fractional split layout. The raw captured and actual origin were unchanged; the old expected value applied scroll constraints without the backing-pixel alignment performed by the native setter. Final expectation uses the original receipt, actual host membership, scroll constraints and valid four-option nearest backing alignment. Unhosted panes retain raw original coordinates. Exact equality and the original selected-pane restoration remain; no tolerance, alternative-value acceptance or receipt recapture was added. A persistent unrelated scroll displacement is still rejected, and original-ID rollback retry succeeds after restoring the expected geometry.

The initial all-view restoration experiment was removed. Incomplete origin-only alignment options were also removed: an isolated Foundation control directly throws an invalid-argument exception for them, while complete origin-and-size options succeed. Intermediate XCTest abort symptoms, diagnostic experiments, fixture compilation mistakes and actual behavioral reds are distinguished in the private report. The observations used backing scale 1; they do not establish physical Retina or multi-display acceptance.

## Outstanding and blocked

Independent review must finish before the next task exposes New Window in the destination chooser and connects final generation-fenced presentation. Groups, streaming transfers and remaining F-02 clauses remain outstanding. No visible windows, keyboard input, XCUITest, VoiceOver, performance benchmark or packaged runtime acceptance was performed here. The console remains locked. Current local package is still source `324a3de`, not this commit; no signing/notarization or publication claim is made.
