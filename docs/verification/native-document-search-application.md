# Managed editor search and application quit — 2026-10-15

Current development source connects the native editor’s Find panel to the managed document-search owner. Source and pane lifetimes fence navigation and approved replacement. AppDelegate owns one quit attempt, prepares native publication, joins search retirement, then awaits external commands before replying to termination. Repeated quit requests share that attempt. These changes are local working-tree implementation; they are not a published release.

Separate current-source verification selections passed and were independently reviewed:

| Command or selection | Result | Scope |
| --- | --- | --- |
| `scripts/test-document-search.sh` | 15 tests, zero failures | Hidden native editor binding, navigation, admission, replacement and quit presentation |
| `scripts/test-document-search-app.sh` | 4 tests, zero failures | Hidden actual application routing and owned quit, with a scripted search backend |
| `scripts/test-managed-documents.sh` | 73 tests, zero failures | Neighboring managed startup, intake, open, close and admission |
| `python3 -B -m unittest discover -s Tests/NativeIntegration -p 'test_*.py'` | 76 checks, zero failures/errors | Pure runner controls; launches no native test |
| Frozen default package, warnings as errors | 1,203 tests, zero failures | Default tests plus actual app/helper compilation and linking |

Counts overlap or cover different invocations and must not be added. Native commands freeze production sources and append explicit test-only access extensions. Each owns its existing watchdog directly; never nest another process-group watchdog. No shown window, physical key-window/responder behavior or current packaged desktop acceptance follows from these selections.

## Actual helper integration

A separately frozen hidden application test passed one case with the real default search owner, driver, fixed bundled helper and tiny synthetic Unicode input. It exercised Find result navigation, approved Replace All, native undo/redo, native session publication, one original quit-task join and actual external-command settlement. Root verified complete captures, natural exit, current source bindings, compiler/link artifacts and unchanged helper bytes. Independent actual-run review accepted the scoped result. This is a local experiment rather than a new public runner command.

The helper was copied without rewriting from a previously accepted build whose 101 relevant production sources still match current source. The synthetic bundle used a fixed resolver layout; this does not establish the installed application’s `Bundle.main` packaging. Terminal `noChild` establishes settled absence, not a literal per-generation PID/reap receipt. Hard regex containment, allocation/RSS bounds and performance remain unverified by this test.

## Unresolved native long-line failure

The corrected legacy PaneSave compiler passed, but its first native case with 2,000,001 ASCII characters was killed by macOS under memory pressure (signal 9 / exit 137). It was not a watchdog timeout. Buffered empty output does not establish which original assertions ran. The source-level allocation cause remains unknown; the other 26 native cases and three compile stages were not entered. Kernel memory-pressure diagnostics are not measured application RSS.

A separate bounded prefix diagnostic compiled and intentionally exited 75 after twelve ordered markers, immediately before loaded text enters native storage. It retained the exact original fixture. Original save, undo and teardown assertions were not entered; this is diagnostic evidence, not a PaneSave pass or a demonstrated memory ceiling. A process address-space cap probe failed before allocation and established no safe cap. The hazardous full native case has not been rerun.

## Remaining acceptance

Continue the bounded storage investigation, repair and run the remaining legacy integrations, and add reproducible helper integration coverage. Distribution artifacts remain at `5672527`; the last actual five-workflow desktop run is historical source `f45f1e9` from 12 October. The desktop is currently locked. Current packaged behavior, physical input, IME, VoiceOver, Accessibility, other supported platforms, memory and full feature acceptance remain outstanding. See [the progress report](../reports/progress-2026-10-15.html) and [the full build brief](../BUILD_PROMPT.md).
