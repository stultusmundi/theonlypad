# Document applied-settings verification

Task1 of the [pane restoration remedy](../superpowers/plans/2026-09-10-pane-restoration-remedy.md) is implemented, independently reviewed and verified with hidden native tests on macOS (2026-09-10). Preferred-responder restoration, eager-layout eligibility and packaged desktop acceptance remain separate tasks.

Each document now records proven typography and effective wrap separately from its window's desired settings. Equal and theme-only settings avoid native typography writes; manual wrap returns to the window default on the next accepted settings application. Transfer preserves source styling, including unknown applied state, until a subsequent destination settings application reconciles it. New and reused panes inherit styling under the same configuration authority.

A synchronous token excludes native edits, marked text, undo, selection/focus, pane commands and close/transfer capture during configuration. Proof is published only after endpoint, policy, document state and pane-attachment checks succeed. Transfer validation compares complete live state; only the exact configuration owner's temporary busy flag is excluded. Geometry reconstruction and replacement receipts retain original applied state and window policy.

## Verified results

| Check | Result |
|---|---|
| Applied settings and native admission | 24 tests passed |
| Existing native document transfer | 12 tests passed |
| Existing controller projection/retry/rollback | 9 tests passed |
| Native close model | 106 checks passed |
| Document factory | 133 checks passed |
| Shared pane ownership | 1 complete scenario passed |
| Pure native coordinator contracts | 28 tests passed |

The close runner also built the complete frozen application. All 15 native stage receipts, source/core inventories and hashes, and three native executable hashes were independently checked against the reviewed source. Scoped formatting, shell/Python syntax, public-source and whitespace checks passed.

Proven commands:

```sh
scripts/test-document-applied-settings.sh
scripts/test-native-document-transfer.sh
scripts/test-editor-transfer-projection.sh
scripts/test-native-close-model.sh
python3 -m unittest discover -s Tests/NativeIntegration -p test_native_regressions.py
```

The native coordinators freeze inputs and call the accepted watchdog in the same process. Do not add another session-owning watchdog around them. The zero-argument close runner builds its own matching application. See [runner verification](native-regression-runners.md) for the optional prebuilt-artifact prerequisite.

## Regression and review evidence

The initial behavioral red run produced 12 failures across five tests: redundant writes/origin movement, admitted edits during a setter, lost pane styling, stale proof and empty-destination policy acceptance. Subsequent tests inspect effective native font, paragraph, typing and storage values; fallback/named fonts; size/tab changes; both-pane inheritance; manual wrap; differing-policy transfer; and blocked/late settings delivery.

An intermediate next-turn origin failure also occurred without any settings call: the fixture's artificial frame resize queued unrelated layout. That failed control is retained. The corrected fixture uses actual native geometry and separately tests no-settings and unchanged/theme-only cases. Both establish literal vertical origins 240/940 and retain them immediately and after the next main-queue callback, with zero typography setters. Its explicit small-document layout is correctness setup, not performance evidence.

Independent review found two remaining post-callback admission gaps. A callback could start configuration before direct nested undo or delegate edit admission completed. Concrete red tests produced three failures across 24 tests; shared post-callback guards then passed all 24. Ordinary undo already refused on this host through a later nested-group guard and is recorded as a positive control, not a reproduced failure. Re-review approved the corrections. Intermediate full-state, unknown-wrap-proof and transient-warning transfer regressions were also resolved without weakening the existing retry/rollback tests.

All native setter probes and private-access extensions are added only to frozen test copies. Five legacy selective source lists received the new type mechanically and were syntax-checked, but those individual legacy runners were not separately executed. Raw receipts and synthetic state remain ignored and private.

No shown-window, physical input, packaged desktop or performance acceptance is established here. Changed-typography cost remains unmeasured; no eager-layout ceiling or timing bound is claimed. No production focus or origin-layout behavior was promoted in Task1.
