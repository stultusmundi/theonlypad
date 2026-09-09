# Native document factory execution

Scope: [factory specification](../specs/native-document-factory.md). Controller/AppDelegate routes remain unchanged.

1. **Complete:** immutable bounded seeds and hidden factory harness; initial fixture compile failure retained separately.
2. **Complete:** behavioral red against throwing factory seam: nine positive initialization cases failed; unchanged shared-pane control passed.
3. **Complete:** model setup implementation; initial 114 checks passed.
4. **Complete:** mismatched history bookmarks observed red (115 checks, one failure), then exact validation fix.
5. **Final tests complete; root source review clear:** 115 checks and unchanged shared-pane ownership passed; both compiles/runtimes exited0. Strict formatting, shell syntax and diff checks passed.
6. **Deferred:** process intake, aggregate reservations, registry projection, routing activation and disk-copy handoff integration. No fake callback surfaces are installed.

Retained command:

```sh
bash scripts/test-document-factory.sh [existing-debug-build-path]
```

With an existing debug PadCore path, the runner snapshots exact native model/factory sources and linked object/module hashes into a unique ignored directory. Without one, it builds actual debug core first. Swift 5, host macOS 14 target, 120-second owned compile watchdog and 30-second hidden runtime watchdog. It also runs the unchanged SharedPaneOwnershipHarness. No GUI activation or events.

Private evidence: initial compile `run.JGGZvyQG`; factory red `run.MSowefMZ`; initial green `run.TIZ25pIS`, under `.local/document-factory`. Bookmark red: `run.upHmjnp1`; final115+shared green: `run.BGkIVNQa`. Root independent hidden integration rerun is separate from these results.

Root independent rerun passed 115 checks plus unchanged shared-pane control in `run.S9SZhoVI`; source review clear. See [verification](../../verification/native-document-factory.md).
